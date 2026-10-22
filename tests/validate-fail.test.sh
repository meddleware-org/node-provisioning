#!/usr/bin/env bash
# Every way a build must fail closed, and proof that failures never echo secret values.
source "$(dirname "$0")/lib.sh"
HASH="$(cat "${ROOT}/tests/fixtures/password-hash")"
FAKE_TOKEN=C1111111111111111111111111

fresh() { rm -rf -- "${T_TMP}/s"; mk_site "${T_TMP}/s"; }
render_fails() { # name; expects non-zero exit and no hash in output
  run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
  if [[ "${RC}" -ne 0 ]]; then ok "$1"; else bad "$1 (expected failure)"; fi
  if [[ "${OUT}" == *"${HASH}"* || "${OUT}" == *"${FAKE_TOKEN}"* ]]; then bad "$1: output leaked a secret"; fi
}
render_ok() {
  run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
  if [[ "${RC}" -eq 0 ]]; then ok "$1"; else bad "$1 (expected success): ${OUT}"; fi
}

fresh; render_ok "baseline site renders"

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

# keys and fragments
fresh; echo 'ssh-ed25519 notbase64!! x' >"${T_TMP}/s/authorized_keys.example"; render_fails "malformed SSH key"
fresh; echo '# only a comment' >"${T_TMP}/s/authorized_keys.example";           render_fails "no SSH keys"
fresh; sed -i 's#192.0.2.10/24#192.0.2.99/24#' "${T_TMP}/s/netplan.yaml";        render_fails "netplan address differs from NODE_IP"
fresh; sed -i 's#192.0.2.10/24#192.0.2.99/24#' "${T_TMP}/s/installer-network.yaml"; render_fails "installer address differs from NODE_IP"
fresh; printf 'network: [unclosed\n' >"${T_TMP}/s/netplan.yaml";                 render_fails "netplan fragment is not YAML"
fresh; rm -f -- "${T_TMP}/s/netplan.yaml";                                         render_fails "netplan fragment missing"

# template problems: an unknown marker and an empty include
cp -r "${ROOT}/targets" "${T_TMP}/targets"
fresh; sed -i 's/^  version: 1$/  version: 1\n  extra: @@NOT_DEFINED@@/' "${T_TMP}/targets/ubuntu-server-26.04/autoinstall/user-data.tmpl.yaml"
NP_TARGET_DIR="${T_TMP}/targets/ubuntu-server-26.04" run_cli render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/o"
[[ "${RC}" -ne 0 ]] && ok "unreplaced marker in the template fails the render" || bad "unreplaced marker in the template fails the render"
fresh; : >"${T_TMP}/s/installer-network.yaml"; render_fails "empty installer network fragment"

# validate subcommand catches a broken rendered file through the validator
fresh; mkdir -p "${T_TMP}/v"; "${CLI}" render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/v" >/dev/null 2>&1
sed -i '1s/.*/#notcloud-config/' "${T_TMP}/v/user-data"
python3 "${ROOT}/lib/validate.py" user-data "${T_TMP}/v/user-data" >/dev/null 2>&1 && bad "validator rejects a wrong first line" || ok "validator rejects a wrong first line"
finish
