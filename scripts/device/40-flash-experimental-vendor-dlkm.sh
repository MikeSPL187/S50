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
BAK=${BAK:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
HOSTTOOLS=${HOSTTOOLS:-$HOME/moto-kernel/hosttools}
AVBTOOL=${AVBTOOL:-$HOSTTOOLS/avbtool.py}
JOURNAL="$BAK/EXPERIMENT-STATE.txt"
LOG="$HOME/moto-kernel/flash-experimental-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
# shellcheck source=expected/W1UI36H.39-25-11-4.env
source "$HERE/expected/W1UI36H.39-25-11-4.env"
# shellcheck source=lib-fastboot.sh
source "$HERE/lib-fastboot.sh"
jlog() { echo "event=$1 epoch=$(date +%s) time=$(date -Iseconds)${2:+ $2}" >> "$JOURNAL"; }
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\nОткат: bash %s/90-restore-stock.sh --i-understand\n' "$*" "$LOG" "$HERE" >&2; exit 1; }

echo "=== Предполётная проверка ==="
HOSTTOOLS="$HOSTTOOLS" AVBTOOL="$AVBTOOL" bash "$HERE/30-preflash-gate.sh" "$ART" "$BAK" || die "предполётная проверка не пройдена"
# Ожидаемый ro.boot.vbmeta.digest экспериментального состояния (vbmeta артефакта + стоковый vbmeta_system):
# по нему 90-restore-stock.sh узнает это состояние, пока Android работает.
TMPD=$(mktemp -d); cp "$ART/vbmeta.img" "$BAK/vbmeta_system.img" "$TMPD/"
EXP_DIGEST_NEW=$(python3 -I "$AVBTOOL" calculate_vbmeta_digest --image "$TMPD/vbmeta.img" --hash_algorithm sha256)
rm -rf "$TMPD"
[[ "$EXP_DIGEST_NEW" =~ ^[0-9a-f]{64}$ ]] || die "не удалось вычислить vbmeta.digest артефакта"
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
jlog prepared "build=$EXP_BUILD_ID slot=$(gv current-slot) bootloader=$(gvm version-bootloader | tr ' ' '_') exp_vbmeta_digest=$EXP_DIGEST_NEW artifact_vendor_dlkm_sha256=$(sha256sum "$ART/vendor_dlkm.img" | cut -d' ' -f1) artifact_vbmeta_sha256=$(sha256sum "$ART/vbmeta.img" | cut -d' ' -f1)"

echo "=== 1/3 vbmeta_a (загрузчик) ==="
"$FASTBOOT" flash vbmeta_a "$ART/vbmeta.img" || die "запись vbmeta_a не удалась — vendor_dlkm не тронут; восстановите стоковый vbmeta_a"
jlog vbmeta_a_written

echo "=== 2/3 переход в fastbootd ==="
"$FASTBOOT" reboot fastboot || die "не удалось перейти в fastbootd"
wait_fb yes || die "fastbootd не появился за 3 минуты (стоковый vbmeta_a восстанавливается из загрузчика)"
[[ "$(gv current-slot)" == a ]] || die "fastbootd сообщает current-slot=$(gv current-slot)"
[[ "$(gv is-logical:vendor_dlkm_a)" == yes ]] || die "vendor_dlkm_a не виден как логический раздел"

echo "=== 3/3 vendor_dlkm_a (fastbootd) ==="
"$FASTBOOT" flash vendor_dlkm_a "$ART/vendor_dlkm.img" || die "запись vendor_dlkm_a не удалась"
jlog vendor_dlkm_a_written

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
echo "  rl_bypass_on_limits и iowait_boost_enable; ro.boot.vbmeta.digest = $EXP_DIGEST_NEW."
echo "Журнал эксперимента (нужен для отката): $JOURNAL"
echo "Если система не загрузилась за 10 минут: Питание + Громкость вниз до загрузчика, затем"
echo "  bash $HERE/90-restore-stock.sh --i-understand"
echo "  (если загрузчик сам переключился на слот B: добавьте --set-active-a)"
echo "Журнал: $LOG"
