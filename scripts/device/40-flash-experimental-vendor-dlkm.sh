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
#  Откат: bash 90-restore-stock.sh
#
#  Использование:
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
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\nОткат: bash %s/90-restore-stock.sh --i-understand\n' "$*" "$LOG" "$HERE" >&2; exit 1; }
gv() { local l; l=$("$FASTBOOT" getvar "$1" 2>&1 | tr -d '\r' | grep -F -- "$1: " | head -n1); printf '%s' "${l#*: }"; }
wait_fb() {  # wait_fb yes|no  — ждём fastboot в нужном режиме (userspace yes/no)
  for _ in $(seq 1 90); do
    if [[ $("$FASTBOOT" devices | awk '$2=="fastboot"' | wc -l) -eq 1 && "$(gv is-userspace)" == "$1" ]]; then return 0; fi
    sleep 2
  done
  return 1
}

echo "=== Предполётная проверка ==="
bash "$HERE/30-preflash-gate.sh" "$ART" || die "предполётная проверка не пройдена"

cat <<EOF

ВНИМАНИЕ. Будут записаны vbmeta_a и vendor_dlkm_a.
  vendor_dlkm.img sha256: $(sha256sum "$ART/vendor_dlkm.img" | cut -d' ' -f1)
  vbmeta.img      sha256: $(sha256sum "$ART/vbmeta.img" | cut -d' ' -f1)
Последствия: другой ro.boot.vbmeta.digest; инкрементальные OTA не установятся,
пока не выполнен откат (90-restore-stock.sh). Возможна незагрузка — откат из
загрузчика/fastbootd описан в docs/06-safety-and-rollback.md.
EOF
read -r -p 'Для подтверждения введите в точности: FLASH S50 VENDOR_DLKM EXPERIMENT > ' ANSWER
[[ "$ANSWER" == 'FLASH S50 VENDOR_DLKM EXPERIMENT' ]] || die "отменено пользователем (ничего не записано)"

echo "=== 1/3 vbmeta_a (загрузчик) ==="
"$FASTBOOT" flash vbmeta_a "$ART/vbmeta.img" || die "запись vbmeta_a не удалась — vendor_dlkm не тронут; восстановите стоковый vbmeta_a"

echo "=== 2/3 переход в fastbootd ==="
"$FASTBOOT" reboot fastboot || die "не удалось перейти в fastbootd"
wait_fb yes || die "fastbootd не появился за 3 минуты (стоковый vbmeta_a восстанавливается из загрузчика)"
[[ "$(gv is-logical:vendor_dlkm_a)" == yes ]] || die "vendor_dlkm_a не логический раздел?"

echo "=== 3/3 vendor_dlkm_a (fastbootd) ==="
"$FASTBOOT" flash vendor_dlkm_a "$ART/vendor_dlkm.img" || die "запись vendor_dlkm_a не удалась"

echo "=== Завершено. Перезагрузка в систему ==="
"$FASTBOOT" reboot
cat <<EOF

После загрузки (ожидайте до 3–5 минут при первой загрузке):
  bash $HERE/00-readonly-diagnostics.sh
  Ожидается: uname -r без изменений; vbmeta.digest ДРУГОЙ (это нормально);
  в 12-modules.txt у /sys/module/cpufreq_sugov_ext/parameters есть
  rl_bypass_on_limits и iowait_boost_enable.
Если телефон не загружается > 10 минут: удерживайте Питание+Громкость вниз до
загрузчика и выполните: bash $HERE/90-restore-stock.sh --i-understand
Журнал: $LOG
EOF
