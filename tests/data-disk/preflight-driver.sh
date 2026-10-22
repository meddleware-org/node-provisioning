#!/bin/bash
# Runs INSIDE the container: 01-preflight.sh under fake disks. Prints "RESULT <name> PASS|FAIL".
export PATH="/stubs/bin:${PATH}"
EXPECT_ARCH="$(uname -m)"
export NP_FAKE=/fake NP_SYS_BLOCK=/fake/sys EXPECT_ARCH EXPECT_INTERFACES=eth0 EXPECT_BONDS=
OS_S=ExampleVendor_OsDisk_EX0000000001; DATA_S=ExampleVendor_DataDisk_EX0000000002
reset() {
  find /fake -mindepth 1 -delete; mkdir -p /fake/sys/nvme0n1 /fake/sys/nvme1n1 /fake/sys/sda /fake/serials
  echo "${DATA_S}" >/fake/serials/nvme0n1; echo "${OS_S}" >/fake/serials/nvme1n1; echo OtherDisk_0001 >/fake/serials/sda
  echo nvme1n1 >/fake/root-disk; : >/fake/blkid.db; : >/fake/calls.log
  export OS_DISK_SERIAL="${OS_S}" DATA_DISK_SERIAL="${DATA_S}"
}
run() { bash /script >/fake/out.txt 2>&1; echo $? >/fake/rc; }
rc() { cat /fake/rc; }
out() { grep -q -- "$1" /fake/out.txt; }
res() { if "$@"; then echo "RESULT $CUR PASS"; else echo "RESULT $CUR FAIL"; fi; }
CUR=both_present;      reset; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "OS disk present" /fake/out.txt && grep -q "data disk present" /fake/out.txt && grep -q "root filesystem is on the OS disk" /fake/out.txt'
CUR=os_missing;        reset; rm -f /fake/serials/nvme1n1; run; res bash -c '[[ "$(cat /fake/rc)" != 0 ]] && grep -q "FAIL.*OS disk: expected exactly one" /fake/out.txt'
CUR=data_duplicate;    reset; echo "${DATA_S}" >/fake/serials/sda; run; res bash -c '[[ "$(cat /fake/rc)" != 0 ]] && grep -q "FAIL.*data disk: expected exactly one disk with the configured serial, found 2" /fake/out.txt'
CUR=root_elsewhere;    reset; echo nvme0n1 >/fake/root-disk; run; res bash -c 'grep -q "WARN.*root filesystem is not on the OS disk" /fake/out.txt'
CUR=serials_unset;     reset; unset OS_DISK_SERIAL DATA_DISK_SERIAL; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "OS_DISK_SERIAL is not set" /fake/out.txt'
CUR=names_not_used;    reset; mv /fake/sys/nvme1n1 /fake/sys/sdq; mv /fake/serials/nvme1n1 /fake/serials/sdq; echo sdq >/fake/root-disk; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "/dev/sdq" /fake/out.txt'
CUR=optional_expectations_unset; reset; unset EXPECT_INTERFACES EXPECT_BONDS EXPECT_KERNEL_PREFIX; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && ! grep -q "unbound variable" /fake/out.txt'
CUR=no_kubectl_short_flag; res bash -c '! grep -q -- "--short" /script'
