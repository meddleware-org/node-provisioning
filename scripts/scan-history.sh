#!/usr/bin/env bash
# Run the public-hygiene scan against EVERY commit of this repository (not only the working tree): a value that was
# committed once stays in history even if a later commit removes it. Same options as check-public-hygiene.sh.
# Usage: scan-history.sh [--site DIR] [--denylist FILE]
# Exit codes: 0 when every commit is clean, 1 when any has findings, 2 for a bad option. Needs git and tar.
# # Stop on any error, unset variable or failed pipe.
set -euo pipefail
# The repository root, and a scratch directory for the unpacked commits (removed on exit).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
# cleanup: remove the scratch directory. Only a `tmp.*` directory is ever removed.
cleanup() { if [[ -n "${TMP}" && -d "${TMP}" && "${TMP##*/}" == tmp.* ]]; then rm -rf -- "${TMP}"; fi; }
# Always clean up.
trap cleanup EXIT
# Option paths must survive the change of directory: make them absolute first.
# The options to pass on to the hygiene script.
args=()
# Only --site and --denylist are accepted, and each needs a value.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site|--denylist) args+=("$1" "$(realpath "${2:?$1 needs a value}")"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
# Work from the repository root.
cd "${ROOT}"
# How many commits failed and how many were scanned.
fail=0; n=0
# For each commit reachable from any ref: unpack it and run the hygiene script that commit itself contains.
while read -r commit; do
  n=$((n + 1))
  dir="${TMP}/${commit}"; mkdir -p "${dir}"
  git archive "${commit}" | tar -x -C "${dir}"
  # A failure prints the commit and the findings (places and kinds only), indented.
  if ! out="$(bash "${dir}/scripts/check-public-hygiene.sh" "${args[@]}" 2>&1)"; then
    echo "  [HISTORY] commit ${commit:0:12} ($(git log -1 --format=%s "${commit}")):" >&2
    printf '%s\n' "${out}" | sed 's/^/      /' >&2
    fail=$((fail + 1))
  fi
  rm -rf -- "${dir}"
# Every commit of every branch and tag.
done < <(git rev-list --all)
# Any failing commit fails the run.
if (( fail > 0 )); then echo "  [FAIL] ${fail} of ${n} commit(s) contain findings" >&2; exit 1; fi
echo "  [OK] history clean: ${n} commit(s) scanned"
