#!/usr/bin/env bash
# The validator rejects unsafe documents even if a template were edited to produce them.
source "$(dirname "$0")/lib.sh"
mk_site "${T_TMP}/s"; mkdir -p "${T_TMP}/v"
"${CLI}" render --site "${T_TMP}/s" --node node1 --out "${T_TMP}/v" >/dev/null 2>&1
cat >"${T_TMP}/mutate.py" <<'PY2'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
a = doc["autoinstall"]
exec(sys.argv[3])
open(sys.argv[2], "w").write("#cloud-config\n" + yaml.safe_dump(doc))
PY2
mutate() { # name python-statements
  rm -f -- "${T_TMP}/v/mut"
  python3 "${T_TMP}/mutate.py" "${T_TMP}/v/user-data" "${T_TMP}/v/mut" "$2"
  if [[ ! -s "${T_TMP}/v/mut" ]]; then bad "validator rejects: $1 (the mutated document was not produced)"; return; fi
  if python3 "${ROOT}/lib/validate.py" user-data "${T_TMP}/v/mut" >/dev/null 2>&1; then bad "validator rejects: $1"; else ok "validator rejects: $1"; fi
}
check "validator accepts the unmodified document" python3 "${ROOT}/lib/validate.py" user-data "${T_TMP}/v/user-data"
mutate "disk selected by path"         'a["storage"]["config"][0]["path"]="/dev/nvme0n1"; a["storage"]["config"][0].pop("match")'
mutate "glob in match.serial"          'a["storage"]["config"][0]["match"]["serial"]="Vendor_*"'
mutate "swap partition reintroduced"   'a["storage"]["config"].append({"type":"format","id":"x-swap-fs","fstype":"swap"})'
mutate "swap size not zero"            'a["storage"]["swap"]["size"]=4'
mutate "identity guard removed"        'a.pop("early-commands")'
mutate "timezone removed"              'a.pop("timezone")'
finish
