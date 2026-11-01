#!/usr/bin/env bash
# =============================================================================
#  Предполётная проверка перед ЭКСПЕРИМЕНТАЛЬНОЙ установкой vendor_dlkm.
#  ТОЛЬКО ЧТЕНИЕ: fastboot getvar, проверка файлов. Ничего не прошивает.
#
#  Политика: всё, что критично для безопасности, — СТОП. Если параметр нельзя
#  прочитать, это тоже СТОП (кроме явно помеченных информационных строк).
#
#  Порядок работы:
#     bash 20-backup-stock.sh --recheck-only     # в Android: свежая сверка (≤ 120 мин)
#     adb reboot bootloader
#     bash 30-preflash-gate.sh <каталог-артефакта> [каталог-бэкапа]
# =============================================================================
set -Euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
DEV="$HERE/scripts/device"
ART=$(realpath "${1:?каталог артефакта}")
BAK=$(realpath "${2:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}")
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
HOSTTOOLS=${HOSTTOOLS:-$HOME/moto-kernel/hosttools}
export AVBTOOL=${AVBTOOL:-$HOSTTOOLS/avbtool.py}
MATCH_MAX_AGE_MIN=${MATCH_MAX_AGE_MIN:-120}
# shellcheck source=expected/W1UI36H.39-25-11-4.env
source "$DEV/expected/W1UI36H.39-25-11-4.env"
EXPECTED_FILE="$DEV/expected/W1UI36H.39-25-11-4.sha256"
# shellcheck source=lib-fastboot.sh
source "$DEV/lib-fastboot.sh"
FAIL=0
ok()  { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [СТОП] %s\n' "$*"; FAIL=1; }
inf() { printf '  (инфо) %s\n' "$*"; }

echo "== Артефакт: $ART"
if [[ -f "$ART/vendor_dlkm.img" && -f "$ART/vbmeta.img" && -f "$ART/SHA256SUMS" ]]; then
  ( cd "$ART" && sha256sum -c --quiet SHA256SUMS ) && ok "SHA256SUMS артефакта" || bad "контрольные суммы артефакта"
  python3 -I "$AVBTOOL" verify_image --image "$ART/vendor_dlkm.img" >/dev/null 2>&1 \
    && ok "hashtree vendor_dlkm.img валиден" || bad "hashtree vendor_dlkm.img"
  python3 -I "$HERE/tools/vbmeta_diff.py" "$BAK/vbmeta.img" "$ART/vbmeta.img" > "$ART/gate-vbmeta-diff.txt" 2>&1 \
    && ok "vbmeta: отличается от стока только дескриптором vendor_dlkm; rollback index/flags как в стоке" \
    || bad "vbmeta отличается не только vendor_dlkm (см. gate-vbmeta-diff.txt)"
  a=$(python3 -I "$AVBTOOL" info_image --image "$ART/vbmeta.img" | awk '/Partition Name: *vendor_dlkm/{f=1} f&&/Root Digest/{print $3; exit}')
  b=$(python3 -I "$AVBTOOL" info_image --image "$ART/vendor_dlkm.img" | awk '/Root Digest/{print $3; exit}')
  [[ -n "$a" && "$a" == "$b" ]] && ok "root digest vbmeta == footer vendor_dlkm.img" || bad "root digest не совпадает"
  sz=$(stat -c %s "$ART/vendor_dlkm.img")
  [[ "$sz" -eq "$EXP_VENDOR_DLKM_PART_SIZE" ]] \
    && ok "размер образа = стоковому логическому разделу ($sz): разметка super не меняется" \
    || bad "размер образа $sz ≠ $EXP_VENDOR_DLKM_PART_SIZE: fastbootd изменил бы разметку super — запрещено"
else
  bad "нет vendor_dlkm.img / vbmeta.img / SHA256SUMS"
fi

echo "== Резервная копия: $BAK"
( cd "$BAK" 2>/dev/null && sha256sum -c --quiet "$EXPECTED_FILE" ) >/dev/null 2>&1 \
  && ok "стоковые образы совпадают с эталоном из репозитория" || bad "резервная копия повреждена/отсутствует (20-backup-stock.sh)"

echo "== Свежесть и содержимое сверки с телефоном (DEVICE-MATCH.txt)"
M="$BAK/DEVICE-MATCH.txt"
mk() { sed -n "s/^$1=//p" "$M" | head -n1; }
if [[ ! -f "$M" ]]; then
  bad "нет DEVICE-MATCH.txt — в Android выполните: bash 20-backup-stock.sh --recheck-only"
else
  [[ "$(mk schema)" == 1 ]] && ok "формат маркера" || bad "маркер старого формата — повторите 20-backup-stock.sh --recheck-only"
  ep=$(mk created_epoch); [[ "$ep" =~ ^[0-9]+$ ]] || ep=0
  age=$(( ( $(date +%s) - ep ) / 60 ))
  [[ $ep -gt 0 && $age -ge 0 && $age -le $MATCH_MAX_AGE_MIN ]] \
    && ok "сверка выполнена $age мин назад (допуск $MATCH_MAX_AGE_MIN)" \
    || bad "сверка устарела/из будущего/повреждена (возраст $age мин) — повторите 20-backup-stock.sh --recheck-only"
  [[ "$(mk build_id)" == "$EXP_BUILD_ID" ]] && ok "маркер для сборки $EXP_BUILD_ID" || bad "маркер для другой сборки: '$(mk build_id)'"
  [[ "$(mk vbmeta_digest)" == "$EXP_VBMETA_DIGEST" ]] && ok "маркер: vbmeta.digest стоковый" || bad "маркер: vbmeta.digest не стоковый"
  [[ "$(mk proc_version_sha256)" == "$(printf '%s' "$EXP_PROC_VERSION" | sha256sum | cut -d' ' -f1)" ]] \
    && ok "маркер: строка сборки ядра стоковая" || bad "маркер: /proc/version не стоковый"
  [[ "$(mk bootimage_utc)" == "$EXP_BOOTIMAGE_UTC" ]] && ok "маркер: метка сборки init_boot" || bad "маркер: bootimage.build.date.utc"
  [[ "$(mk veritymode)" == enforcing ]] && ok "маркер: dm-verity enforcing" || bad "маркер: veritymode='$(mk veritymode)'"
  [[ "$(mk slot)" == _a ]] && ok "маркер: Android работал со слота A" || bad "маркер: слот '$(mk slot)'"
  [[ "$(mk flash_locked)" == 0 && "$(mk vbmeta_device_state)" == unlocked ]] \
    && ok "маркер: загрузчик разблокирован (flash.locked=0, device_state=unlocked)" || bad "маркер: разблокировка не подтверждена"
  [[ "$(mk carrier)" == "$EXP_CARRIER" ]] && ok "маркер: ro.carrier=$EXP_CARRIER" || bad "маркер: ro.carrier='$(mk carrier)'"
  [[ "$(mk expected_file_sha256)" == "$(sha256sum "$EXPECTED_FILE" | cut -d' ' -f1)" ]] \
    && ok "маркер привязан к текущему эталону" || bad "маркер создан для другого эталона"
  [[ -f "$BAK/SHA256SUMS" && "$(mk backup_sha256sums_sha256)" == "$(sha256sum "$BAK/SHA256SUMS" | cut -d' ' -f1)" ]] \
    && ok "маркер привязан к этой резервной копии" || bad "резервная копия изменилась после сверки"
fi

echo "== Устройство (fastboot, только getvar)"
[[ -x "$FASTBOOT" ]] || { bad "нет fastboot: $FASTBOOT"; exit 1; }
n=$(fb_count)
[[ "$n" -eq 1 ]] && ok "ровно одно устройство fastboot" || { bad "устройств fastboot: $n"; exit 1; }
v=$(gv product);      [[ "$v" == vienna ]]         && ok "product=$v" || bad "product='$v'"
v=$(gv sku);          [[ "$v" == "$EXP_SKU" ]]     && ok "sku=$v" || bad "sku='$v'"
v=$(gv cid);          [[ "$v" == "$EXP_CID" ]]     && ok "cid=$v (аппаратный CID 11 — ожидаемо)" || bad "cid='$v'"
v=$(gv ro.carrier);   [[ "$v" == "$EXP_CARRIER" ]] && ok "ro.carrier=$v" || bad "ro.carrier='$v' (ожидается $EXP_CARRIER)"
v=$(gv is-userspace); [[ "$v" == no ]]             && ok "режим загрузчика (не fastbootd)" || bad "is-userspace='$v' (нужен загрузчик)"
v=$(gv current-slot); [[ "$v" == a ]]              && ok "current-slot=a" || bad "current-slot='$v'"
v=$(gv slot-successful:_a); [[ "$v" == yes ]]      && ok "slot-successful:_a=yes" || bad "slot-successful:_a='$v'"
v=$(gv slot-unbootable:_a); [[ "$v" == no ]]       && ok "slot-unbootable:_a=no" || bad "slot-unbootable:_a='$v'"
v=$(gv has-slot:vbmeta);    [[ "$v" == yes ]]      && ok "has-slot:vbmeta=yes" || bad "has-slot:vbmeta='$v'"
v=$(gv snapshot-update-status); [[ "$v" == none ]] && ok "snapshot-update-status=none (нет незавершённого OTA)" || bad "snapshot-update-status='$v'"
b=$(build_of_running_bootloader)
[[ "$b" == "$EXP_BUILD_ID" ]] && ok "загрузчик слота A — сборка $EXP_BUILD_ID ($(gvm version-bootloader))" \
  || bad "version-bootloader → '$b' (ожидается $EXP_BUILD_ID; сырое значение: '$(gvm version-bootloader)')"
fp=$(gvm ro.build.fingerprint)
if [[ -n "$fp" ]]; then
  [[ "$fp" == "$EXP_FINGERPRINT" ]] && ok "fastboot ro.build.fingerprint стоковый" || bad "fastboot ro.build.fingerprint='$fp'"
else
  inf "fastboot getvar ro.build.fingerprint не поддерживается — опора на version-bootloader и свежий маркер"
fi
v=$(gv securestate)
case "$v" in
  *unlock*) ok "securestate=$v" ;;
  *lock*)   bad "securestate=$v — загрузчик ЗАБЛОКИРОВАН, запись запрещена" ;;
  "")       inf "securestate не сообщается; разблокировка подтверждена свежим маркером (ro.boot.flash.locked=0)" ;;
  *)        bad "securestate='$v' — неизвестное значение" ;;
esac
inf "слоты:"; slot_report

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ПРЕДПОЛЁТНАЯ ПРОВЕРКА ПРОЙДЕНА. Ничего не изменено."
  echo "Следующий шаг выполняется ТОЛЬКО вручную и только после вашего решения:"
  echo "   bash $DEV/40-flash-experimental-vendor-dlkm.sh '$ART' --i-understand"
else
  echo "ПРОВЕРКА НЕ ПРОЙДЕНА. Прошивка запрещена. Ничего не изменено."
fi
exit $FAIL
