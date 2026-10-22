#!/usr/bin/env bash
# Fetch the Subiquity autoinstall JSON schema, pinned by commit and checksum.
# The schema is AGPL-licensed: it is downloaded for validation and never vendored into this repository.
# Pinned to Subiquity tag 26.04.1 (the installer shipped on the Ubuntu Server 26.04.1 ISO).
# Usage: fetch-subiquity-schema.sh [destination]   (default: .cache/autoinstall-schema.json)
set -euo pipefail

COMMIT="f759e0adbdc20ceab674946f9be42ed4c0c4f18c"
SHA256="beb72fefb590af5dfaaa615f6836c56fd74451f31b21dca631cb8c414f45a2ae"
RESERVED_SHA256="f9d71784f3e16405ebb2a7e090994746ca8d8d1c99af7edf6bca9fbb275a08e2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-${ROOT}/.cache/autoinstall-schema.json}"
URL="https://raw.githubusercontent.com/canonical/subiquity/${COMMIT}/autoinstall-schema.json"
RESERVED_URL="https://raw.githubusercontent.com/canonical/subiquity/${COMMIT}/reserved-usernames"

mkdir -p "$(dirname "${DEST}")"
tmp="$(mktemp)"
cleanup() { if [[ -n "${tmp}" && -f "${tmp}" && "${tmp##*/}" == tmp.* ]]; then rm -f -- "${tmp}"; fi; }
trap cleanup EXIT
curl -fsSL --max-time 60 -o "${tmp}" "${URL}"
echo "${SHA256}  ${tmp}" | sha256sum -c - >/dev/null || { echo "  [FAIL] schema checksum mismatch" >&2; exit 1; }
mv -f "${tmp}" "${DEST}"
echo "  [OK] Subiquity 26.04.1 autoinstall schema written to ${DEST}"
# The installer also refuses certain user names (reserved-usernames): fetched the same way, next to the schema.
curl -fsSL --max-time 60 -o "${tmp}" "${RESERVED_URL}"
echo "${RESERVED_SHA256}  ${tmp}" | sha256sum -c - >/dev/null || { echo "  [FAIL] reserved-usernames checksum mismatch" >&2; exit 1; }
mv -f "${tmp}" "$(dirname "${DEST}")/reserved-usernames"
echo "  [OK] reserved user names written to $(dirname "${DEST}")/reserved-usernames"
