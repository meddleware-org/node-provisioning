#!/usr/bin/env bash
# The early-commands identity guard: extracted from a rendered user-data, run under dash with a fake /sys/block
# and a stub udevadm. It must pass only when exactly one disk carries each serial.
source "$(dirname "$0")/lib.sh"
mk_site "${T_TMP}/site"
OS_S=ExampleVendor_OsDisk_EX0000000001; DATA_S=ExampleVendor_DataDisk_EX0000000002
"${CLI}" render --site "${T_TMP}/site" --node node1 --out "${T_TMP}/out" >/dev/null 2>&1
python3 - "${T_TMP}/out/user-data" "${T_TMP}/guard.sh" <<'PY'
import sys,yaml
doc=yaml.safe_load(open(sys.argv[1]))["autoinstall"]
open(sys.argv[2],"w").write(doc["early-commands"][0])
PY
check "guard extracted from user-data" test -s "${T_TMP}/guard.sh"
SH="sh"; if command -v dash >/dev/null; then SH="dash"; fi
check "guard is valid POSIX sh (${SH} -n)" ${SH} -n "${T_TMP}/guard.sh"
check "guard uses no bashisms" bash -c "! grep -n -E '\[\[|\]\]|<<<|\\$\\{[a-z_]+//|local ' '${T_TMP}/guard.sh'"

# fake /sys/block + stub udevadm: serials come from files next to the stub
mkdir -p "${T_TMP}/bin" "${T_TMP}/sys"
cat >"${T_TMP}/bin/udevadm" <<'STUB'
#!/bin/sh
# usage: udevadm info --query=property --name=/dev/NAME
name="${3#--name=/dev/}"
f="$NP_SERIALS/$name"
[ -f "$f" ] && echo "ID_SERIAL=$(cat "$f")"
exit 0
STUB
chmod +x "${T_TMP}/bin/udevadm"
run_guard() { # serial-per-device args: name=serial ...
  rm -rf -- "${T_TMP}/sys" "${T_TMP}/serials"; mkdir -p "${T_TMP}/sys" "${T_TMP}/serials"
  local kv
  for kv in "$@"; do mkdir -p "${T_TMP}/sys/${kv%%=*}"; [[ "${kv#*=}" != "" ]] && printf '%s' "${kv#*=}" >"${T_TMP}/serials/${kv%%=*}"; done
  PATH="${T_TMP}/bin:${PATH}" NP_SYS_BLOCK="${T_TMP}/sys" NP_SERIALS="${T_TMP}/serials" ${SH} "${T_TMP}/guard.sh" >/dev/null 2>"${T_TMP}/guard.err"
}
check "passes: one OS disk, one data disk"         run_guard nvme0n1="${OS_S}" nvme1n1="${DATA_S}" sda=OtherDisk_1
check "passes regardless of device names"          run_guard sdz="${DATA_S}" nvme9n1="${OS_S}"
run_guard nvme1n1="${DATA_S}"; [[ $? -ne 0 ]] && ok "aborts: OS disk missing" || bad "aborts: OS disk missing"
run_guard nvme0n1="${OS_S}";   [[ $? -ne 0 ]] && ok "aborts: data disk missing" || bad "aborts: data disk missing"
run_guard nvme0n1="${OS_S}" sda="${OS_S}" nvme1n1="${DATA_S}"; [[ $? -ne 0 ]] && ok "aborts: two disks carry the OS serial" || bad "aborts: two disks carry the OS serial"
run_guard nvme0n1="${OS_S}" nvme1n1="${DATA_S}" sdb="${DATA_S}"; [[ $? -ne 0 ]] && ok "aborts: two disks carry the data serial" || bad "aborts: two disks carry the data serial"
run_guard nvme0n1="${OS_S}x" nvme1n1="${DATA_S}"; [[ $? -ne 0 ]] && ok "aborts: near-miss serial does not match" || bad "aborts: near-miss serial does not match"
run_guard; [[ $? -ne 0 ]] && ok "aborts: no disks at all" || bad "aborts: no disks at all"
run_guard nvme0n1="${OS_S}" nvme1n1="${DATA_S}" loop0="${OS_S}"; [[ $? -eq 0 ]] && ok "loop devices are ignored" || bad "loop devices are ignored"
run_guard nvme1n1="${DATA_S}" || true
check "abort message names the counts, not the serials" bash -c "grep -q 'found' '${T_TMP}/guard.err' && ! grep -q '${OS_S}' '${T_TMP}/guard.err'"
finish
