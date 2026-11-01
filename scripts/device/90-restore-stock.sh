#!/usr/bin/env bash
# =============================================================================
#  ОТКАТ К СТОКУ W1UI36H.39-25-11-4 (слот A).   НЕ ЗАПУСКАЕТСЯ АВТОМАТИЧЕСКИ.
#
#  По умолчанию восстанавливает то, что меняет экспериментальная установка:
#     vbmeta_a (загрузчик) + vendor_dlkm_a (fastbootd)
#  С --all дополнительно перезаписывает boot_a, init_boot_a, vendor_boot_a,
#  dtbo_a, vbmeta_system_a, system_dlkm_a стоковыми образами (на случай других
#  экспериментов).  НИКОГДА не трогает GPT, preloader, lk, nvdata, efuse, modem,
#  userdata, слот B.  Загрузчик не блокируется.
#
#  Использование (телефон в режиме загрузчика):
#     bash 90-restore-stock.sh --i-understand [--all]
# =============================================================================
set -Eeuo pipefail
[[ "${1:-}" == "--i-understand" ]] || { echo "Нужен аргумент --i-understand"; exit 2; }
ALL=0; [[ "${2:-}" == "--all" ]] && ALL=1
BAK=${BAK:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
LOG="$HOME/moto-kernel/restore-stock-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
die() { printf '\n=== ОСТАНОВКА: %s ===\nЖурнал: %s\n' "$*" "$LOG" >&2; exit 1; }
gv() { local l; l=$("$FASTBOOT" getvar "$1" 2>&1 | tr -d '\r' | grep -F -- "$1: " | head -n1); printf '%s' "${l#*: }"; }
wait_fb() { for _ in $(seq 1 90); do [[ $("$FASTBOOT" devices | awk '$2=="fastboot"' | wc -l) -eq 1 && "$(gv is-userspace)" == "$1" ]] && return 0; sleep 2; done; return 1; }

( cd "$BAK" && sha256sum -c EXPECTED.txt ) || die "резервная копия не совпадает с эталоном — не используйте её"
[[ $("$FASTBOOT" devices | awk '$2=="fastboot"' | wc -l) -eq 1 ]] || die "нужно ровно одно устройство fastboot"
[[ "$(gv product)" == vienna && "$(gv sku)" == XT2409-5 ]] || die "это не vienna / XT2409-5"
[[ "$(gv is-userspace)" == no ]] || die "нужен режим загрузчика, а не fastbootd"
echo "current-slot=$(gv current-slot) — восстанавливается слот A"
read -r -p 'Введите в точности: RESTORE S50 STOCK > ' A
[[ "$A" == 'RESTORE S50 STOCK' ]] || die "отменено (ничего не записано)"

"$FASTBOOT" flash vbmeta_a "$BAK/vbmeta.img" || die "vbmeta_a"
if [[ $ALL -eq 1 ]]; then
  for p in boot init_boot vendor_boot dtbo vbmeta_system; do
    "$FASTBOOT" flash "${p}_a" "$BAK/$p.img" || die "${p}_a"
  done
fi
"$FASTBOOT" reboot fastboot || die "переход в fastbootd"
wait_fb yes || die "fastbootd не появился; vbmeta_a уже стоковый, повторите позже"
"$FASTBOOT" flash vendor_dlkm_a "$BAK/vendor_dlkm_a.img" || die "vendor_dlkm_a"
[[ $ALL -eq 1 ]] && { "$FASTBOOT" flash system_dlkm_a "$BAK/system_dlkm_a.img" || die "system_dlkm_a"; }
"$FASTBOOT" reboot
echo
echo "Откат выполнен. После загрузки проверьте: bash 00-readonly-diagnostics.sh"
echo "Ожидается ro.boot.vbmeta.digest = 9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23"
echo "Журнал: $LOG"
