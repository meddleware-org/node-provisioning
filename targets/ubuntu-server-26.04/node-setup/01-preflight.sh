#!/usr/bin/env bash
# Preflight check before Kubernetes prerequisites are installed.
# Validates: OS version, the OS and data disks (by serial), swap state, CRI-O state, network interfaces.
# Expectations come from the site configuration (EXPECT_*), as comma-separated lists.
# Idempotent — safe to re-run at any time.

# Exit codes: 0 when no check failed, 1 otherwise (warnings do not fail). Read-only: this script changes nothing.
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail

# The number of failed checks.
FAIL=0

# ok <message>: a check that passed.
ok()   { echo "  [OK]  $*"; }
# warn <message>: worth seeing; does not fail the run.
warn() { echo "  [WARN] $*"; }
# fail <message>: a check that failed; counted, and the run ends with status 1.
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
# info <message>: a note.
info() { echo "  [INFO] $*"; }

echo "==> preflight checks"
echo ""

# ── OS version ───────────────────────────────────────────────────────────────
echo "── OS"
# The operating system is read from the standard release file.
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]]; then
    ok "Ubuntu 26.04 LTS"
  else
    warn "Expected Ubuntu 26.04, found ${PRETTY_NAME:-unknown} — scripts may still work"
  fi
else
  fail "/etc/os-release not found"
fi

# ── Kernel ───────────────────────────────────────────────────────────────────
echo "── Kernel"
# The running kernel, compared with the site's expected prefix when one is configured.
KVER=$(uname -r)
ok "Kernel: ${KVER}"
EXPECT_KERNEL_PREFIX="${EXPECT_KERNEL_PREFIX:-}"
if [[ -z "${EXPECT_KERNEL_PREFIX}" ]]; then
  info "no expected kernel prefix configured"
elif [[ "${KVER}" == "${EXPECT_KERNEL_PREFIX}"* ]]; then
  ok "Kernel matches the expected prefix (${EXPECT_KERNEL_PREFIX})"
else
  warn "Kernel version ${KVER} differs from the expected ${EXPECT_KERNEL_PREFIX}* — verify compatibility"
fi

# ── Architecture ─────────────────────────────────────────────────────────────
echo "── Architecture"
# The CPU architecture must be the expected one (x86_64 unless the site says otherwise).
ARCH=$(uname -m)
EXPECT_ARCH="${EXPECT_ARCH:-x86_64}"
if [[ "${ARCH}" == "${EXPECT_ARCH}" ]]; then
  ok "${EXPECT_ARCH}"
else
  fail "Unexpected architecture: ${ARCH} (expected ${EXPECT_ARCH})"
fi

# ── Disk layout ──────────────────────────────────────────────────────────────
# Disks are identified by udev ID_SERIAL, never by name: device names are not stable across boots.
echo "── Disks"
# Where the kernel lists block devices (overridable for the tests).
SYS_BLOCK="${NP_SYS_BLOCK:-/sys/block}"
# resolve_serial <serial>: sets RESOLVED_N to the number of disks with that serial and RESOLVED_DEV to the last one found. Same device filter as 00-data-disk.sh.
resolve_serial() { # <serial> -> sets RESOLVED_N and RESOLVED_DEV
  local want="$1" dev name serial
  RESOLVED_N=0; RESOLVED_DEV=""
  for dev in "${SYS_BLOCK}"/*; do
    name="${dev##*/}"
    case "${name}" in loop*|ram*|zram*|sr*|fd*|nbd*|dm-*|md*) continue ;; esac
    serial="$(udevadm info --query=property --name="/dev/${name}" 2>/dev/null | sed -n 's/^ID_SERIAL=//p')"
    if [[ "${serial}" == "${want}" ]]; then RESOLVED_DEV="/dev/${name}"; RESOLVED_N=$((RESOLVED_N + 1)); fi
  done
}
# For each disk serial the site configures: exactly one disk must match; an unset serial is skipped with a note.
OS_RESOLVED=""; DATA_RESOLVED=""
for pair in "OS_DISK_SERIAL:OS disk" "DATA_DISK_SERIAL:data disk"; do
  var="${pair%%:*}"; what="${pair#*:}"; want="${!var:-}"
  if [[ -z "${want}" ]]; then info "${var} is not set: ${what} not checked"; continue; fi
  resolve_serial "${want}"
  if [[ "${RESOLVED_N}" -eq 1 ]]; then
    SIZE=$(lsblk -dno SIZE "${RESOLVED_DEV}" 2>/dev/null || echo "unknown")
    ok "${what} present (${RESOLVED_DEV}, ${SIZE})"
    [[ "${var}" == OS_DISK_SERIAL ]] && OS_RESOLVED="${RESOLVED_DEV}"
    [[ "${var}" == DATA_DISK_SERIAL ]] && DATA_RESOLVED="${RESOLVED_DEV}"
  else
    fail "${what}: expected exactly one disk with the configured serial, found ${RESOLVED_N}"
  fi
done
# When the OS disk resolved, the root file system should be on it.
if [[ -n "${OS_RESOLVED}" ]]; then
  ROOT_PK="$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null || true)" 2>/dev/null | head -1 || true)"
  if [[ -n "${ROOT_PK}" && "/dev/${ROOT_PK}" == "${OS_RESOLVED}" ]]; then ok "root filesystem is on the OS disk"
  else warn "root filesystem is not on the OS disk (${OS_RESOLVED})"; fi
fi

# Data-disk partitions are provisioned by scripts/00-data-disk.sh (which runs later,
# in the OS-setup phase — AFTER this preflight). So on a first boot they are expected
# to be absent here; that is informational, not an error. On a re-install the existing
# labelled partitions are detected. See docs/node-setup.md.
# Only a partition of the CONFIGURED data disk counts: the same labels on another disk (an older install) are not this layout.
# The data-disk layout is created later (by 00-data-disk.sh), so a missing layout here is informational. Only partitions of the configured data disk count.
PERSIST_ON_DATA=0; PERSIST_ELSEWHERE=""
# Each partition labelled `persistent`: on the configured data disk, or somewhere else.
while read -r pdev; do
  [[ -n "${pdev}" ]] || continue
  if [[ -n "${DATA_RESOLVED}" && "${pdev}" =~ ^${DATA_RESOLVED}p?[0-9]+$ ]]; then PERSIST_ON_DATA=1; else PERSIST_ELSEWHERE="${PERSIST_ELSEWHERE} ${pdev}"; fi
done < <(blkid -o device -t LABEL=persistent 2>/dev/null || true)
if (( PERSIST_ON_DATA )); then
  ok "data disk already provisioned (LABEL=persistent on ${DATA_RESOLVED})"
else
  info "data disk not yet provisioned — 00-data-disk.sh will create it in OS setup (docs/node-setup.md)"
fi
[[ -z "${PERSIST_ELSEWHERE}" ]] || warn "LABEL=persistent also exists on${PERSIST_ELSEWHERE}, which is not the configured data disk: ignored (00-data-disk.sh uses only the configured disk)"

# /var/lib/etcd is a dedicated mount once 00-data-disk.sh has run.
# /var/lib/etcd becomes a dedicated mount once the data disk is provisioned.
echo "── etcd mount"
if mountpoint -q /var/lib/etcd 2>/dev/null; then
  ETCD_DEV=$(findmnt -n -o SOURCE /var/lib/etcd)
  ok "/var/lib/etcd is a separate mount (${ETCD_DEV})"
else
  info "/var/lib/etcd not mounted yet — provisioned by 00-data-disk.sh during OS setup"
fi

# ── Swap ─────────────────────────────────────────────────────────────────────
echo "── Swap"
# Kubernetes requires swap off; any active swap fails the check, with the command that fixes it.
SWAP=$(swapon --show 2>/dev/null | wc -l)
if [[ "${SWAP}" -eq 0 ]]; then
  ok "Swap is off"
else
  fail "Swap is active — Kubernetes requires swap to be disabled"
  echo "     Run: sudo swapoff -a && sudo sed -i '/\\bswap\\b/d' /etc/fstab"
fi

# ── Kubernetes toolchain ──────────────────────────────────────────────────────
echo "── Kubernetes toolchain"
# The Kubernetes tools are not installed yet on a first run; their absence is informational.
if command -v kubeadm &>/dev/null; then
  ok "kubeadm $(kubeadm version -o short 2>/dev/null || echo '(version check failed)')"
else
  ok "kubeadm not installed yet — run 04-kubetools.sh"
fi

if command -v kubectl &>/dev/null; then
  ok "kubectl $(kubectl version --client 2>/dev/null | head -1 || echo '(version check failed)')"
fi

# ── CRI-O ─────────────────────────────────────────────────────────────────────
echo "── CRI-O"
# Likewise the container runtime.
if systemctl is-active crio &>/dev/null; then
  ok "crio is active"
elif command -v crio &>/dev/null; then
  warn "crio installed but not running"
else
  ok "crio not installed yet — run 03-crio.sh"
fi

# ── Network interfaces ────────────────────────────────────────────────────────
echo "── Network"
# The interfaces and bonds the site expects: a missing interface fails, a missing bond only warns (a bond appears when the site netplan is applied).
EXPECT_INTERFACES="${EXPECT_INTERFACES:-}"
EXPECT_BONDS="${EXPECT_BONDS:-}"
for iface in ${EXPECT_INTERFACES//,/ }; do
  if ip link show "${iface}" &>/dev/null; then
    ok "${iface} present"
  else
    fail "${iface} not found — verify NIC naming"
  fi
done

for bond in ${EXPECT_BONDS//,/ }; do
  if ip link show "${bond}" &>/dev/null; then
    ok "${bond} present"
  else
    warn "${bond} not present — expected after the site netplan is applied"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
# The summary and the exit status.
echo "==> Preflight complete — ${FAIL} failure(s)"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "    Resolve failures before proceeding."
  exit 1
else
  echo "    Ready to proceed with Kubernetes prerequisites."
fi
