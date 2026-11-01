#!/usr/bin/env bash
# Build selected MediaTek/Motorola device modules (kernel_device_modules-6.1)
# out-of-tree with plain kbuild, the way MediaTek's Kleaf "mgk" rules do it:
#
#   kernel tree   : MotorolaMobilityLLC/kernel-mtk  (KERNEL_DIR=kernel-6.1)
#   config        : merge_config.sh -m -r  gki_defconfig + mgk_64_k61_defconfig
#                   + ext_config/moto-mgk_64_k61.config
#                   + ext_config/moto-mgk_64_k61-vienna.config
#                   (bazel_mgk_rules mgk.bzl:_mgk_build_config_impl)
#   KCONFIG_EXT_PREFIX = kernel_device_modules tree
#   LINUXINCLUDE  := -I<kdm>/include $(LINUXINCLUDE)   (kdm/Kbuild)
#   subdir-ccflags += -Werror -I<kdm>/include -I<kdm>/include/uapi
#
# Symbol CRCs for imports are taken from:
#   * vmlinux.symvers / Module.symvers of the GKI build (build-gki.sh)
#   * a symvers file generated from the STOCK vendor modules (their exports)
#
# Usage:
#   build-mtk-modules.sh <kernel-mtk-src> <kdm-tree> <mgk-out> <work-out> \
#                        <symvers>... -- [subdir ...]
#   default subdir: drivers/misc/mediatek/sched
set -Eeuo pipefail

KSRC=$(realpath "${1:?kernel-mtk source}"); shift
KDM=$(realpath "${1:?kernel_device_modules tree}"); shift
MGK_OUT=$(realpath -m "${1:?mgk config/prepare out dir}"); shift
WORK=$(realpath -m "${1:?work/output dir}"); shift
SYMVERS=()
while [[ $# -gt 0 && "$1" != "--" ]]; do SYMVERS+=("$(realpath "$1")"); shift; done
[[ "${1:-}" == "--" ]] && shift
SUBDIRS=("${@:-drivers/misc/mediatek/sched}")
CLANG_DIR=${CLANG_DIR:-/work/toolchain/clang-r487747c}
JOBS=${JOBS:-$(nproc)}
export PATH="$CLANG_DIR/bin:$PATH"
export KCFLAGS="-D__ANDROID_COMMON_KERNEL__"

MAKE=(make -C "$KSRC" O="$MGK_OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 "KCONFIG_EXT_PREFIX=$KDM/")
mkdir -p "$MGK_OUT/arch/arm64/configs" "$WORK/logs"

# Release string of the stock vendor modules is
# "6.1.157-android14-11-gb7fc4b7b6b17" (Motorola's internal kernel commit,
# not published).  The loader ignores it (CONFIG_MODVERSIONS: only the flags
# part of vermagic is compared) but we reproduce it for a 1:1 modinfo.
MGK_SCMVERSION=${MGK_SCMVERSION:--android14-11-gb7fc4b7b6b17}
if [[ "$(cat "$KSRC/.scmversion" 2>/dev/null)" != "$MGK_SCMVERSION" ]]; then
  printf '%s\n' "$MGK_SCMVERSION" > "$KSRC/.scmversion"
  rm -f "$MGK_OUT/scripts/mod/modpost"   # force modules_prepare (new kernel.release)
fi

# 1. Configuration (only once per MGK_OUT).
if [[ ! -f "$MGK_OUT/.config" ]]; then
  CFG="$KDM/arch/arm64/configs"
  KCONFIG_CONFIG="$MGK_OUT/arch/arm64/configs/mgk_vienna_defconfig" \
    "$KSRC/scripts/kconfig/merge_config.sh" -m -r \
      "$KSRC/arch/arm64/configs/gki_defconfig" \
      "$CFG/mgk_64_k61_defconfig" \
      "$CFG/ext_config/moto-mgk_64_k61.config" \
      "$CFG/ext_config/moto-mgk_64_k61-vienna.config" > "$WORK/logs/merge_config.log" 2>&1
  cp "$MGK_OUT/arch/arm64/configs/mgk_vienna_defconfig" "$MGK_OUT/.config"
  "${MAKE[@]}" olddefconfig > "$WORK/logs/olddefconfig.log" 2>&1
fi
if [[ ! -f "$MGK_OUT/scripts/mod/modpost" ]]; then
  "${MAKE[@]}" -j"$JOBS" modules_prepare > "$WORK/logs/modules_prepare.log" 2>&1
fi

# 2. Wrapper external-module directory reproducing kdm/Kbuild include order.
WRAP="$KDM/.s50-wrap"
rm -rf "$WRAP"; mkdir -p "$WRAP"
{
  echo "LINUXINCLUDE := -I$KDM/include \$(LINUXINCLUDE)"
  echo "subdir-ccflags-y += -Werror -I$KDM/include -I$KDM/include/uapi"
  for d in "${SUBDIRS[@]}"; do
    n=$(echo "$d" | tr '/' '_')
    ln -s "$KDM/$d" "$WRAP/$n"
    echo "obj-y += $n/"
  done
} > "$WRAP/Kbuild"

# 3. Build.  -fmacro-prefix-map makes __FILE__ strings identical to the ones
#    in Motorola's build ("../kernel_device_modules-6.1/<subdir>/...").
PREFIX_MAP=""
for d in "${SUBDIRS[@]}"; do
  n=$(echo "$d" | tr '/' '_')
  PREFIX_MAP+=" -fmacro-prefix-map=$WRAP/$n/=../kernel_device_modules-6.1/$d/"
done
export KCFLAGS="$KCFLAGS$PREFIX_MAP"
"${MAKE[@]}" -j"$JOBS" M="$WRAP" \
  "DEVICE_MODULES_PATH=$KDM" "DEVICE_MODULES_REL_DIR=$KDM" \
  "KBUILD_EXTRA_SYMBOLS=${SYMVERS[*]}" KBUILD_MODPOST_WARN=1 \
  modules 2>&1 | tee "$WORK/logs/modules.log"

# 4. Collect: ko-unstripped/ (with DWARF, for debugging) and ko/ stripped with
#    --strip-debug exactly like the modules installed in vendor_dlkm.
mkdir -p "$WORK/ko" "$WORK/ko-unstripped"
find -L "$WRAP" -name '*.ko' -exec cp -f {} "$WORK/ko-unstripped/" \;
for k in "$WORK"/ko-unstripped/*.ko; do
  llvm-strip --strip-debug -o "$WORK/ko/$(basename "$k")" "$k"
done
( cd "$WORK/ko" && sha256sum ./*.ko ) | tee "$WORK/logs/ko.sha256"
