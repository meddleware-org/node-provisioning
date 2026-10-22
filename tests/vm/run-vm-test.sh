#!/usr/bin/env bash
# Manual VM test matrix for node-provisioning (NOT part of CI: needs KVM, OVMF, QEMU, xorriso and an Ubuntu Server ISO).
#
#   tests/vm/run-vm-test.sh <ubuntu-live-server.iso> [scenario ...]
#   scenarios: probe install setup scrub negative reinstall inspect   (default: all but inspect, in that order)
#
# The VM has two emulated NVMe disks (OS, data) and a third disk with stale labelled partitions (standing in for a disk
# left over from an earlier install). Everything lives in tests/vm/.work (git-ignored); an ephemeral SSH key is generated
# per run. Results are printed as "RESULT <name> PASS|FAIL" lines plus evidence files in the work directory.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="${VM_WORK:-${ROOT}/tests/vm/.work}"
ISO="${1:?usage: run-vm-test.sh <ubuntu-live-server.iso> [scenario ...]}"; shift
SCENARIOS=("$@"); [[ ${#SCENARIOS[@]} -gt 0 ]] || SCENARIOS=(probe install setup negative reinstall)
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
# Disk contents are compared semantically with `qemu-img compare` against a copy taken before the operation (the VM must be
# stopped). Never hash through `qemu-img convert ... -`: it writes a file named "-", not stdout.
disk_snapshot() { cp --sparse=always "$1" "$1.before"; }
disk_unchanged() { qemu-img compare "$1.before" "$1" >/dev/null 2>&1; }

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
run_installer() { # <seed-iso> <serial-log> [stop-regex]: returns when the installer stops, reboots (-no-reboot) or the pattern shows
  qemu_base
  local stop="${3:-}" pid
  : >"$2"
  timeout "${VM_INSTALL_TIMEOUT:-3000}" "${QEMU[@]}" -no-reboot -serial "file:$2" \
    -drive "file=${ISO},media=cdrom,readonly=on,id=iso" -drive "file=$1,media=cdrom,readonly=on,id=seed" \
    -kernel "${W}/vmlinuz" -initrd "${W}/initrd" -append "autoinstall ds=nocloud console=ttyS0 ---" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ -n "${stop}" ]] && grep -a -q -E "${stop}" "$2"; then sleep 5; kill "${pid}" 2>/dev/null; break; fi
    sleep 5
  done
  wait "${pid}" 2>/dev/null || true
}
boot_installed() { # background; waits for ssh
  qemu_base
  rm -f "${W}/qemu.pid"
  "${QEMU[@]}" -serial "file:${W}/boot-serial.log" -daemonize -pidfile "${W}/qemu.pid" >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 90); do vmssh true >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}
vmssh() { ssh -i "${W}/key" -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR nodeadmin@127.0.0.1 "$@"; }
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
      echo PROBE_DONE > /dev/ttyS0
      poweroff -f
UD
  printf 'instance-id: probe\nlocal-hostname: probe\n' >"${W}/probe/meta-data"
  xorrisofs -o "${W}/probe.iso" -V CIDATA -r -J "${W}/probe/user-data" "${W}/probe/meta-data" >/dev/null 2>&1
  run_installer "${W}/probe.iso" "${W}/probe-serial.log" "PROBE_DONE"
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
  disk_snapshot "${W}/data.qcow2"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/install-serial.log" "An error occurred. Press enter to start a shell"
  grep -a -q -E "Rebooting|reboot: Restarting|install.*complete" "${W}/install-serial.log"; result installer_completed $?
  ok_if data_disk_untouched_by_installer disk_unchanged "${W}/data.qcow2"
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
  ssh -p "${SSH_PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR nodeadmin@127.0.0.1 true >/dev/null 2>&1
  pw_rc=$?; eq password_ssh_refused "$([[ ${pw_rc} -ne 0 ]] && echo refused)" refused
  # The installer keeps a root-only copy of the seed's user-data. Any OTHER file holding the hash would be a leak.
  # (The pattern is split in the command line so that journald's record of this very command does not match it.)
  vmssh 'sudo stat -c "%a %U:%G" /var/log/installer/autoinstall-user-data' >"${W}/installer-copy-mode.txt" 2>&1
  eq installer_copy_of_user_data_is_root_only_0400 "$(cat "${W}/installer-copy-mode.txt")" "400 root:root"
  vmssh 'sudo grep -r -l -F "fixture""salt0000" /var/log /var/lib/cloud /etc/cloud /run /home /root /var/tmp --exclude-dir=journal 2>/dev/null' >"${W}/secret-files.txt" 2>&1
  eq no_other_file_holds_the_password_hash "$(grep -v '^/var/log/installer/autoinstall-user-data$' "${W}/secret-files.txt")" ""
  vmssh 'sudo cat /etc/netplan/10-vm.yaml' >"${W}/netplan.installed" 2>&1; grep -q '10.0.2.15/24' "${W}/netplan.installed"; result netplan_from_site_installed $?
  vmssh 'sudo stat -c %a /etc/netplan/10-vm.yaml' 2>/dev/null | grep -q '^600$'; result netplan_mode_600 $?
  vmssh 'sudo sed -n "/^127.0.0.1 motd/p" /etc/hosts' | grep -q motd.ubuntu.com; result telemetry_hosts_block $?
  stop_vm
}

s_negative() { # a seed whose OS serial matches no disk must abort BEFORE any disk is touched
  load_ids || return 1; new_disks; ensure_key; extract_boot_files
  stage_site "NoSuchDisk_000000" "${DATA_ID}"; build_seed
  disk_snapshot "${W}/os.qcow2"; disk_snapshot "${W}/data.qcow2"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/negative-serial.log" "aborting before any disk is touched"
  grep -a -q "found 0 and 1: aborting before any disk is touched" "${W}/negative-serial.log"; result guard_message_seen_missing_os_disk $?
  ok_if os_disk_identical_after_abort disk_unchanged "${W}/os.qcow2"
  ok_if data_disk_identical_after_abort disk_unchanged "${W}/data.qcow2"
}

s_reinstall() { # install, create data on the data disk with node-setup 00, reinstall the OS: the data must survive
  load_ids || return 1
  s_install >/dev/null 2>&1 || true
  boot_installed || { result reinstall_vm_boots 1; return 1; }
  rm -rf "${W}/np-tree"; mkdir -p "${W}/np-tree"; git -C "${ROOT}" archive --format=tar HEAD | tar -x -C "${W}/np-tree"
  tar -C "${W}/np-tree" -czf "${W}/np.tgz" .
  scp -q -i "${W}/key" -P "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${W}/np.tgz" nodenodeadmin@127.0.0.1:/tmp/np.tgz
  vmssh 'rm -rf /tmp/np && mkdir /tmp/np && tar -xzf /tmp/np.tgz -C /tmp/np'
  vmssh "sudo DATA_DISK_SERIAL='${DATA_ID}' ETCD_SIZE=1G LONGHORN_SIZE=2G bash /tmp/np/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh" >"${W}/data-disk-1.txt" 2>&1; result node_setup_00_first_run $?
  vmssh 'findmnt -n /var/lib/persistent && findmnt -n /var/lib/etcd'; result data_partitions_mounted $?
  vmssh "udevadm info --query=property --name=\$(findmnt -no SOURCE /var/lib/persistent | xargs lsblk -no PKNAME | sed 's#^#/dev/#') | grep -q '^ID_SERIAL=${DATA_ID}\$'"; result persistent_is_on_the_data_serial_disk $?
  grep -q "also exists on" "${W}/data-disk-1.txt"; result stale_labels_on_the_old_disk_reported $?
  vmssh 'findmnt -no SOURCE /var/lib/persistent' | grep -qv 'vda'; result persistent_is_not_the_stale_disk $?
  vmssh "echo precious | sudo tee /var/lib/persistent/MARKER >/dev/null"; vmssh 'sync'
  stop_vm
  # reinstall the OS onto the same disks
  disk_snapshot "${W}/data.qcow2"
  run_installer "${W}/seed/nocloud-seed.iso" "${W}/reinstall-serial.log" "An error occurred. Press enter to start a shell"
  ok_if data_disk_identical_after_os_reinstall disk_unchanged "${W}/data.qcow2"
  boot_installed || { result reinstall_vm_boots 1; return 1; }
  scp -q -i "${W}/key" -P "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${W}/np.tgz" nodenodeadmin@127.0.0.1:/tmp/np.tgz
  vmssh 'rm -rf /tmp/np && mkdir /tmp/np && tar -xzf /tmp/np.tgz -C /tmp/np'
  vmssh "sudo DATA_DISK_SERIAL='${DATA_ID}' bash /tmp/np/targets/ubuntu-server-26.04/node-setup/00-data-disk.sh" >"${W}/data-disk-2.txt" 2>&1; result node_setup_00_after_reinstall $?
  grep -q "Layout already present" "${W}/data-disk-2.txt"; result reinstall_recognises_the_layout_no_repartition $?
  eq data_survived_the_os_reinstall "$(vmssh 'cat /var/lib/persistent/MARKER')" precious
  stop_vm
}

stage_np() { # copy the working tree (without .git, caches, VM work) and the site (without the hash file) into the VM
  tar -C "${ROOT}" --exclude=.git --exclude=.cache --exclude=tests/vm/.work -czf "${W}/np.tgz" .
  tar -C "${W}/site" --exclude=hash -czf "${W}/site.tgz" .
  scp -q -i "${W}/key" -P "${SSH_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${W}/np.tgz" "${W}/site.tgz" nodeadmin@127.0.0.1:/tmp/
  vmssh 'rm -rf /tmp/np /tmp/site && mkdir /tmp/np /tmp/site && tar -xzf /tmp/np.tgz -C /tmp/np && tar -xzf /tmp/site.tgz -C /tmp/site'
}

s_setup() { # the real node setup (00-08) inside the installed VM; needs the internet through QEMU's NAT
  load_ids || return 1
  boot_installed || { result setup_vm_boots 1; return 1; }
  stage_np
  local NPCLI='sudo /tmp/np/bin/node-provisioning node-setup --site /tmp/site --node vm1'
  vmssh "${NPCLI} --step preflight" >"${W}/setup-preflight.txt" 2>&1; result preflight_passes $?
  grep -q "OS disk present" "${W}/setup-preflight.txt" && grep -q "data disk present" "${W}/setup-preflight.txt"; result preflight_found_both_disks_by_serial $?
  vmssh "${NPCLI} --step setup" >"${W}/setup-run.txt" 2>&1; result node_setup_completes $?
  vmssh 'true'; result ssh_still_works_after_hardening_and_firewall $?
  grep -q "also exists on /dev/vda" "${W}/setup-run.txt"; result stale_labels_on_the_old_disk_reported $?
  vmssh "for m in /var/lib/etcd /var/lib/longhorn-nvme /var/lib/persistent; do findmnt -no SOURCE \$m; done" >"${W}/mount-sources.txt" 2>&1
  eq three_data_partitions_mounted "$(grep -c '^/dev/nvme' "${W}/mount-sources.txt")" 3
  ! grep -q '/dev/vda' "${W}/mount-sources.txt"; result none_mounted_from_the_stale_disk $?
  vmssh "udevadm info --query=property --name=\$(findmnt -no SOURCE /var/lib/persistent | xargs lsblk -no PKNAME | sed 's#^#/dev/#') | grep -q '^ID_SERIAL=${DATA_ID}\$'"; result data_mounts_are_on_the_data_serial_disk $?
  vmssh 'grep -c "^UUID=" /etc/fstab' | grep -q '^3$'; result fstab_uses_three_uuid_entries $?
  vmssh 'sudo ufw status' >"${W}/ufw-status.txt" 2>&1; grep -q 'Status: active' "${W}/ufw-status.txt" && grep -q 'OpenSSH' "${W}/ufw-status.txt"; result firewall_active_with_ssh_allowed $?
  vmssh 'sudo sshd -T' >"${W}/sshd-T.txt" 2>&1
  grep -q '^passwordauthentication no' "${W}/sshd-T.txt" && grep -q '^permitrootlogin no' "${W}/sshd-T.txt" && grep -q '^allowtcpforwarding no' "${W}/sshd-T.txt" && grep -q '^authenticationmethods publickey' "${W}/sshd-T.txt"; result sshd_effective_config_is_hardened $?
  eq sysctl_kptr_restrict "$(vmssh 'sysctl -n kernel.kptr_restrict')" 2
  eq sysctl_ip_forward "$(vmssh 'sysctl -n net.ipv4.ip_forward')" 1
  vmssh 'systemctl is-active crio' | grep -q '^active$'; result crio_active $?
  vmssh 'kubeadm version -o short' | grep -q '^v1.36.3$'; result kubeadm_pinned_version $?
  vmssh 'apt-mark showhold' >"${W}/holds.txt" 2>&1; grep -q kubeadm "${W}/holds.txt" && grep -q cri-o "${W}/holds.txt"; result runtime_and_kube_packages_held $?
  vmssh 'test -f /etc/apt/apt.conf.d/52unattended-upgrades-local'; result unattended_upgrades_policy_installed $?
  eq no_swap_after_setup "$(vmssh 'swapon --show' 2>/dev/null)" ''
  eq installer_copy_redacted "$(vmssh 'sudo grep -c "<redacted>" /var/log/installer/autoinstall-user-data')" 1
  vmssh 'sudo grep -r -l -F "fixture""salt0000" /var/log /var/lib/cloud /etc/cloud /run /home /root /var/tmp --exclude-dir=journal 2>/dev/null' >"${W}/secret-files-after.txt" 2>&1
  eq no_file_holds_the_password_hash_after_setup "$(cat "${W}/secret-files-after.txt")" ""
  vmssh 'systemctl --failed --no-legend' >"${W}/failed-units.txt" 2>&1; say "failed units: $(wc -l <"${W}/failed-units.txt")"
  vmssh "echo precious | sudo tee /var/lib/persistent/MARKER >/dev/null; sync"
  # idempotence: a second run changes nothing destructive and succeeds
  vmssh "${NPCLI} --step setup" >"${W}/setup-run2.txt" 2>&1; result node_setup_is_idempotent $?
  grep -q "Layout already present" "${W}/setup-run2.txt"; result second_run_recognises_the_layout $?
  eq marker_survives_second_run "$(vmssh 'cat /var/lib/persistent/MARKER')" precious
  stop_vm
}

s_scrub() { # on the installed VM: preflight with the site's interface name, then the redaction of the installer's copy of the seed
  load_ids || return 1
  stage_site "${OS_ID}" "${DATA_ID}"
  boot_installed || { result scrub_vm_boots 1; return 1; }
  stage_np
  vmssh "sudo /tmp/np/bin/node-provisioning node-setup --site /tmp/site --node vm1 --step preflight" >"${W}/scrub-preflight.txt" 2>&1; result preflight_passes $?
  vmssh 'sudo grep -c -F "fixture""salt0000" /var/log/installer/autoinstall-user-data' >"${W}/scrub-before.txt" 2>&1
  say "hash lines in the installer copy before: $(tr -d '\n' <"${W}/scrub-before.txt")"
  vmssh 'sudo bash /tmp/np/targets/ubuntu-server-26.04/node-setup/08-hardening.sh' >"${W}/scrub-08.txt" 2>&1; result hardening_runs $?
  grep -q "credentials redacted in /var/log/installer/autoinstall-user-data" "${W}/scrub-08.txt" || grep -q "no credentials left" "${W}/scrub-08.txt"; result redaction_reported $?
  eq installer_copy_has_redacted_password "$(vmssh 'sudo grep -c "password: \"<redacted>\"" /var/log/installer/autoinstall-user-data')" 1
  vmssh 'sudo grep -r -l -F "fixture""salt0000" /var/log /var/lib/cloud /etc/cloud /run /home /root /var/tmp --exclude-dir=journal 2>/dev/null' >"${W}/scrub-files.txt" 2>&1
  eq no_file_holds_the_password_hash "$(cat "${W}/scrub-files.txt")" ""
  eq installer_copy_mode_kept "$(vmssh 'sudo stat -c "%a %U:%G" /var/log/installer/autoinstall-user-data')" "400 root:root"
  vmssh 'sudo bash /tmp/np/targets/ubuntu-server-26.04/node-setup/08-hardening.sh' >"${W}/scrub-08b.txt" 2>&1; grep -q "no credentials left" "${W}/scrub-08b.txt"; result second_run_finds_nothing_to_redact $?
  stop_vm
}

s_inspect() { # boot the installed system and run $VM_CMD (read-only investigation)
  boot_installed || { say "could not boot"; return 1; }
  vmssh "${VM_CMD:-uname -a}"
  stop_vm
}

for s in "${SCENARIOS[@]}"; do
  say "scenario: ${s}"
  "s_${s}" || say "scenario ${s} returned non-zero"
done
