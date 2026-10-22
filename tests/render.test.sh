#!/usr/bin/env bash
# Golden render of the example site (fixture secrets) with and without an Ubuntu Pro token, plus
# structural expectations that must hold for any site.
source "$(dirname "$0")/lib.sh"
FAKE_TOKEN=C1111111111111111111111111
G="${ROOT}/tests/golden"
mk_site "${T_TMP}/site"

render_to() { "${CLI}" render --site "${T_TMP}/site" --node node1 --out "$1" >/dev/null 2>&1; }

mkdir -p "${T_TMP}/a" "${T_TMP}/b"
render_to "${T_TMP}/a"
UBUNTU_PRO_TOKEN="${FAKE_TOKEN}" INSTANCE_ID=node1-test render_to "${T_TMP}/b"

if [[ "${UPDATE_GOLDEN:-0}" == 1 ]]; then
  mkdir -p "${G}"
  cp "${T_TMP}/a/user-data" "${G}/user-data.no-pro"
  cp "${T_TMP}/b/user-data" "${G}/user-data.pro"
  cp "${T_TMP}/a/meta-data" "${G}/meta-data"
  echo "  (golden files updated)"
fi

check "golden user-data without a token"  cmp -s "${T_TMP}/a/user-data" "${G}/user-data.no-pro"
check "golden user-data with a token"     cmp -s "${T_TMP}/b/user-data" "${G}/user-data.pro"
check "golden meta-data"                  cmp -s "${T_TMP}/a/meta-data" "${G}/meta-data"
check "rendering twice is byte-identical" bash -c "$(declare -f render_to); T_TMP='${T_TMP}'; CLI='${CLI}'; mkdir -p '${T_TMP}/c'; render_to '${T_TMP}/c'; cmp -s '${T_TMP}/a/user-data' '${T_TMP}/c/user-data'"
check "no token: Pro block removed"       bash -c "! grep -q 'ubuntu-pro:' '${T_TMP}/a/user-data'"
check "token: Pro block present"          grep -q '^  ubuntu-pro:' "${T_TMP}/b/user-data"
check "token appears in the token build"  grep -q "token: \"${FAKE_TOKEN}\"" "${T_TMP}/b/user-data"
check "token appears exactly once (never in comments)" test "$(grep -c "${FAKE_TOKEN}" "${T_TMP}/b/user-data")" = 1
check "token absent from the no-token build" bash -c "! grep -q '${FAKE_TOKEN}' '${T_TMP}/a/user-data'"
check "user-data is mode 0600"            test "$(stat -c %a "${T_TMP}/a/user-data")" = 600
check "meta-data is mode 0600"            test "$(stat -c %a "${T_TMP}/a/meta-data")" = 600
check "no unreplaced markers"             bash -c "! grep -q '@@' '${T_TMP}/a/user-data'"
check "instance id derives from hostname and content" grep -Eq '^instance-id: node1-[0-9a-f]{12}$' "${T_TMP}/a/meta-data"
check "INSTANCE_ID override is honoured"  grep -q '^instance-id: node1-test$' "${T_TMP}/b/meta-data"
check "installer network fragment embedded" grep -q '^      enp1s0.100:' "${T_TMP}/a/user-data"
check "netplan fragment embedded in heredoc" grep -q '^          bond0:' "${T_TMP}/a/user-data"
check "wait-online interface rendered"    grep -q 'systemd-networkd-wait-online --interface=bond0.100$' "${T_TMP}/a/user-data"
finish
