#!/usr/bin/env bash
# Logging helpers. Messages carry key names, paths and line numbers; never secret values.
# shellcheck shell=bash

# np_info <message>: progress on stderr. Messages carry key names, paths and line numbers, never secret values.
np_info() { echo "  [node-provisioning] $*" >&2; }
# np_ok <message>: a check that passed.
np_ok()   { echo "  [OK] $*" >&2; }
# np_warn <message>: something worth seeing that does not stop the run.
np_warn() { echo "  [WARN] $*" >&2; }
# np_die <message>: report the failure and stop the whole run with status 1.
np_die()  { echo "  [FAIL] $*" >&2; exit 1; }
# np_have <command>: succeed when the command exists on this machine.
np_have() { command -v "$1" >/dev/null 2>&1; }

# Temporary directories are registered and removed once, on exit (the caller installs the EXIT trap).
# The directories to remove on exit.
NP_TMPDIRS=()
# Create a temporary directory, set the caller's variable to its path (a nameref) and register it for cleanup.
np_mktemp_dir() { # np_mktemp_dir <varname>
  local -n _np_ref="$1"
  _np_ref="$(mktemp -d)"
  NP_TMPDIRS+=("${_np_ref}")
}
# np_cleanup: remove the registered directories. Only a directory whose name starts with `tmp.` (what mktemp -d makes) is ever removed, so a wrong value can never delete something else.
np_cleanup() {
  local d
  for d in "${NP_TMPDIRS[@]:-}"; do
    if [[ -n "${d}" && -d "${d}" && "${d##*/}" == tmp.* ]]; then rm -rf -- "${d}"; fi
  done
}
