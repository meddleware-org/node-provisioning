#!/usr/bin/env bash
# Image builds are byte-reproducible: the same inputs give the same bytes, regardless of wall-clock time,
# time zone or build directory; a different SOURCE_DATE_EPOCH (beyond FAT's 2 s resolution) gives a different image.
source "$(dirname "$0")/lib.sh"
mk_site "${T_TMP}/site"
build() { # <outdir> <format> [env assignments...]
  local out="$1" fmt="$2"; shift 2
  env "$@" "${CLI}" build-seed --site "${T_TMP}/site" --node node1 --format "${fmt}" --out "${out}" >/dev/null 2>&1
}
for fmt in iso img floppy; do
  case "${fmt}" in iso) f=nocloud-seed.iso;; img) f=nocloud-seed.img;; floppy) f=nocloud-seed-floppy.img;; esac
  build "${T_TMP}/a" "${fmt}" SOURCE_DATE_EPOCH=1767225600 TZ=UTC
  sleep 2
  build "${T_TMP}/b" "${fmt}" SOURCE_DATE_EPOCH=1767225600 TZ=Asia/Tokyo
  check "${fmt}: identical bytes across time, time zone and output directory" cmp -s "${T_TMP}/a/${f}" "${T_TMP}/b/${f}"
  build "${T_TMP}/c" "${fmt}" SOURCE_DATE_EPOCH=1767225604
  check "${fmt}: a different SOURCE_DATE_EPOCH changes the image" bash -c "! cmp -s '${T_TMP}/a/${f}' '${T_TMP}/c/${f}'"
  check "${fmt}: output mode is 0600" test "$(stat -c %a "${T_TMP}/a/${f}")" = 600
done
# default epoch (VERSION mtime) is stable between two builds
build "${T_TMP}/d" iso; sleep 2; build "${T_TMP}/e" iso
check "default epoch is stable" cmp -s "${T_TMP}/d/nocloud-seed.iso" "${T_TMP}/e/nocloud-seed.iso"
run_cli build-seed --site "${T_TMP}/site" --node node1 --format iso --out "${T_TMP}/f"
SOURCE_DATE_EPOCH=abc run_cli build-seed --site "${T_TMP}/site" --node node1 --format iso --out "${T_TMP}/f"
check "non-numeric SOURCE_DATE_EPOCH is rejected" test "${RC}" -ne 0
finish
