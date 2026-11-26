#!/usr/bin/env bash
# Strict, schema-typed configuration. Site and node files are parsed as KEY=value data:
# they are never sourced or evaluated. Values never appear in error messages.
# shellcheck shell=bash

# The schema, one entry per key: its type, whether it is required, its default, whether it is a secret and which file scope (site or node) it belongs to. CFG holds the values once loaded.
declare -gA NP_TYPE=() NP_REQ=() NP_DEF=() NP_SECRET=() NP_SCOPE=() CFG=()

# Keys the caller's environment may override (everything else must come from the files).
NP_ENV_ALLOW="INSTANCE_ID"

# np_schema_load <file> <scope>: read a tab-separated schema (key, type, required, default, secret, description) into the tables above; scope is `site` or `node`.
np_schema_load() {
  # Local names; `_desc` is read and ignored (the description is for people).
  local file="$1" scope="$2" key type req def sec _desc
  [[ -f "${file}" ]] || np_die "schema not found: ${file}"
  # One schema row per line; blank lines and `#` lines are skipped.
  while IFS=$'\t' read -r key type req def sec _desc; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    NP_TYPE[${key}]="${type}"; NP_REQ[${key}]="${req}"; NP_DEF[${key}]="${def}"
    NP_SECRET[${key}]="${sec}"; NP_SCOPE[${key}]="${scope}"
  done <"${file}"
}

# np_is_ipv4 <address>: succeed for a dotted-quad IPv4 address with every octet 0-255 and no zero-padded octet.
np_is_ipv4() {
  local ip="$1" IFS=. o
  # Four groups of one to three digits, nothing else.
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local -a oct
  read -r -a oct <<<"${ip}"
  # Check each octet: in range, and not zero-padded (`010` can be read as octal by other tools).
  for o in "${oct[@]}"; do
    (( 10#${o} <= 255 )) || return 1
    [[ "${o}" == 0 || "${o}" != 0* ]] || return 1   # no zero-padded octets
  done
}

# np_check_type <type> <value>: succeed when the value matches the schema type. Each type is a strict pattern; an unknown type is an internal error, not a pass.
np_check_type() {
  local type="$1" v="$2" re a p sub item
  case "${type}" in
    # A host name: dot-separated labels of letters, digits and inner hyphens, up to 63 characters each.
    host)   re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'; [[ "${v}" =~ ${re} ]] ;;
    # An IPv4 address.
    ipv4)   np_is_ipv4 "${v}" ;;
    # An IPv4 network in CIDR form: an address and a prefix length of at most 32.
    cidr4)
      if [[ "${v}" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
        a="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
        np_is_ipv4 "${a}" && (( 10#${p} <= 32 ))
      else return 1; fi ;;
    # A disk serial: letters, digits and . _ : + - only, 4 to 128 characters, so it can never hold a glob character.
    serial) re='^[A-Za-z0-9._:+-]{4,128}$'; [[ "${v}" =~ ${re} ]] ;;   # no glob characters by construction
    # A Linux user name: lower-case, starting with a letter or underscore, at most 32 characters.
    user)   re='^[a-z_][a-z0-9_-]{0,31}$'; [[ "${v}" =~ ${re} ]] ;;
    # A size: a positive whole number and a unit M, G or T.
    size)   re='^[1-9][0-9]*[MGT]$'; [[ "${v}" =~ ${re} ]] ;;
    # A whole number of up to nine digits.
    int)    re='^[0-9]{1,9}$'; [[ "${v}" =~ ${re} ]] ;;
    # Exactly `true` or `false`.
    bool)   [[ "${v}" == true || "${v}" == false ]] ;;
    # Plain text from a safe character set, and never a template marker (@@).
    text)   re='^[A-Za-z0-9._:/@+=,~ -]*$'; [[ "${v}" =~ ${re} && "${v}" != *@@* ]] ;;
    # A non-empty path without control characters (the file is checked where it is used).
    path)   [[ -n "${v}" && "${v}" != *[[:cntrl:]]* ]] ;;
    # A time zone name such as Europe/London: one to three segments.
    tz)     re='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$'; [[ "${v}" =~ ${re} ]] ;;
    # A version number such as 1.2.3, with an optional suffix.
    version) re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; [[ "${v}" =~ ${re} ]] ;;
    # One of the comma-separated choices written after `enum:` in the schema.
    enum:*) [[ ",${type#enum:}," == *",${v},"* ]] ;;
    # A comma-separated list whose every item has the type written after `list:`; an empty value is an empty list.
    list:*)
      sub="${type#list:}"
      [[ -z "${v}" ]] && return 0
      local IFS=,
      for item in ${v}; do np_check_type "${sub}" "${item}" || return 1; done ;;
    # A type the schema names but this function does not know is a bug in the schema, so it stops.
    *) np_die "internal: unknown schema type '${type}'" ;;
  esac
}

# Names the installer refuses for the first user. A short built-in list is always applied; the full list shipped with the
# pinned installer revision (scripts/fetch-subiquity-schema.sh writes .cache/reserved-usernames) is applied when present.
# Names the installer refuses for the first user. A short built-in list is always applied; the full list shipped with the pinned installer revision (scripts/fetch-subiquity-schema.sh writes .cache/reserved-usernames) is applied when present.
NP_BUILTIN_RESERVED=" root admin daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody adm tty disk sudo ssh sshd operator staff users shadow wheel "
# np_check_reserved_user <user>: stop when the installer would refuse the name, so the mistake shows now and not halfway through an install.
np_check_reserved_user() { # <user>
  local u="$1" f="${NP_RESERVED_USERNAMES:-${NP_ROOT:-.}/.cache/reserved-usernames}"
  # The built-in list first.
  [[ "${NP_BUILTIN_RESERVED}" != *" ${u} "* ]] || np_die "ADMIN_USER '${u}' is reserved by the installer: choose another name"
  # Then the pinned list, when it has been fetched.
  if [[ -f "${f}" ]] && grep -v '^#' "${f}" | awk '{print $1}' | grep -qx -- "${u}"; then
    np_die "ADMIN_USER '${u}' is reserved by the installer: choose another name"
  fi
}

# np_set <key> <value> <base-dir> <origin>: type-check and store a value (paths resolve against base-dir). `origin` says where the value came from, for messages.
np_set() {
  local key="$1" val="$2" base="$3" origin="$4" type
  type="${NP_TYPE[${key}]}"
  # A value with leading or trailing white space is almost always a typo, and it would change what a type check means, so it is refused.
  if [[ -n "${val}" && "${val}" =~ ^[[:space:]]|[[:space:]]$ ]]; then
    np_die "${origin}: ${key} has leading or trailing whitespace"
  fi
  # A path value: `~/` is the caller's home, an absolute path stays, and anything else is relative to the site directory.
  if [[ "${type}" == path && -n "${val}" ]]; then
    # shellcheck disable=SC2088  # a literal "~/" prefix in the config file, expanded here on purpose
    case "${val}" in
      "~/"*) val="${HOME}/${val#\~/}" ;;
      /*) ;;
      *) val="${base}/${val}" ;;
    esac
  fi
  # A bad value is reported with its key and type; the value itself is echoed only for strictly shaped, non-secret types.
  if ! np_check_type "${type}" "${val}"; then
    if [[ "${NP_SECRET[${key}]}" == yes ]]; then
      np_die "${origin}: ${key} is not a valid ${type}"
    fi
    # Free text and paths can hold anything, including an address with a user name and password, so they are named by key only.
    case "${type}" in
      text|path|list:text) np_die "${origin}: ${key} is not a valid ${type}" ;;
    esac
    np_die "${origin}: ${key} is not a valid ${type} (got '${val}')"
  fi
  # Store the checked value.
  CFG[${key}]="${val}"
}

# np_load_file <file> <scope> <base-dir>: strict KEY=value parse. Unknown keys, duplicates and malformed
# lines fail. Relative path values resolve against <base-dir> (the site directory).
# np_load_file <file> <scope> <base-dir>: strict KEY=value parse. Unknown keys, duplicates and malformed lines fail. Relative path values resolve against <base-dir> (the site directory). The file is read as data, never sourced.
np_load_file() {
  # Local names; `seen` records the keys already read so a duplicate is an error.
  local file="$1" scope="$2" base="$3" line key val n=0
  local -A seen=()
  [[ -f "${file}" ]] || np_die "config file not found: ${file}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    # Tolerate files saved with Windows line endings.
    line="${line%$'\r'}"
    # Blank lines and comment lines are skipped.
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    # A line is KEY=value with an upper-case key; everything after the first `=` is the value, with no quoting or expansion.
    [[ "${line}" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || np_die "${file}:${n}: not a KEY=value line"
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    # The key must exist in the schema and belong to this file's scope (a node key in the site file is an error).
    [[ -n "${NP_TYPE[${key}]+x}" && "${NP_SCOPE[${key}]}" == "${scope}" ]] \
      || np_die "${file}:${n}: unknown ${scope} key ${key}"
    [[ -z "${seen[${key}]+x}" ]] || np_die "${file}:${n}: duplicate key ${key}"
    seen[${key}]=1
    np_set "${key}" "${val}" "${base}" "${file}:${n}"
  done <"${file}"
}

# np_finish_config: environment overrides (allowlist), schema defaults, required keys.
# np_finish_config: apply environment overrides (allowlist), schema defaults and the required-key check.
np_finish_config() {
  local key missing=() def
  # Only the allow-listed variables may come from the environment, so a stray variable can never change what is built.
  for key in ${NP_ENV_ALLOW}; do
    if [[ -n "${!key:-}" ]]; then np_set "${key}" "${!key}" "${PWD}" "environment"; fi
  done
  # For every schema key: keep a value that is present, fill in a default, or record it as missing.
  for key in "${!NP_TYPE[@]}"; do
    # A required key must be present and non-empty.
    if [[ -n "${CFG[${key}]+x}" && ( -n "${CFG[${key}]}" || "${NP_REQ[${key}]}" != yes ) ]]; then continue; fi
    # A default of `-` means none; one containing `<` is a placeholder that still needs a value.
    def="${NP_DEF[${key}]}"
    if [[ "${def}" != "-" && "${def}" != *"<"* ]]; then
      np_set "${key}" "${def}" "${PWD}" "default of ${key}"
    elif [[ "${NP_REQ[${key}]}" == yes ]]; then
      missing+=("${key}")
    fi
  done
  # Report every missing key at once, sorted, so one run shows the whole list.
  if (( ${#missing[@]} > 0 )); then
    np_die "missing required key(s): $(printf '%s ' "${missing[@]}" | sort | tr '\n' ' ')"
  fi
}

# np_secret_file_check <path>: a secret file must exist, be unreadable to group and others (mode 0600 or tighter) and belong to the caller.
np_secret_file_check() {
  local p="$1" mode owner
  [[ -f "${p}" ]] || np_die "secret file not found: ${p}"
  # Read the mode and owner with stat.
  mode="$(stat -c '%a' "${p}")"; owner="$(stat -c '%u' "${p}")"
  (( (8#${mode} & 8#077) == 0 )) || np_die "secret file ${p} is accessible by group or others (mode ${mode}); chmod 600 it"
  [[ "${owner}" == "$(id -u)" ]] || np_die "secret file ${p} is not owned by the invoking user"
}
