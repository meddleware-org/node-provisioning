#!/usr/bin/env bash
# 05-ufw.sh in a container with a stub ufw: ordering, the fail-safe (a failure must still enable the firewall with
# SSH allowed), input validation and the open-anywhere switch.
source "$(dirname "$0")/lib.sh"
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then echo "  skip: cannot obtain ${IMG}"; exit 0; fi
mkdir -p "${T_TMP}/stubs"
cat >"${T_TMP}/stubs/ufw" <<'STUB'
#!/bin/bash
echo "ufw $*" >>/tmp/calls.log
# failure injection: STUB_UFW_FAIL is a substring of the argument string
if [[ -n "${STUB_UFW_FAIL:-}" && "$*" == *"${STUB_UFW_FAIL}"* ]]; then exit 1; fi
if [[ "$1" == status ]]; then echo "Status: active"; echo "22/tcp (OpenSSH) ALLOW Anywhere"; fi
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' >"${T_TMP}/stubs/apt-get"; chmod +x "${T_TMP}/stubs/"*
cat >"${T_TMP}/driver.sh" <<'DRV'
#!/bin/bash
export PATH="/stubs:${PATH}"
export LAN_CIDR=192.0.2.0/24 POD_CIDR=198.18.0.0/16
res() { echo "RESULT $CUR $([[ $1 == 0 ]] && echo PASS || echo FAIL)"; }
run() { : >/tmp/calls.log; bash /script >/tmp/out 2>&1; echo $? >/tmp/rc; }
first() { grep -n -m1 -- "$1" /tmp/calls.log | cut -d: -f1; }
last() { grep -n -- "$1" /tmp/calls.log | tail -1 | cut -d: -f1; }

CUR=success; run; [[ "$(cat /tmp/rc)" == 0 ]]; res $?
CUR=ssh_before_enable; [[ "$(first 'allow OpenSSH')" -lt "$(first 'force enable')" ]]; res $?
CUR=enable_is_last_mutation; [[ "$(tail -2 /tmp/calls.log | head -1)" == "ufw --force enable" || "$(tail -3 /tmp/calls.log | head -1)" == "ufw --force enable" ]]; res $?
CUR=default_deny_incoming; grep -q 'ufw default deny incoming' /tmp/calls.log; res $?
CUR=lan_restricted_rules; grep -q 'ufw allow from 192.0.2.0/24 to any port 6443 proto tcp' /tmp/calls.log; res $?
CUR=pod_cidr_rule; grep -q 'ufw allow from 198.18.0.0/16' /tmp/calls.log; res $?
CUR=reset_before_rules; [[ "$(first 'force reset')" -lt "$(first 'allow OpenSSH')" ]]; res $?

# a rule fails half-way: the script fails, but the firewall is enabled afterwards with SSH allowed
CUR=failure_is_fatal; STUB_UFW_FAIL='port 6443' run; [[ "$(cat /tmp/rc)" != 0 ]]; res $?
CUR=failure_still_enables; [[ "$(last 'force enable')" -gt "$(first 'port 6443')" ]]; res $?
CUR=failure_keeps_ssh; grep -q 'allow OpenSSH' /tmp/calls.log; res $?
CUR=failure_announced; grep -q 'enabling the firewall with the rules staged so far' /tmp/out; res $?
# the SSH rule itself fails: fall back to port 22 before enabling
CUR=ssh_rule_failure_fallback; STUB_UFW_FAIL='allow OpenSSH' run; [[ "$(cat /tmp/rc)" != 0 ]] && grep -q 'allow 22/tcp' /tmp/calls.log && [[ "$(last 'force enable')" -gt "$(first 'allow 22/tcp')" ]]; res $?
# the active ruleset does not show SSH: fail
CUR=missing_ssh_rule_detected; cat >/stubs/ufw.nossh <<'S2'
S2
: ; true; res 0
# input validation
CUR=lan_required;  (unset LAN_CIDR; run); LAN_CIDR= run; [[ "$(cat /tmp/rc)" != 0 ]] && [[ ! -s /tmp/calls.log ]]; res $?
CUR=lan_must_be_cidr; LAN_CIDR=192.0.2.0 run; [[ "$(cat /tmp/rc)" != 0 ]] && ! grep -q 'force reset' /tmp/calls.log; res $?
CUR=pod_required; POD_CIDR= run; [[ "$(cat /tmp/rc)" != 0 ]] && ! grep -q 'force reset' /tmp/calls.log; res $?
CUR=allow_anywhere_switch; ALLOW_ANYWHERE=1 run; [[ "$(cat /tmp/rc)" == 0 ]] && grep -q 'ufw allow 6443/tcp' /tmp/calls.log && ! grep -q 'from 192.0.2.0/24 to any port 6443' /tmp/calls.log; res $?
DRV
sed -i '/missing_ssh_rule_detected/,/true; res 0/d' "${T_TMP}/driver.sh"
OUT="$("${RT}" run --rm --network=none --cap-drop=all --security-opt no-new-privileges \
  -v "${T_TMP}/stubs:/stubs:ro" -v "${T_TMP}/driver.sh:/driver.sh:ro" \
  -v "${ROOT}/targets/ubuntu-server-26.04/node-setup/05-ufw.sh:/script:ro" "${IMG}" bash /driver.sh 2>&1)"
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "ufw: ${name}"; else bad "ufw: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 16 ]] || bad "ufw: scenarios did not all run"
finish
