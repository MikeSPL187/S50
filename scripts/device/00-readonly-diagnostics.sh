#!/usr/bin/env bash
# =============================================================================
#  Motorola Moto S50 (XT2409-5) — read-only diagnostics over ADB (no root).
#
#  НИЧЕГО НЕ ЗАПИСЫВАЕТ В ТЕЛЕФОН. Только чтение свойств, /proc, /sys, dumpsys.
#  Результат: каталог ~/moto-kernel/diag-YYYYmmdd-HHMMSS/ + SHA256SUMS.
#  Серийный номер, IMEI и т. п. не собираются; строки с ними вырезаются.
#
#  Запуск на Steam Deck (Konsole):
#     bash 00-readonly-diagnostics.sh
#  Переменные: ADB=/путь/к/adb (по умолчанию ~/moto-tools/platform-tools/adb)
# =============================================================================
set -Euo pipefail

ADB=${ADB:-$HOME/moto-tools/platform-tools/adb}
OUT=${OUT:-$HOME/moto-kernel/diag-$(date +%Y%m%d-%H%M%S)}

# Ожидаемые значения для сборки W1UI36H.39-25-11-4 (получены из пакета прошивки
# с SHA-256 6bc78abc...f6a3, см. docs/01-source-audit.md).
EXPECT_KREL='6.1.157-android14-11-g14047afecd8b-ab16012876'
EXPECT_VBMETA_DIGEST='9935ea56ba7359951d5856863727e3c45bce416cb6d18f36f215ebc9b63ccc23'
EXPECT_FINGERPRINT='motorola/vienna_g_sys/vienna:16/W1UI36H.39-25-11-4/2734cd-58da6:user/release-keys'
# Полная строка /proc/version стокового Image (содержит время сборки ядра).
EXPECT_PROC_VERSION='Linux version 6.1.157-android14-11-g14047afecd8b-ab16012876 (build-user@build-host) (Android (10087095, +pgo, +bolt, +lto, -mlgo, based on r487747c) clang version 17.0.2 (https://android.googlesource.com/toolchain/llvm-project d9f89f4d16663d5012e5c09495f3b30ece3d2362), LLD 17.0.2) #1 SMP PREEMPT Tue Aug  4 11:44:32 UTC 2026'
# Из system/etc/ramdisk/build.prop рамдиска init_boot.img.
EXPECT_BOOTIMAGE_UTC='1788995558'

die() { printf 'ОСТАНОВКА: %s\n' "$*" >&2; exit 1; }
[[ -x "$ADB" ]] || die "не найден adb: $ADB"
mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
[[ ${#DEVS[@]} -eq 1 ]] || die "нужно ровно одно устройство в режиме adb 'device', найдено: ${#DEVS[@]}"
mkdir -p "$OUT"
REDACT='s/(serialno|serial|imei|meid|iccid|msisdn|esim|uid|chipid|cpuid|androidboot\.serialno)[^ ]*([=:] *)[^ ]+/\1\2<redacted>/Ig'

# run <file> <adb shell command...>  — never aborts the script
run() {
  local f="$1"; shift
  { echo "# \$ adb shell $*"; timeout 60 "$ADB" shell "$@" 2>&1; echo "# exit=$?"; } \
    | sed -E "$REDACT" > "$OUT/$f"
}

echo "Сбор данных в $OUT ..."
run 01-uname.txt 'uname -a; cat /proc/version'
run 02-props.txt 'for p in ro.product.model ro.product.device ro.boot.hardware ro.hardware \
  ro.build.fingerprint ro.vendor.build.fingerprint ro.build.version.release ro.build.version.sdk \
  ro.build.version.security_patch ro.vendor.build.security_patch ro.boot.slot_suffix \
  ro.boot.verifiedbootstate ro.boot.vbmeta.device_state ro.boot.vbmeta.digest ro.boot.vbmeta.hash_alg \
  ro.boot.vbmeta.size ro.boot.vbmeta.avb_version ro.boot.flash.locked ro.carrier ro.kernel.version \
  ro.board.platform ro.soc.model ro.soc.manufacturer ro.vendor.mtk_platform ro.boot.dynamic_partitions \
  ro.virtual_ab.enabled ro.virtual_ab.compression.enabled ro.boot.dtbo_idx ro.boot.dtb_idx \
  ro.vendor.zram.product_swapon ro.lmk.use_psi ro.lmk.use_minfree_levels ro.lmk.swap_free_low_percentage \
  ro.lmk.thrashing_limit ro.lmk.psi_partial_stall_ms ro.lmk.psi_complete_stall_ms ro.config.low_ram \
  ro.surface_flinger.max_frame_buffer_acquired_buffers ro.vendor.mtk_perf_fast_start_win \
  persist.sys.fflag.override.settings_enable_monitor_phantom_procs vendor.all.modules.ready; do \
  printf "%s=%s\n" "$p" "$(getprop $p)"; done'
run 03-cpuinfo.txt 'cat /proc/cpuinfo; echo; ls /sys/devices/system/cpu/'
run 04-cpufreq.txt 'for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "== $p"; \
  for f in affected_cpus related_cpus scaling_governor scaling_available_governors cpuinfo_min_freq \
  cpuinfo_max_freq scaling_min_freq scaling_max_freq scaling_cur_freq cpuinfo_transition_latency \
  scaling_available_frequencies scaling_boost_frequencies; do printf "%s: " $f; cat $p/$f 2>&1; done; \
  for f in $p/sugov_ext/* $p/schedutil/*; do [ -f "$f" ] && { printf "%s: " "$f"; cat "$f" 2>&1; }; done; \
  [ -d $p/stats ] && { echo "-- time_in_state"; cat $p/stats/time_in_state 2>&1; echo "-- total_trans"; cat $p/stats/total_trans 2>&1; }; done'
run 05-cpuidle.txt 'cat /sys/devices/system/cpu/cpuidle/current_driver /sys/devices/system/cpu/cpuidle/current_governor* 2>&1; \
  for c in /sys/devices/system/cpu/cpu[0-9]*; do for s in $c/cpuidle/state*; do [ -d $s ] || continue; \
  echo "$c $(basename $s) name=$(cat $s/name) lat=$(cat $s/latency) res=$(cat $s/residency) usage=$(cat $s/usage) time=$(cat $s/time) disable=$(cat $s/disable 2>/dev/null)"; done; done'
run 06-sched-sysctl.txt 'for f in sched_pelt_multiplier sched_util_clamp_min sched_util_clamp_max sched_util_clamp_min_rt_default \
  sched_migration_cost_ns sched_child_runs_first sched_latency_ns sched_min_granularity_ns sched_wakeup_granularity_ns \
  sched_rr_timeslice_ms sched_rt_period_us sched_rt_runtime_us sched_energy_aware sched_schedstats; do \
  printf "%s=" $f; cat /proc/sys/kernel/$f 2>&1; done; ls /sys/devices/system/cpu/eas /sys/devices/system/cpu/cpuqos 2>&1 | head -50'
run 07-uclamp-cgroups.txt 'for g in /dev/cpuctl /dev/cpuctl/*/; do echo "== $g"; for f in cpu.uclamp.min cpu.uclamp.max cpu.uclamp.latency_sensitive cpu.shares; do printf "%s=" $f; cat $g/$f 2>&1; done; done; \
  for g in /dev/cpuset/*/; do printf "%s cpus=%s\n" "$g" "$(cat $g/cpus 2>&1)"; done'
run 08-memory.txt 'cat /proc/meminfo; echo; cat /proc/swaps; echo; for f in comp_algorithm disksize mm_stat io_stat bd_stat max_comp_streams; do printf "zram0/%s: " $f; cat /sys/block/zram0/$f 2>&1; done; \
  for f in swappiness page-cluster watermark_scale_factor watermark_boost_factor min_free_kbytes extra_free_kbytes dirty_ratio dirty_background_ratio dirty_bytes dirty_background_bytes vfs_cache_pressure; do printf "vm.%s=" $f; cat /proc/sys/vm/$f 2>&1; done; \
  printf "lru_gen="; cat /sys/kernel/mm/lru_gen/enabled 2>&1; printf "lru_gen min_ttl_ms="; cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>&1'
run 09-psi.txt 'for r in cpu memory io irq; do echo "== $r"; cat /proc/pressure/$r 2>&1; done'
run 10-block.txt 'for b in /sys/block/sd* /sys/block/dm-* /sys/block/zram*; do [ -d $b ] || continue; echo "== $b"; \
  for f in queue/scheduler queue/read_ahead_kb queue/nr_requests queue/rotational queue/iostats queue/rq_affinity queue/nomerges queue/add_random; do printf "%s=" $f; cat $b/$f 2>&1; done; done'
run 11-thermal.txt 'for z in /sys/class/thermal/thermal_zone*; do printf "%s type=%s temp=%s policy=%s\n" $z "$(cat $z/type 2>&1)" "$(cat $z/temp 2>&1)" "$(cat $z/policy 2>&1)"; done; \
  for c in /sys/class/thermal/cooling_device*; do printf "%s type=%s cur=%s max=%s\n" $c "$(cat $c/type 2>&1)" "$(cat $c/cur_state 2>&1)" "$(cat $c/max_state 2>&1)"; done'
run 12-modules.txt 'cat /proc/modules 2>&1 | head -600; echo; for m in cpufreq_sugov_ext scheduler mtk_core_ctl moto_sched task_turbo; do echo "== /sys/module/$m/parameters"; ls /sys/module/$m/parameters 2>&1; done'
run 13-dumpsys-cpuinfo.txt 'dumpsys cpuinfo'
run 14-dumpsys-meminfo.txt 'dumpsys meminfo -c'
run 15-dumpsys-battery.txt 'dumpsys battery; echo; cat /sys/class/power_supply/battery/charge_counter /sys/class/power_supply/battery/current_now /sys/class/power_supply/battery/voltage_now /sys/class/power_supply/battery/temp 2>&1'
run 16-dumpsys-thermal.txt 'dumpsys thermalservice'
run 17-display.txt 'dumpsys display | grep -iE "mode|fps|refresh|renderFrameRate|supportedModes" | head -60; dumpsys SurfaceFlinger | grep -iE "refresh|vsync|fps|present" | head -40'
run 18-power-hal.txt 'dumpsys android.hardware.power.IPower/default 2>&1 | head -80; getprop | grep -iE "vendor\.(powerhal|mtkpower|perf|fpsgo)" | head -60'
run 19-cmdline-bootconfig.txt 'cat /proc/cmdline 2>&1; echo; cat /proc/bootconfig 2>&1'
run 20-lmkd.txt 'getprop | grep -E "ro\.lmk|persist\.device_config\.lmkd" ; dumpsys activity lmk 2>&1 | head -40'
run 21-mounts.txt 'cat /proc/mounts | grep -E " / | /vendor| /vendor_dlkm| /system_dlkm| /data | /product | /system_ext" ; ls -l /dev/block/by-name 2>&1 | head -5'
run 22-perfetto.txt 'which perfetto; perfetto --version 2>&1 | head -3; ls /data/misc/perfetto-traces 2>&1 | head'
# Как MTK грузит модули vendor_dlkm (нужно, чтобы понять, сработает ли A/B через
# modules.options без root): init.insmod.sh и какой modprobe он вызывает.
run 23-module-loading.txt 'ls -l /vendor/bin/init.insmod.sh /vendor/bin/modprobe /system/bin/modprobe 2>&1; echo; head -80 /vendor/bin/init.insmod.sh 2>&1; echo; ls /vendor_dlkm/lib/modules/modules.* 2>&1'

# ---------- автоматические проверки соответствия ----------
g() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }
krel=$(g uname -r)
pver=$(g cat /proc/version)
digest=$(g getprop ro.boot.vbmeta.digest)
fp=$(g getprop ro.build.fingerprint)
bi_utc=$(g getprop ro.bootimage.build.date.utc)
vmode=$(g getprop ro.boot.veritymode)
slot=$(g getprop ro.boot.slot_suffix)
vbs=$(g getprop ro.boot.verifiedbootstate)
chk() { if [[ "$2" == "$3" ]]; then echo "СОВПАДАЕТ  $1"; else echo "ОТЛИЧАЕТСЯ $1: устройство='$2' ожидалось='$3'"; fi; }
{
  echo "=== Проверка: установлена ли ровно та прошивка, которую мы анализировали ==="
  chk "vbmeta (ro.boot.vbmeta.digest)          → vbmeta_a + vbmeta_system_a"   "$digest" "$EXPECT_VBMETA_DIGEST"
  chk "ядро (/proc/version, со временем сборки) → boot_a"                       "$pver"   "$EXPECT_PROC_VERSION"
  chk "init_boot (ro.bootimage.build.date.utc)  → init_boot_a"                  "$bi_utc" "$EXPECT_BOOTIMAGE_UTC"
  chk "dm-verity (ro.boot.veritymode)           → vendor/vendor_dlkm/… проверяются при чтении" "$vmode" "enforcing"
  chk "ro.build.fingerprint" "$fp" "$EXPECT_FINGERPRINT"
  echo "uname -r: $krel   активный слот: $slot   verifiedbootstate: $vbs"
  echo
  echo "Что доказывают совпадения (загрузчик разблокирован = ORANGE, ошибки AVB не останавливают загрузку):"
  echo " * vbmeta.digest — vbmeta_a и vbmeta_system_a побайтно как в пакете;"
  echo " * veritymode=enforcing + успешная загрузка — прочитанные блоки vendor, vendor_dlkm, system_dlkm, system,"
  echo "   system_ext, product соответствуют корням hashtree из этого vbmeta (иначе dm-verity дал бы ошибки чтения);"
  echo " * /proc/version — работает ядро из стокового boot.img этой сборки;"
  echo " * bootimage.date.utc — рамдиск init_boot этой сборки."
  echo " vendor_boot_a и dtbo_a без root напрямую не проверяются (fastboot fetch запрещён на user-сборках);"
  echo " их соответствие следует из журнала прошивки 30.10.2026 (OKAY, MD5 совпали)."
} | tee "$OUT/00-SUMMARY.txt"

( cd "$OUT" && sha256sum ./*.txt > SHA256SUMS )
echo
echo "Готово: $OUT"
echo "Ничего на телефоне не изменено. Пришлите архив каталога (tar czf diag.tgz -C $(dirname "$OUT") $(basename "$OUT"))."
