#!/usr/bin/env bash
# =============================================================================
#  Резервная копия СТОКОВЫХ образов загрузки/модулей для W1UI36H.39-25-11-4.
#
#  Root на телефоне нет, поэтому разделы нельзя считать с устройства напрямую.
#  Вместо этого:
#   1) берём образы из того самого пакета прошивки, который был установлен
#      (проверяем MD5 из flashfile.xml и SHA-256 эталонов);
#   2) извлекаем vendor_dlkm_a / system_dlkm_a из super (tools/superimg.py);
#   3) сверяем с работающим телефоном (adb, без root):
#      - ro.boot.vbmeta.digest  → vbmeta_a и vbmeta_system_a = пакет;
#      - /proc/version целиком  → ядро boot_a = пакет;
#      - ro.bootimage.build.date.utc → рамдиск init_boot_a = пакет;
#      - ro.boot.veritymode=enforcing → verity-разделы (vendor_dlkm и др.)
#        проверяются dm-verity по корням hashtree из этого vbmeta.
#      Загрузчик разблокирован (ORANGE): ошибка хэша boot/vendor_boot НЕ
#      остановила бы загрузку, поэтому одного vbmeta.digest недостаточно.
#      vendor_boot_a и dtbo_a без root не проверяются (fastboot fetch на
#      user-сборках запрещён) — опираемся на журнал прошивки 30.10.2026.
#
#  В телефон НИЧЕГО не пишется.  Результат: ~/moto-kernel/backup-W1UI36H.39-25-11-4/
#  Использование:  bash 20-backup-stock.sh [путь-к-распакованной-прошивке]
# =============================================================================
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
FW=${1:-$HOME/moto-firmware/extracted/VIENNA_G_SYS_W1UI36H.39_25_11_4_subsidy_DEFAULT_regulatory_DEFAULT_cid50_CFC.xml}
ADB=${ADB:-$HOME/moto-tools/platform-tools/adb}
HOSTTOOLS=${HOSTTOOLS:-$HOME/moto-kernel/hosttools}
DST=${DST:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
EXPECT_VBMETA_DIGEST='9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23'
die() { printf 'ОСТАНОВКА: %s\n' "$*" >&2; exit 1; }

[[ -f "$FW/flashfile.xml" ]] || die "не найден $FW/flashfile.xml"
[[ "$(sha256sum "$FW/flashfile.xml" | cut -d' ' -f1)" == 17c2fad9875e021e35fef00e3e9f0bdaf96ed29f4874a7884fef130ca4a9a5fd ]] \
  || die "flashfile.xml не совпадает с проверенной копией"
mkdir -p "$DST"

echo "1/4 проверка MD5 нужных образов по flashfile.xml"
python3 -I - "$FW" <<'EOF'
import sys, os, hashlib, xml.etree.ElementTree as ET
fw = sys.argv[1]
need = {"boot.img", "init_boot.img", "vendor_boot.img", "dtbo.img", "vbmeta.img", "vbmeta_system.img"}
need |= {f"super.img_sparsechunk.{i}" for i in range(31)}
seen = set()
for st in ET.parse(os.path.join(fw, "flashfile.xml")).getroot().iter("step"):
    fn = st.get("filename")
    if fn in need and fn not in seen:
        h = hashlib.md5()
        with open(os.path.join(fw, fn), "rb") as f:
            for c in iter(lambda: f.read(1 << 22), b""): h.update(c)
        if h.hexdigest() != st.get("MD5"):
            sys.exit(f"MD5 MISMATCH: {fn}")
        seen.add(fn)
missing = need - seen
if missing:
    sys.exit(f"нет в flashfile.xml/на диске: {sorted(missing)}")
print(f"   OK: {len(seen)} файлов")
EOF

echo "2/4 копирование образов разделов-кандидатов"
for f in boot init_boot vendor_boot dtbo vbmeta vbmeta_system; do cp -f "$FW/$f.img" "$DST/$f.img"; done

echo "3/4 извлечение vendor_dlkm_a / system_dlkm_a из super"
mapfile -t CH < <(ls "$FW"/super.img_sparsechunk.* | sort -t. -k3 -n)
python3 -I "$HERE/tools/superimg.py" extract "${CH[@]}" -p vendor_dlkm_a -p system_dlkm_a -o "$DST" | tee "$DST/superimg-extract.log"

echo "4/4 контрольные суммы и сверка с устройством"
( cd "$DST" && sha256sum ./*.img > SHA256SUMS )
cat > "$DST/EXPECTED.txt" <<'EOF'
# SHA-256 эталонных образов из пакета W1UI36H.39-25-11-4 (7z sha256 6bc78abc...f6a3)
f8a5f539754947deeb54bf80a1927e93b5807c81f0fca7aab04cbc8ee25ac919  ./boot.img
59b64d0e216cc3aa08f125799b52d89cb2d60029a155a80b564ed32e1d297ba8  ./init_boot.img
5a0c47aaf3f9852d758de53901ab23411de1afca4706083d0b2f1531774bfa49  ./vendor_boot.img
9a442cf2d48b02001c6a002ce03f29099edd1a41da1e5eb74492f91cf06feda6  ./dtbo.img
654e7f9fcf3c7f18a4f3c143cb68fa16ae383f09960547ccaf55b0ded10405e3  ./vbmeta.img
1528d9c7b325c1c3ac41a94b87f418523fd4e871a56b01a5f51e9903012754b9  ./vbmeta_system.img
91a9ade67032c86c6c05c8a6a2daea9ae14a870c7f421b220cbbc45afd7bfcb0  ./vendor_dlkm_a.img
917666e69954046a1c50e4c7031348618b4f660d258eead2bb8f1b6fd5121c42  ./system_dlkm_a.img
EOF
( cd "$DST" && sha256sum -c EXPECTED.txt ) || die "резервная копия не совпала с эталоном"

if [[ -x "$ADB" ]] && "$ADB" get-state >/dev/null 2>&1; then
  g() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
  dev=$(g getprop ro.boot.vbmeta.digest)
  pver=$(g cat /proc/version)
  bi_utc=$(g getprop ro.bootimage.build.date.utc)
  vmode=$(g getprop ro.boot.veritymode)
  slot=$(g getprop ro.boot.slot_suffix)
  exp_pver=$(python3 -I "$HERE/tools/bootimg_kernel.py" "$DST/boot.img" || true)
  exp_bi=1788995558
  echo "   slot=$slot veritymode=$vmode"
  res=0
  [[ "$dev" == "$EXPECT_VBMETA_DIGEST" ]] && echo "   OK  vbmeta.digest" || { echo "   НЕТ vbmeta.digest=$dev"; res=1; }
  [[ -n "$exp_pver" && "$pver" == "$exp_pver" ]] && echo "   OK  /proc/version = баннер стокового boot.img" || { echo "   НЕТ /proc/version='$pver'"; res=1; }
  [[ "$bi_utc" == "$exp_bi" ]] && echo "   OK  ro.bootimage.build.date.utc" || { echo "   НЕТ bootimage.build.date.utc=$bi_utc"; res=1; }
  [[ "$vmode" == enforcing ]] && echo "   OK  dm-verity enforcing" || { echo "   НЕТ veritymode=$vmode"; res=1; }
  [[ "$slot" == _a ]] && echo "   OK  активный слот A" || { echo "   НЕТ слот=$slot"; res=1; }
  if [[ $res -eq 0 ]]; then
    { echo "СОВПАДАЕТ ($(date -Iseconds)): vbmeta/vbmeta_system, ядро boot_a, init_boot_a и verity-разделы"
      echo "соответствуют этой копии; vendor_boot_a/dtbo_a — по журналу прошивки 30.10.2026."; } | tee "$DST/DEVICE-MATCH.txt"
  else
    echo "   НЕ СОВПАДАЕТ: на телефоне другая сборка/образы. Не используйте эту копию для отката!" | tee "$DST/DEVICE-MISMATCH.txt"
    rm -f "$DST/DEVICE-MATCH.txt"
    exit 2
  fi
else
  echo "   adb недоступен — сверку с устройством выполните позже: adb shell getprop ro.boot.vbmeta.digest"
  echo "   ожидается: $EXPECT_VBMETA_DIGEST"
fi
echo "Готово: $DST  (телефон не изменялся)"
