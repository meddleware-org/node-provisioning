#!/usr/bin/env bash
# Minimal test helpers. Each *.test.sh sources this, defines checks, and ends with `finish`.
# shellcheck shell=bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/bin/node-provisioning"
T_PASS=0; T_FAIL=0
T_TMP="$(mktemp -d)"
t_cleanup() { if [[ -n "${T_TMP}" && -d "${T_TMP}" && "${T_TMP##*/}" == tmp.* ]]; then rm -rf -- "${T_TMP}"; fi; }
trap t_cleanup EXIT

ok()  { T_PASS=$((T_PASS + 1)); echo "  ok   $*"; }
bad() { T_FAIL=$((T_FAIL + 1)); echo "  FAIL $*"; }
check() { local name="$1"; shift; if "$@"; then ok "${name}"; else bad "${name}"; fi; }
finish() { echo "  -- $(basename "$0"): ${T_PASS} passed, ${T_FAIL} failed"; [[ "${T_FAIL}" -eq 0 ]]; }

# mk_site <dir>: a private copy of the example site with fixture secrets (hash file 0600).
mk_site() {
  local d="$1"
  mkdir -p "${d}"
  cp -r "${ROOT}/examples/site/." "${d}/"
  cp "${ROOT}/tests/fixtures/password-hash" "${d}/ph"
  chmod 600 "${d}/ph"
  echo 'PASSWORD_HASH_FILE=ph' >>"${d}/nodes/node1.env"
}

# shellcheck disable=SC2034  # OUT and RC are read by the sourcing tests
# run_cli <args...>: run the CLI capturing stdout+stderr into $OUT and the status into $RC.
run_cli() { OUT="$("${CLI}" "$@" 2>&1)"; RC=$?; }
