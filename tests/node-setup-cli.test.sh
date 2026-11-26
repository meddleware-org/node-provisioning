#!/usr/bin/env bash
# `node-provisioning node-setup --site --node` exports the site and node values into the scripts: run the real CLI and
# preflight in a container (fake disks) and check that the configured serials, expectations and secrets-handling arrive.
source "$(dirname "$0")/lib.sh"
# Find a container runtime; without one the test is skipped, with a message.
RT=""; for c in podman docker; do command -v "${c}" >/dev/null 2>&1 && { RT="${c}"; break; }; done
# The image the CLI runs in (overridable).
IMG="${NP_TEST_IMAGE:-docker.io/library/ubuntu:26.04}"
if [[ -z "${RT}" ]]; then echo "  skip: no container runtime (podman or docker)"; exit 0; fi
if ! "${RT}" image inspect "${IMG}" >/dev/null 2>&1 && ! "${RT}" pull -q "${IMG}" >/dev/null 2>&1; then echo "  skip: cannot obtain ${IMG}"; exit 0; fi
# A copy of the example site; the interface expectation is changed to one the container has.
mk_site "${T_TMP}/site"
sed -i 's/^EXPECT_INTERFACES=.*/EXPECT_INTERFACES=eth0/; /^EXPECT_BONDS=/d' "${T_TMP}/site/site.env"
# The driver that runs inside the container: fake disks, then the real CLI.
cat >"${T_TMP}/driver.sh" <<'DRV'
#!/bin/bash
# The disk-tool stubs shadow the real tools.
export PATH="/stubs/bin:${PATH}"
export NP_FAKE=/fake NP_SYS_BLOCK=/fake/sys EXPECT_ARCH_UNUSED=1
# The fake tree: a data disk, an OS disk that is the root disk, and empty databases.
find /fake -mindepth 1 -delete; mkdir -p /fake/sys/nvme0n1 /fake/sys/nvme1n1 /fake/serials
echo ExampleVendor_DataDisk_EX0000000002 >/fake/serials/nvme0n1; echo ExampleVendor_OsDisk_EX0000000001 >/fake/serials/nvme1n1
echo nvme1n1 >/fake/root-disk; : >/fake/blkid.db; : >/fake/calls.log
# res <name> <status>: print a scenario verdict.
res() { echo "RESULT $1 $([[ $2 == 0 ]] && echo PASS || echo FAIL)"; }
# Run the preflight phase through the CLI with the site, then check that the configured serials and expectations arrived and that no secret reached the output.
/repo/bin/node-provisioning node-setup --site /site --node node1 --step preflight >/tmp/out 2>&1; rc=$?
grep -q "OS disk present (/dev/nvme1n1" /tmp/out; res os_serial_from_the_node_file_reached_preflight $?
grep -q "data disk present (/dev/nvme0n1" /tmp/out; res data_serial_from_the_node_file_reached_preflight $?
grep -q "root filesystem is on the OS disk" /tmp/out; res root_checked_against_the_os_disk $?
grep -q "eth0 present" /tmp/out; res site_interface_expectation_reached_preflight $?
! grep -q -F -e 'fixturesalt' /tmp/out; res no_password_hash_in_output $?
# the exported environment never contains the secret file path's content
# An unknown node and an unknown step must both fail.
/repo/bin/node-provisioning node-setup --site /site --node nosuch --step preflight >/tmp/out2 2>&1; [[ $? -ne 0 ]]; res unknown_node_fails $?
/repo/bin/node-provisioning node-setup --step bogus >/tmp/out3 2>&1; [[ $? -ne 0 ]]; res unknown_step_fails $?
DRV
# Run the driver with no network, no capabilities, the repository and the site mounted read-only.
OUT="$("${RT}" run --rm --network=none --cap-drop=all --security-opt no-new-privileges --tmpfs /fake \
  -v "${ROOT}:/repo:ro" -v "${T_TMP}/site:/site:ro" -v "${ROOT}/tests/data-disk:/stubs:ro" -v "${T_TMP}/driver.sh:/driver.sh:ro" \
  "${IMG}" bash /driver.sh 2>&1)"
# Each scenario becomes one check.
while read -r _ name verdict; do
  if [[ "${verdict}" == PASS ]]; then ok "node-setup CLI: ${name}"; else bad "node-setup CLI: ${name}"; fi
done < <(grep '^RESULT ' <<<"${OUT}")
# All scenarios must have run.
[[ "$(grep -c '^RESULT ' <<<"${OUT}")" -ge 7 ]] || bad "node-setup CLI: scenarios did not all run"
finish
