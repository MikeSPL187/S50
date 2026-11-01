#!/usr/bin/env bash
# =============================================================================
#  Воспроизводимые замеры UX/энергии/температуры через ADB, БЕЗ root.
#  Ничего не прошивает и не меняет в разделах. Временные изменения состояния
#  (запуск/остановка приложений, нагрузка CPU в shell) снимаются по завершении.
#
#  Использование (Steam Deck, Konsole):
#     bash 10-baseline-profile.sh [label] [tests]
#     label : метка серии, например stock-run1 / patched-run1
#     tests : через запятую из: launch,scroll,switch,sustained,perfetto
#             (по умолчанию все, кроме sustained — её запускайте отдельно)
#  Переменные:
#     ADB, OUT, REPEAT (повторы запуска, по умолчанию 10),
#     PKGS (список пакетов через пробел), SUSTAIN_SEC (по умолчанию 600)
#
#  ПЕРЕД ЗАПУСКОМ (одинаково для stock и patched — иначе сравнение некорректно):
#   * яркость фиксирована вручную (автояркость выкл), режим экрана 120 Гц как обычно;
#   * батарея 50–90 %, телефон остыл (не менее 10 мин в покое), комнатная температура записана;
#   * одинаковый набор приложений и аккаунтов, Wi-Fi одинаковый;
#   * после перезагрузки подождать 10 минут (завершатся dexopt и фоновые задачи).
# =============================================================================
set -Euo pipefail
ADB=${ADB:-$HOME/moto-tools/platform-tools/adb}
LABEL=${1:-run-$(date +%Y%m%d-%H%M%S)}
TESTS=${2:-launch,scroll,switch,perfetto}
OUT=${OUT:-$HOME/moto-kernel/profile-$LABEL}
REPEAT=${REPEAT:-10}
SUSTAIN_SEC=${SUSTAIN_SEC:-600}
PKGS=${PKGS:-"com.android.settings com.android.chrome com.google.android.apps.messaging com.google.android.dialer com.android.vending"}

die() { printf 'ОСТАНОВКА: %s\n' "$*" >&2; exit 1; }
[[ -x "$ADB" ]] || die "не найден adb: $ADB"
[[ $("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l) -eq 1 ]] || die "нужно ровно одно устройство adb"
sh() { "$ADB" shell "$@" | tr -d '\r'; }
mkdir -p "$OUT"
has() { [[ ",$TESTS," == *",$1,"* ]]; }

# ---------- метаданные серии ----------
{
  echo "label=$LABEL"; echo "date=$(date -Iseconds)"
  echo "kernel=$(sh uname -r)"; echo "fingerprint=$(sh getprop ro.build.fingerprint)"
  echo "vbmeta_digest=$(sh getprop ro.boot.vbmeta.digest)"
  echo "battery_level=$(sh dumpsys battery | awk -F': ' '/level/{print $2; exit}')"
  echo "battery_temp_dC=$(sh dumpsys battery | awk -F': ' '/temperature/{print $2; exit}')"
  echo "screen_brightness=$(sh settings get system screen_brightness)"
  echo "brightness_mode=$(sh settings get system screen_brightness_mode)"
  echo "peak_refresh_rate=$(sh settings get system peak_refresh_rate)"
  echo "min_refresh_rate=$(sh settings get system min_refresh_rate)"
  echo "uptime=$(sh cat /proc/uptime)"
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "$(basename $p)_rate_limits=$(sh "cat $p/sugov_ext/up_rate_limit_us $p/sugov_ext/down_rate_limit_us 2>/dev/null | tr '\n' ' '")"
  done
} > "$OUT/meta.txt"

# Разрешаем только установленные пакеты.
APPS=()
for p in $PKGS; do
  comp=$(sh cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$p" 2>/dev/null | tail -n1)
  [[ "$comp" == */* ]] && APPS+=("$comp")
done
[[ ${#APPS[@]} -gt 0 ]] || die "ни один пакет из PKGS не установлен"
printf '%s\n' "${APPS[@]}" > "$OUT/apps.txt"
read -r W H < <(sh wm size | awk -F'[: x]+' '/Physical size/{print $3, $4}')

go_home() { sh input keyevent KEYCODE_HOME >/dev/null; sleep 1; }

# ---------- 1. Холодный и тёплый запуск ----------
if has launch; then
  echo "[launch] ${#APPS[@]} приложений × $REPEAT повторов (cold + warm)"
  : > "$OUT/launch.tsv"
  for comp in "${APPS[@]}"; do
    pkg=${comp%%/*}
    for i in $(seq 1 "$REPEAT"); do
      sh am force-stop "$pkg"; sleep 2
      res=$(sh am start -W -S -n "$comp")
      printf '%s\tcold\t%s\t%s\t%s\n' "$pkg" "$i" \
        "$(awk -F': ' '/TotalTime/{print $2}' <<<"$res")" "$(awk -F': ' '/WaitTime/{print $2}' <<<"$res")" >> "$OUT/launch.tsv"
      sleep 3; go_home
      res=$(sh am start -W -n "$comp")
      printf '%s\twarm\t%s\t%s\t%s\n' "$pkg" "$i" \
        "$(awk -F': ' '/TotalTime/{print $2}' <<<"$res")" "$(awk -F': ' '/WaitTime/{print $2}' <<<"$res")" >> "$OUT/launch.tsv"
      sleep 2; go_home
    done
    sh am force-stop "$pkg"
  done
fi

# ---------- 2. Прокрутка длинного списка (кадры/jank) ----------
if has scroll; then
  echo "[scroll] Настройки → список, 40 быстрых свайпов × 3 серии"
  for s in 1 2 3; do
    sh am start -W -S -n com.android.settings/.Settings >/dev/null; sleep 3
    sh dumpsys gfxinfo com.android.settings reset >/dev/null
    for k in $(seq 1 20); do
      sh input swipe $((W/2)) $((H*8/10)) $((W/2)) $((H*2/10)) 120; sleep 0.4
      sh input swipe $((W/2)) $((H*2/10)) $((W/2)) $((H*8/10)) 120; sleep 0.4
    done
    sh dumpsys gfxinfo com.android.settings > "$OUT/scroll-gfxinfo-$s.txt"
    sh dumpsys SurfaceFlinger --timestats -dump >/dev/null 2>&1 || true
    go_home
  done
  sh am force-stop com.android.settings
fi

# ---------- 3. Переключение между приложениями ----------
if has switch; then
  echo "[switch] циклическое переключение ${#APPS[@]} приложений × $REPEAT"
  : > "$OUT/switch.tsv"
  for comp in "${APPS[@]}"; do sh am start -W -n "$comp" >/dev/null; sleep 2; done
  for i in $(seq 1 "$REPEAT"); do
    for comp in "${APPS[@]}"; do
      res=$(sh am start -W -n "$comp")
      printf '%s\t%s\t%s\n' "${comp%%/*}" "$i" "$(awk -F': ' '/TotalTime/{print $2}' <<<"$res")" >> "$OUT/switch.tsv"
      sleep 1
    done
  done
  go_home
fi

# ---------- 4. Трасса Perfetto во время прокрутки ----------
if has perfetto; then
  echo "[perfetto] 20 с: sched, freq, idle, gfx, view, input, thermal, battery"
  cat > "$OUT/perfetto.cfg" <<'EOF'
buffers { size_kb: 131072 fill_policy: RING_BUFFER }
data_sources { config { name: "linux.ftrace" ftrace_config {
  ftrace_events: "sched/sched_switch" ftrace_events: "sched/sched_wakeup" ftrace_events: "sched/sched_waking"
  ftrace_events: "power/cpu_frequency" ftrace_events: "power/cpu_idle" ftrace_events: "power/cpu_frequency_limits"
  ftrace_events: "power/suspend_resume" ftrace_events: "thermal/thermal_temperature"
  atrace_categories: "gfx" atrace_categories: "view" atrace_categories: "input" atrace_categories: "am"
  atrace_categories: "wm" atrace_categories: "sched" atrace_categories: "freq" atrace_categories: "binder_driver"
  atrace_apps: "*" } } }
data_sources { config { name: "linux.process_stats" } }
data_sources { config { name: "android.power" android_power_config { battery_poll_ms: 250
  battery_counters: BATTERY_COUNTER_CAPACITY_PERCENT battery_counters: BATTERY_COUNTER_CHARGE
  battery_counters: BATTERY_COUNTER_CURRENT collect_power_rails: true } } }
data_sources { config { name: "android.surfaceflinger.frametimeline" } }
duration_ms: 20000
EOF
  "$ADB" push "$OUT/perfetto.cfg" /data/local/tmp/s50.cfg >/dev/null
  sh am start -W -S -n com.android.settings/.Settings >/dev/null; sleep 2
  sh "cat /data/local/tmp/s50.cfg | perfetto --txt -c - -o /data/misc/perfetto-traces/s50-$LABEL.pftrace --background" >/dev/null
  sleep 2
  for k in $(seq 1 12); do
    sh input swipe $((W/2)) $((H*8/10)) $((W/2)) $((H*2/10)) 120; sleep 0.5
    sh input swipe $((W/2)) $((H*2/10)) $((W/2)) $((H*8/10)) 120; sleep 0.5
  done
  sleep 8
  "$ADB" pull "/data/misc/perfetto-traces/s50-$LABEL.pftrace" "$OUT/" >/dev/null && \
    sh rm -f "/data/misc/perfetto-traces/s50-$LABEL.pftrace" /data/local/tmp/s50.cfg
  go_home
fi

# ---------- 5. Устойчивая нагрузка + температура/частоты ----------
if has sustained; then
  echo "[sustained] $SUSTAIN_SEC с нагрузки 8 потоков shell + выборка каждые 2 с"
  sh 'rm -f /data/local/tmp/s50-burn.pid; for i in 0 1 2 3 4 5 6 7; do (while :; do :; done) & echo $! >> /data/local/tmp/s50-burn.pid; done'
  trap 'sh "kill \$(cat /data/local/tmp/s50-burn.pid) 2>/dev/null; rm -f /data/local/tmp/s50-burn.pid" >/dev/null' EXIT
  hdr="t"; for p in 0 4 7; do hdr+="\tcpu${p}_khz"; done; hdr+="\tbatt_temp_dC\tcurrent_uA\tvoltage_uV\tzones..."
  printf '%b\n' "$hdr" > "$OUT/sustained.tsv"
  end=$(( $(date +%s) + SUSTAIN_SEC ))
  while [[ $(date +%s) -lt $end ]]; do
    line=$(sh 'printf "%s" "$(cat /proc/uptime | cut -d" " -f1)"; for c in 0 4 7; do printf "\t%s" "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)"; done; \
      printf "\t%s\t%s\t%s" "$(cat /sys/class/power_supply/battery/temp 2>/dev/null)" "$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)" "$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)"; \
      for z in /sys/class/thermal/thermal_zone*; do printf "\t%s=%s" "$(cat $z/type)" "$(cat $z/temp 2>/dev/null)"; done')
    printf '%s\n' "$line" >> "$OUT/sustained.tsv"
    sleep 2
  done
  sh "kill \$(cat /data/local/tmp/s50-burn.pid) 2>/dev/null; rm -f /data/local/tmp/s50-burn.pid" >/dev/null
  trap - EXIT
fi

( cd "$OUT" && sha256sum ./* > SHA256SUMS 2>/dev/null )
echo "Готово: $OUT"
echo "Сводка: python3 tools/analyze_profile.py $OUT  (или сравнение: analyze_profile.py A B)"
