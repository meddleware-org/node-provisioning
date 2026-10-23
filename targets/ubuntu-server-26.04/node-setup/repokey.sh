#!/usr/bin/env bash
# Shared helper (sourced by 03-crio.sh and 04-kubetools.sh): install the signing key of a third-party apt repository.
#
#   np_install_repo_key <name> <url> <keyring-path> <allowed-fingerprints>
#
# The key is downloaded on EVERY run (so an upstream extension of its expiry is picked up) and checked before it is trusted:
#   * every primary key in the download must have a fingerprint in the allowed set (comma or space separated, 40 hex digits). A
#     key that is not listed, or an extra key smuggled into the same file, is refused: apt would trust all of them;
#   * no primary key may be expired or revoked (an expired key is refused, never bypassed);
#   * only then is the keyring written (binary, mode 0644, replaced only when it changed).
# The fingerprints are public values. They are pinned in the scripts after being cross-checked against independent sources
# (public keyservers and a Kubernetes SIG repository that pins the same values); a rotation by the vendor therefore fails closed
# here and is adopted deliberately, by adding the new fingerprint to the site (KUBE_REPO_KEY_FPRS / CRIO_REPO_KEY_FPRS).
# A throwaway GnuPG home is used, so nothing is written to the invoking user's keyring.
# shellcheck shell=bash

np_install_repo_key() {
  local name="$1" url="$2" keyring="$3" allowed="${4//,/ }" work gnupg fpr a ok n=0 now status exp
  [[ -n "${allowed// /}" ]] || { echo "  [FAIL] no fingerprint is pinned for the ${name} repository key" >&2; return 1; }
  work="$(mktemp -d)"; gnupg="${work}/gnupg"; mkdir -m 700 "${gnupg}"
  _np_rk_cleanup() { if [[ -n "${work:-}" && -d "${work}" && "${work##*/}" == tmp.* ]]; then rm -rf -- "${work}"; fi; }

  if ! curl -fsSL --max-time 60 -o "${work}/key.asc" "${url}"; then
    _np_rk_cleanup; echo "  [FAIL] could not download the ${name} repository key" >&2; return 1
  fi
  if ! GNUPGHOME="${gnupg}" gpg --batch --show-keys --with-colons "${work}/key.asc" >"${work}/info" 2>/dev/null || ! grep -q '^pub:' "${work}/info"; then
    _np_rk_cleanup; echo "  [FAIL] the ${name} repository download is not an OpenPGP public key" >&2; return 1
  fi

  now="$(date +%s)"
  # records: pub:<validity>:...:<expiry>... then fpr:...:<fingerprint>: for each primary key
  while IFS=: read -r kind c2 _ _ _ _ c7 _ _ c10 _; do
    case "${kind}" in
      pub) status="${c2}"; exp="${c7}" ;;
      fpr)
        [[ -n "${status:-}" ]] || continue            # the fpr of a subkey follows "sub", not "pub": skipped via status reset below
        fpr="${c10^^}"; n=$((n + 1)); ok=0
        for a in ${allowed}; do [[ "${a^^}" == "${fpr}" ]] && ok=1; done
        if (( ok == 0 )); then
          _np_rk_cleanup; echo "  [FAIL] the ${name} repository key ${fpr} is not one of the pinned fingerprints (${allowed}); refusing it. If the vendor rotated the key, verify the new fingerprint independently and add it to the site." >&2; return 1
        fi
        if [[ "${status}" == r || "${status}" == e || ( -n "${exp}" && "${exp}" -le "${now}" ) ]]; then
          _np_rk_cleanup; echo "  [FAIL] the ${name} repository key ${fpr} is expired or revoked; refusing it (apt would reject the repository too)." >&2; return 1
        fi
        if [[ -n "${exp}" ]] && (( exp - now < 60 * 86400 )); then
          echo "  [WARN] the ${name} repository key ${fpr} expires on $(date -u -d "@${exp}" +%Y-%m-%d); upstream must extend or replace it" >&2
        fi
        status="" ;;
      sub) status="" ;;
    esac
  done <"${work}/info"
  (( n > 0 )) || { _np_rk_cleanup; echo "  [FAIL] no primary key found in the ${name} repository download" >&2; return 1; }

  GNUPGHOME="${gnupg}" gpg --batch --dearmor -o "${work}/key.gpg" <"${work}/key.asc" 2>/dev/null || { _np_rk_cleanup; echo "  [FAIL] could not convert the ${name} repository key" >&2; return 1; }
  install -m 0755 -d "$(dirname "${keyring}")"
  if [[ -f "${keyring}" ]] && cmp -s "${work}/key.gpg" "${keyring}"; then
    echo "  [OK] ${name} repository key ${fpr} unchanged"
  else
    # run as root by the node setup, so the file is root-owned without naming the owner (the tests run unprivileged)
    if ! { install -m 0644 "${work}/key.gpg" "${keyring}.new" && mv -f "${keyring}.new" "${keyring}"; }; then
      rm -f -- "${keyring}.new"; _np_rk_cleanup; echo "  [FAIL] could not install the ${name} repository key" >&2; return 1
    fi
    echo "  [OK] ${name} repository key ${fpr} installed"
  fi
  _np_rk_cleanup
}
