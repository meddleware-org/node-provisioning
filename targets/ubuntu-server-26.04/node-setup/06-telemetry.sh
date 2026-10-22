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
# Network-level fallback for components that have their own opt-out settings
# but may still attempt outbound connections before config is applied, or if
# a future update re-enables them by default.
#   stats.grafana.com       — Grafana analytics (grafana.ini reporting_enabled: false)
#   analytics.longhornio.com — Longhorn phone-home (allowCollectingLonghornUsageMetrics: false)
#   usage.juicefs.com       — JuiceFS client stats (StorageClass --no-usage-report)
#   sentry.io / o1368324.* — Ory SQA crash reporting (sqa.opt_out: true in all Ory configs)
# Idempotent: only adds the block if the marker is not already present.
HOSTS_MARKER="# Telemetry / analytics endpoint blocks"
if ! grep -qF "${HOSTS_MARKER}" /etc/hosts; then
  cat >> /etc/hosts <<'TELEMETRY_BLOCK'

# Telemetry / analytics endpoint blocks (added by 06-telemetry.sh)
127.0.0.1 motd.ubuntu.com
127.0.0.1 metrics.ubuntu.com
127.0.0.1 report.ubuntu.com
127.0.0.1 stats.grafana.com
127.0.0.1 analytics.longhornio.com
127.0.0.1 usage.juicefs.com
127.0.0.1 sentry.io
127.0.0.1 o1368324.ingest.sentry.io
TELEMETRY_BLOCK
  ok "/etc/hosts: telemetry domains blocked"
else
  ok "/etc/hosts: telemetry block already present (added by autoinstall)"
fi

echo "==> OS telemetry hardening complete"
