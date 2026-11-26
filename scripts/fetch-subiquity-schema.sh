#!/usr/bin/env bash
# Fetch the Subiquity autoinstall JSON schema, pinned by commit and checksum.
# The schema is AGPL-licensed: it is downloaded for validation and never vendored into this repository.
# Pinned to Subiquity tag 26.04.1 (the installer shipped on the Ubuntu Server 26.04.1 ISO).
# Usage: fetch-subiquity-schema.sh [destination]   (default: .cache/autoinstall-schema.json)
# Exit codes: 0 when both files are written, 1 on a checksum mismatch or a failed download. Side effects: writes the schema to the destination and
# # `reserved-usernames` next to it. Network: raw.githubusercontent.com only.
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail

# The pinned Subiquity commit and the checksums of the two files it must serve: a changed upstream file is refused, not trusted.
COMMIT="f759e0adbdc20ceab674946f9be42ed4c0c4f18c"
SHA256="beb72fefb590af5dfaaa615f6836c56fd74451f31b21dca631cb8c414f45a2ae"
RESERVED_SHA256="f9d71784f3e16405ebb2a7e090994746ca8d8d1c99af7edf6bca9fbb275a08e2"
# The repository root and the destination (the cache directory by default).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-${ROOT}/.cache/autoinstall-schema.json}"
# Where the two files come from: raw files at the pinned commit.
URL="https://raw.githubusercontent.com/canonical/subiquity/${COMMIT}/autoinstall-schema.json"
RESERVED_URL="https://raw.githubusercontent.com/canonical/subiquity/${COMMIT}/reserved-usernames"

# Make sure the destination directory exists.
mkdir -p "$(dirname "${DEST}")"
# Download to a scratch file first, so a failed or tampered download never replaces a good file.
tmp="$(mktemp)"
# cleanup: remove the scratch file. Only a `tmp.*` file is ever removed.
cleanup() { if [[ -n "${tmp}" && -f "${tmp}" && "${tmp##*/}" == tmp.* ]]; then rm -f -- "${tmp}"; fi; }
# Always clean up.
trap cleanup EXIT
# Fetch the schema: fail on an HTTP error, follow redirects quietly, give up after a minute.
curl -fsSL --max-time 60 -o "${tmp}" "${URL}"
# Verify the checksum before moving the file into place.
echo "${SHA256}  ${tmp}" | sha256sum -c - >/dev/null || { echo "  [FAIL] schema checksum mismatch" >&2; exit 1; }
# Install the verified schema.
mv -f "${tmp}" "${DEST}"
# Say what was written.
echo "  [OK] Subiquity 26.04.1 autoinstall schema written to ${DEST}"
# The installer also refuses certain user names (reserved-usernames): fetched the same way, next to the schema.
curl -fsSL --max-time 60 -o "${tmp}" "${RESERVED_URL}"
echo "${RESERVED_SHA256}  ${tmp}" | sha256sum -c - >/dev/null || { echo "  [FAIL] reserved-usernames checksum mismatch" >&2; exit 1; }
mv -f "${tmp}" "$(dirname "${DEST}")/reserved-usernames"
echo "  [OK] reserved user names written to $(dirname "${DEST}")/reserved-usernames"
