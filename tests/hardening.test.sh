#!/usr/bin/env bash
# 08-hardening.sh in a container: files, modes, idempotence, the forwarding switch, and rollback when sshd -t fails.
source "$(dirname "$0")/lib.sh"
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then echo "  skip: cannot obtain ${IMG}"; exit 0; fi
mkdir -p "${T_TMP}/stubs"
for c in systemctl sysctl; do printf '#!/bin/sh\necho "%s $*" >>/tmp/calls.log\nexit 0\n' "${c}" >"${T_TMP}/stubs/${c}"; done
cat >"${T_TMP}/stubs/sshd" <<'STUB'
#!/bin/sh
echo "sshd $*" >>/tmp/calls.log
[ -f /tmp/sshd-fail ] && exit 1
exit 0
STUB
chmod +x "${T_TMP}/stubs/"*
cat >"${T_TMP}/driver.sh" <<'DRV'
#!/bin/bash
export PATH="/stubs:${PATH}"
S=/script/08-hardening.sh
: >/tmp/calls.log
mkdir -p /etc/ssh/sshd_config.d /etc/sysctl.d /etc/apt/apt.conf.d /var/log/installer
printf 'autoinstall:\n  identity:\n    username: x\n    password: "%s"\n  ubuntu-pro:\n    token: "%s"\n  keep: "value"\n' 'HASHVALUE-1' 'TOKENVALUE-1' >/var/log/installer/autoinstall-user-data; chmod 400 /var/log/installer/autoinstall-user-data
r() { echo "RESULT $1 $([[ $2 == 0 ]] && echo PASS || echo FAIL)"; }
bash "${S}" >/tmp/o1 2>&1; r first_run_ok $?
[[ "$(stat -c %a /etc/ssh/sshd_config.d/99-hardening.conf)" == 644 ]]; r sshd_conf_mode $?
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf && grep -q '^PermitRootLogin no' /etc/ssh/sshd_config.d/99-hardening.conf \
  && grep -q '^AuthenticationMethods publickey' /etc/ssh/sshd_config.d/99-hardening.conf && grep -q '^KbdInteractiveAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf; r sshd_key_only $?
! grep -q ChallengeResponseAuthentication /etc/ssh/sshd_config.d/99-hardening.conf; r no_deprecated_option $?
grep -q '^AllowTcpForwarding no' /etc/ssh/sshd_config.d/99-hardening.conf; r forwarding_default_no $?
grep -q 'sshd -t' /tmp/calls.log; r sshd_validated_before_reload $?
grep -q 'systemctl reload ssh' /tmp/calls.log; r sshd_reloaded $?
grep -q 'kernel.kptr_restrict = 2' /etc/sysctl.d/90-hardening.conf; r sysctl_file $?
grep -q 'sysctl -q -p /etc/sysctl.d/90-hardening.conf' /tmp/calls.log; r sysctl_applied $?
grep -q '"kubelet";' /etc/apt/apt.conf.d/52unattended-upgrades-local && grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/52unattended-upgrades-local; r unattended_policy $?
[[ ! -e /etc/apt/apt.conf.d/50unattended-upgrades ]]; r package_conf_untouched $?
! grep -q -E 'HASHVALUE|TOKENVALUE' /var/log/installer/autoinstall-user-data; r installer_copy_redacted $?
grep -q 'password: "<redacted>"' /var/log/installer/autoinstall-user-data && grep -q 'token: "<redacted>"' /var/log/installer/autoinstall-user-data && grep -q 'keep: "value"' /var/log/installer/autoinstall-user-data; r redaction_keeps_the_rest $?
[[ "$(stat -c %a /var/log/installer/autoinstall-user-data)" == 400 ]]; r installer_copy_mode_kept $?
sha256sum /etc/ssh/sshd_config.d/99-hardening.conf /etc/sysctl.d/90-hardening.conf /etc/apt/apt.conf.d/52unattended-upgrades-local /var/log/installer/autoinstall-user-data >/tmp/h1
: >/tmp/calls.log; bash "${S}" >/tmp/o2 2>&1; r second_run_ok $?
sha256sum /etc/ssh/sshd_config.d/99-hardening.conf /etc/sysctl.d/90-hardening.conf /etc/apt/apt.conf.d/52unattended-upgrades-local /var/log/installer/autoinstall-user-data >/tmp/h2
cmp -s /tmp/h1 /tmp/h2; r idempotent_files $?
! grep -q -E 'sshd -t|reload|sysctl' /tmp/calls.log; r idempotent_no_reload $?
SSH_ALLOW_TCP_FORWARDING=true bash "${S}" >/tmp/o3 2>&1; r forwarding_opt_in $?
grep -q '^AllowTcpForwarding yes' /etc/ssh/sshd_config.d/99-hardening.conf; r forwarding_yes_written $?
SSH_ALLOW_TCP_FORWARDING=maybe bash "${S}" >/tmp/o4 2>&1; [[ $? -ne 0 ]]; r forwarding_value_validated $?
# rollback: sshd rejects the new config -> previous content restored, script fails
cp /etc/ssh/sshd_config.d/99-hardening.conf /tmp/before
touch /tmp/sshd-fail; SSH_ALLOW_TCP_FORWARDING=false bash "${S}" >/tmp/o5 2>&1; [[ $? -ne 0 ]]; r rejected_config_fails $?
cmp -s /tmp/before /etc/ssh/sshd_config.d/99-hardening.conf; r rejected_config_rolled_back $?
rm -f /etc/ssh/sshd_config.d/99-hardening.conf; SSH_ALLOW_TCP_FORWARDING=false bash "${S}" >/tmp/o6 2>&1; [[ $? -ne 0 && ! -e /etc/ssh/sshd_config.d/99-hardening.conf ]]; r rejected_fresh_config_removed $?
DRV
OUT="$("${RT}" run --rm --network=none --cap-drop=all --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE \
  --security-opt no-new-privileges -v "${T_TMP}/stubs:/stubs:ro" -v "${T_TMP}/driver.sh:/driver.sh:ro" \
  -v "${ROOT}/targets/ubuntu-server-26.04/node-setup:/script:ro" "${IMG}" bash /driver.sh 2>&1)"
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "hardening: ${name}"; else bad "hardening: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 22 ]] || bad "hardening: scenarios did not all run"
finish
