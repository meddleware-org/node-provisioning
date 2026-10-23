#!/usr/bin/env bash
# Fails when the repository contains values that must never be public: non-documentation IPv4 addresses,
# crypt password hashes, SSH public keys, Ubuntu Pro token shapes, or any term from a denylist.
# Findings are reported as file:line and kind only: the matched value is never printed.
#
# Usage: check-public-hygiene.sh [--site DIR] [--denylist FILE] [--print-denylist]
#   --site DIR       derive a denylist from a (private) site directory: hostnames, addresses, serials
#   --denylist FILE  extra terms, one per line (CI passes the HYGIENE_DENYLIST secret this way)
#   --print-denylist print the terms derived from --site (one per line) and exit, without scanning. Pipe it straight into the
#                    CI secret so the values never pass through a terminal log or a chat:
#                    check-public-hygiene.sh --site DIR --print-denylist | gh secret set HYGIENE_DENYLIST --repo ORG/REPO
# Allowlist: .hygiene-allowlist, lines "<kind>|<value>|<reason>" (kinds: ipv4 hash sshkey token term).
# A "term" entry waives one denylist term everywhere (for a value that is public on purpose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
SITE=""; DENY_FILE=""; PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:?}"; shift 2 ;;
    --denylist) DENY_FILE="${2:?}"; shift 2 ;;
    --print-denylist) PRINT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

TMP="$(mktemp -d)"
cleanup() { if [[ -n "${TMP}" && -d "${TMP}" && "${TMP##*/}" == tmp.* ]]; then rm -rf -- "${TMP}"; fi; }
trap cleanup EXIT

# Files to scan: tracked plus untracked-not-ignored (so a pre-commit run sees new files).
if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files --cached --others --exclude-standard -z >"${TMP}/files"
else
  find . -type f -not -path './.git/*' -print0 >"${TMP}/files"
fi

declare -A ALLOW=()
if [[ -f .hygiene-allowlist ]]; then
  while IFS='|' read -r kind value _reason; do
    [[ -z "${kind}" || "${kind}" == \#* ]] && continue
    ALLOW["${kind}|${value}"]=1
  done <.hygiene-allowlist
fi
allowed() { # kind value
  local k="$1" v="$2" key
  [[ -n "${ALLOW[${k}|${v}]+x}" ]] && return 0
  if [[ "${k}" != ipv4 ]]; then
    for key in "${!ALLOW[@]}"; do [[ "${key}" == "${k}|"* && "${v}" == "${key#"${k}|"}"* ]] && return 0; done
  fi
  return 1
}

FINDINGS=0
report() { echo "  [HYGIENE] $1:$2: $3" >&2; FINDINGS=$((FINDINGS + 1)); }

# scan <kind> <perl-regex>: report each match that is not allowlisted.
scan() {
  local kind="$1" re="$2" file line text
  while IFS= read -r -d '' file; do
    while IFS=: read -r line text; do
      [[ -n "${line}" ]] || continue
      if [[ "${kind}" == ipv4 ]]; then
        ipv4_is_documentation "${text}" && continue
      fi
      allowed "${kind}" "${text}" && continue
      report "${file}" "${line}" "${kind}"
    done < <(grep -n -I -o -P "${re}" -- "${file}" 2>/dev/null || true)
  done <"${TMP}/files"
}

ipv4_is_documentation() {
  local ip="$1" o IFS=.
  local -a oct
  read -r -a oct <<<"${ip}"
  for o in "${oct[@]}"; do (( 10#${o} <= 255 )) || return 0; done   # not an address (version string)
  case "${ip}" in
    192.0.2.*|198.51.100.*|203.0.113.*|0.0.0.0|127.0.0.1|255.255.255.*) return 0 ;;
  esac
  return 1
}

if (( PRINT == 0 )); then
scan ipv4   '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])'
scan hash   '\$(?:1|2[aby]|5|6|7|y|gy)\$[./A-Za-z0-9$,=_-]{8,}'
scan sshkey '(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) AAAA[0-9A-Za-z+/=]{20,}'
scan token  '\bC(?=[1-9A-HJ-NP-Za-km-z]*[0-9])[1-9A-HJ-NP-Za-km-z]{23,29}\b'
fi

# Denylist: terms from a file, the HYGIENE_DENYLIST variable, and values of a private site directory.
: >"${TMP}/deny"
[[ -n "${DENY_FILE}" && -f "${DENY_FILE}" ]] && cat "${DENY_FILE}" >>"${TMP}/deny"
[[ -n "${HYGIENE_DENYLIST:-}" ]] && printf '%s\n' "${HYGIENE_DENYLIST}" >>"${TMP}/deny"
if [[ -n "${SITE}" ]]; then
  [[ -d "${SITE}" ]] || { echo "site directory not found" >&2; exit 2; }
  {
    # KEY=value lines: keep values that identify (host names, addresses, serials).
    grep -h -E '^(HOSTNAME|NODE_IP|ADMIN_USER|OS_DISK_SERIAL|DATA_DISK_SERIAL|LAN_CIDR|POD_CIDR)=' "${SITE}"/site.env "${SITE}"/nodes/*.env 2>/dev/null | cut -d= -f2- | sed 's#/[0-9]*$##' || true
    # every IPv4 address and every search-domain in the YAML fragments
    grep -h -o -P '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])' "${SITE}"/*.yaml 2>/dev/null || true
    { grep -h -A3 -E '^\s*search:' "${SITE}"/*.yaml 2>/dev/null || true; } | grep -o -E '[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true
  } | awk 'length($0) >= 5' | { grep -v -i -x -E 'admin|administrator|root|ubuntu|user|localhost|node[0-9]*' || true; } | sort -u >>"${TMP}/deny"
fi
# A copy from a terminal can carry CR or stray blanks; a term with trailing spaces would silently never match.
sed -i -E 's/\r//g; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "${TMP}/deny"
sort -u "${TMP}/deny" -o "${TMP}/deny"
if (( PRINT == 1 )); then cat "${TMP}/deny"; exit 0; fi
echo "  [hygiene] denylist: $(wc -l <"${TMP}/deny") term(s) loaded"
# Each term is checked on its own so the allowlist can waive one (kind "term") with a stated reason.
while IFS= read -r term; do
  [[ -n "${term}" ]] || continue
  [[ -n "${ALLOW[term|${term}]+x}" ]] && continue
  while IFS= read -r -d '' file; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] && report "${file}" "${line}" "denylisted term"
    done < <(grep -n -I -i -F -e "${term}" -- "${file}" 2>/dev/null | cut -d: -f1 || true)
  done <"${TMP}/files"
done <"${TMP}/deny"

if (( FINDINGS > 0 )); then
  echo "  [FAIL] ${FINDINGS} hygiene finding(s). Remove the value, or add a reasoned entry to .hygiene-allowlist." >&2
  exit 1
fi
echo "  [OK] public hygiene: no identifying or secret-shaped values"
