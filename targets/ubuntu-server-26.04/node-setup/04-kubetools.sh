#!/usr/bin/env bash
# Install kubeadm, kubelet, and kubectl from the Kubernetes APT repository.
# Pinned to KUBE_VERSION — change to upgrade (then run: sudo apt-get upgrade kubeadm kubelet kubectl).
# Idempotent — safe to re-run.

set -euo pipefail

# Both come from the site configuration; KUBE_MINOR is the repository channel (for example v1.NN).
KUBE_VERSION="${KUBE_VERSION:?KUBE_VERSION is required}"
KUBE_MINOR="${KUBE_MINOR:?KUBE_MINOR is required}"

echo "==> 04-kubetools: installing Kubernetes toolchain v${KUBE_VERSION}"

# ── Kubernetes APT repository ─────────────────────────────────────────────────
# The signing key is owned by the Kubernetes project and shared by all minor repositories. It is downloaded on every run and
# accepted only if its fingerprint is pinned and it has not expired (see repokey.sh): when the project extends the key's expiry
# the refreshed key is picked up here; when it replaces the key the run fails closed until the new fingerprint is added to
# KUBE_REPO_KEY_FPRS (site key). Fingerprint cross-checked 2026-10-22 against public keyservers and a Kubernetes SIG repository
# that pins the same value.
# shellcheck source=repokey.sh
source "$(dirname "${BASH_SOURCE[0]}")/repokey.sh"
np_install_repo_key "Kubernetes" "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/Release.key" \
  /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${KUBE_REPO_KEY_FPRS:-DE15B14486CD377B9E876E1A234654DA9A296436}"

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

# Install (idempotent: apt is a no-op if already at the pinned version)
apt-get install -y -q \
  "kubeadm=${KUBE_VERSION}-*" \
  "kubelet=${KUBE_VERSION}-*" \
  "kubectl=${KUBE_VERSION}-*"

# Pin to prevent unintended upgrades — Kubernetes nodes must be upgraded deliberately
apt-mark hold kubeadm kubelet kubectl
echo "  [OK] kubeadm, kubelet, kubectl ${KUBE_VERSION} installed and held"

# ── Longhorn prerequisites ────────────────────────────────────────────────────
# Packages deferred from autoinstall — all fail in the installer's chroot
# environment and must be installed on the live running system instead.
#   nfs-common / open-iscsi: post-install scripts start rpcbind/iscsid (fails in chroot)
#   iotop-c: causes errors during autoinstall packages phase
# iscsid is left socket-activated (not enabled); Longhorn needs the binaries only.
apt-get install -y -q nfs-common open-iscsi iotop-c
systemctl disable iscsid 2>/dev/null || true
echo "  [OK] nfs-common, open-iscsi, iotop-c installed"

# ── Enable kubelet ────────────────────────────────────────────────────────────
# kubelet will crash-loop until kubeadm init runs — that is expected and correct.
systemctl enable kubelet
echo "  [OK] kubelet enabled (will start properly after kubeadm init)"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
kubeadm version
kubectl version --client
echo ""
echo "==> 04-kubetools: done"
echo "    Next step: initialise the cluster (kubeadm init)"
