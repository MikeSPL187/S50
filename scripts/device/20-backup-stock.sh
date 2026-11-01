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
#  Использование:
#     bash 20-backup-stock.sh [путь-к-распакованной-прошивке]   # копия + сверка
#     bash 20-backup-stock.sh --recheck-only                    # только сверка (перед прошивкой)
#  Маркер DEVICE-MATCH.txt создаётся ТОЛЬКО при успешной сверке с работающим
#  телефоном; любой предыдущий маркер удаляется до начала сверки. Маркер
#  содержит проверенные значения, время и хэш копии; 30-preflash-gate.sh
#  принимает его не старше MATCH_MAX_AGE_MIN минут (по умолчанию 120).
# =============================================================================
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
DEV=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=expected/W1UI36H.39-25-11-4.env
source "$DEV/expected/W1UI36H.39-25-11-4.env"
EXPECTED_FILE="$DEV/expected/W1UI36H.39-25-11-4.sha256"
RECHECK=0
if [[ "${1:-}" == "--recheck-only" ]]; then RECHECK=1; shift; fi
FW=${1:-$HOME/moto-firmware/extracted/VIENNA_G_SYS_W1UI36H.39_25_11_4_subsidy_DEFAULT_regulatory_DEFAULT_cid50_CFC.xml}
ADB=${ADB:-$HOME/moto-tools/platform-tools/adb}
DST=${DST:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
die() { printf 'ОСТАНОВКА: %s\n' "$*" >&2; exit 1; }
mkdir -p "$DST"
# Устаревший результат сверки никогда не переживает новый запуск.
rm -f "$DST/DEVICE-MATCH.txt" "$DST/DEVICE-MISMATCH.txt"

if [[ $RECHECK -eq 0 ]]; then
[[ -f "$FW/flashfile.xml" ]] || die "не найден $FW/flashfile.xml"
[[ "$(sha256sum "$FW/flashfile.xml" | cut -d' ' -f1)" == 17c2fad9875e021e35fef00e3e9f0bdaf96ed29f4874a7884fef130ca4a9a5fd ]] \
  || die "flashfile.xml не совпадает с проверенной копией"

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
fi

echo "4/4 контрольные суммы и сверка с устройством"
cp -f "$EXPECTED_FILE" "$DST/EXPECTED.txt"
( cd "$DST" && sha256sum -c --quiet "$EXPECTED_FILE" ) || die "резервная копия не совпала с эталоном из репозитория"
( cd "$DST" && sha256sum ./*.img > SHA256SUMS )

[[ -x "$ADB" ]] && "$ADB" get-state >/dev/null 2>&1 || die "adb недоступен: копия проверена, но сверка с телефоном НЕ выполнена, маркер DEVICE-MATCH не создан.
Включите Android с отладкой USB и запустите: bash $0 --recheck-only"
[[ $("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l) -eq 1 ]] || die "нужно ровно одно устройство adb"
g() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
declare -A V=(
  [vbmeta_digest]="$(g getprop ro.boot.vbmeta.digest)"
  [proc_version]="$(g cat /proc/version)"
  [bootimage_utc]="$(g getprop ro.bootimage.build.date.utc)"
  [veritymode]="$(g getprop ro.boot.veritymode)"
  [slot]="$(g getprop ro.boot.slot_suffix)"
  [fingerprint]="$(g getprop ro.build.fingerprint)"
  [flash_locked]="$(g getprop ro.boot.flash.locked)"
  [vbmeta_device_state]="$(g getprop ro.boot.vbmeta.device_state)"
  [carrier]="$(g getprop ro.carrier)"
  [sku]="$(g getprop ro.boot.hardware.sku)"
)
exp_banner=$(python3 -I "$HERE/tools/bootimg_kernel.py" "$DST/boot.img")
[[ "$exp_banner" == "$EXP_PROC_VERSION" ]] || die "баннер ядра в копии boot.img не равен ожидаемому (копия повреждена?)"
res=0
c() { if [[ "$2" == "$3" ]]; then echo "   OK  $1"; else echo "   НЕТ $1: '$2' (ожидалось '$3')"; res=1; fi; }
c "vbmeta.digest (vbmeta_a + vbmeta_system_a)"      "${V[vbmeta_digest]}"  "$EXP_VBMETA_DIGEST"
c "/proc/version = баннер ядра из копии boot.img"     "${V[proc_version]}"   "$EXP_PROC_VERSION"
c "ro.bootimage.build.date.utc (init_boot)"         "${V[bootimage_utc]}"  "$EXP_BOOTIMAGE_UTC"
c "ro.boot.veritymode"                              "${V[veritymode]}"     "enforcing"
c "активный слот"                                    "${V[slot]}"           "_a"
c "ro.build.fingerprint"                            "${V[fingerprint]}"    "$EXP_FINGERPRINT"
c "ro.boot.flash.locked (загрузчик разблокирован)"  "${V[flash_locked]}"   "0"
c "ro.boot.vbmeta.device_state"                     "${V[vbmeta_device_state]}" "unlocked"
c "ro.carrier"                                      "${V[carrier]}"        "$EXP_CARRIER"
[[ -n "${V[sku]}" ]] && echo "   (инфо) ro.boot.hardware.sku=${V[sku]}"

if [[ $res -ne 0 ]]; then
  echo "   НЕ СОВПАДАЕТ: на телефоне другая сборка/состояние. Не используйте эту копию для отката!" | tee "$DST/DEVICE-MISMATCH.txt"
  exit 2
fi
{
  echo "schema=1"
  echo "build_id=$EXP_BUILD_ID"
  echo "created_epoch=$(date +%s)"
  echo "created_iso=$(date -Iseconds)"
  echo "vbmeta_digest=${V[vbmeta_digest]}"
  echo "proc_version_sha256=$(printf '%s' "${V[proc_version]}" | sha256sum | cut -d' ' -f1)"
  echo "bootimage_utc=${V[bootimage_utc]}"
  echo "veritymode=${V[veritymode]}"
  echo "slot=${V[slot]}"
  echo "fingerprint=${V[fingerprint]}"
  echo "flash_locked=${V[flash_locked]}"
  echo "vbmeta_device_state=${V[vbmeta_device_state]}"
  echo "carrier=${V[carrier]}"
  echo "expected_file_sha256=$(sha256sum "$EXPECTED_FILE" | cut -d' ' -f1)"
  echo "backup_sha256sums_sha256=$(sha256sum "$DST/SHA256SUMS" | cut -d' ' -f1)"
} > "$DST/DEVICE-MATCH.txt"
cat <<EOF
   СОВПАДАЕТ — маркер $DST/DEVICE-MATCH.txt (действует ограниченное время).
   Уровень уверенности: vbmeta/vbmeta_system — побайтно (дайджест); ядро boot_a — по строке
   сборки с временем компиляции; init_boot_a — по метке времени сборки; verity-разделы — блоки,
   прочитанные при работе, проверены dm-verity по корням hashtree этого vbmeta. Полной побайтной
   идентичности boot/init_boot/vendor_boot/dtbo это НЕ доказывает (без root невозможно).
EOF
echo "Готово: $DST  (телефон не изменялся)"
