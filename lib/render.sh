#!/usr/bin/env bash
# Rendering front end. Callers fill NP_R (name -> value) and NP_RI (name -> file), plus NP_PRO (1 = keep the Pro block),
# then call np_render. Values reach awk through exported variables of a subshell (builtins only: no argv).
# shellcheck shell=bash

# The values to substitute (NP_R) and the files to include (NP_RI), filled by the caller before np_render; NP_PRO says whether the Ubuntu Pro block stays.
declare -gA NP_R=() NP_RI=()
NP_PRO=0

# np_render <template> <out-file>: expand the template with render.awk. The subshell keeps the exported values out of the caller's environment, and umask 077 makes the output private.
np_render() {
  local tmpl="$1" out="$2" k
  (
    umask 077
    # The space-separated names, so the awk program knows which environment variables are values and which are includes.
    names=""; incs=""
    # Every value travels as an exported variable (never through argv, where `ps` would show it).
    for k in "${!NP_R[@]}"; do export "NP_V_${k}=${NP_R[${k}]}"; names+="${k} "; done
    # Every include is a file path.
    for k in "${!NP_RI[@]}"; do export "NP_I_${k}=${NP_RI[${k}]}"; incs+="${k} "; done
    # Hand the name lists and the Pro switch to awk.
    export NP_VARS="${names}" NP_INCS="${incs}" NP_PRO
    # Render to the output file; any unreplaced marker or missing include fails the run.
    awk -f "${NP_LIB}/render.awk" "${tmpl}" >"${out}"
  ) || np_die "render failed for template ${tmpl}"
}
