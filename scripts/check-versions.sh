#!/usr/bin/env bash
# VERSION must be semver, and on a tag push the tag must equal VERSION and CHANGELOG must carry its heading.
# Exit codes: 0 when aligned, 1 otherwise (a GitHub Actions `::error::` line says why). Reads GITHUB_REF_TYPE and GITHUB_REF_NAME in CI.
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail
# Work from the repository root.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# The version file, without white space.
version="$(tr -d '[:space:]' <VERSION)"
# It must be three numbers, so a release tag can be compared exactly.
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::VERSION is not X.Y.Z (got '${version}')"; exit 1; }
# Only on a tag push: the tag (without its `v`) must equal VERSION, and CHANGELOG.md must have a heading for it, so a release is never tagged without notes.
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag="${GITHUB_REF_NAME#v}"
  [[ "${tag}" == "${version}" ]] || { echo "::error::tag ${GITHUB_REF_NAME} does not match VERSION ${version}"; exit 1; }
  grep -q "^## \[${version}\]" CHANGELOG.md || { echo "::error::CHANGELOG.md has no '## [${version}]' heading"; exit 1; }
fi
# Success message.
echo "versions aligned: ${version}"
