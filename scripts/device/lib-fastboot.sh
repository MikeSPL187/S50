# shellcheck shell=bash
# Общие функции для scripts/device/*.sh (подключается через `source`).
# Требует переменную FASTBOOT (путь к Google fastboot).

# gv <key> — значение `fastboot getvar <key>`; корректно для ключей с ':'
# (slot-successful:_a): отрезается самый короткий префикс до ": ".
gv() { local l; l=$("$FASTBOOT" getvar "$1" 2>&1 | tr -d '\r' | grep -F -- "$1: " | head -n1); printf '%s' "${l#*: }"; }

fb_count() { "$FASTBOOT" devices | awk '$2=="fastboot" || $2=="fastbootd"' | wc -l; }

# wait_fb yes|no — ждать (до 3 мин) одно устройство fastboot в режиме
# fastbootd (yes) или загрузчика (no).
wait_fb() {
  local _
  for _ in $(seq 1 90); do
    [[ $(fb_count) -eq 1 && "$(gv is-userspace)" == "$1" ]] && return 0
    sleep 2
  done
  return 1
}

# slot_report — состояние обоих слотов (только чтение).
slot_report() {
  local s
  echo "  режим: $([[ "$(gv is-userspace)" == yes ]] && echo fastbootd || echo загрузчик)   current-slot=$(gv current-slot)"
  for s in a b; do
    echo "  слот $s: successful=$(gv slot-successful:_$s) unbootable=$(gv slot-unbootable:_$s) retry-count=$(gv slot-retry-count:_$s)"
  done
}

# confirm "<фраза>" — точный ввод фразы; иначе код 1.
confirm() { local a; read -r -p "Введите в точности: $1 > " a; [[ "$a" == "$1" ]]; }

# final_boot_prompt — устройство в загрузчике: показать слоты и загрузить
# систему только после отдельного подтверждения.
final_boot_prompt() {
  echo
  echo "=== Состояние перед загрузкой системы ==="
  slot_report
  if [[ "$(gv current-slot)" != a || "$(gv slot-unbootable:_a)" == yes ]]; then
    echo "  Слот A не активен или помечен unbootable — загрузка НЕ выполняется."
    return 1
  fi
  echo "Телефон остаётся в загрузчике, пока вы не подтвердите загрузку."
  if confirm "BOOT"; then
    "$FASTBOOT" reboot
    echo "Команда перезагрузки отправлена."
  else
    echo "Загрузка не выполнена. Телефон в загрузчике; продолжить вручную: $FASTBOOT reboot"
  fi
}

# gvm <key> — значение переменной, которое загрузчик Motorola может отдавать
# частями: "key[0]: …", "key[1]: …" (с префиксом "(bootloader) " или без).
# Части склеиваются по порядку; одиночное "key: value" тоже поддерживается.
gvm() {
  "$FASTBOOT" getvar "$1" 2>&1 | tr -d '\r' | awk -v k="$1" '
    { sub(/^\(bootloader\) /, "") }
    index($0, k ": ") == 1 { v = v substr($0, length(k) + 3); next }
    index($0, k "[") == 1 { i = index($0, "]: "); if (i) v = v substr($0, i + 3) }
    END { printf "%s", v }'
}

# build_of_running_bootloader — идентификатор сборки, к которой относится
# работающий загрузчик (lk активного слота): EXP_BUILD_ID, EXP_SLOT_B_BUILD,
# "other:<строка>" или "unknown" (если переменная не читается).
build_of_running_bootloader() {
  local v; v=$(gvm version-bootloader)
  if [[ -z "$v" ]]; then echo unknown
  elif [[ "$v" == *"$EXP_BUILD_ID"* ]]; then echo "$EXP_BUILD_ID"
  elif [[ "$v" == *"$EXP_SLOT_B_BUILD"* ]]; then echo "$EXP_SLOT_B_BUILD"
  else echo "other:$v"; fi
}
