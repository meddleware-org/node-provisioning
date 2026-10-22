#!/usr/bin/env bash
# Kernel modules and sysctl settings required by Kubernetes + Cilium.
# Idempotent — safe to re-run.

set -euo pipefail

echo "==> 02-kernel: loading modules and applying sysctl"

# ── Kernel modules ────────────────────────────────────────────────────────────
# overlay:       required by the container runtime's overlayfs storage driver (CRI-O)
# br_netfilter:  required for bridged traffic to traverse iptables (kubeadm preflight)
# dm_crypt:      device-mapper crypto target; required for LUKS-encrypted volumes
cat > /etc/modules-load.d/kubernetes.conf << 'EOF'
overlay
br_netfilter
dm_crypt
EOF

modprobe overlay
modprobe br_netfilter
modprobe dm_crypt
echo "  [OK] kernel modules: overlay, br_netfilter, dm_crypt"

# ── sysctl settings ───────────────────────────────────────────────────────────
# The kubeadm-preflight and Cilium rp_filter lines below mirror the reference
# /etc/sysctl.d/99-kubernetes.conf exactly (order and comments).
# The performance/limit tunings in the second block are additions beyond the
# reference baseline.
cat > /etc/sysctl.d/99-kubernetes.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Disable rp_filter on Cilium interfaces since it may cause mangled packets to be dropped
-net.ipv4.conf.lxc*.rp_filter = 0
-net.ipv4.conf.cilium_*.rp_filter = 0
# The kernel uses max(conf.all, conf.{dev}) as its value, so we need to set .all. to 0 as well.
# Otherwise it will overrule the device specific settings.
net.ipv4.conf.all.rp_filter = 0

# ── Additions beyond the reference baseline ────────────────────────────────────
# Increase conntrack table for high-throughput workloads
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Increase inotify limits for kubelet and container runtimes
fs.inotify.max_user_watches   = 1048576
fs.inotify.max_user_instances = 8192

# Increase pid_max for dense single-node
kernel.pid_max = 4194304
EOF

sysctl --system > /dev/null
echo "  [OK] sysctl applied"

# ── Verify swap is off ────────────────────────────────────────────────────────
if swapon --show 2>/dev/null | grep -q .; then
  echo "  [WARN] swap is active — disabling now"
  swapoff -a
  sed -i '/\bswap\b/d' /etc/fstab
fi
echo "  [OK] swap off"

echo "==> 02-kernel: done"
