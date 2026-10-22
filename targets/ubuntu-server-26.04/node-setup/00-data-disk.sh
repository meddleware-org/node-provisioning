#!/usr/bin/env bash
# Idempotent data-disk provisioner for a cluster node.
#
# WHY THIS EXISTS
#   The Ubuntu autoinstall (autoinstall/user-data.yaml) manages ONLY the OS disk
#   (the OS disk: EFI + swap + root). The data disk — which holds etcd, the Longhorn
#   fast tier, and the general-purpose persistent partition (registry data, other
#   stateful services) — is deliberately left out of the installer so that wiping
#   and re-installing the OS can NEVER destroy that data.
#
#   This script creates the data-disk layout ONCE (first boot), then on every
#   subsequent boot / re-install it detects the existing labelled partitions and
#   simply re-mounts them by LABEL. Data survives OS re-installs. See docs/node-setup.md.
#
# LAYOUT (labels are the stable contract — mount points key off them):
#   LABEL=etcd           -> /var/lib/etcd          (control-plane state)
#   LABEL=longhorn-nvme  -> /var/lib/longhorn-nvme (Longhorn fast tier)
#   LABEL=persistent     -> /var/lib/persistent    (registry data + future services)
#
# CONFIG (all optional; sensible defaults, nothing hardcoded to a specific disk):
#   DATA_DISK        Target disk (default: auto-detect the largest non-root disk)
#   ETCD_SIZE        etcd partition size            (default: 50G)
#   LONGHORN_SIZE    Longhorn fast-tier size        (default: 150G)
#   REGISTRY_UID     Owner uid for the registry dir (default: 1000 — Distribution image user)
#   REGISTRY_GID     Owner gid for the registry dir (default: 1000)
#   WIPE_DATA_DISK   Set to 1 to allow (re)partitioning a disk that already holds
#                    UNRECOGNISED data. Default 0 = refuse (data-loss guard).
#
# Idempotent and safe to re-run.

set -euo pipefail

info() { echo "  [data-disk] $*"; }
ok()   { echo "  [OK] $*"; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

ETCD_SIZE="${ETCD_SIZE:-50G}"
LONGHORN_SIZE="${LONGHORN_SIZE:-150G}"
REGISTRY_UID="${REGISTRY_UID:-1000}"
REGISTRY_GID="${REGISTRY_GID:-1000}"
WIPE_DATA_DISK="${WIPE_DATA_DISK:-0}"

echo "==> 00-data-disk: provisioning persistent data disk"

# ── Fast path: everything already provisioned ─────────────────────────────────
# The `persistent` label is the sentinel: if it exists, the data disk was already
# laid out (fresh install completed earlier, or this is a re-install). Skip all
# destructive work and jump straight to mounting — UNLESS WIPE_DATA_DISK=1 is
# set, which forces a full repartition even on a recognised disk.
if blkid -L persistent >/dev/null 2>&1 && [[ "${WIPE_DATA_DISK:-0}" -ne 1 ]]; then
  info "Existing 'persistent' partition found — data disk already provisioned; will mount only."
else
  # ── Resolve the target disk ─────────────────────────────────────────────────
  # Root disk (never a data-disk candidate): strip the partition suffix from the
  # device backing /.
  root_src="$(findmnt -no SOURCE / || true)"
  root_disk="$(lsblk -no PKNAME "${root_src}" 2>/dev/null | head -1)"
  [[ -n "${root_disk}" ]] && root_disk="/dev/${root_disk}"

  if [[ -z "${DATA_DISK:-}" ]]; then
    # Largest whole disk that is not the root disk.
    DATA_DISK="$(lsblk -dn -o NAME,TYPE,SIZE -b \
      | awk '$2=="disk"{print $1, $3}' \
      | while read -r name size; do
          [[ "/dev/${name}" == "${root_disk}" ]] && continue
          echo "${size} /dev/${name}"
        done \
      | sort -rn | head -1 | awk '{print $2}')"
  fi
  [[ -n "${DATA_DISK:-}" ]] || die "Could not determine a data disk. Set DATA_DISK explicitly."
  [[ -b "${DATA_DISK}" ]]   || die "DATA_DISK ${DATA_DISK} is not a block device."
  [[ "${DATA_DISK}" != "${root_disk}" ]] || die "Refusing to use the root disk (${root_disk}) as the data disk."
  info "Target data disk: ${DATA_DISK} (root disk: ${root_disk:-unknown})"

  # ── Data-loss guard ─────────────────────────────────────────────────────────
  # If the disk already carries partitions/filesystems that are NOT our labels,
  # do not touch it unless the operator explicitly opts in.
  existing_parts="$(lsblk -no NAME "${DATA_DISK}" | tail -n +2 | wc -l)"
  if [[ "${existing_parts}" -gt 0 && "${WIPE_DATA_DISK}" -ne 1 ]]; then
    die "${DATA_DISK} already has ${existing_parts} partition(s) but no 'persistent' label.
       Refusing to overwrite unrecognised data. Re-run with WIPE_DATA_DISK=1 to
       repartition (DESTROYS all data on ${DATA_DISK})."
  fi

  # ── Create GPT + three partitions with sfdisk (util-linux; always present) ──
  info "Creating GPT layout on ${DATA_DISK} (etcd=${ETCD_SIZE}, longhorn-nvme=${LONGHORN_SIZE}, persistent=rest)"
  wipefs -a "${DATA_DISK}" >/dev/null 2>&1 || true
  sfdisk "${DATA_DISK}" >/dev/null <<EOF
label: gpt
size=${ETCD_SIZE}, name=etcd
size=${LONGHORN_SIZE}, name=longhorn-nvme
name=persistent
EOF
  partprobe "${DATA_DISK}" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  # Partition device names: NVMe/mmc use a 'p' separator, sd*/vd* do not.
  if [[ "${DATA_DISK}" =~ [0-9]$ ]]; then P="p"; else P=""; fi
  mkfs.ext4 -q -L etcd          "${DATA_DISK}${P}1"
  mkfs.ext4 -q -L longhorn-nvme "${DATA_DISK}${P}2"
  mkfs.ext4 -q -L persistent    "${DATA_DISK}${P}3"
  ok "Partitions created and formatted (labels: etcd, longhorn-nvme, persistent)"
fi

# ── Ensure mount points, fstab entries (by LABEL), and mounts ─────────────────
_ensure_fstab() {
  local label="$1" path="$2" opts="$3"
  mkdir -p "${path}"
  if ! grep -qE "^LABEL=${label}[[:space:]]" /etc/fstab; then
    printf 'LABEL=%s %s ext4 %s 0 2\n' "${label}" "${path}" "${opts}" >> /etc/fstab
    info "fstab += LABEL=${label} -> ${path}"
  fi
}

_ensure_fstab etcd          /var/lib/etcd          "noatime"
_ensure_fstab longhorn-nvme /var/lib/longhorn-nvme "noatime"
_ensure_fstab persistent    /var/lib/persistent    "noatime"

info "Mounting all fstab entries..."
systemctl daemon-reload
mount -a
ok "Data partitions mounted"

# ── Persistent service directories ────────────────────────────────────────────
# /var/lib/persistent is the home for host-path stateful services that must
# survive OS re-installs. The registry subdir is created + owned up-front so a
# host-path-backed local registry can use it (see docs/node-setup.md).
mkdir -p /var/lib/persistent/registry
chown "${REGISTRY_UID}:${REGISTRY_GID}" /var/lib/persistent/registry
chmod 0750 /var/lib/persistent/registry
if [[ ! -f /var/lib/persistent/README ]]; then
  cat > /var/lib/persistent/README <<'README'
This partition (LABEL=persistent) is provisioned by scripts/00-data-disk.sh and is
PRESERVED across OS re-installs (the installer only manages the OS disk). Put
host-path stateful data here (e.g. registry/). See docs/node-setup.md.
README
fi
ok "/var/lib/persistent ready (registry dir owned by ${REGISTRY_UID}:${REGISTRY_GID})"

echo "==> 00-data-disk: done"
