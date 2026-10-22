#!/usr/bin/env bash
# Install CRI-O (the container runtime this cluster uses) and apply the custom
# runtime drop-in. Idempotent — safe to re-run.
#
# CRI-O is installed from the OpenSUSE repository (the official upstream source).
# Version is matched to the Kubernetes minor per CRI-O best practices.
#
# Expected versions:
#   cri-o matching the Kubernetes minor, default runtime = crun, cgroup_manager = systemd,
#   socket unix:///var/run/crio/crio.sock, pause image = PAUSE_IMAGE

set -euo pipefail

# Repository channel (must equal the Kubernetes minor used by 04-kubetools.sh), for example v1.NN
CRIO_VERSION="${KUBE_MINOR:?KUBE_MINOR is required}"
PAUSE_IMAGE="${PAUSE_IMAGE:?PAUSE_IMAGE is required}"

echo "==> 03-crio: installing CRI-O ${CRIO_VERSION} + crun + conmon"

# ── Prerequisites for adding repositories ─────────────────────────────────────
if ! command -v curl &>/dev/null || ! command -v gpg &>/dev/null; then
  apt-get update -qq
  apt-get install -y -q curl gnupg
  echo "  [OK] curl and gnupg installed"
fi

# ── Add OpenSUSE CRI-O repository ─────────────────────────────────────────────
if [[ ! -f /etc/apt/keyrings/cri-o-apt-keyring.gpg ]]; then
  echo "  Adding OpenSUSE CRI-O repository (${CRIO_VERSION})..."

  mkdir -p /etc/apt/keyrings

  # Import the CRI-O GPG key
  curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/cri-o-apt-keyring.gpg
  echo "  [OK] CRI-O GPG key imported"

  # Add the CRI-O repository
  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] \
https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/cri-o.list > /dev/null
  echo "  [OK] CRI-O repository added"
fi

# ── Install from the OpenSUSE repository ──────────────────────────────────────
apt-get update -qq
apt-get install -y -q cri-o crun conmon
echo "  [OK] cri-o, crun, conmon installed"

# ── podman + skopeo for local-first image builds ──────────────────────────────
# podman builds first-party images directly into the SHARED containers/storage
# that CRI-O reads (see storage.conf below), so a locally-built image is usable by
# the kubelet with imagePullPolicy: IfNotPresent — no registry needed on the very
# first bootstrap. skopeo resolves published digests for the normal (pull) path.
apt-get install -y -q podman skopeo
echo "  [OK] podman, skopeo installed"

# Pin cri-o so it is upgraded deliberately alongside the Kubernetes minor version.
apt-mark hold cri-o
echo "  [OK] cri-o held (upgrade deliberately with the k8s minor)"

# ── Custom runtime drop-in ────────────────────────────────────────────────────
# The package ships /etc/crio/crio.conf.d/10-crio.conf (pause image, runtime
# paths under /usr/libexec/crio, crun as default). We add a second drop-in for
# the cluster-specific tuning captured from the live server. Drop-ins are merged
# in lexical order, so 10-runtime.conf refines 10-crio.conf.
mkdir -p /etc/crio/crio.conf.d
cat > /etc/crio/crio.conf.d/10-runtime.conf << EOF
[crio.image]
# Pin the pause image kubeadm uses, to suppress the inconsistency warning.
pause_image = "${PAUSE_IMAGE}"

[crio.runtime]
default_runtime = "crun"
# cgroup_manager must match kubelet's cgroupDriver (both systemd).
cgroup_manager = "systemd"
# Raise the per-container PID limit for dense single-node workloads.
pids_limit = 4096
# Cap per-container log size at 50 MiB before rotation.
log_size_max = 52428800

[crio.runtime.runtimes.crun]
runtime_path = "/usr/bin/crun"
runtime_type = "oci"
runtime_root = "/run/crun"
EOF
echo "  [OK] /etc/crio/crio.conf.d/10-runtime.conf written"

# ── Shared containers/storage (podman <-> CRI-O) ──────────────────────────────
# Pin the storage backend explicitly so rootful podman and CRI-O provably use the
# SAME graphroot. Both default to /var/lib/containers/storage, but making it
# explicit guarantees a `sudo podman build` image is visible to CRI-O regardless
# of package-default drift. Written before CRI-O starts so it takes effect on boot.
mkdir -p /etc/containers
cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
# Let overlay pick the kernel-native driver; no fuse-overlayfs needed for rootful.
EOF
echo "  [OK] /etc/containers/storage.conf written (shared podman <-> CRI-O graphroot)"

# ── Start / enable CRI-O ──────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now crio

# Verify
if systemctl is-active --quiet crio; then
  echo "  [OK] crio is running"
  crio --version | head -1
else
  echo "  [FAIL] crio failed to start — check: journalctl -xeu crio"
  exit 1
fi

# Confirm the CRI socket is present (kubeadm criSocket points here).
if [[ -S /var/run/crio/crio.sock ]]; then
  echo "  [OK] CRI socket present at /var/run/crio/crio.sock"
else
  echo "  [WARN] /var/run/crio/crio.sock not found yet — it appears once crio is fully up"
fi

echo "==> 03-crio: done"
