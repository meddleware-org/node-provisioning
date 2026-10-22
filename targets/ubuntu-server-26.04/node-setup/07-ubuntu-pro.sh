#!/usr/bin/env bash
# Ubuntu Pro service posture for a cluster node.
#
# The autoinstall `ubuntu-pro.token` key only ATTACHES the machine to Ubuntu Pro;
# which services end up enabled then depends on your online account defaults. This
# script makes the posture DETERMINISTIC and independent of those defaults by
# explicitly enabling the desired services and disabling the rest.
#
# Optimal set for this k8s node (Ubuntu 26.04):
#   enable : esm-infra   — security maintenance for the base OS
#            esm-apps    — security maintenance for universe packages
#            livepatch   — kernel-CVE mitigation WITHOUT reboots (pairs well with the
#                          kernel-upgrade blacklist in 50unattended-upgrades)
#   disable: landscape   — Canonical management/phone-home (not used here)
#            anbox-cloud  — Android-in-cloud (irrelevant)
#
# Services shown `n/a` by `pro status` on 26.04 (fips*, usg, cc-eal, ros*,
# realtime-kernel) are not applicable on this release and are skipped.
#
# Configurable and idempotent — safe to re-run.

set -euo pipefail

info() { echo "  [ubuntu-pro] $*"; }
ok()   { echo "  [OK] $*"; }

# Space- or comma-separated.
PRO_ENABLE="${PRO_ENABLE:-esm-infra esm-apps livepatch}"
PRO_DISABLE="${PRO_DISABLE:-landscape anbox-cloud}"
PRO_ENABLE="${PRO_ENABLE//,/ }"
PRO_DISABLE="${PRO_DISABLE//,/ }"

echo "==> 07-ubuntu-pro: enforcing Ubuntu Pro service posture"

# ── Preconditions ─────────────────────────────────────────────────────────────
if ! command -v pro &>/dev/null; then
  info "pro CLI not found (machine not on Ubuntu Pro) — skipping"
  echo "==> 07-ubuntu-pro: done (skipped)"
  exit 0
fi

# Only act on an attached machine. `pro status --format json` exposes `attached`.
attached="$(pro status --format json 2>/dev/null | { command -v jq >/dev/null && jq -r '.attached' || grep -o '"attached": *[a-z]*' | grep -o '[a-z]*$'; } || echo false)"
if [[ "${attached}" != "true" ]]; then
  info "Machine is not attached to Ubuntu Pro (no token) — skipping service posture"
  echo "==> 07-ubuntu-pro: done (unattached)"
  exit 0
fi

# Reduce apt-news noise (also set in 06-telemetry.sh; harmless to reassert).
pro config set apt_news=false 2>/dev/null || true

# _svc_status <service> -> prints the STATUS column (enabled|disabled|n/a|—)
_svc_status() {
  pro status --format json 2>/dev/null \
    | { command -v jq >/dev/null \
          && jq -r --arg s "$1" '.services[] | select(.name==$s) | .status' \
          || grep -A2 "\"name\": *\"$1\"" | grep -o '"status": *"[a-z/]*"' | grep -o '[a-z/]*"$' | tr -d '"'; } \
    | head -1
}

# ── Enable desired services (idempotent) ──────────────────────────────────────
for svc in ${PRO_ENABLE}; do
  st="$(_svc_status "${svc}")"
  case "${st}" in
    enabled)  ok "${svc} already enabled" ;;
    n/a|"")   info "${svc} is n/a on this release — skipping" ;;
    *)
      info "enabling ${svc}..."
      _out="$(pro enable "${svc}" --assume-yes 2>&1)" && ok "${svc} enabled" \
        || info "could not enable ${svc} (continuing): ${_out}"
      ;;
  esac
done

# ── Disable unwanted services (idempotent) ────────────────────────────────────
for svc in ${PRO_DISABLE}; do
  st="$(_svc_status "${svc}")"
  case "${st}" in
    disabled|n/a|"") ok "${svc} already off (${st:-n/a})" ;;
    *)               info "disabling ${svc}..."; pro disable "${svc}" --assume-yes >/dev/null && ok "${svc} disabled" || info "could not disable ${svc} (continuing)" ;;
  esac
done

echo "==> 07-ubuntu-pro: done"
