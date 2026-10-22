#!/usr/bin/env bash
# run.sh: the order of the numbered scripts and which failures are fatal (00-04) versus reported (05-07).
source "$(dirname "$0")/lib.sh"
RUN="${ROOT}/targets/ubuntu-server-26.04/node-setup/run.sh"
D="${T_TMP}/ns"; mkdir -p "${D}/bin"
cp "${RUN}" "${D}/run.sh"
for s in 00-data-disk 01-preflight 02-kernel 03-crio 04-kubetools 05-ufw 06-telemetry 07-ubuntu-pro 08-hardening; do
  cat >"${D}/${s}.sh" <<STUB
#!/usr/bin/env bash
echo "${s}" >>"\${ORDER_LOG}"
[[ "\${FAIL_STEP:-}" == "${s}" ]] && exit 1
exit 0
STUB
done
for c in apt-get systemctl kubeadm sleep; do printf '#!/bin/sh\nexit 0\n' >"${D}/bin/${c}"; chmod +x "${D}/bin/${c}"; done
# the runner insists on root; run it through unshare when we are not root, else directly
runner() { # args: step ; env FAIL_STEP
  ORDER_LOG="${T_TMP}/order.log" PATH="${D}/bin:${PATH}" "$@"
}
if [[ "$(id -u)" -ne 0 ]]; then
  # The root check is the first statement after the helper definitions; neutralise it in the COPY under test only.
  sed -i 's/^\[\[ \$EUID -eq 0 \]\].*$/true/' "${D}/run.sh"
fi
run_setup() { : >"${T_TMP}/order.log"; export ORDER_LOG="${T_TMP}/order.log"; PATH="${D}/bin:${PATH}" bash "${D}/run.sh" "${1:-setup}" >/dev/null 2>&1; }

FAIL_STEP="" run_setup setup
check "setup order is 00,02,03,04,05,06,07,08" test "$(tr '\n' ' ' <"${T_TMP}/order.log")" = "00-data-disk 02-kernel 03-crio 04-kubetools 05-ufw 06-telemetry 07-ubuntu-pro 08-hardening "
FAIL_STEP="" run_setup preflight
check "preflight runs only 01" test "$(tr '\n' ' ' <"${T_TMP}/order.log")" = "01-preflight "
for s in 00-data-disk 02-kernel 03-crio 04-kubetools 05-ufw 08-hardening; do
  FAIL_STEP="${s}" run_setup setup; rc=$?
  check "${s} failure is fatal: it is the last script run" bash -c "[[ ${rc} -ne 0 && \"\$(tail -1 '${T_TMP}/order.log')\" == '${s}' ]]"
done
for s in 06-telemetry 07-ubuntu-pro; do
  FAIL_STEP="${s}" run_setup setup; rc=$?
  check "${s} failure is reported and the run continues" bash -c "[[ ${rc} -eq 0 ]] && grep -q '08-hardening' '${T_TMP}/order.log'"
done
FAIL_STEP="01-preflight" run_setup all; rc=$?
check "failing preflight stops 'all' before setup" bash -c "[[ ${rc} -ne 0 ]] && ! grep -q '00-data-disk' '${T_TMP}/order.log'"
finish
