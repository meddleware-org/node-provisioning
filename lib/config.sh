#!/usr/bin/env bash
# Strict, schema-typed configuration. Site and node files are parsed as KEY=value data:
# they are never sourced or evaluated. Values never appear in error messages.
# shellcheck shell=bash

declare -gA NP_TYPE=() NP_REQ=() NP_DEF=() NP_SECRET=() NP_SCOPE=() CFG=()

# Keys the caller's environment may override (everything else must come from the files).
NP_ENV_ALLOW="INSTANCE_ID"

# np_schema_load <file> <scope>   scope = site | node
np_schema_load() {
  local file="$1" scope="$2" key type req def sec _desc
  [[ -f "${file}" ]] || np_die "schema not found: ${file}"
  while IFS=$'\t' read -r key type req def sec _desc; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    NP_TYPE[${key}]="${type}"; NP_REQ[${key}]="${req}"; NP_DEF[${key}]="${def}"
    NP_SECRET[${key}]="${sec}"; NP_SCOPE[${key}]="${scope}"
  done <"${file}"
}

np_is_ipv4() {
  local ip="$1" IFS=. o
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local -a oct
  read -r -a oct <<<"${ip}"
  for o in "${oct[@]}"; do
    (( 10#${o} <= 255 )) || return 1
    [[ "${o}" == 0 || "${o}" != 0* ]] || return 1   # no zero-padded octets
  done
}

# np_check_type <type> <value>: returns 0 when the value matches the schema type.
np_check_type() {
  local type="$1" v="$2" re a p sub item
  case "${type}" in
    host)   re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'; [[ "${v}" =~ ${re} ]] ;;
    ipv4)   np_is_ipv4 "${v}" ;;
    cidr4)
      if [[ "${v}" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
        a="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
        np_is_ipv4 "${a}" && (( 10#${p} <= 32 ))
      else return 1; fi ;;
    serial) re='^[A-Za-z0-9._:+-]{4,128}$'; [[ "${v}" =~ ${re} ]] ;;   # no glob characters by construction
    user)   re='^[a-z_][a-z0-9_-]{0,31}$'; [[ "${v}" =~ ${re} ]] ;;
    size)   re='^[1-9][0-9]*[MGT]$'; [[ "${v}" =~ ${re} ]] ;;
    int)    re='^[0-9]{1,9}$'; [[ "${v}" =~ ${re} ]] ;;
    bool)   [[ "${v}" == true || "${v}" == false ]] ;;
    text)   re='^[A-Za-z0-9._:/@+=,~ -]*$'; [[ "${v}" =~ ${re} && "${v}" != *@@* ]] ;;
    path)   [[ -n "${v}" && "${v}" != *[[:cntrl:]]* ]] ;;
    tz)     re='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$'; [[ "${v}" =~ ${re} ]] ;;
    version) re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; [[ "${v}" =~ ${re} ]] ;;
    enum:*) [[ ",${type#enum:}," == *",${v},"* ]] ;;
    list:*)
      sub="${type#list:}"
      [[ -z "${v}" ]] && return 0
      local IFS=,
      for item in ${v}; do np_check_type "${sub}" "${item}" || return 1; done ;;
    *) np_die "internal: unknown schema type '${type}'" ;;
  esac
}

# np_set <key> <value> <base-dir> <origin>: type-check and store (paths resolve against base-dir).
np_set() {
  local key="$1" val="$2" base="$3" origin="$4" type
  type="${NP_TYPE[${key}]}"
  if [[ -n "${val}" && "${val}" =~ ^[[:space:]]|[[:space:]]$ ]]; then
    np_die "${origin}: ${key} has leading or trailing whitespace"
  fi
  if [[ "${type}" == path && -n "${val}" ]]; then
    # shellcheck disable=SC2088  # a literal "~/" prefix in the config file, expanded here on purpose
    case "${val}" in
      "~/"*) val="${HOME}/${val#\~/}" ;;
      /*) ;;
      *) val="${base}/${val}" ;;
    esac
  fi
  if ! np_check_type "${type}" "${val}"; then
    if [[ "${NP_SECRET[${key}]}" == yes ]]; then
      np_die "${origin}: ${key} is not a valid ${type}"
    fi
    np_die "${origin}: ${key} is not a valid ${type} (got '${val}')"
  fi
  CFG[${key}]="${val}"
}

# np_load_file <file> <scope> <base-dir>: strict KEY=value parse. Unknown keys, duplicates and malformed
# lines fail. Relative path values resolve against <base-dir> (the site directory).
np_load_file() {
  local file="$1" scope="$2" base="$3" line key val n=0
  local -A seen=()
  [[ -f "${file}" ]] || np_die "config file not found: ${file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || np_die "${file}:${n}: not a KEY=value line"
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    [[ -n "${NP_TYPE[${key}]+x}" && "${NP_SCOPE[${key}]}" == "${scope}" ]] \
      || np_die "${file}:${n}: unknown ${scope} key ${key}"
    [[ -z "${seen[${key}]+x}" ]] || np_die "${file}:${n}: duplicate key ${key}"
    seen[${key}]=1
    np_set "${key}" "${val}" "${base}" "${file}:${n}"
  done <"${file}"
}

# np_finish_config: environment overrides (allowlist), schema defaults, required keys.
np_finish_config() {
  local key missing=() def
  for key in ${NP_ENV_ALLOW}; do
    if [[ -n "${!key:-}" ]]; then np_set "${key}" "${!key}" "${PWD}" "environment"; fi
  done
  for key in "${!NP_TYPE[@]}"; do
    # A required key must be present and non-empty.
    if [[ -n "${CFG[${key}]+x}" && ( -n "${CFG[${key}]}" || "${NP_REQ[${key}]}" != yes ) ]]; then continue; fi
    def="${NP_DEF[${key}]}"
    if [[ "${def}" != "-" && "${def}" != *"<"* ]]; then
      np_set "${key}" "${def}" "${PWD}" "default of ${key}"
    elif [[ "${NP_REQ[${key}]}" == yes ]]; then
      missing+=("${key}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    np_die "missing required key(s): $(printf '%s ' "${missing[@]}" | sort | tr '\n' ' ')"
  fi
}

# np_secret_file_check <path>: mode must not grant group/other access; owner must be the caller.
np_secret_file_check() {
  local p="$1" mode owner
  [[ -f "${p}" ]] || np_die "secret file not found: ${p}"
  mode="$(stat -c '%a' "${p}")"; owner="$(stat -c '%u' "${p}")"
  (( (8#${mode} & 8#077) == 0 )) || np_die "secret file ${p} is accessible by group or others (mode ${mode}); chmod 600 it"
  [[ "${owner}" == "$(id -u)" ]] || np_die "secret file ${p} is not owned by the invoking user"
}
