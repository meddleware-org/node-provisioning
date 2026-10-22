#!/usr/bin/env bash
# late-commands must fail closed: no `set +e`, and every multi-line command starts with `set -eu`. The netplan
# command is also executed against a scratch root to prove a failing step aborts and a good run writes the files.
source "$(dirname "$0")/lib.sh"
mk_site "${T_TMP}/site"
"${CLI}" render --site "${T_TMP}/site" --node node1 --out "${T_TMP}/out" >/dev/null 2>&1
UD="${T_TMP}/out/user-data"

check "no 'set +e' anywhere" bash -c "! grep -q 'set +e' '${UD}'"
python3 - "${UD}" "${T_TMP}" <<'PYEND'
import sys,yaml
cmds=yaml.safe_load(open(sys.argv[1]))["autoinstall"]["late-commands"]
multi=[(i,c) for i,c in enumerate(cmds) if "\n" in c.strip()]
bad=[i for i,c in multi if not c.lstrip().startswith("set -eu")]
open(sys.argv[2]+"/multi.txt","w").write("%d %d\n" % (len(multi), len(bad)))
# the netplan command: the one that writes under /target/etc/netplan
for i,c in multi:
    if "/target/etc/netplan/" in c and "cat >" in c:
        open(sys.argv[2]+"/netplan.sh","w").write(c)
PYEND
read -r nmulti nbad <"${T_TMP}/multi.txt"
check "found multi-line late-commands (${nmulti})" test "${nmulti}" -ge 1
check "every multi-line late-command starts with set -eu" test "${nbad}" -eq 0
check "netplan command extracted" test -s "${T_TMP}/netplan.sh"

# Run the netplan command with /target redirected into a scratch directory (rewrite the path prefix only).
run_netplan() { # <target-dir>
  sed "s#/target/#$1/#g" "${T_TMP}/netplan.sh" >"${T_TMP}/np-run.sh"
  sh "${T_TMP}/np-run.sh" >/dev/null 2>&1
}
mkdir -p "${T_TMP}/t1/etc/netplan"
run_netplan "${T_TMP}/t1"
check "good run succeeds" test $? -eq 0
check "netplan file written with mode 600" test "$(stat -c %a "${T_TMP}/t1/etc/netplan/10-site.yaml" 2>/dev/null)" = 600
check "wait-online drop-in written" grep -q 'systemd-networkd-wait-online --interface=bond0.100' "${T_TMP}/t1/etc/systemd/system/systemd-networkd-wait-online.service.d/10-scope.conf"
# Failure: the target directory cannot be written -> the command must exit non-zero (it used to exit 0)
mkdir -p "${T_TMP}/t2"; chmod 500 "${T_TMP}/t2"
if [[ "$(id -u)" -ne 0 ]]; then
  run_netplan "${T_TMP}/t2"; rc=$?
  chmod 700 "${T_TMP}/t2"
  check "a failing write aborts (non-zero exit)" test "${rc}" -ne 0
else
  echo "  skip a failing write aborts (running as root: permissions do not apply)"
fi
finish
