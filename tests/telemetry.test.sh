#!/usr/bin/env bash
# 06-telemetry.sh /etc/hosts handling in a container: entries are merged one by one, never duplicated, and
# never suppressed by an existing marker.
source "$(dirname "$0")/lib.sh"
# Find a container runtime; without one the test is skipped, with a message.
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
# The image the script runs in (overridable).
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then echo "  skip: cannot obtain ${IMG}"; exit 0; fi
# The driver that runs inside the container.
cat >"${T_TMP}/driver.sh" <<'DRV'
#!/bin/bash
# The script under test.
S=/script
# res <status>: print a scenario verdict.
res() { echo "RESULT $CUR $([[ $1 == 0 ]] && echo PASS || echo FAIL)"; }
# count <regex>: how many /etc/hosts lines map the (escaped) name to 127.0.0.1.
count() { grep -c -E "^127\.0\.0\.1[[:space:]]+$1([[:space:]]|\$)" /etc/hosts || true; }
# Start from a minimal hosts file.
printf '127.0.0.1 localhost\n' >/etc/hosts
# Scenarios: defaults added once; nothing third-party by default; a re-run changes nothing; extras added and idempotent.
CUR=defaults_added; bash "${S}" >/tmp/o 2>&1; [[ "$(count motd\\.ubuntu\\.com)" == 1 && "$(count metrics\\.ubuntu\\.com)" == 1 && "$(count report\\.ubuntu\\.com)" == 1 ]]; res $?
CUR=no_third_party_by_default; ! grep -q -E 'grafana|longhorn|juicefs|sentry' /etc/hosts; res $?
CUR=idempotent; sha256sum /etc/hosts >/tmp/h1; bash "${S}" >/tmp/o 2>&1; sha256sum /etc/hosts >/tmp/h2; cmp -s /tmp/h1 /tmp/h2; res $?
CUR=extras_added; TELEMETRY_HOSTS_EXTRA=a.example.invalid,b.example.invalid bash "${S}" >/tmp/o 2>&1; [[ "$(count a\\.example\\.invalid)" == 1 && "$(count b\\.example\\.invalid)" == 1 ]]; res $?
CUR=extras_idempotent; sha256sum /etc/hosts >/tmp/h1; TELEMETRY_HOSTS_EXTRA=a.example.invalid,b.example.invalid bash "${S}" >/tmp/o 2>&1; sha256sum /etc/hosts >/tmp/h2; cmp -s /tmp/h1 /tmp/h2; res $?
# The installer already wrote its marker and part of the list: the missing entries must still be added (this used to be skipped).
# the installer already wrote its marker and part of the list: the missing entries must still be added (this used to be skipped)
printf '127.0.0.1 localhost\n\n# Telemetry / analytics endpoint blocks (added by autoinstall)\n127.0.0.1 motd.ubuntu.com\n127.0.0.1 metrics.ubuntu.com\n127.0.0.1 report.ubuntu.com\n' >/etc/hosts
CUR=marker_present_extras_still_added; TELEMETRY_HOSTS_EXTRA=sentry.example.invalid bash "${S}" >/tmp/o 2>&1; [[ "$(count sentry\\.example\\.invalid)" == 1 ]]; res $?
CUR=marker_not_repeated; [[ "$(grep -c 'Telemetry / analytics endpoint blocks' /etc/hosts)" == 1 ]]; res $?
CUR=existing_not_duplicated; [[ "$(count motd\\.ubuntu\\.com)" == 1 ]]; res $?
# An invalid host name stops the run before /etc/hosts is touched; a dot in a name is literal, not "any character".
cp /etc/hosts /tmp/before
CUR=invalid_host_rejected; TELEMETRY_HOSTS_EXTRA='x.example.invalid;rm' bash "${S}" >/tmp/o 2>&1; [[ $? -ne 0 ]] && cmp -s /tmp/before /etc/hosts; res $?
CUR=dotted_name_is_literal; printf '127.0.0.1 localhost\n127.0.0.1 motdXubuntuXcom\n' >/etc/hosts; bash "${S}" >/tmp/o 2>&1; [[ "$(count motd\\.ubuntu\\.com)" == 1 ]]; res $?
DRV
# Run the driver as root in a container with no network and only the capabilities the script needs.
OUT="$("${RT}" run --rm --network=none --cap-drop=all --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE --security-opt no-new-privileges \
  -v "${T_TMP}/driver.sh:/driver.sh:ro" -v "${ROOT}/targets/ubuntu-server-26.04/node-setup/06-telemetry.sh:/script:ro" "${IMG}" bash /driver.sh 2>&1)"
# Each scenario becomes one check.
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "telemetry: ${name}"; else bad "telemetry: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
# All scenarios must have run.
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 10 ]] || bad "telemetry: scenarios did not all run"
finish
