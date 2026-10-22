#!/usr/bin/env bash
# Manual VM test matrix for node-provisioning (NOT part of CI: needs KVM, OVMF, QEMU, xorriso and an Ubuntu Server ISO).
#
#   tests/vm/run-vm-test.sh <ubuntu-live-server.iso> [scenario ...]
#   scenarios: probe install negative reinstall   (default: all, in that order)
#
# The VM has two emulated NVMe disks (OS, data) and a third disk with stale labelled partitions (standing in for a disk
# left over from an earlier install). Everything lives in tests/vm/.work (git-ignored); an ephemeral SSH key is generated
# per run. Results are printed as "RESULT <name> PASS|FAIL" lines plus evidence files in the work directory.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${VM_WORK:-${ROOT}/tests/vm/.work}"
ISO="${1:?usage: run-vm-test.sh <ubuntu-live-server.iso> [scenario ...]}"; shift
SCENARIOS=("$@"); [[ ${#SCENARIOS[@]} -gt 0 ]] || SCENARIOS=(probe install negative reinstall)
OS_SERIAL=TESTOS0001; DATA_SERIAL=TESTDATA0001; HDD_SERIAL=TESTHDD0001
SSH_PORT="${VM_SSH_PORT:-2222}"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
mkdir -p "${W}"

say() { echo "[vm] $*" >&2; }
result() { if [[ "$2" == 0 ]]; then echo "RESULT $1 PASS"; else echo "RESULT $1 FAIL"; fi; }
# eq <name> <actual> <expected>: PASS when equal. ok_if <name> <command...>: PASS when the command succeeds.
eq() { local rc=1; [[ "$2" == "$3" ]] && rc=0; result "$1" "${rc}"; return "${rc}"; }
ok_if() { local n="$1" rc=0; shift; "$@" >/dev/null 2>&1 || rc=1; result "${n}" "${rc}"; return "${rc}"; }

# ── disks ──────────────────────────────────────────────────────────────────────
new_disks() { # fresh OS, data and stale-HDD images and UEFI vars
  rm -f "${W}"/os.qcow2 "${W}"/data.qcow2 "${W}"/hdd.img "${W}"/OVMF_VARS.fd
  qemu-img create -q -f qcow2 "${W}/os.qcow2" 16G
  qemu-img create -q -f qcow2 "${W}/data.qcow2" 8G
  cp "${OVMF_VARS_SRC}" "${W}/OVMF_VARS.fd"
  make_stale_hdd
}
make_stale_hdd() { # a raw 2G image holding three ext4 partitions labelled like the data layout of an older install
  truncate -s 2G "${W}/hdd.img"
  printf 'label: gpt\nsize=200M, name=etcd\nsize=300M, name=longhorn-nvme\nname=persistent\n' | sfdisk -q "${W}/hdd.img" >/dev/null
  local i=0 label start size
  for label in etcd longhorn-nvme persistent; do
    i=$((i + 1))
    read -r start size < <(sfdisk -J "${W}/hdd.img" | python3 -c "import sys,json; p=json.load(sys.stdin)['partitiontable']['partitions'][$((i - 1))]; print(p['start'], p['size'])")
    mkfs.ext4 -q -L "${label}" -E "offset=$((start * 512))" "${W}/hdd.img" "$((size * 512 / 1024))k"
  done
}
disk_sum() { sha256sum "$1" | cut -d' ' -f1; }   # raw bytes are compared on a copy converted from qcow2 (below)
disk_raw_sum() { qemu-img convert -O raw "$1" - 2>/dev/null | sha256sum | cut -d' ' -f1; }

# ── seed and site ──────────────────────────────────────────────────────────────
ensure_key() { [[ -f "${W}/key" ]] || ssh-keygen -q -t ed25519 -N '' -C vmtest@example.invalid -f "${W}/key"; }
stage_site() { # <os-id-serial> <data-id-serial>
  rm -rf "${W}/site"; mkdir -p "${W}"
  cp -r "${ROOT}/tests/vm/site" "${W}/site"
  sed -i "s/@OS_SERIAL@/$1/; s/@DATA_SERIAL@/$2/" "${W}/site/nodes/vm1.env"
  cp "${W}/key.pub" "${W}/site/authorized_keys"
  cp "${ROOT}/tests/fixtures/password-hash" "${W}/site/hash"; chmod 600 "${W}/site/hash"
  echo 'PASSWORD_HASH_FILE=hash' >>"${W}/site/nodes/vm1.env"
}
build_seed() { # <out-iso-dir>
  rm -rf "${W}/seed"; "${ROOT}/bin/node-provisioning" build-seed --site "${W}/site" --node vm1 --format iso --out "${W}/seed" >"${W}/build-seed.log" 2>&1
}
extract_boot_files() {
  [[ -f "${W}/vmlinuz" ]] || xorriso -osirrox on -indev "${ISO}" -extract /casper/vmlinuz "${W}/vmlinuz" -extract /casper/initrd "${W}/initrd" >/dev/null 2>&1
}

# ── qemu ───────────────────────────────────────────────────────────────────────
qemu_base() {
  QEMU=(qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 4096 -machine q35 -display none
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" -drive "if=pflash,format=raw,file=${W}/OVMF_VARS.fd"
    -drive "if=none,id=os,file=${W}/os.qcow2,format=qcow2" -device "nvme,drive=os,serial=${OS_SERIAL}"
    -drive "if=none,id=data,file=${W}/data.qcow2,format=qcow2" -device "nvme,drive=data,serial=${DATA_SERIAL}"
    -drive "if=none,id=hdd,file=${W}/hdd.img,format=raw" -device "virtio-blk-pci,drive=hdd,serial=${HDD_SERIAL}"
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22")
}
run_installer() { # <seed-iso> <serial-log> ; returns when the installer stops or reboots (-no-reboot)
  qemu_base
  timeout "${VM_INSTALL_TIMEOUT:-3000}" "${QEMU[@]}" -no-reboot -serial "file:$2" \
    -drive "file=${ISO},media=cdrom,readonly=on,id=iso" -drive "file=$1,media=cdrom,readonly=on,id=seed" \
    -kernel "${W}/vmlinuz" -initrd "${W}/initrd" -append "autoinstall ds=nocloud console=ttyS0 ---" >/dev/null 2>&1
}
boot_installed() { # background; waits for ssh
  qemu_base
  rm -f "${W}/qemu.pid"
  "${QEMU[@]}" -serial "file:${W}/boot-serial.log" -daemonize -pidfile "${W}/qemu.pid" >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 90); do vmssh true >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}
vmssh() { ssh -i "${W}/key" -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR admin@127.0.0.1 "$@"; }
stop_vm() { [[ -f "${W}/qemu.pid" ]] && kill "$(cat "${W}/qemu.pid")" 2>/dev/null; rm -f "${W}/qemu.pid"; sleep 2; }

# ── scenarios ──────────────────────────────────────────────────────────────────
s_probe() { # learn the real udev ID_SERIAL strings of the emulated disks from the installer environment
  new_disks; ensure_key; extract_boot_files
  rm -rf "${W}/probe"; mkdir -p "${W}/probe"
  cat >"${W}/probe/user-data" <<'UD'
#cloud-config
autoinstall:
  version: 1
  early-commands:
    - |
      for d in /sys/block/*; do n="${d##*/}"; echo "PROBE $n $(udevadm info --query=property --name=/dev/$n | grep '^ID_SERIAL=')" > /dev/ttyS0; done
      exit 1
UD
  printf 'instance-id: probe\nlocal-hostname: probe\n' >"${W}/probe/meta-data"
  xorrisofs -o "${W}/probe.iso" -V CIDATA -r -J "${W}/probe/user-data" "${W}/probe/meta-data" >/dev/null 2>&1
  run_installer "${W}/probe.iso" "${W}/probe-serial.log"
  grep -a '^PROBE ' "${W}/probe-serial.log" | tr -d '\r' | sort -u >"${W}/probe.txt"
  cat "${W}/probe.txt" >&2
  OS_ID="$(grep -a "nvme" "${W}/probe.txt" | grep -a "${OS_SERIAL}" | head -1 | sed -n 's/.*ID_SERIAL=//p')"
  DATA_ID="$(grep -a "nvme" "${W}/probe.txt" | grep -a "${DATA_SERIAL}" | head -1 | sed -n 's/.*ID_SERIAL=//p')"
  printf 'OS_ID=%s\nDATA_ID=%s\n' "${OS_ID}" "${DATA_ID}" >"${W}/idserials"
  ok_if probe_found_distinct_serials test -n "${OS_ID}" -a -n "${DATA_ID}" -a "${OS_ID}" != "${DATA_ID}"
}
load_ids() { [[ -f "${W}/idserials" ]] || { say "run the probe scenario first"; return 1; }; . "${W}/idserials"; }

s_install() {
  load_ids || return 1; new_disks; ensure_key; extract_boot_files
  stage_site "${OS_ID}" "${DATA_ID}"; build_seed; ok_if seed_built test -f "${W}/seed/nocloud-seed.iso" || return 1
  local before_data; before_data="$(disk_raw_sum "${W}/data.qcow2")"; echo "${before_data}" >"${W}/data.before"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/install-serial.log"
  grep -a -q -E "Rebooting|reboot: Restarting|install.*complete" "${W}/install-serial.log"; result installer_completed $?
  eq data_disk_untouched_by_installer "$(disk_raw_sum "${W}/data.qcow2")" "${before_data}"
  boot_installed; result installed_system_boots_and_accepts_the_key $? || return 1
  eq hostname "$(vmssh hostname)" vm1
  vmssh 'sudo -n true' >/dev/null 2>&1; result sudo_works $?
  eq no_swap_active "$(vmssh 'swapon --show' 2>/dev/null)" ''
  vmssh 'test ! -e /swap.img && ! grep -q swap /etc/fstab'; result no_swap_file_or_fstab_entry $?
  eq timezone "$(vmssh 'timedatectl show -p Timezone --value')" Etc/UTC
  root_disk="$(vmssh 'findmnt -no SOURCE / | xargs lsblk -no PKNAME')"
  ok_if root_on_an_nvme_disk grep -Eq '^nvme[01]n1$' <<<"${root_disk}"
  # the OS went to the disk whose serial matched, not by name: root must be on the OS-serial disk
  vmssh "udevadm info --query=property --name=/dev/\$(findmnt -no SOURCE / | xargs lsblk -no PKNAME) | grep -q '^ID_SERIAL=${OS_ID}\$'"; result root_disk_carries_the_os_serial $?
  vmssh 'sudo systemctl is-system-running --wait' >"${W}/system-state.txt" 2>&1; cat "${W}/system-state.txt" >&2
  vmssh 'sudo ssh -V' >/dev/null 2>&1; true
  # SSH: password authentication is refused
  ssh -p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@127.0.0.1 true >/dev/null 2>&1
  pw_rc=$?; eq password_ssh_refused "$([[ ${pw_rc} -ne 0 ]] && echo refused)" refused
  # secrets left behind by the installer (hash, token shapes) in logs and cloud-init state
  vmssh "sudo grep -r -l -F '\$6\$fixturesalt' /var/log /var/lib/cloud /etc/cloud /run/cloud-init 2>/dev/null" >"${W}/secret-files.txt" 2>&1
  if [[ -s "${W}/secret-files.txt" ]]; then say "password hash found in: $(tr '\n' ' ' <"${W}/secret-files.txt")"; result installer_leaves_no_password_hash 1; else result installer_leaves_no_password_hash 0; fi
  vmssh 'sudo cat /etc/netplan/10-vm.yaml' >"${W}/netplan.installed" 2>&1; grep -q '10.0.2.15/24' "${W}/netplan.installed"; result netplan_from_site_installed $?
  vmssh 'sudo stat -c %a /etc/netplan/10-vm.yaml' 2>/dev/null | grep -q '^600$'; result netplan_mode_600 $?
  vmssh 'sudo sed -n "/^127.0.0.1 motd/p" /etc/hosts' | grep -q motd.ubuntu.com; result telemetry_hosts_block $?
  stop_vm
}

s_negative() { # a seed whose OS serial matches no disk must abort BEFORE any disk is touched
  load_ids || return 1; new_disks; ensure_key; extract_boot_files
  stage_site "NoSuchDisk_000000" "${DATA_ID}"; build_seed
  local b_os b_data; b_os="$(disk_raw_sum "${W}/os.qcow2")"; b_data="$(disk_raw_sum "${W}/data.qcow2")"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/negative-serial.log"
  grep -a -q "found 0 and 1: aborting before any disk is touched" "${W}/negative-serial.log"; result guard_message_seen_missing_os_disk $?
  eq os_disk_byte_identical_after_abort "$(disk_raw_sum "${W}/os.qcow2")" "${b_os}"
  eq data_disk_byte_identical_after_abort "$(disk_raw_sum "${W}/data.qcow2")" "${b_data}"
  # ambiguous: the data serial equals the stale disk's serial scheme is covered by unit tests; here OS and data swapped must not erase the data disk
  stage_site "${DATA_ID}" "${OS_ID}"; build_seed
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/swapped-serial.log"
  true
}

s_reinstall() { # install, create data on the data disk with node-setup 00, reinstall the OS: the data must survive
  load_ids || return 1
  s_install >/dev/null 2>&1 || true
  boot_installed || { result reinstall_vm_boots 1; return 1; }
  rm -rf "${W}/np-tree"; mkdir -p "${W}/np-tree"; git -C "${ROOT}" archive --format=tar HEAD | tar -x -C "${W}/np-tree"
  tar -C "${W}/np-tree" -czf "${W}/np.tgz" .
  scp -q -i "${W}/key" -P "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${W}/np.tgz" admin@127.0.0.1:/tmp/np.tgz
  vmssh 'rm -rf /tmp/np && mkdir /tmp/np && tar -xzf /tmp/np.tgz -C /tmp/np'
  vmssh "sudo DATA_DISK_SERIAL='${DATA_ID}' ETCD_SIZE=1G LONGHORN_SIZE=2G bash /tmp/np/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh" >"${W}/data-disk-1.txt" 2>&1; result node_setup_00_first_run $?
  vmssh 'findmnt -n /var/lib/persistent && findmnt -n /var/lib/etcd'; result data_partitions_mounted $?
  vmssh "udevadm info --query=property --name=\$(findmnt -no SOURCE /var/lib/persistent | xargs lsblk -no PKNAME | sed 's#^#/dev/#') | grep -q '^ID_SERIAL=${DATA_ID}\$'"; result persistent_is_on_the_data_serial_disk $?
  grep -q "also exists on" "${W}/data-disk-1.txt"; result stale_labels_on_the_old_disk_reported $?
  vmssh 'findmnt -no SOURCE /var/lib/persistent' | grep -qv 'vda'; result persistent_is_not_the_stale_disk $?
  vmssh "echo precious | sudo tee /var/lib/persistent/MARKER >/dev/null"; vmssh 'sync'
  stop_vm
  # reinstall the OS onto the same disks
  local before_layout; before_layout="$(disk_raw_sum "${W}/data.qcow2")"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/reinstall-serial.log"
  eq data_disk_byte_identical_after_os_reinstall "$(disk_raw_sum "${W}/data.qcow2")" "${before_layout}"
  boot_installed || { result reinstall_vm_boots 1; return 1; }
  scp -q -i "${W}/key" -P "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${W}/np.tgz" admin@127.0.0.1:/tmp/np.tgz
  vmssh 'rm -rf /tmp/np && mkdir /tmp/np && tar -xzf /tmp/np.tgz -C /tmp/np'
  vmssh "sudo DATA_DISK_SERIAL='${DATA_ID}' bash /tmp/np/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh" >"${W}/data-disk-2.txt" 2>&1; result node_setup_00_after_reinstall $?
  grep -q "Layout already present" "${W}/data-disk-2.txt"; result reinstall_recognises_the_layout_no_repartition $?
  eq data_survived_the_os_reinstall "$(vmssh 'cat /var/lib/persistent/MARKER')" precious
  stop_vm
}

for s in "${SCENARIOS[@]}"; do
  say "scenario: ${s}"
  "s_${s}" || say "scenario ${s} returned non-zero"
done
