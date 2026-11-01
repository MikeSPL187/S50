#!/usr/bin/env bash
# =============================================================================
#  ОТКАТ К СТОКУ W1UI36H.39-25-11-4 (слот A).   НЕ ЗАПУСКАЕТСЯ АВТОМАТИЧЕСКИ.
#
#  По умолчанию восстанавливает то, что меняет экспериментальная установка:
#     vbmeta_a (загрузчик) + vendor_dlkm_a (fastbootd)
#  --all          дополнительно boot_a, init_boot_a, vendor_boot_a, dtbo_a,
#                 vbmeta_system_a, system_dlkm_a (на случай других экспериментов)
#  --set-active-a разрешить восстановление, если загрузчик сам переключился на B
#                 (после 7 неудачных загрузок A); после записи A выполняется
#                 `fastboot --set-active=a`.  Без этого флага при current-slot≠a
#                 скрипт останавливается.
#
#  Слот B НЕ является запасным: после прошивки 30.10 boot_b/vendor_boot_b и др.
#  остались от Android 15, а в super у слота B нет vendor/product/vendor_dlkm
#  (размер 0) — Android 16 со слота B не загрузится.
#
#  НИКОГДА не трогает GPT, preloader, lk, nvdata, efuse, modem, userdata и
#  разделы слота B. Загрузчик не блокируется. Систему не загружает без
#  отдельного подтверждения.
#
#  Запуск: телефон в загрузчике ИЛИ в fastbootd.
#     bash 90-restore-stock.sh --i-understand [--all] [--set-active-a]
# =============================================================================
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OK=0; ALL=0; SETA=0
for arg in "$@"; do
  case "$arg" in
    --i-understand) OK=1 ;; --all) ALL=1 ;; --set-active-a) SETA=1 ;;
    *) echo "неизвестный аргумент: $arg"; exit 2 ;;
  esac
done
[[ $OK -eq 1 ]] || { echo "Нужен аргумент --i-understand (см. docs/06-safety-and-rollback.md)"; exit 2; }
BAK=${BAK:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
LOG="$HOME/moto-kernel/restore-stock-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
# shellcheck source=lib-fastboot.sh
source "$HERE/lib-fastboot.sh"
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\n' "$*" "$LOG" >&2; exit 1; }

( cd "$BAK" && sha256sum -c --quiet EXPECTED.txt ) || die "резервная копия не совпадает с эталоном — не используйте её"
[[ $(fb_count) -eq 1 ]] || die "нужно ровно одно устройство fastboot"
[[ "$(gv product)" == vienna && "$(gv sku)" == XT2409-5 ]] || die "это не vienna / XT2409-5"
MODE=$(gv is-userspace)
[[ "$MODE" == yes || "$MODE" == no ]] || die "не удалось определить режим (is-userspace='$MODE')"

echo "=== Текущее состояние ==="
slot_report
CUR=$(gv current-slot)
if [[ "$CUR" != a ]]; then
  if [[ $SETA -ne 1 ]]; then
    die "current-slot=$CUR, ожидается a. Вероятно, загрузчик сам переключился на B после неудачных загрузок A.
Повторите с флагом --set-active-a (будут восстановлены разделы A и активирован слот A)."
  fi
  [[ "$MODE" == no ]] || die "для смены слота запустите скрипт из загрузчика: $FASTBOOT reboot bootloader"
fi

echo
echo "План: vbmeta_a$([[ $ALL -eq 1 ]] && echo ', boot_a, init_boot_a, vendor_boot_a, dtbo_a, vbmeta_system_a') (загрузчик);" \
     "vendor_dlkm_a$([[ $ALL -eq 1 ]] && echo ', system_dlkm_a') (fastbootd)$([[ $SETA -eq 1 ]] && echo '; затем --set-active=a')"
confirm "RESTORE S50 STOCK" || die "отменено (ничего не записано)"

flash_physical() {
  "$FASTBOOT" flash vbmeta_a "$BAK/vbmeta.img" || die "vbmeta_a"
  if [[ $ALL -eq 1 ]]; then
    local p
    for p in boot init_boot vendor_boot dtbo vbmeta_system; do
      "$FASTBOOT" flash "${p}_a" "$BAK/$p.img" || die "${p}_a"
    done
  fi
}
flash_logical() {
  [[ "$(gv is-logical:vendor_dlkm_a)" == yes ]] || die "vendor_dlkm_a не виден как логический раздел"
  "$FASTBOOT" flash vendor_dlkm_a "$BAK/vendor_dlkm_a.img" || die "vendor_dlkm_a"
  if [[ $ALL -eq 1 ]]; then "$FASTBOOT" flash system_dlkm_a "$BAK/system_dlkm_a.img" || die "system_dlkm_a"; fi
}

if [[ "$MODE" == no ]]; then
  echo "=== 1. загрузчик: физические разделы ==="
  flash_physical
  if [[ $SETA -eq 1 ]]; then
    "$FASTBOOT" --set-active=a || die "--set-active=a"
    [[ "$(gv current-slot)" == a ]] || die "слот A не стал активным"
  fi
  echo "=== 2. fastbootd: логические разделы ==="
  "$FASTBOOT" reboot fastboot || die "переход в fastbootd"
  wait_fb yes || die "fastbootd не появился за 3 минуты; vbmeta_a уже стоковый — повторите скрипт из загрузчика"
  [[ "$(gv current-slot)" == a ]] || die "fastbootd сообщает current-slot=$(gv current-slot)"
  flash_logical
else
  echo "=== 1. fastbootd: логические разделы ==="
  flash_logical
  echo "=== 2. загрузчик: физические разделы ==="
  "$FASTBOOT" reboot bootloader || die "переход в загрузчик"
  wait_fb no || die "загрузчик не появился; vendor_dlkm_a уже стоковый — восстановите vbmeta_a вручную"
  flash_physical
fi

if [[ "$(gv is-userspace)" == yes ]]; then
  "$FASTBOOT" reboot bootloader || die "переход в загрузчик"
  wait_fb no || die "загрузчик не появился после записи (разделы уже восстановлены)"
fi
echo
echo "Откат записан. Журнал: $LOG"
echo "После загрузки: bash $HERE/00-readonly-diagnostics.sh — ожидается"
echo "  ro.boot.vbmeta.digest = 9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23"
final_boot_prompt || true
