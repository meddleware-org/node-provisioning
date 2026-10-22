#!/usr/bin/env bash
# Builds all three image formats from the example site and checks label, size, mode and contents.
source "$(dirname "$0")/lib.sh"
mk_site "${T_TMP}/site"
mkdir -p "${T_TMP}/ref" "${T_TMP}/out"
"${CLI}" render --site "${T_TMP}/site" --node node1 --out "${T_TMP}/ref" >/dev/null 2>&1

for fmt in iso img floppy; do
  run_cli build-seed --site "${T_TMP}/site" --node node1 --format "${fmt}" --out "${T_TMP}/out"
  check "build-seed ${fmt} succeeds" test "${RC}" -eq 0
done
check "iso exists, mode 0600"    test "$(stat -c %a "${T_TMP}/out/nocloud-seed.iso")" = 600
check "img is 4 MiB"             test "$(stat -c %s "${T_TMP}/out/nocloud-seed.img")" = 4194304
check "floppy is exactly 1.44 MB" test "$(stat -c %s "${T_TMP}/out/nocloud-seed-floppy.img")" = 1474560
check "img mode 0600"            test "$(stat -c %a "${T_TMP}/out/nocloud-seed.img")" = 600
check "floppy mode 0600"         test "$(stat -c %a "${T_TMP}/out/nocloud-seed-floppy.img")" = 600

check "iso volume label is CIDATA" bash -c "xorriso -indev '${T_TMP}/out/nocloud-seed.iso' -pvd_info 2>&1 | grep -q 'Volume Id    : CIDATA'"
for img in nocloud-seed.img nocloud-seed-floppy.img; do
  check "${img} label is CIDATA" bash -c "MTOOLS_SKIP_CHECK=1 mlabel -i '${T_TMP}/out/${img}' -s :: 2>&1 | grep -q 'CIDATA'"
done
check "floppy is FAT12" bash -c "file -b '${T_TMP}/out/nocloud-seed-floppy.img' | grep -q 'FAT (12 bit)'"

mkdir -p "${T_TMP}/x/iso" "${T_TMP}/x/img" "${T_TMP}/x/fl"
xorriso -osirrox on -indev "${T_TMP}/out/nocloud-seed.iso" -extract / "${T_TMP}/x/iso" >/dev/null 2>&1
MTOOLS_SKIP_CHECK=1 mcopy -n -i "${T_TMP}/out/nocloud-seed.img" ::user-data ::meta-data "${T_TMP}/x/img/"
MTOOLS_SKIP_CHECK=1 mcopy -n -i "${T_TMP}/out/nocloud-seed-floppy.img" ::user-data ::meta-data "${T_TMP}/x/fl/"
for d in iso img fl; do
  check "${d}: user-data equals the rendered file" cmp -s "${T_TMP}/x/${d}/user-data" "${T_TMP}/ref/user-data"
  check "${d}: meta-data equals the rendered file" cmp -s "${T_TMP}/x/${d}/meta-data" "${T_TMP}/ref/meta-data"
done

run_cli build-seed --site "${T_TMP}/site" --node node1 --format cdrom --out "${T_TMP}/out"
check "unknown format is rejected" test "${RC}" -ne 0
run_cli build-seed --site "${T_TMP}/site" --node node1 --out "${T_TMP}/out"
check "format is required (no default)" test "${RC}" -ne 0
finish
