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
# Exit codes: 0 when clean, 1 when there are findings, 2 for a bad option or a missing site directory. Environment: HYGIENE_DENYLIST
# # (extra terms, one per line). The scan covers every file git would commit; a value in a message is never printed, only its place.
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail

# The repository root, so the script works from any directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# Option values and whether to print the denylist instead of scanning.
SITE=""; DENY_FILE=""; PRINT=0
# Parse the options; an unknown one is a usage error.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:?}"; shift 2 ;;
    --denylist) DENY_FILE="${2:?}"; shift 2 ;;
    --print-denylist) PRINT=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# A scratch directory for the file list and the denylist; removed on exit.
TMP="$(mktemp -d)"
# cleanup: remove the scratch directory. Only a `tmp.*` directory is ever removed.
cleanup() { if [[ -n "${TMP}" && -d "${TMP}" && "${TMP##*/}" == tmp.* ]]; then rm -rf -- "${TMP}"; fi; }
# Always clean up, even after a failure.
trap cleanup EXIT

# Files to scan: tracked plus untracked-not-ignored (so a pre-commit run sees new files).
# Inside a git checkout use git's own list (so ignored files are skipped); otherwise scan every file except .git.
if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files --cached --others --exclude-standard -z >"${TMP}/files"
else
  find . -type f -not -path './.git/*' -print0 >"${TMP}/files"
fi

# The allowlist: reasoned exceptions, keyed by kind and value.
declare -A ALLOW=()
# Each line is kind|value|reason. The reason is required reading for reviewers and is not used by the script.
if [[ -f .hygiene-allowlist ]]; then
  while IFS='|' read -r kind value _reason; do
    [[ -z "${kind}" || "${kind}" == \#* ]] && continue
    ALLOW["${kind}|${value}"]=1
  done <.hygiene-allowlist
fi
# allowed <kind> <value>: succeed when the allowlist waives this finding. An exact match always waives; for kinds other than ipv4 a listed prefix waives every value that starts with it (a public key's type and start, for example).
allowed() { # kind value
  local k="$1" v="$2" key
  [[ -n "${ALLOW[${k}|${v}]+x}" ]] && return 0
  if [[ "${k}" != ipv4 ]]; then
    for key in "${!ALLOW[@]}"; do [[ "${key}" == "${k}|"* && "${v}" == "${key#"${k}|"}"* ]] && return 0; done
  fi
  return 1
}

# The number of findings reported so far.
FINDINGS=0
# report <file> <line> <kind>: print one finding (place and kind, never the matched text) and count it.
report() { echo "  [HYGIENE] $1:$2: $3" >&2; FINDINGS=$((FINDINGS + 1)); }

# scan <kind> <perl-regex>: report each match in the scanned files that is not allowlisted.
scan() {
  local kind="$1" re="$2" file line text
  while IFS= read -r -d '' file; do
    while IFS=: read -r line text; do
      [[ -n "${line}" ]] || continue
      # Documentation and unspecified addresses are fine to publish.
      if [[ "${kind}" == ipv4 ]]; then
        ipv4_is_documentation "${text}" && continue
      fi
      # An allowlisted value is skipped.
      allowed "${kind}" "${text}" && continue
      report "${file}" "${line}" "${kind}"
    done < <(grep -n -I -o -P "${re}" -- "${file}" 2>/dev/null || true)
  done <"${TMP}/files"
}

# ipv4_is_documentation <text>: succeed for text that is safe to publish as an address: not an address at all (a version string with an octet above 255), or a documentation range, loopback or the unspecified or broadcast-style values.
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

# The four secret-shaped scans (skipped when only the denylist is being printed): addresses, crypt password hashes, SSH public keys and Ubuntu Pro token shapes.
if (( PRINT == 0 )); then
# Dotted quads that are not part of a longer number or version string.
scan ipv4   '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])'
# A crypt hash with a known scheme prefix and a body.
scan hash   '\$(?:1|2[aby]|5|6|7|y|gy)\$[./A-Za-z0-9$,=_-]{8,}'
# A supported SSH public key type followed by a base64 body.
scan sshkey '(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) AAAA[0-9A-Za-z+/=]{20,}'
# A Pro token shape: C then 23 to 29 base58 characters containing at least one digit (so ordinary words are not flagged).
scan token  '\bC(?=[1-9A-HJ-NP-Za-km-z]*[0-9])[1-9A-HJ-NP-Za-km-z]{23,29}\b'
fi

# The denylist is built from a file, the environment, and the values of a private site directory.
# Denylist: terms from a file, the HYGIENE_DENYLIST variable, and values of a private site directory.
# Start empty, then add each source.
: >"${TMP}/deny"
[[ -n "${DENY_FILE}" && -f "${DENY_FILE}" ]] && cat "${DENY_FILE}" >>"${TMP}/deny"
[[ -n "${HYGIENE_DENYLIST:-}" ]] && printf '%s\n' "${HYGIENE_DENYLIST}" >>"${TMP}/deny"
# With a site directory, derive the terms that identify it.
if [[ -n "${SITE}" ]]; then
  [[ -d "${SITE}" ]] || { echo "site directory not found" >&2; exit 2; }
  {
    # KEY=value lines: keep values that identify (host names, addresses, serials).
    # Values of the identifying keys (host name, address, user, serials, networks), with a trailing prefix length removed.
    grep -h -E '^(HOSTNAME|NODE_IP|ADMIN_USER|OS_DISK_SERIAL|DATA_DISK_SERIAL|LAN_CIDR|POD_CIDR)=' "${SITE}"/site.env "${SITE}"/nodes/*.env 2>/dev/null | cut -d= -f2- | sed 's#/[0-9]*$##' || true
    # every IPv4 address and every search-domain in the YAML fragments
    # Every address in the site's YAML fragments.
    grep -h -o -P '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])' "${SITE}"/*.yaml 2>/dev/null || true
    # Every search domain in the YAML fragments.
    { grep -h -A3 -E '^\s*search:' "${SITE}"/*.yaml 2>/dev/null || true; } | grep -o -E '[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true
  } | awk 'length($0) >= 5' | { grep -v -i -x -E 'admin|administrator|root|ubuntu|user|localhost|node[0-9]*' || true; } | sort -u >>"${TMP}/deny"
fi
# A copy from a terminal can carry CR or stray blanks; a term with trailing spaces would silently never match.
sed -i -E 's/\r//g; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "${TMP}/deny"
# One of each term.
sort -u "${TMP}/deny" -o "${TMP}/deny"
# --print-denylist: print the terms and stop, so they can be piped into a secret store without showing them.
if (( PRINT == 1 )); then cat "${TMP}/deny"; exit 0; fi
# Say how many terms were loaded (a count, not the terms).
echo "  [hygiene] denylist: $(wc -l <"${TMP}/deny") term(s) loaded"
# Each term is checked on its own so the allowlist can waive one (kind "term") with a stated reason.
while IFS= read -r term; do
  [[ -n "${term}" ]] || continue
  # A waived term is skipped everywhere.
  [[ -n "${ALLOW[term|${term}]+x}" ]] && continue
  while IFS= read -r -d '' file; do
    while IFS= read -r line; do
      [[ -n "${line}" ]] && report "${file}" "${line}" "denylisted term"
    done < <(grep -n -I -i -F -e "${term}" -- "${file}" 2>/dev/null | cut -d: -f1 || true)
  done <"${TMP}/files"
done <"${TMP}/deny"

# Any finding fails the run, with the way out in the message.
if (( FINDINGS > 0 )); then
  echo "  [FAIL] ${FINDINGS} hygiene finding(s). Remove the value, or add a reasoned entry to .hygiene-allowlist." >&2
  exit 1
fi
echo "  [OK] public hygiene: no identifying or secret-shaped values"
