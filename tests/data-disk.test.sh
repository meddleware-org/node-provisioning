#!/usr/bin/env bash
# 00-data-disk.sh under fake devices, in a container (root, no network, no devices, no extra privileges).
source "$(dirname "$0")/lib.sh"
# Find a container runtime (podman or docker); without one the test is skipped, with a message.
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
# The image the script runs in (overridable); it must exist locally or be pullable.
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then
  echo "  skip: cannot obtain ${IMG}"; exit 0
fi
# Run the scenarios as root in a container with no network, no devices and only the capabilities the script needs, with the stubs and the script mounted read-only.
OUT="$("${RT}" run --rm --network=none --cap-drop=all --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE \
  --security-opt no-new-privileges --tmpfs /fake \
  -v "${ROOT}/tests/data-disk:/stubs:ro" -v "${ROOT}/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh:/script:ro" \
  "${IMG}" bash /stubs/driver.sh 2>&1)"
# Each scenario prints `RESULT <name> PASS|FAIL`; each becomes one check.
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "data-disk: ${name}"; else bad "data-disk: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
# All eighteen scenarios must have run, so a driver that stops early cannot pass.
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 18 ]] || bad "data-disk: scenarios did not all run"
finish
