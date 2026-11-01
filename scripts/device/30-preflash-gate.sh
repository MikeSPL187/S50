#!/usr/bin/env bash
# =============================================================================
#  Предполётная проверка перед ЭКСПЕРИМЕНТАЛЬНОЙ установкой vendor_dlkm.
#  ТОЛЬКО ЧТЕНИЕ: fastboot getvar, проверка файлов. Ничего не прошивает.
#
#  Телефон должен быть в режиме загрузчика (adb reboot bootloader).
#  Использование:
#     bash 30-preflash-gate.sh <каталог-артефакта> [каталог-бэкапа]
#  <каталог-артефакта> содержит vendor_dlkm.img, vbmeta.img, SHA256SUMS
#  (результат scripts/host/make-vendor-dlkm.sh).
# =============================================================================
set -Euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
ART=$(realpath "${1:?каталог артефакта}")
BAK=$(realpath "${2:-$HOME/moto-kernel/backup-W1UI36H.39-25-11-4}")
FASTBOOT=${FASTBOOT:-$HOME/moto-tools/platform-tools/fastboot}
HOSTTOOLS=${HOSTTOOLS:-$HOME/moto-kernel/hosttools}
export AVBTOOL=${AVBTOOL:-$HOSTTOOLS/avbtool.py}
FAIL=0
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [СТОП] %s\n' "$*"; FAIL=1; }
warn() { printf '  [ВНИМ] %s\n' "$*"; }
gv() { local l; l=$("$FASTBOOT" getvar "$1" 2>&1 | tr -d '\r' | grep -F -- "$1: " | head -n1); printf '%s' "${l#*: }"; }

echo "== Артефакт: $ART"
[[ -f "$ART/vendor_dlkm.img" && -f "$ART/vbmeta.img" && -f "$ART/SHA256SUMS" ]] || { bad "нет vendor_dlkm.img/vbmeta.img/SHA256SUMS"; }
( cd "$ART" && sha256sum -c --quiet SHA256SUMS ) && ok "SHA256SUMS артефакта" || bad "контрольные суммы артефакта"
python3 -I "$AVBTOOL" verify_image --image "$ART/vendor_dlkm.img" >/dev/null 2>&1 && ok "hashtree vendor_dlkm.img валиден" || bad "hashtree vendor_dlkm.img"
python3 -I "$HERE/tools/vbmeta_diff.py" "$BAK/vbmeta.img" "$ART/vbmeta.img" > "$ART/gate-vbmeta-diff.txt" 2>&1 \
  && ok "vbmeta: изменён только дескриптор vendor_dlkm (rollback index/flags как в стоке)" || bad "vbmeta отличается не только vendor_dlkm (см. gate-vbmeta-diff.txt)"
a=$(python3 -I "$AVBTOOL" info_image --image "$ART/vbmeta.img" | awk '/Partition Name: *vendor_dlkm/{f=1} f&&/Root Digest/{print $3; exit}')
b=$(python3 -I "$AVBTOOL" info_image --image "$ART/vendor_dlkm.img" | awk '/Root Digest/{print $3; exit}')
[[ -n "$a" && "$a" == "$b" ]] && ok "root digest vbmeta == footer vendor_dlkm.img" || bad "root digest не совпадает"
[[ $(stat -c %s "$ART/vendor_dlkm.img") -le $(stat -c %s "$BAK/vendor_dlkm_a.img") ]] && ok "размер образа ≤ стокового раздела (изменение super не нужно)" || warn "образ больше стокового раздела: fastbootd изменит размер логического раздела"

echo "== Резервная копия: $BAK"
( cd "$BAK" && sha256sum -c --quiet EXPECTED.txt ) && ok "стоковые образы совпадают с эталоном" || bad "резервная копия повреждена/отсутствует (сначала 20-backup-stock.sh)"
[[ -f "$BAK/DEVICE-MATCH.txt" ]] && ok "ранее подтверждено: телефон работает на этих образах (vbmeta.digest)" || bad "нет подтверждения DEVICE-MATCH.txt (запустите 20-backup-stock.sh при включённом adb)"

echo "== Устройство (fastboot, только getvar)"
[[ -x "$FASTBOOT" ]] || { bad "нет fastboot: $FASTBOOT"; exit 1; }
n=$("$FASTBOOT" devices | awk '$2=="fastboot"' | wc -l)
[[ "$n" -eq 1 ]] && ok "ровно одно устройство fastboot" || { bad "устройств fastboot: $n"; exit 1; }
v=$(gv product);       [[ "$v" == vienna ]]   && ok "product=$v" || bad "product=$v"
v=$(gv sku);           [[ "$v" == XT2409-5 ]] && ok "sku=$v" || bad "sku=$v"
v=$(gv cid);           [[ "$v" == 0x000B ]]   && ok "cid=$v (аппаратный CID 11 — ожидаемо)" || bad "cid=$v"
v=$(gv ro.carrier);    [[ "$v" == teleu ]]    && ok "ro.carrier=$v" || warn "ro.carrier=$v"
v=$(gv is-userspace);  [[ "$v" == no ]]       && ok "режим загрузчика (не fastbootd)" || bad "is-userspace=$v (нужен загрузчик)"
v=$(gv current-slot);  [[ "$v" == a ]]        && ok "current-slot=a (артефакт рассчитан на _a)" || bad "current-slot=$v"
v=$(gv slot-successful:_a); [[ "$v" == yes ]] && ok "slot-successful:_a=yes" || warn "slot-successful:_a=$v"
v=$(gv slot-unbootable:_a); [[ "$v" == no ]]  && ok "slot-unbootable:_a=no" || bad "slot-unbootable:_a=$v"
v=$(gv securestate);   [[ "$v" == *unlock* ]] && ok "securestate=$v" || warn "securestate='$v' — убедитесь, что загрузчик РАЗБЛОКИРОВАН (ro.boot.flash.locked=0)"
v=$(gv has-slot:vbmeta); [[ "$v" == yes ]]    && ok "has-slot:vbmeta=yes" || warn "has-slot:vbmeta=$v"
v=$(gv snapshot-update-status); [[ -z "$v" || "$v" == none ]] && ok "snapshot-update-status=${v:-<пусто>} (нет незавершённого OTA)" || bad "snapshot-update-status=$v — незавершённое OTA, не прошивать"
echo "  (инфо) version-bootloader: $(gv version-bootloader)"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ПРЕДПОЛЁТНАЯ ПРОВЕРКА ПРОЙДЕНА. Ничего не изменено."
  echo "Следующий шаг выполняется ТОЛЬКО вручную и только после вашего решения:"
  echo "   bash 40-flash-experimental-vendor-dlkm.sh '$ART'"
else
  echo "ПРОВЕРКА НЕ ПРОЙДЕНА. Прошивка запрещена. Ничего не изменено."
fi
exit $FAIL
