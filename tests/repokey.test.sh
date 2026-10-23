#!/usr/bin/env bash
# repokey.sh: a third-party apt signing key is installed only when every primary key in the download is pinned, unexpired
# and unrevoked. Real gpg with throwaway keys; curl is a stub that "downloads" a local file. Hermetic.
source "$(dirname "$0")/lib.sh"
command -v gpg >/dev/null 2>&1 || { echo "  skip: gpg not installed"; exit 0; }
LIB="${ROOT}/targets/ubuntu-server-26.04/node-setup/repokey.sh"
GH="${T_TMP}/gh"; mkdir -p "${GH}"; chmod 700 "${GH}"
STUB="${T_TMP}/bin"; mkdir -p "${STUB}"
cat >"${STUB}/curl" <<'STUBEOF'
#!/bin/bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[[ -f "${NP_TEST_SERVE:-/nonexistent}" ]] || exit 22
cp "${NP_TEST_SERVE}" "${out}"
STUBEOF
chmod +x "${STUB}/curl"

mkkey() { # name [expiry]
  GNUPGHOME="${GH}" gpg --batch --quiet --passphrase '' --quick-generate-key "$1 <$1@example.invalid>" ed25519 sign "${2:-never}" 2>/dev/null
  GNUPGHOME="${GH}" gpg --batch --with-colons --fingerprint "$1@example.invalid" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'
}
armor() { GNUPGHOME="${GH}" gpg --batch --armor --export "$@" 2>/dev/null; }

F_A="$(mkkey keya)"; F_B="$(mkkey keyb)"; mkkey keyx >/dev/null; F_SOON="$(mkkey keysoon seconds=1)"
armor keya@example.invalid >"${T_TMP}/a.asc"
armor keyb@example.invalid >"${T_TMP}/b.asc"
armor keya@example.invalid keyx@example.invalid >"${T_TMP}/ax.asc"
armor keysoon@example.invalid >"${T_TMP}/soon.asc"
echo "not a key" >"${T_TMP}/junk.asc"
sleep 3   # let the 1-second key expire

KR="${T_TMP}/keyrings/test.gpg"
call() { OUT="$(NP_TEST_SERVE="$1" PATH="${STUB}:${PATH}" bash -c 'source "$1"; np_install_repo_key Test https://example.invalid/key "$2" "$3"' _ "${LIB}" "${KR}" "$2" 2>&1)"; RC=$?; }

call "${T_TMP}/a.asc" "${F_A}"
[[ "${RC}" -eq 0 && -f "${KR}" && "${OUT}" == *installed* ]] && ok "pinned fingerprint is installed" || bad "pinned fingerprint is installed: ${OUT}"
[[ "$(stat -c %a "${KR}")" == 644 ]] && ok "keyring mode is 0644" || bad "keyring mode is 0644"
[[ "$(GNUPGHOME="${GH}" gpg --batch --show-keys --with-colons "${KR}" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')" == "${F_A}" ]] && ok "keyring is binary and holds the pinned key" || bad "keyring is binary and holds the pinned key"
H1="$(sha256sum "${KR}")"
call "${T_TMP}/a.asc" "${F_A}"
[[ "${RC}" -eq 0 && "${OUT}" == *unchanged* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "second run reports unchanged" || bad "second run reports unchanged: ${OUT}"
call "${T_TMP}/a.asc" "$(echo "${F_A}" | tr 'A-F' 'a-f')"
[[ "${RC}" -eq 0 ]] && ok "fingerprint comparison is case-insensitive" || bad "fingerprint comparison is case-insensitive"
call "${T_TMP}/a.asc" "${F_B},${F_A}"
[[ "${RC}" -eq 0 ]] && ok "several allowed fingerprints (comma list)" || bad "several allowed fingerprints (comma list)"

call "${T_TMP}/b.asc" "${F_A}"
[[ "${RC}" -ne 0 && "${OUT}" == *"not one of the pinned"* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "unlisted fingerprint refused, keyring untouched" || bad "unlisted fingerprint refused: ${OUT}"
call "${T_TMP}/ax.asc" "${F_A}"
[[ "${RC}" -ne 0 && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "an extra smuggled primary key is refused" || bad "an extra smuggled primary key is refused"
call "${T_TMP}/soon.asc" "${F_SOON}"
[[ "${RC}" -ne 0 && "${OUT}" == *"expired or revoked"* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "expired key refused, keyring untouched" || bad "expired key refused: ${OUT}"
call "${T_TMP}/junk.asc" "${F_A}"
[[ "${RC}" -ne 0 && "${OUT}" == *"not an OpenPGP"* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "non-key download refused" || bad "non-key download refused: ${OUT}"
call "${T_TMP}/missing.asc" "${F_A}"
[[ "${RC}" -ne 0 && "${OUT}" == *"could not download"* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "download failure keeps the old keyring" || bad "download failure keeps the old keyring: ${OUT}"
call "${T_TMP}/a.asc" ""
[[ "${RC}" -ne 0 && "${OUT}" == *"no fingerprint is pinned"* ]] && ok "an empty pin set is refused" || bad "an empty pin set is refused"

# a stale keyring is refreshed when the served key differs (an extended expiry produces different bytes)
printf 'stale' >"${KR}"
call "${T_TMP}/a.asc" "${F_A}"
[[ "${RC}" -eq 0 && "${OUT}" == *installed* && "$(sha256sum "${KR}")" == "${H1}" ]] && ok "stale keyring is refreshed" || bad "stale keyring is refreshed: ${OUT}"
left=(); for f in "$(dirname "${KR}")"/*; do [[ "${f##*/}" == test.gpg ]] || left+=("${f}"); done
[[ ${#left[@]} -eq 0 ]] && ok "no temporary files left in the keyring directory" || bad "no temporary files left in the keyring directory"
finish
