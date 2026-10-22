#!/usr/bin/env bash
# 00-data-disk.sh under fake devices, in a container (root, no network, no devices, no extra privileges).
source "$(dirname "$0")/lib.sh"
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then
  echo "  skip: cannot obtain ${IMG}"; exit 0
fi
OUT="$("${RT}" run --rm --network=none --cap-drop=all --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE \
  --security-opt no-new-privileges --tmpfs /fake \
  -v "${ROOT}/tests/data-disk:/stubs:ro" -v "${ROOT}/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh:/script:ro" \
  "${IMG}" bash /stubs/driver.sh 2>&1)"
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "data-disk: ${name}"; else bad "data-disk: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 14 ]] || bad "data-disk: scenarios did not all run"
finish
