#!/bin/bash
# Runs INSIDE the container (root, no network). Executes 00-data-disk.sh under scenario fixtures and prints
# "RESULT <name> PASS|FAIL". The script under test is mounted at /script.
# Stubs shadow the real disk tools, so nothing touches a device.
export PATH="/stubs/bin:${PATH}"
# Where the fake tree lives, and where the script looks for block devices.
export NP_FAKE=/fake NP_SYS_BLOCK=/fake/sys
# There are no block devices in a container: every candidate counts as one (the script's test seam).
np_is_block() { return 0; }
export -f np_is_block
export ETCD_SIZE=1G LONGHORN_SIZE=2G
# Three fixed serials: the data disk, the OS disk and an unrelated hard disk.
DATA_S=ExampleVendor_DataDisk_EX0000000002; OS_S=ExampleVendor_OsDisk_EX0000000001; HDD_S=ExampleVendor_Hdd_EX0000000003

# reset: a fresh fake tree. The root disk is nvme1n1 (OS), the data disk nvme0n1, and an HDD sda; fstab and the mount points are emptied.
reset() { # root disk is nvme1n1 (OS), data disk nvme0n1, hdd sda
  find /fake -mindepth 1 -delete; mkdir -p /fake/sys/nvme0n1 /fake/sys/nvme1n1 /fake/sys/sda /fake/serials
  echo "${DATA_S}" >/fake/serials/nvme0n1; echo "${OS_S}" >/fake/serials/nvme1n1; echo "${HDD_S}" >/fake/serials/sda
  echo nvme1n1 >/fake/root-disk; : >/fake/blkid.db; : >/fake/calls.log
  : >/etc/fstab; rm -rf /var/lib/persistent /var/lib/etcd /var/lib/longhorn-nvme
  unset WIPE_DATA_DISK; export DATA_DISK_SERIAL="${DATA_S}"
}
# layout <disk>: record a complete labelled layout (etcd, longhorn-nvme, persistent) on that disk in the fake blkid database.
layout() { # disk-path -> labelled layout in the fake blkid db
  printf '%s|etcd|uuid-%s1\n%s|longhorn-nvme|uuid-%s2\n%s|persistent|uuid-%s3\n' "${1}p1" "${1##*/}" "${1}p2" "${1##*/}" "${1}p3" "${1##*/}" >>/fake/blkid.db
}
# run: execute the script and keep its output and exit status.
run() { bash /script >/fake/out.txt 2>&1; echo $? >/fake/rc; }
# rc: the exit status of the last run.
rc() { cat /fake/rc; }
# called <pattern>: did the stubs record a call that starts with the pattern?
called() { grep -q -E "^$1" /fake/calls.log; }
# result <command>...: print the scenario verdict from a command's status.
result() { if "$@"; then echo "RESULT $CUR PASS"; else echo "RESULT $CUR FAIL"; fi; }
# t <name> <command>...: name a scenario and run it.
t() { CUR="$1"; shift; "$@"; }

# Fresh data disk: partitions, file systems and three fstab entries are created, and the README is left.
s_fresh() { reset; run; [[ "$(rc)" == 0 ]] && called "sfdisk /dev/nvme0n1" && called "mkfs.ext4 -q -L persistent /dev/nvme0n1p3" \
  && [[ "$(grep -c '^UUID=' /etc/fstab)" == 3 ]] && grep -q 'UUID=uuid-.* /var/lib/etcd ext4' /etc/fstab && [[ -f /var/lib/persistent/README ]]; }
# Re-install: the layout is recognised and only mounted; nothing is partitioned or formatted.
s_reinstall() { reset; layout /dev/nvme0n1; run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called mkfs && ! called wipefs \
  && grep -q 'UUID=uuid-nvme0n11 /var/lib/etcd' /etc/fstab && grep -q 'UUID=uuid-nvme0n13 /var/lib/persistent' /etc/fstab; }
# The same labels on another disk are reported and ignored, and the blank data disk is provisioned.
s_stale_hdd_blank_data() { reset; layout /dev/sda; run; [[ "$(rc)" == 0 ]] && called "sfdisk /dev/nvme0n1" && ! called "sfdisk /dev/sda" \
  && grep -q "also exists on /dev/sda" /fake/out.txt && ! grep -q 'uuid-sda' /etc/fstab; }
# A present layout plus stale labels elsewhere: mount only, stale labels reported.
s_stale_hdd_layout_present() { reset; layout /dev/sda; layout /dev/nvme0n1; run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called mkfs \
  && grep -q "also exists on /dev/sda" /fake/out.txt && grep -q 'uuid-nvme0n11' /etc/fstab && ! grep -q 'uuid-sda' /etc/fstab; }
# Unrecognised partitions without the opt-in: refuse, touch nothing, and name the switch.
s_unrecognised_refuses() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs && grep -q 'WIPE_DATA_DISK=1' /fake/out.txt; }
# WIPE_DATA_DISK=1 erases the unrecognised data on the named disk only.
s_unrecognised_wipe() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && called "wipefs -a /dev/nvme0n1" && called "sfdisk /dev/nvme0n1" && ! called "sfdisk /dev/sda"; }
# The wipe never reaches another disk.
s_wipe_never_other_disk() { reset; echo '/dev/sda1|keep|uuid-h' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called "wipefs -a /dev/sda" && grep -q '/dev/sda1|keep' /fake/blkid.db; }
# WIPE_DATA_DISK=1 never erases a layout the script itself created.
s_wipe1_keeps_own_layout() { reset; layout /dev/nvme0n1; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called wipefs && ! called mkfs && grep -q 'existing layout is kept' /fake/out.txt; }
# `force` rebuilds even our own layout.
s_wipe_force_rebuilds() { reset; layout /dev/nvme0n1; WIPE_DATA_DISK=force run; [[ "$(rc)" == 0 ]] && called "wipefs -a /dev/nvme0n1" && called "sfdisk /dev/nvme0n1" && called "mkfs.ext4 -q -L persistent /dev/nvme0n1p3"; }
# Any other value of the switch is refused.
s_wipe_value_validated() { reset; WIPE_DATA_DISK=yes run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs; }
# Re-running a failed bootstrap with the switch still set is safe: the second run changes nothing.
s_wipe1_rerun_after_first_wipe() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; : >/fake/calls.log; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called wipefs; }
# No disk with the serial: refuse before touching anything.
s_serial_absent() { reset; rm -f /fake/serials/nvme0n1; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called mkfs && ! called wipefs; }
# Two disks with the serial: refuse.
s_serial_duplicate() { reset; echo "${DATA_S}" >/fake/serials/sda; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs; }
# The root disk is never accepted as the data disk.
s_serial_is_root_disk() { reset; export DATA_DISK_SERIAL="${OS_S}"; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs && grep -q 'root disk' /fake/out.txt; }
# No serial configured: refuse.
s_serial_required() { reset; unset DATA_DISK_SERIAL; run; [[ "$(rc)" != 0 ]] && ! called sfdisk; }
# A serial with a glob character: refuse.
s_serial_glob_rejected() { reset; export DATA_DISK_SERIAL='ExampleVendor_*'; run; [[ "$(rc)" != 0 ]] && ! called sfdisk; }
# An fstab entry that maps a mount point elsewhere: refuse to change it.
s_fstab_conflict() { reset; layout /dev/nvme0n1; echo 'UUID=some-other /var/lib/etcd ext4 noatime 0 2' >/etc/fstab; run; [[ "$(rc)" != 0 ]] && grep -q 'different source' /fake/out.txt; }
# A second run changes nothing: same fstab, no partitioning, no formatting.
s_idempotent() { reset; run; cp /etc/fstab /fake/fstab1; : >/fake/calls.log; run; [[ "$(rc)" == 0 ]] && cmp -s /etc/fstab /fake/fstab1 && ! called sfdisk && ! called mkfs; }

# Run every scenario in turn and print its verdict.
for s in fresh reinstall stale_hdd_blank_data stale_hdd_layout_present unrecognised_refuses unrecognised_wipe wipe_never_other_disk \
         wipe1_keeps_own_layout wipe_force_rebuilds wipe_value_validated wipe1_rerun_after_first_wipe \
         serial_absent serial_duplicate serial_is_root_disk serial_required serial_glob_rejected fstab_conflict idempotent; do
  CUR="$s"; "s_${s}" && echo "RESULT ${s} PASS" || echo "RESULT ${s} FAIL"
done
