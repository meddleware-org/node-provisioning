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
#   WIPE_DATA_DISK   Set to 1 to allow (re)partitioning the selected disk when it holds UNRECOGNISED data.
#                    Default 0 = refuse (data-loss guard). It only ever applies to the disk named by the serial.
#
# Idempotent and safe to re-run.

set -euo pipefail

info() { echo "  [data-disk] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*" >&2; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

DATA_DISK_SERIAL="${DATA_DISK_SERIAL:?DATA_DISK_SERIAL is required (udev ID_SERIAL of the data disk)}"
ETCD_SIZE="${ETCD_SIZE:-50G}"
LONGHORN_SIZE="${LONGHORN_SIZE:-150G}"
REGISTRY_UID="${REGISTRY_UID:-1000}"
REGISTRY_GID="${REGISTRY_GID:-1000}"
WIPE_DATA_DISK="${WIPE_DATA_DISK:-0}"
SYS_BLOCK="${NP_SYS_BLOCK:-/sys/block}"
LABELS=(etcd longhorn-nvme persistent)
MOUNTS=(/var/lib/etcd /var/lib/longhorn-nvme /var/lib/persistent)

# Test seam: tests may export their own np_is_block (there are no block devices in a container).
declare -F np_is_block >/dev/null || np_is_block() { [[ -b "$1" ]]; }

echo "==> 00-data-disk: provisioning persistent data disk"

[[ "${DATA_DISK_SERIAL}" =~ ^[A-Za-z0-9._:+-]{4,128}$ ]] || die "DATA_DISK_SERIAL is not a valid serial"

# ── Resolve the data disk by serial ─────────────────────────────────────────────
n=0; DATA_DISK=""
for dev in "${SYS_BLOCK}"/*; do
  name="${dev##*/}"
  case "${name}" in loop*|ram*|zram*|sr*|fd*|nbd*|dm-*|md*) continue ;; esac
  serial="$(udevadm info --query=property --name="/dev/${name}" 2>/dev/null | sed -n 's/^ID_SERIAL=//p')"
  if [[ "${serial}" == "${DATA_DISK_SERIAL}" ]]; then DATA_DISK="/dev/${name}"; n=$((n + 1)); fi
done
(( n == 1 )) || die "expected exactly one disk with the configured data-disk serial, found ${n}"
np_is_block "${DATA_DISK}" || die "${DATA_DISK} is not a block device"
info "Data disk resolved by serial: ${DATA_DISK}"

# Root disk (never a data-disk candidate): strip the partition suffix from the device backing /.
root_src="$(findmnt -no SOURCE / || true)"
root_disk="$(lsblk -no PKNAME "${root_src}" 2>/dev/null | head -1 || true)"
[[ -n "${root_disk}" ]] && root_disk="/dev/${root_disk}"
[[ "${DATA_DISK}" != "${root_disk}" ]] || die "Refusing to use the root disk (${root_disk}) as the data disk."

# Partition device names: NVMe/mmc use a 'p' separator, sd*/vd* do not.
if [[ "${DATA_DISK}" =~ [0-9]$ ]]; then P="p"; else P=""; fi
part() { echo "${DATA_DISK}${P}$1"; }
label_of() { blkid -s LABEL -o value "$1" 2>/dev/null || true; }

# ── Is the layout already present ON THIS DISK? ─────────────────────────────────
layout_present=0
if [[ "$(label_of "$(part 1)")" == "${LABELS[0]}" && "$(label_of "$(part 2)")" == "${LABELS[1]}" \
      && "$(label_of "$(part 3)")" == "${LABELS[2]}" ]]; then
  layout_present=1
fi

if (( layout_present )) && [[ "${WIPE_DATA_DISK}" -ne 1 ]]; then
  info "Layout already present on ${DATA_DISK}; will mount only."
else
  # ── Data-loss guard ───────────────────────────────────────────────────────────
  # The selected disk carries partitions that are NOT our layout: do not touch it unless the operator opts in.
  existing_parts="$(lsblk -no NAME "${DATA_DISK}" | tail -n +2 | wc -l)"
  if [[ "${existing_parts}" -gt 0 && "${WIPE_DATA_DISK}" -ne 1 ]]; then
    die "${DATA_DISK} already has ${existing_parts} partition(s) that are not this layout.
       Refusing to overwrite unrecognised data. Re-run with WIPE_DATA_DISK=1 to
       repartition (DESTROYS all data on ${DATA_DISK})."
  fi

  # ── Create GPT + three partitions with sfdisk (util-linux; always present) ────
  info "Creating GPT layout on ${DATA_DISK} (etcd=${ETCD_SIZE}, longhorn-nvme=${LONGHORN_SIZE}, persistent=rest)"
  wipefs -a "${DATA_DISK}" >/dev/null 2>&1 || true
  sfdisk "${DATA_DISK}" >/dev/null <<LAYOUT
label: gpt
size=${ETCD_SIZE}, name=${LABELS[0]}
size=${LONGHORN_SIZE}, name=${LABELS[1]}
name=${LABELS[2]}
LAYOUT
  partprobe "${DATA_DISK}" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  for i in 0 1 2; do mkfs.ext4 -q -L "${LABELS[${i}]}" "$(part $((i + 1)))"; done
  ok "Partitions created and formatted (labels: ${LABELS[*]})"
fi

# ── Same labels on another device: report, never trust ──────────────────────────
for label in "${LABELS[@]}"; do
  while IFS= read -r other; do
    [[ -n "${other}" && "${other}" != "${DATA_DISK}"* ]] && warn "label '${label}' also exists on ${other}: ignored (mounts use the UUIDs of ${DATA_DISK})"
  done < <(blkid -o device -t "LABEL=${label}" 2>/dev/null || true)
done

# ── Mount points and fstab entries (by UUID of THIS disk's partitions) ──────────
_ensure_fstab() { # index(0-2)
  local i="$1" dev uuid path="${MOUNTS[$1]}" label="${LABELS[$1]}"
  dev="$(part $((i + 1)))"
  uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null || true)"
  [[ -n "${uuid}" ]] || die "no filesystem UUID on ${dev}"
  mkdir -p "${path}"
  if [[ -f /etc/fstab ]] && awk -v p="${path}" '$1 !~ /^#/ && $2 == p { f = 1 } END { exit !f }' /etc/fstab; then
    grep -qE "^UUID=${uuid}[[:space:]]+${path}[[:space:]]" /etc/fstab \
      || die "/etc/fstab already maps ${path} to a different source; refusing to change it"
  else
    printf '# %s (data disk)\nUUID=%s %s ext4 noatime 0 2\n' "${label}" "${uuid}" "${path}" >>/etc/fstab
    info "fstab += UUID=${uuid} -> ${path} (${label})"
  fi
}
for i in 0 1 2; do _ensure_fstab "${i}"; done

info "Mounting all fstab entries..."
systemctl daemon-reload
mount -a
ok "Data partitions mounted"

# ── Persistent service directories ────────────────────────────────────────────
# /var/lib/persistent is the home for host-path stateful services that must survive OS re-installs. The
# registry subdir is created and owned up-front so a host-path-backed local registry can use it.
mkdir -p /var/lib/persistent/registry
chown "${REGISTRY_UID}:${REGISTRY_GID}" /var/lib/persistent/registry
chmod 0750 /var/lib/persistent/registry
if [[ ! -f /var/lib/persistent/README ]]; then
  cat > /var/lib/persistent/README <<'README'
This partition (LABEL=persistent) is provisioned by 00-data-disk.sh and is PRESERVED across OS re-installs
(the installer only manages the OS disk). Put host-path stateful data here (e.g. registry/).
See docs/node-setup.md.
README
fi
ok "/var/lib/persistent ready (registry dir owned by ${REGISTRY_UID}:${REGISTRY_GID})"

echo "==> 00-data-disk: done"
