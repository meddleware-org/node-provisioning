#!/usr/bin/env bash
# VERSION must be semver, and on a tag push the tag must equal VERSION and CHANGELOG must carry its heading.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
version="$(tr -d '[:space:]' <VERSION)"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::VERSION is not X.Y.Z (got '${version}')"; exit 1; }
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag="${GITHUB_REF_NAME#v}"
  [[ "${tag}" == "${version}" ]] || { echo "::error::tag ${GITHUB_REF_NAME} does not match VERSION ${version}"; exit 1; }
  grep -q "^## \[${version}\]" CHANGELOG.md || { echo "::error::CHANGELOG.md has no '## [${version}]' heading"; exit 1; }
fi
echo "versions aligned: ${version}"
