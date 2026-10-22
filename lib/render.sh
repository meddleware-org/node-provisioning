#!/usr/bin/env bash
# Rendering front end. Callers fill NP_R (name -> value) and NP_RI (name -> file), plus NP_PRO (1 = keep the Pro block),
# then call np_render. Values reach awk through exported variables of a subshell (builtins only: no argv).
# shellcheck shell=bash

declare -gA NP_R=() NP_RI=()
NP_PRO=0

# np_render <template> <out-file>
np_render() {
  local tmpl="$1" out="$2" k
  (
    umask 077
    names=""; incs=""
    for k in "${!NP_R[@]}"; do export "NP_V_${k}=${NP_R[${k}]}"; names+="${k} "; done
    for k in "${!NP_RI[@]}"; do export "NP_I_${k}=${NP_RI[${k}]}"; incs+="${k} "; done
    export NP_VARS="${names}" NP_INCS="${incs}" NP_PRO
    awk -f "${NP_LIB}/render.awk" "${tmpl}" >"${out}"
  ) || np_die "render failed for template ${tmpl}"
}
