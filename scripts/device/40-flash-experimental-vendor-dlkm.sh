#!/usr/bin/env bash
# =============================================================================
#  !!! ЭКСПЕРИМЕНТАЛЬНАЯ ЗАПИСЬ В ТЕЛЕФОН !!!   НЕ ЗАПУСКАЕТСЯ АВТОМАТИЧЕСКИ.
#
#  Записывает РОВНО ДВА раздела активного слота A:
#     vbmeta_a       (загрузчик)  — стоковые дескрипторы + новый hashtree vendor_dlkm
#     vendor_dlkm_a  (fastbootd)  — стоковый vendor_dlkm с заменённым cpufreq_sugov_ext.ko
#  НЕ трогает: boot, init_boot, vendor_boot, dtbo, GPT, preloader, lk, nvdata,
#  efuse, modem, слот B, userdata.  Загрузчик НЕ блокируется.
#
#  Порядок выбран так, чтобы при сбое на любом шаге откат был возможен из
#  загрузчика/fastbootd (recovery и fastbootd не используют vendor_dlkm).
#  После записи телефон возвращается в ЗАГРУЗЧИК; систему загружает только
#  отдельное подтверждение (фраза BOOT).  Откат: bash 90-restore-stock.sh
#
#  Использование (телефон в загрузчике):
#     bash 40-flash-experimental-vendor-dlkm.sh <каталог-артефакта> --i-understand
# =============================================================================
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ART=$(realpath "${1:?каталог артефакта}")
[[ "${2:-}" == "--i-understand" ]] || { echo "Нужен второй аргумент --i-understand (см. docs/06-safety-and-rollback.md)"; exit 2; }
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
LOG="$HOME/moto-kernel/flash-experimental-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
# shellcheck source=lib-fastboot.sh
source "$HERE/lib-fastboot.sh"
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\nОткат: bash %s/90-restore-stock.sh --i-understand\n' "$*" "$LOG" "$HERE" >&2; exit 1; }

echo "=== Предполётная проверка ==="
bash "$HERE/30-preflash-gate.sh" "$ART" || die "предполётная проверка не пройдена"
echo "Состояние слотов до записи:"
slot_report

cat <<EOF

ВНИМАНИЕ. Будут записаны vbmeta_a и vendor_dlkm_a.
  vendor_dlkm.img sha256: $(sha256sum "$ART/vendor_dlkm.img" | cut -d' ' -f1)
  vbmeta.img      sha256: $(sha256sum "$ART/vbmeta.img" | cut -d' ' -f1)
Последствия: другой ro.boot.vbmeta.digest; vbmeta подписан не ключом Motorola
(при разблокированном загрузчике допустимо, состояние остаётся ORANGE);
инкрементальные OTA не установятся до отката (90-restore-stock.sh).
EOF
confirm "FLASH S50 VENDOR_DLKM EXPERIMENT" || die "отменено пользователем (ничего не записано)"

echo "=== 1/3 vbmeta_a (загрузчик) ==="
"$FASTBOOT" flash vbmeta_a "$ART/vbmeta.img" || die "запись vbmeta_a не удалась — vendor_dlkm не тронут; восстановите стоковый vbmeta_a"

echo "=== 2/3 переход в fastbootd ==="
"$FASTBOOT" reboot fastboot || die "не удалось перейти в fastbootd"
wait_fb yes || die "fastbootd не появился за 3 минуты (стоковый vbmeta_a восстанавливается из загрузчика)"
[[ "$(gv current-slot)" == a ]] || die "fastbootd сообщает current-slot=$(gv current-slot)"
[[ "$(gv is-logical:vendor_dlkm_a)" == yes ]] || die "vendor_dlkm_a не виден как логический раздел"

echo "=== 3/3 vendor_dlkm_a (fastbootd) ==="
"$FASTBOOT" flash vendor_dlkm_a "$ART/vendor_dlkm.img" || die "запись vendor_dlkm_a не удалась"

echo "=== Запись завершена. Возврат в загрузчик (система НЕ загружается автоматически) ==="
"$FASTBOOT" reboot bootloader || die "не удалось вернуться в загрузчик (разделы уже записаны)"
wait_fb no || die "загрузчик не появился за 3 минуты (разделы уже записаны)"
echo
echo "Записаны vbmeta_a и vendor_dlkm_a. Ещё можно, не загружая систему, вернуть сток:"
echo "  bash $HERE/90-restore-stock.sh --i-understand"
final_boot_prompt || true
echo
echo "После загрузки (первая загрузка может занять 3–5 минут):"
echo "  bash $HERE/00-readonly-diagnostics.sh"
echo "  Ожидается: uname -a без изменений; ro.boot.vbmeta.digest ДРУГОЙ (это нормально);"
echo "  в 12-modules.txt у /sys/module/cpufreq_sugov_ext/parameters есть"
echo "  rl_bypass_on_limits и iowait_boost_enable."
echo "Если система не загрузилась за 10 минут: Питание + Громкость вниз до загрузчика, затем"
echo "  bash $HERE/90-restore-stock.sh --i-understand"
echo "  (если загрузчик сам переключился на слот B: добавьте --set-active-a)"
echo "Журнал: $LOG"
