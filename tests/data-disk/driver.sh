#!/bin/bash
# Runs INSIDE the container (root, no network). Executes 00-data-disk.sh under scenario fixtures and prints
# "RESULT <name> PASS|FAIL". The script under test is mounted at /script.
export PATH="/stubs/bin:${PATH}"
export NP_FAKE=/fake NP_SYS_BLOCK=/fake/sys
np_is_block() { return 0; }
export -f np_is_block
export ETCD_SIZE=1G LONGHORN_SIZE=2G
DATA_S=ExampleVendor_DataDisk_EX0000000002; OS_S=ExampleVendor_OsDisk_EX0000000001; HDD_S=ExampleVendor_Hdd_EX0000000003

reset() { # root disk is nvme1n1 (OS), data disk nvme0n1, hdd sda
  find /fake -mindepth 1 -delete; mkdir -p /fake/sys/nvme0n1 /fake/sys/nvme1n1 /fake/sys/sda /fake/serials
  echo "${DATA_S}" >/fake/serials/nvme0n1; echo "${OS_S}" >/fake/serials/nvme1n1; echo "${HDD_S}" >/fake/serials/sda
  echo nvme1n1 >/fake/root-disk; : >/fake/blkid.db; : >/fake/calls.log
  : >/etc/fstab; rm -rf /var/lib/persistent /var/lib/etcd /var/lib/longhorn-nvme
  unset WIPE_DATA_DISK; export DATA_DISK_SERIAL="${DATA_S}"
}
layout() { # disk-path -> labelled layout in the fake blkid db
  printf '%s|etcd|uuid-%s1\n%s|longhorn-nvme|uuid-%s2\n%s|persistent|uuid-%s3\n' "${1}p1" "${1##*/}" "${1}p2" "${1##*/}" "${1}p3" "${1##*/}" >>/fake/blkid.db
}
run() { bash /script >/fake/out.txt 2>&1; echo $? >/fake/rc; }
rc() { cat /fake/rc; }
called() { grep -q -E "^$1" /fake/calls.log; }
result() { if "$@"; then echo "RESULT $CUR PASS"; else echo "RESULT $CUR FAIL"; fi; }
t() { CUR="$1"; shift; "$@"; }

s_fresh() { reset; run; [[ "$(rc)" == 0 ]] && called "sfdisk /dev/nvme0n1" && called "mkfs.ext4 -q -L persistent /dev/nvme0n1p3" \
  && [[ "$(grep -c '^UUID=' /etc/fstab)" == 3 ]] && grep -q 'UUID=uuid-.* /var/lib/etcd ext4' /etc/fstab && [[ -f /var/lib/persistent/README ]]; }
s_reinstall() { reset; layout /dev/nvme0n1; run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called mkfs && ! called wipefs \
  && grep -q 'UUID=uuid-nvme0n11 /var/lib/etcd' /etc/fstab && grep -q 'UUID=uuid-nvme0n13 /var/lib/persistent' /etc/fstab; }
s_stale_hdd_blank_data() { reset; layout /dev/sda; run; [[ "$(rc)" == 0 ]] && called "sfdisk /dev/nvme0n1" && ! called "sfdisk /dev/sda" \
  && grep -q "also exists on /dev/sda" /fake/out.txt && ! grep -q 'uuid-sda' /etc/fstab; }
s_stale_hdd_layout_present() { reset; layout /dev/sda; layout /dev/nvme0n1; run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called mkfs \
  && grep -q "also exists on /dev/sda" /fake/out.txt && grep -q 'uuid-nvme0n11' /etc/fstab && ! grep -q 'uuid-sda' /etc/fstab; }
s_unrecognised_refuses() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs && grep -q 'WIPE_DATA_DISK=1' /fake/out.txt; }
s_unrecognised_wipe() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && called "wipefs -a /dev/nvme0n1" && called "sfdisk /dev/nvme0n1" && ! called "sfdisk /dev/sda"; }
s_wipe_never_other_disk() { reset; echo '/dev/sda1|keep|uuid-h' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called "wipefs -a /dev/sda" && grep -q '/dev/sda1|keep' /fake/blkid.db; }
s_wipe1_keeps_own_layout() { reset; layout /dev/nvme0n1; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called wipefs && ! called mkfs && grep -q 'existing layout is kept' /fake/out.txt; }
s_wipe_force_rebuilds() { reset; layout /dev/nvme0n1; WIPE_DATA_DISK=force run; [[ "$(rc)" == 0 ]] && called "wipefs -a /dev/nvme0n1" && called "sfdisk /dev/nvme0n1" && called "mkfs.ext4 -q -L persistent /dev/nvme0n1p3"; }
s_wipe_value_validated() { reset; WIPE_DATA_DISK=yes run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs; }
s_wipe1_rerun_after_first_wipe() { reset; echo '/dev/nvme0n1p1|other|uuid-x' >>/fake/blkid.db; WIPE_DATA_DISK=1 run; : >/fake/calls.log; WIPE_DATA_DISK=1 run; [[ "$(rc)" == 0 ]] && ! called sfdisk && ! called wipefs; }
s_serial_absent() { reset; rm -f /fake/serials/nvme0n1; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called mkfs && ! called wipefs; }
s_serial_duplicate() { reset; echo "${DATA_S}" >/fake/serials/sda; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs; }
s_serial_is_root_disk() { reset; export DATA_DISK_SERIAL="${OS_S}"; run; [[ "$(rc)" != 0 ]] && ! called sfdisk && ! called wipefs && grep -q 'root disk' /fake/out.txt; }
s_serial_required() { reset; unset DATA_DISK_SERIAL; run; [[ "$(rc)" != 0 ]] && ! called sfdisk; }
s_serial_glob_rejected() { reset; export DATA_DISK_SERIAL='ExampleVendor_*'; run; [[ "$(rc)" != 0 ]] && ! called sfdisk; }
s_fstab_conflict() { reset; layout /dev/nvme0n1; echo 'UUID=some-other /var/lib/etcd ext4 noatime 0 2' >/etc/fstab; run; [[ "$(rc)" != 0 ]] && grep -q 'different source' /fake/out.txt; }
s_idempotent() { reset; run; cp /etc/fstab /fake/fstab1; : >/fake/calls.log; run; [[ "$(rc)" == 0 ]] && cmp -s /etc/fstab /fake/fstab1 && ! called sfdisk && ! called mkfs; }

for s in fresh reinstall stale_hdd_blank_data stale_hdd_layout_present unrecognised_refuses unrecognised_wipe wipe_never_other_disk \
         wipe1_keeps_own_layout wipe_force_rebuilds wipe_value_validated wipe1_rerun_after_first_wipe \
         serial_absent serial_duplicate serial_is_root_disk serial_required serial_glob_rejected fstab_conflict idempotent; do
  CUR="$s"; "s_${s}" && echo "RESULT ${s} PASS" || echo "RESULT ${s} FAIL"
done
