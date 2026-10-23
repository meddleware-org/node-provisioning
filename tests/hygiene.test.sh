#!/usr/bin/env bash
# The hygiene check must flag every secret-shaped or identifying value, never print the value,
# honour the allowlist, and pass on documentation addresses.
source "$(dirname "$0")/lib.sh"
R="${T_TMP}/repo"; mkdir -p "${R}/scripts"
cp "${ROOT}/scripts/check-public-hygiene.sh" "${R}/scripts/"
H() { bash "${R}/scripts/check-public-hygiene.sh" "$@" 2>&1; }

echo 'documentation only: 192.0.2.7 198.51.100.2 203.0.113.9 127.0.0.1 version 999.1.1.1 and 1.2.3' >"${R}/ok.md"
check "clean repository passes" bash -c "bash '${R}/scripts/check-public-hygiene.sh' >/dev/null 2>&1"

expect_finding() { # name file-content kind value-that-must-not-appear
  printf '%s\n' "$2" >"${R}/bad.txt"
  OUT="$(H)"; RC=$?
  if [[ "${RC}" -ne 0 && "${OUT}" == *"bad.txt:1: $3"* ]]; then ok "$1 is flagged"; else bad "$1 is flagged (rc=${RC})"; fi
  if [[ "${OUT}" == *"$4"* ]]; then bad "$1: finding output leaked the value"; else ok "$1: value not printed"; fi
}
# Sample values are assembled at run time so this file holds no secret-shaped literal.
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "${s}"; }
D='$'
IP="10.20"; IP+=".30.40"
HASH6="${D}6${D}abcdefgh${D}$(rep A 60)"
HASHY="${D}y${D}j9T${D}abcdefghijkl${D}$(rep z 43)"
KEY_ED="ssh-ed25519 AAAAC3NzaC1l"; KEY_ED+="ZDI1NTE5AAAA$(rep Q 48) me"
KEY_RSA="ssh-rsa AAAAB3NzaC1y"; KEY_RSA+="c2EAAAADAQAB$(rep x 40)"
TOKEN="C7Gh3jK9"; TOKEN+="mNpQ2rSt"; TOKEN+="VwXyZ4bcd5"
expect_finding "private IPv4"  "host ${IP} here"   ipv4   "${IP}"
expect_finding "sha512 hash"   "p: ${HASH6}"       hash   "$(rep A 24)"
expect_finding "yescrypt hash" "p: ${HASHY}"       hash   "$(rep z 16)"
expect_finding "ed25519 key"   "k: ${KEY_ED}"      sshkey "$(rep Q 16)"
expect_finding "rsa key"       "k: ${KEY_RSA}"     sshkey "$(rep x 16)"
expect_finding "Pro token"     "t: ${TOKEN}"       token  "${TOKEN}"
rm -f -- "${R}/bad.txt"

# allowlist: exact value allowed, anything else still flagged
echo "x ${IP}" >"${R}/a.txt"
check "ipv4 flagged before allowlisting" bash -c "! bash '${R}/scripts/check-public-hygiene.sh' >/dev/null 2>&1"
echo "ipv4|${IP}|test" >"${R}/.hygiene-allowlist"
check "allowlisted ipv4 passes"          bash -c "bash '${R}/scripts/check-public-hygiene.sh' >/dev/null 2>&1"
echo "y ${IP%0}1" >>"${R}/a.txt"
check "a different ipv4 is still flagged" bash -c "! bash '${R}/scripts/check-public-hygiene.sh' >/dev/null 2>&1"
rm -f -- "${R}/a.txt" "${R}/.hygiene-allowlist"

# denylist: file, environment variable and site-derived terms, case-insensitive, term never printed
echo 'we deploy to PRODHOST-01 daily' >"${R}/d.txt"
printf 'prodhost-01\n' >"${T_TMP}/deny"
OUT="$(H --denylist "${T_TMP}/deny")"; RC=$?
[[ "${RC}" -ne 0 && "${OUT}" == *"d.txt:1: denylisted term"* && "${OUT}" != *PRODHOST* && "${OUT}" != *prodhost* ]] && ok "denylist file term flagged, not printed" || bad "denylist file term flagged, not printed"
OUT="$(HYGIENE_DENYLIST='prodhost-01' H)"; RC=$?
[[ "${RC}" -ne 0 ]] && ok "HYGIENE_DENYLIST variable flagged" || bad "HYGIENE_DENYLIST variable flagged"
mkdir -p "${T_TMP}/site/nodes"
printf 'ADMIN_USER=admin\n' >"${T_TMP}/site/site.env"; printf 'HOSTNAME=prodhost-01\nNODE_IP=192.0.2.50\n' >"${T_TMP}/site/nodes/n.env"
OUT="$(H --site "${T_TMP}/site")"; RC=$?
[[ "${RC}" -ne 0 && "${OUT}" == *"d.txt:1: denylisted term"* ]] && ok "site-derived hostname flagged" || bad "site-derived hostname flagged: ${OUT}"
OUT="$(H --site "${T_TMP}/site" --print-denylist)"; RC=$?
[[ "${RC}" -eq 0 && "${OUT}" == *prodhost-01* && "${OUT}" == *192.0.2.50* ]] && ok "--print-denylist prints the derived terms" || bad "--print-denylist prints the derived terms"
echo 'prodhost-01 is waived' >"${R}/d.txt"
echo 'term|prodhost-01|public on purpose' >"${R}/.hygiene-allowlist"
OUT="$(H --site "${T_TMP}/site")"; RC=$?
[[ "${RC}" -eq 0 ]] && ok "an allowlisted term is waived" || bad "an allowlisted term is waived: ${OUT}"
rm -f -- "${R}/.hygiene-allowlist"
echo 'ok again' >"${R}/d.txt"
OUT="$(H --site "${T_TMP}/site")"; RC=$?
[[ "${RC}" -eq 0 ]] && ok "passes once the term is removed" || bad "passes once the term is removed: ${OUT}"
finish
