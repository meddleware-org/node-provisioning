#!/usr/bin/env bash
# Logging helpers. Messages carry key names, paths and line numbers; never secret values.
# shellcheck shell=bash

np_info() { echo "  [node-provisioning] $*" >&2; }
np_ok()   { echo "  [OK] $*" >&2; }
np_warn() { echo "  [WARN] $*" >&2; }
np_die()  { echo "  [FAIL] $*" >&2; exit 1; }
np_have() { command -v "$1" >/dev/null 2>&1; }

# Temporary directories are registered and removed once, on exit (the caller installs the EXIT trap).
NP_TMPDIRS=()
np_mktemp_dir() { # np_mktemp_dir <varname>
  local -n _np_ref="$1"
  _np_ref="$(mktemp -d)"
  NP_TMPDIRS+=("${_np_ref}")
}
np_cleanup() {
  local d
  for d in "${NP_TMPDIRS[@]:-}"; do
    if [[ -n "${d}" && -d "${d}" && "${d##*/}" == tmp.* ]]; then rm -rf -- "${d}"; fi
  done
}
