#!/usr/bin/env bash
# Disable OS-level telemetry and phone-home services.
#
# This script runs on the live system (post-boot) and complements the
# late-commands in user-data.yaml, which only cover what can be done inside
# the installer chroot. Some services (snap, ubuntu-report, ubuntu-pro) are
# not available during the chroot and must be configured here.
#
# Idempotent — safe to re-run.

set -euo pipefail

info() { echo "  [telemetry] $*"; }
ok()   { echo "  [OK] $*"; }

echo "==> Disabling OS telemetry and phone-home services"

# ── Apport (crash reporter → Canonical) ──────────────────────────────────────
if [[ -f /etc/default/apport ]]; then
  sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
  systemctl stop apport.service 2>/dev/null || true
  systemctl disable apport.service 2>/dev/null || true
  ok "apport crash reporter disabled"
else
  info "apport config not found — skipping"
fi

# ── MOTD news (contacts motd.ubuntu.com on SSH login) ────────────────────────
systemctl stop motd-news.timer 2>/dev/null || true
systemctl disable motd-news.timer 2>/dev/null || true
ok "motd-news timer disabled"

# ── ubuntu-report (one-shot system metrics → Canonical) ──────────────────────
if command -v ubuntu-report &>/dev/null; then
  ubuntu-report send no 2>/dev/null || true
  ok "ubuntu-report: opted out"
else
  info "ubuntu-report not found — skipping"
fi

# ── Popularity Contest (reports package usage → Canonical) ───────────────────
if [[ -f /etc/popularity-contest.conf ]]; then
  sed -i 's/^PARTICIPATE=.*/PARTICIPATE=no/' /etc/popularity-contest.conf
  ok "popularity-contest: PARTICIPATE=no"
else
  echo 'PARTICIPATE=no' > /etc/popularity-contest.conf
  ok "popularity-contest: created with PARTICIPATE=no"
fi

# ── Ubuntu Pro / ubuntu-advantage (apt news, MOTD messaging) ─────────────────
if command -v pro &>/dev/null; then
  pro config set apt_news=false 2>/dev/null || true
  ok "ubuntu-pro: apt_news=false"
else
  info "ubuntu-pro CLI not found — skipping"
fi

# Disable landscape-sysinfo if present (contacts Canonical Landscape)
if command -v landscape-config &>/dev/null; then
  landscape-config --disable 2>/dev/null || true
  ok "landscape-sysinfo disabled"
fi

# ── Snap metrics ─────────────────────────────────────────────────────────────
if command -v snap &>/dev/null; then
  snap set system metrics.enabled=false 2>/dev/null || true
  ok "snap: metrics.enabled=false"
else
  info "snap not found — skipping"
fi

# ── /etc/hosts telemetry block (belt-and-suspenders) ─────────────────────────
# Network-level fallback for components that have their own opt-out settings but may still attempt
# outbound connections before the opt-out is applied, or if an update re-enables them by default.
# The Ubuntu hosts below are built in; anything specific to the services you run (analytics and crash-report
# endpoints of third-party software) comes from TELEMETRY_HOSTS_EXTRA (comma-separated host names).
# Idempotent and MERGING: each missing entry is added individually, so entries the installer already wrote
# neither suppress nor duplicate the rest.
HOSTS_MARKER="# Telemetry / analytics endpoint blocks"
DEFAULT_HOSTS="motd.ubuntu.com metrics.ubuntu.com report.ubuntu.com"
EXTRA_HOSTS="${TELEMETRY_HOSTS_EXTRA:-}"
EXTRA_HOSTS="${EXTRA_HOSTS//,/ }"
added=0
for host in ${DEFAULT_HOSTS} ${EXTRA_HOSTS}; do
  [[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "  [FAIL] invalid host name in TELEMETRY_HOSTS_EXTRA" >&2; exit 1; }
done
for host in ${DEFAULT_HOSTS} ${EXTRA_HOSTS}; do
  if ! grep -qE "^127\.0\.0\.1[[:space:]]+${host//./\\.}([[:space:]]|\$)" /etc/hosts; then
    if (( added == 0 )) && ! grep -qF "${HOSTS_MARKER}" /etc/hosts; then
      printf '\n%s (added by node-provisioning)\n' "${HOSTS_MARKER}" >> /etc/hosts
    fi
    echo "127.0.0.1 ${host}" >> /etc/hosts
    added=$((added + 1))
  fi
done
ok "/etc/hosts: telemetry domains blocked (${added} entries added)"

echo "==> OS telemetry hardening complete"
