#!/usr/bin/env bash
# 01-preflight.sh in a container with fake disks: serial-based disk checks.
source "$(dirname "$0")/lib.sh"
# Find a container runtime; without one the test is skipped, with a message.
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
# The image the script runs in (overridable).
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then echo "  skip: cannot obtain ${IMG}"; exit 0; fi
# Run the preflight driver in a container with no network and no capabilities, with the stubs and the script mounted read-only.
OUT="$("${RT}" run --rm --network=none --cap-drop=all --security-opt no-new-privileges --tmpfs /fake \
  -v "${ROOT}/tests/data-disk:/stubs:ro" -v "${ROOT}/targets/ubuntu-server-26.04/node-setup/01-preflight.sh:/script:ro" \
  "${IMG}" bash /stubs/preflight-driver.sh 2>&1)"
# Each scenario becomes one check.
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "preflight: ${name}"; else bad "preflight: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
# All scenarios must have run.
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 11 ]] || bad "preflight: scenarios did not all run"
finish
