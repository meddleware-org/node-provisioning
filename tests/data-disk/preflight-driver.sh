#!/bin/bash
# Runs INSIDE the container: 01-preflight.sh under fake disks. Prints "RESULT <name> PASS|FAIL".
# Stubs shadow the real disk tools.
export PATH="/stubs/bin:${PATH}"
# The container's own architecture is the expected one.
EXPECT_ARCH="$(uname -m)"
export NP_FAKE=/fake NP_SYS_BLOCK=/fake/sys EXPECT_ARCH EXPECT_INTERFACES=eth0 EXPECT_BONDS=
# Fixed serials for the OS and data disks.
OS_S=ExampleVendor_OsDisk_EX0000000001; DATA_S=ExampleVendor_DataDisk_EX0000000002
# reset: a fresh fake tree with the OS disk as the root disk and a third, unrelated disk.
reset() {
  find /fake -mindepth 1 -delete; mkdir -p /fake/sys/nvme0n1 /fake/sys/nvme1n1 /fake/sys/sda /fake/serials
  echo "${DATA_S}" >/fake/serials/nvme0n1; echo "${OS_S}" >/fake/serials/nvme1n1; echo OtherDisk_0001 >/fake/serials/sda
  echo nvme1n1 >/fake/root-disk; : >/fake/blkid.db; : >/fake/calls.log
  export OS_DISK_SERIAL="${OS_S}" DATA_DISK_SERIAL="${DATA_S}"
}
# run: execute the preflight script and keep its output and status.
run() { bash /script >/fake/out.txt 2>&1; echo $? >/fake/rc; }
# rc: the exit status of the last run.
rc() { cat /fake/rc; }
# out <text>: does the output contain the text?
out() { grep -q -- "$1" /fake/out.txt; }
# res <command>...: print the scenario verdict from a command's status.
res() { if "$@"; then echo "RESULT $CUR PASS"; else echo "RESULT $CUR FAIL"; fi; }
# Scenarios: both disks present and the root file system on the OS disk.
CUR=both_present;      reset; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "OS disk present" /fake/out.txt && grep -q "data disk present" /fake/out.txt && grep -q "root filesystem is on the OS disk" /fake/out.txt'
# A missing OS disk fails.
CUR=os_missing;        reset; rm -f /fake/serials/nvme1n1; run; res bash -c '[[ "$(cat /fake/rc)" != 0 ]] && grep -q "FAIL.*OS disk: expected exactly one" /fake/out.txt'
# Two disks with the data serial fail, and the count is reported.
CUR=data_duplicate;    reset; echo "${DATA_S}" >/fake/serials/sda; run; res bash -c '[[ "$(cat /fake/rc)" != 0 ]] && grep -q "FAIL.*data disk: expected exactly one disk with the configured serial, found 2" /fake/out.txt'
# Root on another disk only warns.
CUR=root_elsewhere;    reset; echo nvme0n1 >/fake/root-disk; run; res bash -c 'grep -q "WARN.*root filesystem is not on the OS disk" /fake/out.txt'
# Unset serials are skipped with a note.
CUR=serials_unset;     reset; unset OS_DISK_SERIAL DATA_DISK_SERIAL; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "OS_DISK_SERIAL is not set" /fake/out.txt'
# Device names do not matter, only serials.
CUR=names_not_used;    reset; mv /fake/sys/nvme1n1 /fake/sys/sdq; mv /fake/serials/nvme1n1 /fake/serials/sdq; echo sdq >/fake/root-disk; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && grep -q "/dev/sdq" /fake/out.txt'
# Unset optional expectations raise no unbound-variable error.
CUR=optional_expectations_unset; reset; unset EXPECT_INTERFACES EXPECT_BONDS EXPECT_KERNEL_PREFIX; run; res bash -c '[[ "$(cat /fake/rc)" == 0 ]] && ! grep -q "unbound variable" /fake/out.txt'
# The layout on the configured data disk is recognised.
CUR=data_layout_on_data_disk;  reset; echo "/dev/nvme0n1p3|persistent|uuid-a" >>/fake/blkid.db; run; res bash -c 'grep -q "data disk already provisioned (LABEL=persistent on /dev/nvme0n1)" /fake/out.txt'
# The same label on another disk is a warning and does not count.
CUR=stale_label_on_another_disk; reset; echo "/dev/sda3|persistent|uuid-b" >>/fake/blkid.db; run; res bash -c '! grep -q "data disk already provisioned" /fake/out.txt && grep -q "WARN.*LABEL=persistent also exists on /dev/sda3.*not the configured data disk" /fake/out.txt && grep -q "data disk not yet provisioned" /fake/out.txt'
# Both together.
CUR=layout_and_stale_label;    reset; printf "/dev/nvme0n1p3|persistent|uuid-a\n/dev/sda3|persistent|uuid-b\n" >>/fake/blkid.db; run; res bash -c 'grep -q "data disk already provisioned (LABEL=persistent on /dev/nvme0n1)" /fake/out.txt && grep -q "WARN.*also exists on /dev/sda3" /fake/out.txt'
# The script must not use the removed `--short` flag.
CUR=no_kubectl_short_flag; res bash -c '! grep -q -- "--short" /script'
