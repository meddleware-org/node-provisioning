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

# np_install_repo_key <name> <url> <keyring-path> <allowed-fingerprints>: see the header. Returns 0 when the keyring is in place, 1 when the key was refused or could not be installed.
np_install_repo_key() {
  local name="$1" url="$2" keyring="$3" allowed="${4//,/ }" work gnupg fpr a ok n=0 now status exp
  # Pinning nothing would trust anything, so no fingerprint is an error.
  [[ -n "${allowed// /}" ]] || { echo "  [FAIL] no fingerprint is pinned for the ${name} repository key" >&2; return 1; }
  # A scratch directory and a private GnuPG home inside it, so nothing is written to anyone's own keyring.
  work="$(mktemp -d)"; gnupg="${work}/gnupg"; mkdir -m 700 "${gnupg}"
  # _np_rk_cleanup: remove the scratch directory (only a `tmp.*` directory is ever removed); every exit path calls it.
  _np_rk_cleanup() { if [[ -n "${work:-}" && -d "${work}" && "${work##*/}" == tmp.* ]]; then rm -rf -- "${work}"; fi; }

  # Download the key every run, so an upstream extension of its expiry is picked up.
  if ! curl -fsSL --max-time 60 -o "${work}/key.asc" "${url}"; then
    _np_rk_cleanup; echo "  [FAIL] could not download the ${name} repository key" >&2; return 1
  fi
  # What was downloaded must be an OpenPGP public key; the machine-readable listing is parsed below.
  if ! GNUPGHOME="${gnupg}" gpg --batch --show-keys --with-colons "${work}/key.asc" >"${work}/info" 2>/dev/null || ! grep -q '^pub:' "${work}/info"; then
    _np_rk_cleanup; echo "  [FAIL] the ${name} repository download is not an OpenPGP public key" >&2; return 1
  fi

  # The current time, to compare with each key's expiry.
  now="$(date +%s)"
  # Records: pub:<validity>:...:<expiry>... then fpr:...:<fingerprint>: for each primary key.
  # records: pub:<validity>:...:<expiry>... then fpr:...:<fingerprint>: for each primary key
  # Walk the colon-separated listing: a `pub` line starts a primary key (validity and expiry), the `fpr` line after it carries its fingerprint, and a `sub` line (a subkey) resets the state so a subkey's fingerprint is never read as a primary key.
  while IFS=: read -r kind c2 _ _ _ _ c7 _ _ c10 _; do
    case "${kind}" in
      pub) status="${c2}"; exp="${c7}" ;;
      fpr)
        [[ -n "${status:-}" ]] || continue            # the fpr of a subkey follows "sub", not "pub": skipped via status reset below
        fpr="${c10^^}"; n=$((n + 1)); ok=0
        # The fingerprint must be one of the pinned values (compared in upper case).
        for a in ${allowed}; do [[ "${a^^}" == "${fpr}" ]] && ok=1; done
        if (( ok == 0 )); then
          _np_rk_cleanup; echo "  [FAIL] the ${name} repository key ${fpr} is not one of the pinned fingerprints (${allowed}); refusing it. If the vendor rotated the key, verify the new fingerprint independently and add it to the site." >&2; return 1
        fi
        # A revoked or expired key is refused, never bypassed.
        if [[ "${status}" == r || "${status}" == e || ( -n "${exp}" && "${exp}" -le "${now}" ) ]]; then
          _np_rk_cleanup; echo "  [FAIL] the ${name} repository key ${fpr} is expired or revoked; refusing it (apt would reject the repository too)." >&2; return 1
        fi
        # A key within sixty days of expiry still works but warns, so the maintainer can act before it fails.
        if [[ -n "${exp}" ]] && (( exp - now < 60 * 86400 )); then
          echo "  [WARN] the ${name} repository key ${fpr} expires on $(date -u -d "@${exp}" +%Y-%m-%d); upstream must extend or replace it" >&2
        fi
        status="" ;;
      sub) status="" ;;
    esac
  done <"${work}/info"
  # At least one primary key must have been found.
  (( n > 0 )) || { _np_rk_cleanup; echo "  [FAIL] no primary key found in the ${name} repository download" >&2; return 1; }

  # Convert the armoured key to the binary form apt reads.
  GNUPGHOME="${gnupg}" gpg --batch --dearmor -o "${work}/key.gpg" <"${work}/key.asc" 2>/dev/null || { _np_rk_cleanup; echo "  [FAIL] could not convert the ${name} repository key" >&2; return 1; }
  # Make sure the keyring directory exists.
  install -m 0755 -d "$(dirname "${keyring}")"
  # Replace the keyring only when it changed, so a re-run changes nothing.
  if [[ -f "${keyring}" ]] && cmp -s "${work}/key.gpg" "${keyring}"; then
    echo "  [OK] ${name} repository key ${fpr} unchanged"
  else
    # run as root by the node setup, so the file is root-owned without naming the owner (the tests run unprivileged)
    # Write beside the target and rename, so a partial write can never leave a broken keyring.
    if ! { install -m 0644 "${work}/key.gpg" "${keyring}.new" && mv -f "${keyring}.new" "${keyring}"; }; then
      rm -f -- "${keyring}.new"; _np_rk_cleanup; echo "  [FAIL] could not install the ${name} repository key" >&2; return 1
    fi
    echo "  [OK] ${name} repository key ${fpr} installed"
  fi
  _np_rk_cleanup
}
