#!/usr/bin/env bash
# Runs the numbered node-setup scripts in a fixed order (root, on the target node).
#
# Usage: run.sh [preflight|setup|all]     (default: all)
#
# Configuration arrives through the environment (the CLI exports the site and node values):
#   required: DATA_DISK_SERIAL (00), KUBE_MINOR KUBE_VERSION PAUSE_IMAGE (03/04), LAN_CIDR POD_CIDR (05)
#   optional pass-through: ETCD_SIZE LONGHORN_SIZE REGISTRY_UID REGISTRY_GID WIPE_DATA_DISK
#                          ALLOW_ANYWHERE PRO_ENABLE PRO_DISABLE EXPECT_* SKIP_PREFLIGHT
# Order and failure semantics: 00-05 and 08 are fatal; 06-07 report and continue.

# Exit codes: 0 when every fatal step succeeds, 1 on the first fatal failure, 2 for a bad argument. Side effects: installs packages, provisions
# # the data disk, configures the kernel, the container runtime, the firewall and SSH (see each script).
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail

# The directory of the numbered scripts, found from this file so the runner works from any directory.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# apt must never stop to ask a question during an unattended run.
export DEBIAN_FRONTEND=noninteractive

# log_info <message>: a progress line on stdout.
log_info()  { echo "[INFO] $*"; }
# log_ok <message>: a step that succeeded.
log_ok()    { echo "[OK] $*"; }
# log_warn <message>: a problem that does not stop the run.
log_warn()  { echo "[WARN] $*"; }
# log_error <message>: a failure, on stderr.
log_error() { echo "[ERROR] $*" >&2; }
# section <title>: a blank line and a heading, so the log reads as a list of steps.
section()   { echo ""; echo "==> $*"; }

# Every script changes the system, so the runner must be root.
[[ $EUID -eq 0 ]] || { log_error "node-setup must run as root"; exit 1; }

# preflight: run the read-only checks first, unless SKIP_PREFLIGHT is set (then say so). A failure is fatal.
preflight() {
  if [[ "${SKIP_PREFLIGHT:-0}" -ne 0 ]]; then log_warn "Skipping preflight checks (SKIP_PREFLIGHT=1)"; return 0; fi
  section "Preflight checks"
  bash "${SCRIPTS_DIR}/01-preflight.sh" || { log_error "Preflight checks failed"; exit 1; }
  log_ok "Preflight checks passed"
}

# setup: the numbered steps in order. 00-05 and 08 are fatal; 06 and 07 report their problems and carry on.
setup() {
  section "Base packages (git, vim, htop, ethtool, less, lsof, strace)"
  # Base tools an operator needs on the node.
  apt-get update -qq
  apt-get install -y -q --no-install-recommends git vim htop ethtool socat less lsof strace
  log_ok "Base packages installed"

  section "Persistent data disk (provision + mount)"
  # The data disk is provisioned and mounted first, so later steps can use its mounts.
  bash "${SCRIPTS_DIR}/00-data-disk.sh" || { log_error "Data-disk provisioning failed"; exit 1; }
  log_ok "Data disk provisioned and mounted"

  section "Kernel setup (modules, sysctl)"
  # Kernel modules and sysctl settings Kubernetes needs.
  bash "${SCRIPTS_DIR}/02-kernel.sh" || { log_error "Kernel setup failed"; exit 1; }
  log_ok "Kernel setup complete"

  section "CRI-O container runtime"
  # The container runtime.
  bash "${SCRIPTS_DIR}/03-crio.sh" || { log_error "CRI-O setup failed"; exit 1; }
  log_ok "CRI-O setup complete"
  # The service may need a moment after installation; wait once, then require it to be running.
  if ! systemctl is-active --quiet crio; then
    log_warn "CRI-O not running yet, waiting for startup..."
    sleep 3
    systemctl is-active --quiet crio || { log_error "CRI-O failed to start"; exit 1; }
  fi
  log_ok "CRI-O is running"

  section "Kubernetes tools (kubeadm, kubelet, kubectl)"
  # kubeadm, kubelet and kubectl, which must exist afterwards.
  bash "${SCRIPTS_DIR}/04-kubetools.sh" || { log_error "Kubernetes tools setup failed"; exit 1; }
  command -v kubeadm &>/dev/null || { log_error "kubeadm not found after installation"; exit 1; }
  log_ok "kubeadm, kubelet, kubectl installed and verified"

  section "UFW firewall configuration"
  # The firewall.
  bash "${SCRIPTS_DIR}/05-ufw.sh" || { log_error "Firewall configuration failed"; exit 1; }
  log_ok "UFW configuration complete"

  section "Disabling OS telemetry and phone-home services"
  # Turn off the OS's telemetry and phone-home services; non-fatal.
  bash "${SCRIPTS_DIR}/06-telemetry.sh" || log_warn "Telemetry hardening had issues — continuing (non-fatal)"
  log_ok "Telemetry hardening complete"

  section "Ubuntu Pro service posture"
  # The Ubuntu Pro service posture; non-fatal.
  bash "${SCRIPTS_DIR}/07-ubuntu-pro.sh" || log_warn "Ubuntu Pro posture had issues — continuing (non-fatal)"

  section "Host hardening (SSH, sysctl, unattended upgrades)"
  # SSH, sysctl and unattended-upgrade hardening; fatal, because a node without it must not be used.
  bash "${SCRIPTS_DIR}/08-hardening.sh" || { log_error "Host hardening failed"; exit 1; }
  log_ok "Host hardening complete"

  section "Package cleanup (autoremove + autoclean)"
  # Remove packages nothing needs and clear the package cache.
  apt-get autoremove -y -q
  apt-get autoclean -y -q
  log_ok "Package cleanup complete"
  log_ok "OS setup complete"
}

# The phase to run: preflight only, setup only, or both (the default).
case "${1:-all}" in
  preflight) preflight ;;
  setup)     setup ;;
  all)       preflight; setup ;;
  *) echo "usage: run.sh [preflight|setup|all]" >&2; exit 2 ;;
esac
