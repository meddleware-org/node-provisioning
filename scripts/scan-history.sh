#!/usr/bin/env bash
# Run the public-hygiene scan against EVERY commit of this repository (not only the working tree): a value that was
# committed once stays in history even if a later commit removes it. Same options as check-public-hygiene.sh.
# Usage: scan-history.sh [--site DIR] [--denylist FILE]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { if [[ -n "${TMP}" && -d "${TMP}" && "${TMP##*/}" == tmp.* ]]; then rm -rf -- "${TMP}"; fi; }
trap cleanup EXIT
# Option paths must survive the change of directory: make them absolute first.
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site|--denylist) args+=("$1" "$(realpath "${2:?$1 needs a value}")"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
cd "${ROOT}"
fail=0; n=0
while read -r commit; do
  n=$((n + 1))
  dir="${TMP}/${commit}"; mkdir -p "${dir}"
  git archive "${commit}" | tar -x -C "${dir}"
  if ! out="$(bash "${dir}/scripts/check-public-hygiene.sh" "${args[@]}" 2>&1)"; then
    echo "  [HISTORY] commit ${commit:0:12} ($(git log -1 --format=%s "${commit}")):" >&2
    printf '%s\n' "${out}" | sed 's/^/      /' >&2
    fail=$((fail + 1))
  fi
  rm -rf -- "${dir}"
done < <(git rev-list --all)
if (( fail > 0 )); then echo "  [FAIL] ${fail} of ${n} commit(s) contain findings" >&2; exit 1; fi
echo "  [OK] history clean: ${n} commit(s) scanned"
