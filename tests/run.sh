#!/usr/bin/env bash
# Runs every tests/*.test.sh. Offline; needs bash, awk, python3 with PyYAML, xorriso, dosfstools, mtools.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
fail=0
for t in ./*.test.sh; do
  echo "== ${t#./}"
  bash "${t}" || fail=$((fail + 1))
done
if (( fail > 0 )); then echo "FAILED: ${fail} test file(s)"; exit 1; fi
echo "all test files passed"
