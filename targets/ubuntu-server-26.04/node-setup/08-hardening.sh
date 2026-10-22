#!/usr/bin/env bash
# Host hardening: SSH, sysctl and unattended-upgrades. Idempotent; fatal on failure (a node that could not be
# hardened must not be reported as set up).
#
# The autoinstall already creates the administrator with key-only SSH (allow-pw: false). This script makes the
# posture explicit and durable, and applies the pieces the installer cannot (they need a running system):
#   * /etc/ssh/sshd_config.d/99-hardening.conf   key-only authentication, no root login, no X11/agent forwarding
#   * /etc/sysctl.d/90-hardening.conf             network and kernel-pointer hardening (Kubernetes parameters are in
#                                                 99-kubernetes.conf, written by 02-kernel.sh, and load after this)
#   * /etc/apt/apt.conf.d/52unattended-upgrades-local   security updates on, kernel/runtime/kubernetes packages held
# The sshd configuration is validated (sshd -t) BEFORE it is activated: an invalid file is rolled back and the
# script fails, so a bad edit can never lock the operator out.
#
# CONFIG
#   SSH_ALLOW_TCP_FORWARDING  true|false (default false): allow `ssh -L` / `-R` port forwarding.

set -euo pipefail

info() { echo "  [hardening] $*"; }
ok()   { echo "  [OK] $*"; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

SSH_ALLOW_TCP_FORWARDING="${SSH_ALLOW_TCP_FORWARDING:-false}"
[[ "${SSH_ALLOW_TCP_FORWARDING}" == true || "${SSH_ALLOW_TCP_FORWARDING}" == false ]] \
  || die "SSH_ALLOW_TCP_FORWARDING must be true or false"
fwd=no; [[ "${SSH_ALLOW_TCP_FORWARDING}" == true ]] && fwd=yes

echo "==> 08-hardening: SSH, sysctl, unattended upgrades"

# First boot: let cloud-init finish so it does not compete for the apt/dpkg locks or rewrite these files.
if command -v cloud-init >/dev/null 2>&1; then
  timeout 600 cloud-init status --wait >/dev/null 2>&1 || info "cloud-init did not report done within 600 s; continuing"
fi

# install_file <path> <mode> <content-on-stdin>: write only when the content changes. Returns 0 if changed, 1 if not.
install_file() {
  local path="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"${tmp}"
  if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
    rm -f -- "${tmp}"; chmod "${mode}" "${path}"; return 1
  fi
  install -D -m "${mode}" -o root -g root "${tmp}" "${path}"
  rm -f -- "${tmp}"
  return 0
}

# ── SSH ─────────────────────────────────────────────────────────────────────────
SSHD_CONF=/etc/ssh/sshd_config.d/99-hardening.conf
prev=""
if [[ -f "${SSHD_CONF}" ]]; then prev="$(mktemp)"; cp -p "${SSHD_CONF}" "${prev}"; fi
changed=0
if install_file "${SSHD_CONF}" 0644 <<EOT
# Managed by node-provisioning (08-hardening.sh). Key-only SSH.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey

# Drop idle sessions after 15 minutes (3 x 300 s)
ClientAliveInterval 300
ClientAliveCountMax 3

LogLevel VERBOSE
SyslogFacility AUTHPRIV

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding ${fwd}
EOT
then changed=1; fi
if (( changed )) && command -v sshd >/dev/null 2>&1; then
  if ! sshd -t >/dev/null 2>&1; then
    if [[ -n "${prev}" ]]; then install -m 0644 -o root -g root "${prev}" "${SSHD_CONF}"; else rm -f -- "${SSHD_CONF}"; fi
    [[ -z "${prev}" ]] || rm -f -- "${prev}"
    die "sshd rejected the hardening configuration; it was rolled back"
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || info "could not reload sshd (not running?)"
fi
[[ -z "${prev}" ]] || rm -f -- "${prev}"
ok "ssh hardening in place (AllowTcpForwarding ${fwd})"

# ── sysctl (security only; Kubernetes requirements are in 99-kubernetes.conf) ────
changed=0
if install_file /etc/sysctl.d/90-hardening.conf 0644 <<'EOT'
# Managed by node-provisioning (08-hardening.sh).
# Disable IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# SYN flood protection
net.ipv4.tcp_syncookies = 1
# Kernel pointer and log hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOT
then changed=1; fi
if (( changed )); then sysctl -q -p /etc/sysctl.d/90-hardening.conf >/dev/null; fi
ok "sysctl hardening in place"

# ── Unattended upgrades (a drop-in; the package's own 50unattended-upgrades is left alone) ──
install_file /etc/apt/apt.conf.d/52unattended-upgrades-local 0644 <<'EOT' || true
// Managed by node-provisioning (08-hardening.sh).
// Never upgrade the kernel, container runtime or Kubernetes automatically: do that deliberately.
Unattended-Upgrade::Package-Blacklist {
    "linux-image*";
    "linux-headers*";
    "linux-modules*";
    "cri-o*";
    "crun";
    "conmon";
    "kubeadm";
    "kubelet";
    "kubectl";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOT
ok "unattended-upgrades policy in place"

echo "==> 08-hardening: done"
