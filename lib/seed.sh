#!/usr/bin/env bash
# Seed rendering, validation and image building.
# shellcheck shell=bash
# shellcheck disable=SC2034  # NP_R and NP_RI are consumed by np_render (lib/render.sh)

# Subiquity autoinstall schema, fetched on demand (AGPL: never vendored), pinned by commit and checksum.
NP_SCHEMA_CACHE="${NP_ROOT}/.cache/autoinstall-schema.json"

np_valid_node_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]; }

# np_prepare <site-dir> <node-name>: load, type-check and complete the configuration.
np_prepare() {
  local site="$1" node="$2"
  [[ -d "${site}" ]] || np_die "site directory not found: ${site}"
  np_valid_node_name "${node}" || np_die "invalid node name"
  NP_SITE_DIR="$(cd "${site}" && pwd)"
  NP_SITE_NAME="$(basename "${NP_SITE_DIR}")"
  np_schema_load "${NP_ROOT}/schema/site.schema.tsv" site
  np_schema_load "${NP_ROOT}/schema/node.schema.tsv" node
  np_load_file "${NP_SITE_DIR}/site.env" site "${NP_SITE_DIR}"
  np_load_file "${NP_SITE_DIR}/nodes/${node}.env" node "${NP_SITE_DIR}"
  np_finish_config
  np_check_reserved_user "${CFG[ADMIN_USER]}"
  [[ "${CFG[OS_DISK_SERIAL]}" != "${CFG[DATA_DISK_SERIAL]}" ]] || np_die "OS_DISK_SERIAL and DATA_DISK_SERIAL must name different disks"
  if [[ -z "${CFG[PASSWORD_HASH_FILE]:-}" ]]; then
    CFG[PASSWORD_HASH_FILE]="${HOME}/.config/node-provisioning/${NP_SITE_NAME}/${node}/password-hash"
  fi
}

# np_collect_secrets: read the password hash and the optional Ubuntu Pro token (files or environment).
np_collect_secrets() {
  local f tok_re hash_re
  # shellcheck disable=SC2016  # regular expressions, not shell expansions
  tok_re='^C[1-9A-HJ-NP-Za-km-z]{23,29}$'; hash_re='^\$(y|6|5|2b|2y|7|gy|1)\$[./A-Za-z0-9$,=_-]+$'
  f="${CFG[PASSWORD_HASH_FILE]}"
  np_secret_file_check "${f}"
  NP_HASH=""
  IFS= read -r NP_HASH <"${f}" || true
  [[ "${NP_HASH}" =~ ${hash_re} ]] || np_die "PASSWORD_HASH_FILE does not hold a crypt password hash"
  NP_PRO=0; NP_PRO_TOKEN=""
  if [[ -n "${UBUNTU_PRO_TOKEN:-}" && -n "${CFG[UBUNTU_PRO_TOKEN_FILE]:-}" ]]; then
    np_die "both UBUNTU_PRO_TOKEN and UBUNTU_PRO_TOKEN_FILE are set; use one"
  fi
  if [[ -n "${UBUNTU_PRO_TOKEN:-}" ]]; then
    NP_PRO_TOKEN="${UBUNTU_PRO_TOKEN}"
  elif [[ -n "${CFG[UBUNTU_PRO_TOKEN_FILE]:-}" ]]; then
    np_secret_file_check "${CFG[UBUNTU_PRO_TOKEN_FILE]}"
    IFS= read -r NP_PRO_TOKEN <"${CFG[UBUNTU_PRO_TOKEN_FILE]}" || true
  fi
  if [[ -n "${NP_PRO_TOKEN}" ]]; then
    [[ "${NP_PRO_TOKEN}" =~ ${tok_re} ]] || np_die "the Ubuntu Pro token is not a valid token"
    NP_PRO=1
  fi
}

# np_keys_fragment <keys-file> <out-file>: YAML list items from an authorized_keys file.
np_keys_fragment() {
  local in="$1" out="$2" line n=0
  local key_re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^"\\[:cntrl:]]*)?$'
  [[ -f "${in}" ]] || np_die "AUTHORIZED_KEYS_FILE not found: ${in}"
  : >"${out}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ${key_re} ]] || np_die "AUTHORIZED_KEYS_FILE line $((n + 1)) is not a supported SSH public key"
    printf -- '- "%s"\n' "${line}" >>"${out}"
    n=$((n + 1))
  done <"${in}"
  (( n > 0 )) || np_die "AUTHORIZED_KEYS_FILE holds no keys"
}

# np_check_fragments: parse the site fragments and check the node address against them.
np_check_fragments() {
  local f
  for f in "${CFG[INSTALLER_NETWORK_FILE]}" "${CFG[NETPLAN_FILE]}"; do
    [[ -f "${f}" ]] || np_die "site fragment not found: ${f}"
    python3 "${NP_LIB}/validate.py" fragment "${f}" --node-ip "${CFG[NODE_IP]}" --require-address \
      || np_die "site fragment ${f} failed validation"
  done
}

# np_netplan_check <fragment>: netplan generate against a scratch root (skipped when netplan is absent).
np_netplan_check() {
  local frag="$1" root
  if ! np_have netplan; then np_warn "netplan not installed: fragment generate check skipped"; return 0; fi
  np_mktemp_dir root
  mkdir -p "${root}/etc/netplan"
  cp "${frag}" "${root}/etc/netplan/10-check.yaml"
  chmod 600 "${root}/etc/netplan/10-check.yaml"
  netplan generate --root-dir "${root}" >/dev/null 2>&1 || np_die "netplan generate rejected ${frag}"
  np_ok "netplan generate accepts ${frag##*/}"
}

# np_render_seed <out-dir>: write user-data and meta-data (mode 0600) and print their paths.
np_render_seed() {
  local out="$1" work wait_args="" i hex
  local -a ifs
  mkdir -p "${out}"
  np_mktemp_dir work
  np_check_fragments
  np_keys_fragment "${CFG[AUTHORIZED_KEYS_FILE]}" "${work}/keys.yaml"
  IFS=, read -r -a ifs <<<"${CFG[WAIT_ONLINE_INTERFACES]}"
  for i in "${ifs[@]}"; do wait_args+="${wait_args:+ }--interface=${i}"; done

  NP_R=(
    [HOSTNAME]="${CFG[HOSTNAME]}" [ADMIN_USER]="${CFG[ADMIN_USER]}" [PASSWORD_HASH]="${NP_HASH}"
    [LOCALE]="${CFG[LOCALE]}" [KEYBOARD_LAYOUT]="${CFG[KEYBOARD_LAYOUT]}" [KEYBOARD_VARIANT]="${CFG[KEYBOARD_VARIANT]:-}"
    [TIMEZONE]="${CFG[TIMEZONE]}" [APT_FALLBACK]="${CFG[APT_FALLBACK]}" [SOURCE_ID]="${CFG[SOURCE_ID]}" [UPDATES]="${CFG[UPDATES]}" [EFI_SIZE]="${CFG[EFI_SIZE]}"
    [OS_DISK_SERIAL]="${CFG[OS_DISK_SERIAL]}" [DATA_DISK_SERIAL]="${CFG[DATA_DISK_SERIAL]}" [NETPLAN_FILE_NAME]="${CFG[NETPLAN_FILE_NAME]}"
    [WAIT_ONLINE_ARGS]="${wait_args}"
  )
  if [[ "${NP_PRO}" == 1 ]]; then NP_R[UBUNTU_PRO_TOKEN]="${NP_PRO_TOKEN}"; fi
  NP_RI=(
    [INSTALLER_NETWORK]="${CFG[INSTALLER_NETWORK_FILE]}" [NETPLAN]="${CFG[NETPLAN_FILE]}" [AUTHORIZED_KEYS]="${work}/keys.yaml"
  )
  np_render "${NP_TARGET_DIR}/autoinstall/user-data.tmpl.yaml" "${work}/user-data"
  if [[ -z "${CFG[INSTANCE_ID]:-}" ]]; then
    hex="$(sha256sum <"${work}/user-data" | cut -c1-12)"
    CFG[INSTANCE_ID]="${CFG[HOSTNAME]}-${hex}"
  fi
  printf 'instance-id: %s\nlocal-hostname: %s\n' "${CFG[INSTANCE_ID]}" "${CFG[HOSTNAME]}" >"${work}/meta-data"
  mv -f "${work}/user-data" "${out}/user-data"
  mv -f "${work}/meta-data" "${out}/meta-data"
  np_info "wrote ${out}/user-data and ${out}/meta-data (mode 0600; contain credentials: keep private)"
}

# np_validate_seed <out-dir> [strict]: validate rendered files and the site fragments.
np_validate_seed() {
  local out="$1" strict="${2:-0}" schema=""
  python3 "${NP_LIB}/validate.py" fragment "${CFG[INSTALLER_NETWORK_FILE]}" --node-ip "${CFG[NODE_IP]}" --require-address >/dev/null \
    || np_die "installer network fragment failed validation"
  np_netplan_check "${CFG[NETPLAN_FILE]}"
  np_netplan_check "${CFG[INSTALLER_NETWORK_FILE]}"
  if [[ -f "${NP_SUBIQUITY_SCHEMA:-${NP_SCHEMA_CACHE}}" ]]; then schema="${NP_SUBIQUITY_SCHEMA:-${NP_SCHEMA_CACHE}}"; fi
  if [[ -z "${schema}" ]]; then
    if [[ "${strict}" == 1 ]]; then np_die "Subiquity schema missing: run scripts/fetch-subiquity-schema.sh"; fi
    np_warn "Subiquity autoinstall schema not available: schema check skipped (scripts/fetch-subiquity-schema.sh)"
    python3 "${NP_LIB}/validate.py" user-data "${out}/user-data" || np_die "user-data failed validation"
  else
    python3 "${NP_LIB}/validate.py" user-data "${out}/user-data" --schema "${schema}" || np_die "user-data failed validation"
    np_ok "user-data satisfies the pinned Subiquity autoinstall schema"
  fi
  if np_have cloud-init; then
    cloud-init schema --config-file "${out}/user-data" >/dev/null 2>&1 \
      && np_ok "cloud-init schema: valid" || np_die "cloud-init schema rejected user-data"
  else
    np_warn "cloud-init not installed: cloud-init schema check skipped"
  fi
}

# np_build_seed <format> <out-dir>: render, validate and pack into a CIDATA image.
np_build_seed() {
  local fmt="$1" out="$2" work tmp artifact kib fat epoch
  case "${fmt}" in iso|img|floppy) ;; *) np_die "--format must be iso, img or floppy" ;; esac
  case "${fmt}" in
    iso) np_have xorrisofs || np_die "format iso needs xorrisofs (apt install xorriso)" ;;
    *) np_have mkfs.vfat && np_have mcopy || np_die "format ${fmt} needs mkfs.vfat and mcopy (apt install dosfstools mtools)" ;;
  esac
  umask 077
  np_mktemp_dir work
  np_render_seed "${work}/seed"
  np_validate_seed "${work}/seed" "${NP_STRICT:-0}"
  mkdir -p "${out}"
  tmp="${work}/image"
  # Reproducible output: every timestamp derives from SOURCE_DATE_EPOCH (default: the mtime of VERSION, which in a
  # release tarball is the commit time), identifiers are fixed, and ownership is normalised.
  epoch="${SOURCE_DATE_EPOCH:-$(stat -c %Y "${NP_ROOT}/VERSION")}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || np_die "SOURCE_DATE_EPOCH must be a number of seconds"
  export SOURCE_DATE_EPOCH="${epoch}"
  export TZ=UTC   # FAT stores local time: the build must not depend on the builder's time zone
  touch -d "@${epoch}" "${work}/seed/user-data" "${work}/seed/meta-data"
  case "${fmt}" in
    iso)
      artifact="${out}/nocloud-seed.iso"
      xorrisofs -output "${tmp}" -volid CIDATA -r -J -p node-provisioning -publisher node-provisioning \
        --modification-date="$(date -u -d "@${epoch}" +%Y%m%d%H%M%S00)" \
        "${work}/seed/user-data" "${work}/seed/meta-data" >/dev/null 2>&1 || np_die "xorrisofs failed" ;;
    img|floppy)
      if [[ "${fmt}" == img ]]; then kib=4096; fat=auto; artifact="${out}/nocloud-seed.img"
      else kib=1440; fat=12; artifact="${out}/nocloud-seed-floppy.img"; fi
      dd if=/dev/zero of="${tmp}" bs=1024 count="${kib}" status=none
      if [[ "${fat}" == auto ]]; then mkfs.vfat --invariant -i 4E505631 -n CIDATA "${tmp}" >/dev/null
      else mkfs.vfat --invariant -i 4E505631 -F "${fat}" -n CIDATA "${tmp}" >/dev/null; fi
      MTOOLS_SKIP_CHECK=1 mcopy -m -i "${tmp}" "${work}/seed/user-data" ::user-data || np_die "mcopy user-data failed"
      MTOOLS_SKIP_CHECK=1 mcopy -m -i "${tmp}" "${work}/seed/meta-data" ::meta-data || np_die "mcopy meta-data failed"
      if [[ "${fmt}" == floppy ]]; then
        [[ "$(stat -c%s "${tmp}")" -le 1474560 ]] || np_die "floppy image exceeds the 1.44 MB limit"
      fi ;;
  esac
  [[ -s "${tmp}" ]] || np_die "image build produced no output"
  mv -f "${tmp}" "${artifact}"
  np_ok "seed written: ${artifact} (mode $(stat -c%a "${artifact}"); contains credentials: keep private, delete after install)"
}
