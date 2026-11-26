#!/usr/bin/env bash
# Idempotent data-disk provisioner for a cluster node.
#
# WHY THIS EXISTS
#   The Ubuntu autoinstall manages ONLY the OS disk (EFI + root). The data disk, which holds etcd, the Longhorn
#   fast tier and the general-purpose persistent partition (registry data, other stateful services), is
#   deliberately left out of the installer so that wiping and re-installing the OS can NEVER destroy that data.
#
#   This script creates the data-disk layout ONCE (first boot). On every later boot or re-install it recognises
#   the layout on THAT disk and simply re-mounts it, so data survives OS re-installs. See docs/node-setup.md.
#
# WHICH DISK
#   Only the disk whose udev ID_SERIAL equals DATA_DISK_SERIAL (required, no default). Device names such as
#   nvme0n1 are not stable across boots, and "the largest other disk" can be an unrelated volume, so neither is
#   ever used. Exactly one disk must match. The root disk is never accepted.
#
# LAYOUT (labels are the stable contract; mount points key off them, mounts use the partitions' UUIDs):
#   LABEL=etcd           -> /var/lib/etcd          (control-plane state)
#   LABEL=longhorn-nvme  -> /var/lib/longhorn-nvme (Longhorn fast tier)
#   LABEL=persistent     -> /var/lib/persistent    (registry data + future services)
#   Only partitions of the selected disk are considered. The same labels on ANOTHER device (for example a disk
#   from an earlier install) are reported and ignored.
#
# CONFIG
#   DATA_DISK_SERIAL Required. udev ID_SERIAL of the data disk.
#   ETCD_SIZE        etcd partition size            (default: 50G)
#   LONGHORN_SIZE    Longhorn fast-tier size        (default: 150G)
#   REGISTRY_UID     Owner uid for the registry dir (default: 1000)
#   REGISTRY_GID     Owner gid for the registry dir (default: 1000)
#   WIPE_DATA_DISK   0 (default): refuse to touch a disk that holds unrecognised data (data-loss guard).
#                    1: allow erasing UNRECOGNISED data on the named disk (for example an older install). A layout this script
#                       created is never erased by 1, so re-running a failed bootstrap with the flag still set is safe.
#                    force: erase and rebuild even a layout this script created (DESTROYS its data).
#                    It only ever applies to the disk named by the serial.
#
# Idempotent and safe to re-run.

# Stop on any error, unset variable or failed pipe. Exit codes: 0 on success (provisioned or already present), 1 on any refusal or failure.
set -euo pipefail

# info <message>: a progress line.
info() { echo "  [data-disk] $*"; }
# ok <message>: a step that succeeded.
ok()   { echo "  [OK] $*"; }
# warn <message>: something to see that does not stop the run.
warn() { echo "  [WARN] $*" >&2; }
# die <message>: report the failure and stop with status 1.
die()  { echo "  [FAIL] $*" >&2; exit 1; }

# The serial has no default: without it the script refuses to run.
DATA_DISK_SERIAL="${DATA_DISK_SERIAL:?DATA_DISK_SERIAL is required (udev ID_SERIAL of the data disk)}"
# The tunables, each with its documented default.
ETCD_SIZE="${ETCD_SIZE:-50G}"
LONGHORN_SIZE="${LONGHORN_SIZE:-150G}"
REGISTRY_UID="${REGISTRY_UID:-1000}"
REGISTRY_GID="${REGISTRY_GID:-1000}"
# The data-loss switch (see CONFIG above): 0, 1 or force.
WIPE_DATA_DISK="${WIPE_DATA_DISK:-0}"
# Any other value is refused, so a typo can never mean "erase".
[[ "${WIPE_DATA_DISK}" =~ ^(0|1|force)$ ]] || { echo "  [FAIL] WIPE_DATA_DISK must be 0, 1 or force" >&2; exit 1; }
# Where the kernel lists block devices (overridable so the tests can use a fake tree).
SYS_BLOCK="${NP_SYS_BLOCK:-/sys/block}"
# The three partition labels and the mount points that belong to them, in order.
LABELS=(etcd longhorn-nvme persistent)
MOUNTS=(/var/lib/etcd /var/lib/longhorn-nvme /var/lib/persistent)

# Test seam: tests may export their own np_is_block (there are no block devices in a container).
declare -F np_is_block >/dev/null || np_is_block() { [[ -b "$1" ]]; }

echo "==> 00-data-disk: provisioning persistent data disk"

# The serial must have the same shape the configuration schema allows, which contains no glob character.
[[ "${DATA_DISK_SERIAL}" =~ ^[A-Za-z0-9._:+-]{4,128}$ ]] || die "DATA_DISK_SERIAL is not a valid serial"

# ── Resolve the data disk by serial ─────────────────────────────────────────────
# Look at every physical block device (skipping loop, RAM, optical, floppy, network, device-mapper and RAID devices) and count the ones whose serial matches.
n=0; DATA_DISK=""
for dev in "${SYS_BLOCK}"/*; do
  name="${dev##*/}"
  case "${name}" in loop*|ram*|zram*|sr*|fd*|nbd*|dm-*|md*) continue ;; esac
  serial="$(udevadm info --query=property --name="/dev/${name}" 2>/dev/null | sed -n 's/^ID_SERIAL=//p')"
  if [[ "${serial}" == "${DATA_DISK_SERIAL}" ]]; then DATA_DISK="/dev/${name}"; n=$((n + 1)); fi
done
# Zero or two matches stop the script before anything is touched.
(( n == 1 )) || die "expected exactly one disk with the configured data-disk serial, found ${n}"
# The match must be a real block device.
np_is_block "${DATA_DISK}" || die "${DATA_DISK} is not a block device"
info "Data disk resolved by serial: ${DATA_DISK}"

# Root disk (never a data-disk candidate): strip the partition suffix from the device backing /.
# The disk that holds `/`: the parent of the device mounted there.
root_src="$(findmnt -no SOURCE / || true)"
root_disk="$(lsblk -no PKNAME "${root_src}" 2>/dev/null | head -1 || true)"
[[ -n "${root_disk}" ]] && root_disk="/dev/${root_disk}"
# The root disk can never be the data disk, even if the serial was configured wrongly.
[[ "${DATA_DISK}" != "${root_disk}" ]] || die "Refusing to use the root disk (${root_disk}) as the data disk."

# Partition device names: NVMe/mmc use a 'p' separator, sd*/vd* do not.
# NVMe and MMC disks name partitions with a `p` before the number, SATA and virtio disks do not.
if [[ "${DATA_DISK}" =~ [0-9]$ ]]; then P="p"; else P=""; fi
# part <n>: the device name of partition n of the data disk.
part() { echo "${DATA_DISK}${P}$1"; }
# label_of <device>: the file-system label on a device, or nothing.
label_of() { blkid -s LABEL -o value "$1" 2>/dev/null || true; }

# ── Is the layout already present ON THIS DISK? ─────────────────────────────────
# The layout is "present" only when partitions 1 to 3 of THIS disk carry the three labels in order.
layout_present=0
if [[ "$(label_of "$(part 1)")" == "${LABELS[0]}" && "$(label_of "$(part 2)")" == "${LABELS[1]}" \
      && "$(label_of "$(part 3)")" == "${LABELS[2]}" ]]; then
  layout_present=1
fi

# A present layout is only re-mounted (unless `force` was given).
if (( layout_present )) && [[ "${WIPE_DATA_DISK}" != force ]]; then
  info "Layout already present on ${DATA_DISK}; will mount only."
  [[ "${WIPE_DATA_DISK}" != 1 ]] || info "WIPE_DATA_DISK=1 erases only unrecognised data: the existing layout is kept (use force to rebuild it)."
else
  # ── Data-loss guard ───────────────────────────────────────────────────────────
  # The selected disk carries partitions that are NOT our layout: do not touch it unless the operator opts in.
  # Count the partitions on the disk.
  existing_parts="$(lsblk -no NAME "${DATA_DISK}" | tail -n +2 | wc -l)"
  # Unrecognised partitions and no opt-in: stop, and say how to opt in.
  if [[ "${existing_parts}" -gt 0 && "${WIPE_DATA_DISK}" == 0 ]]; then
    die "${DATA_DISK} already has ${existing_parts} partition(s) that are not this layout.
       Refusing to overwrite unrecognised data. Re-run with WIPE_DATA_DISK=1 to
       repartition (DESTROYS all data on ${DATA_DISK})."
  fi

  # ── Create GPT + three partitions with sfdisk (util-linux; always present) ────
  info "Creating GPT layout on ${DATA_DISK} (etcd=${ETCD_SIZE}, longhorn-nvme=${LONGHORN_SIZE}, persistent=rest)"
  # Clear old signatures so no stale file system or RAID label confuses the new layout.
  wipefs -a "${DATA_DISK}" >/dev/null 2>&1 || true
  # The GPT layout: etcd and Longhorn of fixed size, the rest persistent.
  sfdisk "${DATA_DISK}" >/dev/null <<LAYOUT
label: gpt
size=${ETCD_SIZE}, name=${LABELS[0]}
size=${LONGHORN_SIZE}, name=${LABELS[1]}
name=${LABELS[2]}
LAYOUT
  # Tell the kernel about the new partitions and wait for udev to create their device nodes.
  partprobe "${DATA_DISK}" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  # Format each partition with its label.
  for i in 0 1 2; do mkfs.ext4 -q -L "${LABELS[${i}]}" "$(part $((i + 1)))"; done
  ok "Partitions created and formatted (labels: ${LABELS[*]})"
fi

# ── Same labels on another device: report, never trust ──────────────────────────
# Report (never use) partitions on any other device with one of our labels.
for label in "${LABELS[@]}"; do
  while IFS= read -r other; do
    [[ -n "${other}" && "${other}" != "${DATA_DISK}"* ]] && warn "label '${label}' also exists on ${other}: ignored (mounts use the UUIDs of ${DATA_DISK})"
  done < <(blkid -o device -t "LABEL=${label}" 2>/dev/null || true)
done

# ── Mount points and fstab entries (by UUID of THIS disk's partitions) ──────────
# _ensure_fstab <index>: make sure /etc/fstab mounts partition <index+1> at its mount point by UUID. An existing entry for that mount point must already point at the same UUID, or the script refuses to change it.
_ensure_fstab() { # index(0-2)
  local i="$1" dev uuid path="${MOUNTS[$1]}" label="${LABELS[$1]}"
  # The partition's device and its file-system UUID (mounts key off the UUID, never the label or the device name).
  dev="$(part $((i + 1)))"
  uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null || true)"
  [[ -n "${uuid}" ]] || die "no filesystem UUID on ${dev}"
  mkdir -p "${path}"
  # Is there already an uncommented entry for this mount point?
  if [[ -f /etc/fstab ]] && awk -v p="${path}" '$1 !~ /^#/ && $2 == p { f = 1 } END { exit !f }' /etc/fstab; then
    grep -qE "^UUID=${uuid}[[:space:]]+${path}[[:space:]]" /etc/fstab \
      || die "/etc/fstab already maps ${path} to a different source; refusing to change it"
  else
    # A new entry: noatime, and fsck order 2.
    printf '# %s (data disk)\nUUID=%s %s ext4 noatime 0 2\n' "${label}" "${uuid}" "${path}" >>/etc/fstab
    info "fstab += UUID=${uuid} -> ${path} (${label})"
  fi
}
# Add the three entries.
for i in 0 1 2; do _ensure_fstab "${i}"; done

info "Mounting all fstab entries..."
# systemd regenerates its mount units from fstab; then mount everything.
systemctl daemon-reload
mount -a
ok "Data partitions mounted"

# ── Persistent service directories ────────────────────────────────────────────
# /var/lib/persistent is the home for host-path stateful services that must survive OS re-installs. The
# registry subdir is created and owned up-front so a host-path-backed local registry can use it.
# The registry directory, owned by the configured uid and gid and closed to everyone else.
mkdir -p /var/lib/persistent/registry
chown "${REGISTRY_UID}:${REGISTRY_GID}" /var/lib/persistent/registry
chmod 0750 /var/lib/persistent/registry
# Leave a note on the partition for whoever finds it, once.
if [[ ! -f /var/lib/persistent/README ]]; then
  cat > /var/lib/persistent/README <<'README'
This partition (LABEL=persistent) is provisioned by 00-data-disk.sh and is PRESERVED across OS re-installs
(the installer only manages the OS disk). Put host-path stateful data here (e.g. registry/).
See docs/node-setup.md.
README
fi
ok "/var/lib/persistent ready (registry dir owned by ${REGISTRY_UID}:${REGISTRY_GID})"

echo "==> 00-data-disk: done"
