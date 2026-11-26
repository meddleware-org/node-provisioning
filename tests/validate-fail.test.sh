#!/usr/bin/env bash
# Every way a build must fail closed, and proof that failures never echo secret values.
source "$(dirname "$0")/lib.sh"
# The fixture password hash and a fake token, which must never appear in any output.
HASH="$(cat "${ROOT}/tests/fixtures/password-hash")"
FAKE_TOKEN=C1111111111111111111111111

# fresh: a new private copy of the example site.
fresh() { rm -rf -- "${T_TMP}/s"; mk_site "${T_TMP}/s"; }
# render_fails <name>: render the site; it must fail, and the output must not contain the hash or the token.
render_fails() { # name; expects non-zero exit and no hash in output
  run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
  if [[ "${RC}" -ne 0 ]]; then ok "$1"; else bad "$1 (expected failure)"; fi
  if [[ "${OUT}" == *"${HASH}"* || "${OUT}" == *"${FAKE_TOKEN}"* ]]; then bad "$1: output leaked a secret"; fi
}
# render_ok <name>: render the site; it must succeed.
render_ok() {
  run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
  if [[ "${RC}" -eq 0 ]]; then ok "$1"; else bad "$1 (expected success): ${OUT}"; fi
}

# The baseline renders; then each case below breaks one thing and expects the build to fail closed.
fresh; render_ok "baseline site renders"

# Configuration keys: a missing, unknown, out-of-range, duplicate, metacharacter, marker-like, uppercase, prefix-less or empty value.
fresh; sed -i '/^ADMIN_USER=/d' "${T_TMP}/s/site.env";            render_fails "missing required key ADMIN_USER"
[[ "${OUT}" == *ADMIN_USER* ]] && ok "missing key is named in the error" || bad "missing key is named in the error"
fresh; echo 'MYSTERY=1' >>"${T_TMP}/s/site.env";                  render_fails "unknown key"
fresh; sed -i 's/^NODE_IP=.*/NODE_IP=192.0.2.300/' "${T_TMP}/s/nodes/node1.env"; render_fails "NODE_IP out of range"
fresh; echo 'ADMIN_USER=root2' >>"${T_TMP}/s/site.env";           render_fails "duplicate key"
fresh; sed -i 's/^HOSTNAME=.*/HOSTNAME=node1;reboot/' "${T_TMP}/s/nodes/node1.env"; render_fails "shell metacharacters in HOSTNAME"
fresh; sed -i 's/^HOSTNAME=.*/HOSTNAME=@@x@@/' "${T_TMP}/s/nodes/node1.env"; render_fails "marker-like value in HOSTNAME"
fresh; sed -i 's/^ADMIN_USER=.*/ADMIN_USER=Admin/' "${T_TMP}/s/site.env"; render_fails "uppercase ADMIN_USER"
fresh; sed -i 's/^LAN_CIDR=.*/LAN_CIDR=192.0.2.0/' "${T_TMP}/s/site.env"; render_fails "LAN_CIDR without prefix"
fresh; sed -i 's/^WAIT_ONLINE_INTERFACES=.*/WAIT_ONLINE_INTERFACES=/' "${T_TMP}/s/site.env"; render_fails "empty WAIT_ONLINE_INTERFACES"

# Disk identity: globs, missing serials, identical serials and short serials are refused.
# disk identity
fresh; sed -i 's/^OS_DISK_SERIAL=.*/OS_DISK_SERIAL=ExampleVendor_*/' "${T_TMP}/s/nodes/node1.env"; render_fails "glob in OS_DISK_SERIAL"
fresh; sed -i '/^OS_DISK_SERIAL=/d' "${T_TMP}/s/nodes/node1.env";                   render_fails "OS_DISK_SERIAL missing (no default)"
fresh; sed -i '/^DATA_DISK_SERIAL=/d' "${T_TMP}/s/nodes/node1.env";                 render_fails "DATA_DISK_SERIAL missing (no default)"
fresh; sed -i 's/^DATA_DISK_SERIAL=.*/DATA_DISK_SERIAL=ExampleVendor_OsDisk_EX0000000001/' "${T_TMP}/s/nodes/node1.env"; render_fails "OS and data serial identical"
fresh; sed -i 's/^OS_DISK_SERIAL=.*/OS_DISK_SERIAL=abc/' "${T_TMP}/s/nodes/node1.env"; render_fails "serial too short"

# Installer settings have no geolocation or other default.
# a free-text value that is refused is never repeated (it could be an address with a user name and password in it)
fresh; sed -i 's#^PAUSE_IMAGE=.*#PAUSE_IMAGE=user:stand-in-secret"x@registry.example.invalid/pause:1#' "${T_TMP}/s/site.env"; render_fails "PAUSE_IMAGE with a refused character"
[[ "${OUT}" == *PAUSE_IMAGE* && "${OUT}" != *stand-in-secret* ]] && ok "a refused free-text value is named by key, not repeated" || bad "a refused free-text value is named by key, not repeated"

# installer settings
fresh; sed -i '/^TIMEZONE=/d' "${T_TMP}/s/site.env";                              render_fails "TIMEZONE missing (no geolocation default)"
fresh; sed -i 's/^TIMEZONE=.*/TIMEZONE=Europe\/..\/x/' "${T_TMP}/s/site.env";     render_fails "invalid TIMEZONE"
fresh; sed -i 's/^APT_FALLBACK=.*/APT_FALLBACK=whatever/' "${T_TMP}/s/site.env";   render_fails "invalid APT_FALLBACK"

# Reserved administrator names (the installer refuses them: `admin` was found the hard way in a VM install); the pinned installer list is applied when present.
# reserved administrator names (the installer refuses them: 'admin' was found the hard way in a VM install)
for u in admin root sshd operator; do
  fresh; sed -i "s/^ADMIN_USER=.*/ADMIN_USER=${u}/" "${T_TMP}/s/site.env"; render_fails "reserved ADMIN_USER ${u}"
  [[ "${OUT}" == *"reserved by the installer"* ]] && ok "reserved ADMIN_USER ${u} is explained" || bad "reserved ADMIN_USER ${u} is explained"
done
printf '# test list\nzzreserved\n' >"${T_TMP}/reserved"
fresh; sed -i "s/^ADMIN_USER=.*/ADMIN_USER=zzreserved/" "${T_TMP}/s/site.env"
NP_RESERVED_USERNAMES="${T_TMP}/reserved" run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
[[ "${RC}" -ne 0 ]] && ok "the pinned installer list is applied when present" || bad "the pinned installer list is applied when present"
fresh; render_ok "a non-reserved name is accepted"

# Secret handling: file modes, a missing or malformed hash, extra lines, a bad Pro token (never echoed), and the token given twice.
# secret handling
fresh; chmod 644 "${T_TMP}/s/ph";                                render_fails "password file readable by others"
fresh; chmod 640 "${T_TMP}/s/ph";                                render_fails "password file readable by group"
fresh; rm -f -- "${T_TMP}/s/ph";                                 render_fails "password file missing"
fresh; echo 'not-a-hash' >"${T_TMP}/s/ph";                       render_fails "password file is not a crypt hash"
fresh; printf '%s\n%s\n' "${HASH}" "${HASH}" >"${T_TMP}/s/ph";  render_ok "extra lines after the hash are ignored (first line only)"
fresh; UBUNTU_PRO_TOKEN=C123 run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
[[ "${RC}" -ne 0 && "${OUT}" != *C123* ]] && ok "invalid Pro token rejected without echoing it" || bad "invalid Pro token rejected without echoing it"
fresh; echo "${FAKE_TOKEN}" >"${T_TMP}/s/tok"; chmod 644 "${T_TMP}/s/tok"; echo 'UBUNTU_PRO_TOKEN_FILE=tok' >>"${T_TMP}/s/nodes/node1.env"
render_fails "token file readable by others"
chmod 600 "${T_TMP}/s/tok"; UBUNTU_PRO_TOKEN="${FAKE_TOKEN}" run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
[[ "${RC}" -ne 0 ]] && ok "token env and token file together are refused" || bad "token env and token file together are refused"
render_ok "token file mode 0600 accepted"
grep -q "token: \"${FAKE_TOKEN}\"" "${T_TMP}/o/user-data" && ok "token from file rendered" || bad "token from file rendered"

# Keys and fragments: malformed or missing SSH keys, addresses that differ from NODE_IP, YAML that does not parse and a missing fragment.
# keys and fragments
fresh; echo 'ssh-ed25519 notbase64!! x' >"${T_TMP}/s/authorized_keys.example"; render_fails "malformed SSH key"
fresh; echo '# only a comment' >"${T_TMP}/s/authorized_keys.example";           render_fails "no SSH keys"
fresh; sed -i 's#192.0.2.10/24#192.0.2.99/24#' "${T_TMP}/s/netplan.yaml";        render_fails "netplan address differs from NODE_IP"
fresh; sed -i 's#192.0.2.10/24#192.0.2.99/24#' "${T_TMP}/s/installer-network.yaml"; render_fails "installer address differs from NODE_IP"
fresh; printf 'network: [unclosed\n' >"${T_TMP}/s/netplan.yaml";                 render_fails "netplan fragment is not YAML"
fresh; rm -f -- "${T_TMP}/s/netplan.yaml";                                         render_fails "netplan fragment missing"

# Template problems: an unknown marker and an empty include.
# template problems: an unknown marker and an empty include
cp -r "${ROOT}/targets" "${T_TMP}/targets"
fresh; sed -i 's/^  version: 1$/  version: 1\n  extra: @@NOT_DEFINED@@/' "${T_TMP}/targets/ubuntu-server-26.04/autoinstall/user-data.tmpl.yaml"
NP_TARGET_DIR="${T_TMP}/targets/ubuntu-server-26.04" run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
[[ "${RC}" -ne 0 ]] && ok "unreplaced marker in the template fails the render" || bad "unreplaced marker in the template fails the render"
fresh; : >"${T_TMP}/s/installer-network.yaml"; render_fails "empty installer network fragment"

# The validator catches a broken rendered file.
# validate subcommand catches a broken rendered file through the validator
fresh; mkdir -p "${T_TMP}/v"; "${CLI}" render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/v" >/dev/null 2>&1
sed -i '1s/.*/#notcloud-config/' "${T_TMP}/v/user-data"
python3 "${ROOT}/lib/validate.py" user-data "${T_TMP}/v/user-data" >/dev/null 2>&1 && bad "validator rejects a wrong first line" || ok "validator rejects a wrong first line"
finish
