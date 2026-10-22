#!/usr/bin/env bash
# UFW firewall configuration for a cluster node.
# Idempotent — safe to re-run.
#
# UFW is NOT installed by default on Ubuntu 26.04 — this script installs it.
#
# Rules below mirror the reference firewall. Only OpenSSH ships a named
# UFW application profile (via the openssh-server package); every other service
# (Kubernetes control plane, Cilium, Longhorn, NodePorts) has no UFW profile, so
# those ports are opened manually.
#
# SCOPE / DEFENCE IN DEPTH: the control-plane, etcd, storage, metrics, and NodePort
# rules are source-restricted to the LAN subnet by DEFAULT (LAN_CIDR). These ports
# are internal/administrative and should never be reachable from outside the LAN.
# SSH stays reachable from anywhere on the wire (key-only, hardened) so the operator
# is not locked out when managing from a different subnet; the router blocks WAN.
#
# LAN_CIDR and POD_CIDR are required (no default: a wrong default opens or locks the node):
#   LAN_CIDR=<lan-cidr> POD_CIDR=<pod-cidr> bash 05-ufw.sh
# Open everything (NOT recommended — only for an isolated bench network):
#   ALLOW_ANYWHERE=1 bash 05-ufw.sh

set -Eeuo pipefail

# Subnet permitted to reach internal/administrative ports.
LAN_CIDR="${LAN_CIDR:?LAN_CIDR is required}"
ALLOW_ANYWHERE="${ALLOW_ANYWHERE:-0}"
POD_CIDR="${POD_CIDR:?POD_CIDR is required}"
cidr_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
[[ "${LAN_CIDR}" =~ ${cidr_re} ]] || { echo "  [FAIL] LAN_CIDR is not a CIDR" >&2; exit 1; }
[[ "${POD_CIDR}" =~ ${cidr_re} ]] || { echo "  [FAIL] POD_CIDR is not a CIDR" >&2; exit 1; }

# _allow <port-spec> <proto> <comment>
# Opens a port restricted to LAN_CIDR by default; from Anywhere only if
# ALLOW_ANYWHERE=1 is explicitly set.
_allow() {
  local spec="$1" proto="$2" comment="$3"
  if [[ "${ALLOW_ANYWHERE}" -eq 1 ]]; then
    ufw allow "${spec}/${proto}" comment "${comment} (ANYWHERE)"
  else
    ufw allow from "${LAN_CIDR}" to any port "${spec}" proto "${proto}" comment "${comment} (LAN)"
  fi
}

echo "==> 05-ufw: installing and configuring UFW"
echo "  LAN_CIDR=${LAN_CIDR}  ALLOW_ANYWHERE=${ALLOW_ANYWHERE}"

# ── Install UFW ───────────────────────────────────────────────────────────────
apt-get install -y -q ufw
echo "  [OK] ufw installed"

# Reset to a clean state (removes any existing rules, disables ufw)
ufw --force reset

# From here until the end of this script the firewall is DISABLED. If anything fails, do not leave the node open:
# keep SSH reachable and enable the firewall with the rules staged so far (incoming is denied by default).
fail_safe() {
  echo "  [FAIL] 05-ufw failed: enabling the firewall with the rules staged so far (SSH stays allowed)" >&2
  { ufw allow OpenSSH || ufw allow 22/tcp; } >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}
trap fail_safe ERR

# ── Default policies ──────────────────────────────────────────────────────────
# routed=allow is REQUIRED: Cilium forwards pod traffic through the host, and UFW
# filters the FORWARD chain. Denying routed traffic breaks pod-to-pod networking.
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed
echo "  [OK] default policies: deny incoming, allow outgoing, allow routed"

# ── SSH (named OpenSSH profile) ───────────────────────────────────────────────
ufw allow OpenSSH
echo "  [OK] SSH (OpenSSH named profile)"

# ── Explicitly deny direct HTTP/HTTPS ─────────────────────────────────────────
# Ingress is fronted elsewhere (an outbound tunnel); no direct 80/443 on the node.
ufw deny 80/tcp   comment 'No direct HTTP'
ufw deny 443/tcp  comment 'No direct HTTPS'
echo "  [OK] deny 80/443"

# ── Pod network (Cilium kube-proxy replacement) ────────────────────────────────
# Cilium socket LB rewrites ClusterIP destinations to node-IP:port at the socket
# level. The resulting packet is host-bound (INPUT chain, not FORWARD), with source
# IP still set to a pod IP.  Without a blanket pod-CIDR rule the
# default deny-incoming policy drops all pod→host traffic, causing i/o timeouts on
# the API server (6443) and any other service whose endpoint is on this node.
# The pod CIDR is trusted internal traffic — pods are scheduled by kubelet and
# already allowed to do anything by Kubernetes RBAC.
ufw allow from "${POD_CIDR}" comment "Pod network (Cilium kube-proxy replacement)"
echo "  [OK] pod CIDR ${POD_CIDR} — all ports allowed (host-bound ClusterIP traffic)"

# ── Kubernetes control plane (LAN-restricted) ─────────────────────────────────
_allow 6443       tcp 'K8s API'
_allow 10250      tcp 'kubelet API'
_allow 10259      tcp 'kube-scheduler'
_allow 10257      tcp 'kube-controller-manager'
_allow 2379:2380  tcp 'etcd'
echo "  [OK] Kubernetes control plane (6443, 10250, 10259, 10257, 2379-2380)"

# ── NodePort services (LAN-restricted) ────────────────────────────────────────
# With an outbound tunnel, public traffic reaches services through the tunnel connector → ClusterIP,
# so NodePorts only serve direct LAN browser access (dashboards, metrics).
_allow 30000:32767 tcp 'NodePort services'
echo "  [OK] NodePort range (30000-32767/tcp)"

# ── Cilium ────────────────────────────────────────────────────────────────────
# 4244/tcp:  Hubble peer gRPC (Cilium agent). The hubble-relay pod connects to the
#            hubble-peer ClusterIP service; Cilium socket LB rewrites the destination
#            to node-IP:4244. That packet is host-bound (INPUT chain, not FORWARD),
#            so UFW's deny-incoming default drops it unless explicitly allowed here.
# 51871/udp: Cilium WireGuard transparent encryption (opened for when encryption
#            is enabled; harmless if not). VXLAN overlay (8472/udp) stays host-local
#            on a single node — open it when a second node joins:
#            ufw allow 8472/udp comment 'Cilium VXLAN'
# 9962/tcp:  Cilium agent Prometheus metrics (scraped by a metrics agent via the node IP).
_allow 4244  tcp 'Cilium Hubble peer gRPC'
_allow 51871 udp 'Cilium WireGuard'
_allow 9962  tcp 'Cilium metrics'
echo "  [OK] Cilium (4244/tcp Hubble peer, 51871/udp WireGuard, 9962/tcp metrics)"

# ── Longhorn (LAN-restricted) ─────────────────────────────────────────────────
# Longhorn manager/engine/replica ports span 9500-9600.
_allow 9500:9600 tcp 'Longhorn'
echo "  [OK] Longhorn (9500-9600/tcp)"

# ── Enable UFW ────────────────────────────────────────────────────────────────
ufw --force enable
ufw status verbose
trap - ERR
ufw status | grep -qiE 'OpenSSH|^22' || { echo "  [FAIL] SSH is not allowed in the active ruleset" >&2; exit 1; }
echo "  [OK] ufw enabled"

echo "==> 05-ufw: done"
