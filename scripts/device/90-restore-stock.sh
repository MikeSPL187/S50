#!/usr/bin/env bash
# =============================================================================
#  ОТКАТ К СТОКУ W1UI36H.39-25-11-4 (слот A).   НЕ ЗАПУСКАЕТСЯ АВТОМАТИЧЕСКИ.
#
#  Восстанавливает то, что меняет экспериментальная установка:
#     vbmeta_a (загрузчик) + vendor_dlkm_a (fastbootd)
#  --all          дополнительно boot_a, init_boot_a, vendor_boot_a, dtbo_a,
#                 vbmeta_system_a, system_dlkm_a
#  --set-active-a если загрузчик сам переключился на слот B после неудачных
#                 загрузок A: восстановить A и активировать A (до входа в fastbootd)
#  --accept-unverified-state  продолжить без журнала эксперимента / при нечитаемой
#                 версии загрузчика. НЕ отменяет запреты из раздела «никогда».
#
#  Состояние телефона должно быть ИЗВЕСТНЫМ. Источники уверенности:
#   1) Android работает (adb): fingerprint этой сборки, слот _a, vbmeta.digest —
#      стоковый или экспериментальный из журнала установки;
#   2) Android не работает: журнал EXPERIMENT-STATE.txt, который пишет
#      40-flash-experimental-vendor-dlkm.sh, + version-bootloader этой сборки.
#  НИКОГДА (без обхода): другая сборка Android по adb; version-bootloader
#  чужой сборки; слот B помечен successful (это рабочая система, например
#  после OTA, а не аварийный переход на непригодный старый слот B).
#
#  Проверки модели/CID возможны только в ЗАГРУЗЧИКЕ (в AOSP fastbootd нет
#  getvar sku/cid). Если скрипт запущен из fastbootd, он сначала перезагружает
#  телефон в загрузчик (это не запись).
#  НИКОГДА не трогает GPT, preloader, lk, nvdata, efuse, modem, userdata, слот B.
#  Систему не загружает без отдельного подтверждения (фраза BOOT).
#
#     bash 90-restore-stock.sh --i-understand [--all] [--set-active-a] [--accept-unverified-state]
# =============================================================================
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OK=0; ALL=0; SETA=0; UNVERIFIED=0
for arg in "$@"; do
  case "$arg" in
    --i-understand) OK=1 ;; --all) ALL=1 ;; --set-active-a) SETA=1 ;;
    --accept-unverified-state) UNVERIFIED=1 ;;
    *) echo "неизвестный аргумент: $arg"; exit 2 ;;
  esac
done
[[ $OK -eq 1 ]] || { echo "Нужен аргумент --i-understand (см. docs/06-safety-and-rollback.md)"; exit 2; }
BAK=${BAK:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
ADB=${ADB:-$HOME/moto-tools/platform-tools/adb}
JOURNAL="$BAK/EXPERIMENT-STATE.txt"
LOG="$HOME/moto-kernel/restore-stock-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
# shellcheck source=expected/W1UI36H.39-25-11-4.env
source "$HERE/expected/W1UI36H.39-25-11-4.env"
# shellcheck source=lib-fastboot.sh
source "$HERE/lib-fastboot.sh"
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\n' "$*" "$LOG" >&2; exit 1; }
jget() { [[ -f "$JOURNAL" ]] && grep "^event=$1 " "$JOURNAL" | tail -n1 | tr ' ' '\n' | sed -n "s/^$2=//p"; }
jlast() { [[ -f "$JOURNAL" ]] && tail -n1 "$JOURNAL" | sed -n 's/^event=\([^ ]*\).*/\1/p'; }

( cd "$BAK" && sha256sum -c --quiet "$HERE/expected/W1UI36H.39-25-11-4.sha256" ) \
  || die "резервная копия не совпадает с эталоном W1UI36H.39-25-11-4 — не используйте её"

LAST=$(jlast || true); LAST=${LAST:-none}
EXP_DIGEST=$(jget prepared exp_vbmeta_digest || true)
case "$LAST" in prepared|vbmeta_a_written|vendor_dlkm_a_written) ACTIVE=1 ;; *) ACTIVE=0 ;; esac
echo "Журнал эксперимента: последнее событие '$LAST'$([[ $ACTIVE -eq 1 ]] && echo ' (эксперимент не откатан)')"

# ---------- 1. Если Android работает — сверка по adb (самый надёжный источник) ----------
STATE_FROM_ADB=0
if [[ -x "$ADB" ]] && [[ $("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | wc -l) -eq 1 ]]; then
  g() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
  fp=$(g getprop ro.build.fingerprint); dg=$(g getprop ro.boot.vbmeta.digest); sl=$(g getprop ro.boot.slot_suffix)
  echo "Android работает: slot=$sl vbmeta.digest=$dg"
  [[ "$fp" == "$EXP_FINGERPRINT" ]] || die "Android работает со сборкой '$fp', а не $EXP_BUILD_ID. Откат этой копией запрещён."
  [[ "$sl" == _a ]] || die "Android работает со слота '$sl'. Откат слота A запрещён — ситуация требует отдельной оценки."
  if [[ "$dg" == "$EXP_VBMETA_DIGEST" ]]; then
    echo "Телефон уже на стоковом vbmeta (digest стоковый)."
  elif [[ -n "$EXP_DIGEST" && "$dg" == "$EXP_DIGEST" ]]; then
    echo "Телефон в экспериментальном состоянии из журнала (digest совпал)."
  else
    die "vbmeta.digest '$dg' не стоковый и не из журнала эксперимента — неизвестное состояние, откат запрещён."
  fi
  confirm "REBOOT TO BOOTLOADER" || die "отменено (ничего не изменено)"
  "$ADB" reboot bootloader
  wait_fb no || die "загрузчик не появился за 3 минуты"
  STATE_FROM_ADB=1
fi

# ---------- 2. Загрузчик: идентификация и решение ----------
[[ $(fb_count) -eq 1 ]] || die "нужно ровно одно устройство fastboot"
if [[ "$(gv is-userspace)" == yes ]]; then
  echo "Сейчас fastbootd: модель/CID здесь не читаются. Перезагрузка в загрузчик (без записи)."
  "$FASTBOOT" reboot bootloader || die "переход в загрузчик"
  wait_fb no || die "загрузчик не появился за 3 минуты"
fi
[[ "$(gv is-userspace)" == no ]] || die "не удалось перейти в загрузчик"
[[ "$(gv product)" == vienna && "$(gv sku)" == "$EXP_SKU" && "$(gv cid)" == "$EXP_CID" ]] \
  || die "это не vienna / $EXP_SKU / CID $EXP_CID"

echo "=== Текущее состояние ==="
slot_report
CUR=$(gv current-slot)
BLD=$(build_of_running_bootloader)
echo "  работающий загрузчик относится к сборке: $BLD"
need_override() {
  [[ $UNVERIFIED -eq 1 ]] || die "$1
Если вы точно знаете состояние телефона, повторите с --accept-unverified-state."
  echo "  ВНИМАНИЕ: $1 — продолжение по --accept-unverified-state"
}

if [[ "$CUR" == a ]]; then
  case "$BLD" in
    "$EXP_BUILD_ID") ;;
    unknown) need_override "version-bootloader не читается" ;;
    *) die "слот A загружает сборку '$BLD', копия — для $EXP_BUILD_ID. Откат запрещён." ;;
  esac
  [[ $STATE_FROM_ADB -eq 1 || $ACTIVE -eq 1 ]] \
    || need_override "Android не работает, а журнал не содержит незавершённого эксперимента"
else
  [[ $SETA -eq 1 ]] || die "current-slot=$CUR, ожидается a. Если загрузчик сам переключился на B после неудачных загрузок A —
повторите с --set-active-a."
  # Аварийный переход: слот B непригоден (загрузочная цепочка Android 15, нет vendor_b),
  # поэтому он не может быть помечен successful. successful=yes означает рабочую систему
  # на B (например, после OTA) — возврат на A запрещён без возможности обхода.
  [[ "$(gv slot-successful:_b)" != yes ]] \
    || die "слот B помечен successful — это рабочая система (вероятно, OTA), а не аварийный переход. Возврат на A запрещён."
  case "$BLD" in
    "$EXP_SLOT_B_BUILD"|"$EXP_BUILD_ID") ;;
    unknown) need_override "version-bootloader не читается" ;;
    *) die "в слоте $CUR загрузчик сборки '$BLD' (ожидалась $EXP_SLOT_B_BUILD или $EXP_BUILD_ID). Возврат на A запрещён." ;;
  esac
  [[ $ACTIVE -eq 1 ]] || need_override "журнал не содержит незавершённого эксперимента, причина перехода на B неизвестна"
fi

echo
echo "План: vbmeta_a$([[ $ALL -eq 1 ]] && echo ', boot_a, init_boot_a, vendor_boot_a, dtbo_a, vbmeta_system_a') (загрузчик)" \
     "$([[ "$CUR" != a ]] && echo '→ --set-active=a ')→ vendor_dlkm_a$([[ $ALL -eq 1 ]] && echo ', system_dlkm_a') (fastbootd) → загрузчик"
confirm "RESTORE S50 STOCK" || die "отменено (ничего не записано)"

# ---------- 3. Запись ----------
"$FASTBOOT" flash vbmeta_a "$BAK/vbmeta.img" || die "vbmeta_a"
if [[ $ALL -eq 1 ]]; then
  for p in boot init_boot vendor_boot dtbo vbmeta_system; do
    "$FASTBOOT" flash "${p}_a" "$BAK/$p.img" || die "${p}_a"
  done
fi
if [[ "$CUR" != a ]]; then
  "$FASTBOOT" --set-active=a || die "--set-active=a"
  [[ "$(gv current-slot)" == a ]] || die "слот A не стал активным"
fi
"$FASTBOOT" reboot fastboot || die "переход в fastbootd"
wait_fb yes || die "fastbootd не появился за 3 минуты; vbmeta_a уже стоковый — повторите скрипт"
[[ "$(gv current-slot)" == a ]] || die "fastbootd сообщает current-slot=$(gv current-slot)"
[[ "$(gv is-logical:vendor_dlkm_a)" == yes ]] || die "vendor_dlkm_a не виден как логический раздел"
"$FASTBOOT" flash vendor_dlkm_a "$BAK/vendor_dlkm_a.img" || die "vendor_dlkm_a"
if [[ $ALL -eq 1 ]]; then "$FASTBOOT" flash system_dlkm_a "$BAK/system_dlkm_a.img" || die "system_dlkm_a"; fi
"$FASTBOOT" reboot bootloader || die "переход в загрузчик (разделы уже восстановлены)"
wait_fb no || die "загрузчик не появился после записи (разделы уже восстановлены)"
echo "event=restored epoch=$(date +%s) time=$(date -Iseconds) all=$ALL set_active_a=$([[ "$CUR" != a ]] && echo 1 || echo 0)" >> "$JOURNAL"

echo
echo "Откат записан. Журнал: $LOG"
echo "После загрузки: bash $HERE/00-readonly-diagnostics.sh — ожидается"
echo "  ro.boot.vbmeta.digest = $EXP_VBMETA_DIGEST"
final_boot_prompt || true
