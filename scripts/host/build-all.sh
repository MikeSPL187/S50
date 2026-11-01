#!/usr/bin/env bash
# End-to-end, reproducible pipeline (host only, never touches a phone):
#   sources -> toolchain -> GKI rebuild -> MTK modules (stock + patched)
#   -> KMI gate -> reproducibility gate -> vendor_dlkm + vbmeta artifact.
#
#   build-all.sh <work-dir> <stock-images-dir>
#
# <stock-images-dir> = output of scripts/device/20-backup-stock.sh, i.e. a dir
# with boot.img, vendor_boot.img, vbmeta.img, vbmeta_system.img,
# vendor_dlkm_a.img, system_dlkm_a.img (+ EXPECTED.txt).
#
# Disk: ~12 GB (sources 3.5 GB, clang 2.3 GB, GKI out 2.8 GB, misc).
# Time on Steam Deck (4C/8T): roughly 15-30 min for the GKI build.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
W=$(realpath -m "${1:?work dir}")
STOCK=$(realpath "${2:?stock images dir}")
JOBS=${JOBS:-$(nproc)}
mkdir -p "$W"/{src,out,results}
export HOSTTOOLS="$W/hosttools" AVBTOOL="$W/hosttools/avbtool.py" CLANG_DIR="$W/clang-r487747c"
step() { printf '\n==== %s ====\n' "$*"; }

step "0. verify stock images"
( cd "$STOCK" && sha256sum -c --quiet EXPECTED.txt )

step "1. toolchain + sources"
"$HERE/scripts/host/setup-toolchain.sh" "$W"
"$HERE/scripts/host/fetch-sources.sh" "$W/src"

step "2. unpack stock images (Image, IKCONFIG, module trees)"
S="$W/out/stock"; mkdir -p "$S"
python3 -I "$HOSTTOOLS/unpack_bootimg.py" --boot_img "$STOCK/boot.img" --out "$S/boot" >/dev/null
python3 -I "$HOSTTOOLS/unpack_bootimg.py" --boot_img "$STOCK/vendor_boot.img" --out "$S/vendor_boot" >/dev/null
gzip -dc "$S/boot/kernel" > "$S/boot/Image"
bash "$W/src/common/scripts/extract-ikconfig" "$S/boot/Image" > "$S/stock.config"
mkdir -p "$S/vendor_ramdisk"; ( cd "$S/vendor_ramdisk" && lz4 -dc "$S/vendor_boot/vendor_ramdisk00" | cpio -idm --quiet )
for p in vendor_dlkm_a system_dlkm_a; do rm -rf "$S/$p"; fsck.erofs --extract="$S/$p" --preserve "$STOCK/$p.img" >/dev/null; done
MODDIRS=(--modules "$S/vendor_ramdisk/lib/modules" --modules "$S/vendor_dlkm_a/lib/modules" --modules "$S/system_dlkm_a")

step "3. GKI rebuild (android14-6.1-2025-12_r29, stock IKCONFIG)"
JOBS=$JOBS "$HERE/scripts/host/build-gki.sh" "$W/src/common" "$W/out/gki" "$S/stock.config" "$CLANG_DIR"

step "4. KMI gate: rebuilt GKI vs all stock modules"
python3 -I "$HERE/tools/kmi_check.py" --symvers "$W/out/gki/Module.symvers" "${MODDIRS[@]}" \
  --json "$W/results/kmi-gki.json" | tee "$W/results/kmi-gki.txt" | tail -n 2

step "5. MTK scheduler modules: stock source and patched source"
python3 -I "$HERE/tools/ko2symvers.py" "$S/vendor_dlkm_a/lib/modules" "$S/vendor_ramdisk/lib/modules" "$S/system_dlkm_a" \
  -o "$W/out/stock-vendor.symvers" --exclude scheduler.ko --exclude cpufreq_sugov_ext.ko --exclude mtk_core_ctl.ko \
  --skip-provided-by "$W/out/gki/Module.symvers"
for v in kdm kdm-patched; do
  JOBS=$JOBS "$HERE/scripts/host/build-mtk-modules.sh" "$W/src/kernel-mtk" "$W/src/$v" "$W/out/mgk" "$W/out/mtk-$v" \
    "$W/out/gki/Module.symvers" "$W/out/stock-vendor.symvers" -- drivers/misc/mediatek/sched > "$W/out/mtk-$v.log" 2>&1
done

step "6. reproducibility gate (unmodified source == stock binaries)"
for m in scheduler cpufreq_sugov_ext mtk_core_ctl; do
  python3 -I "$HERE/tools/ko_compare.py" "$S/vendor_dlkm_a/lib/modules/$m.ko" "$W/out/mtk-kdm/ko/$m.ko"
done | tee "$W/results/repro.txt" | grep RESULT
python3 -I "$HERE/tools/ko_compare.py" "$S/vendor_dlkm_a/lib/modules/cpufreq_sugov_ext.ko" \
  "$W/out/mtk-kdm-patched/ko/cpufreq_sugov_ext.ko" --expect-params rl_bypass_on_limits,iowait_boost_enable \
  --allow-new-imports param_ops_bool | tee -a "$W/results/repro.txt" | grep RESULT

step "7. KMI gate with the patched module substituted"
mkdir -p "$W/out/candidate"; cp "$W/out/mtk-kdm-patched/ko/cpufreq_sugov_ext.ko" "$W/out/candidate/"
python3 -I "$HERE/tools/kmi_check.py" --symvers "$W/out/gki/Module.symvers" "${MODDIRS[@]}" \
  --candidate-modules "$W/out/candidate" --json "$W/results/kmi-patched.json" | tee "$W/results/kmi-patched.txt" | tail -n 1

step "8. experimental artifact: vendor_dlkm.img + vbmeta.img"
"$HERE/scripts/host/make-vendor-dlkm.sh" "$STOCK/vendor_dlkm_a.img" "$STOCK/vbmeta.img" "$W/out/artifact" \
  "$W/out/mtk-kdm-patched/ko/cpufreq_sugov_ext.ko" | grep -v '^  same'
echo
echo "Artifact: $W/out/artifact  (NOT flashed; see docs/06-safety-and-rollback.md)"
