#!/usr/bin/env bash
# Build the Android GKI kernel (android14-6.1) exactly at the commit that the
# stock Motorola S50 boot.img was built from, with the configuration that is
# embedded in that stock Image (IKCONFIG).  Plain kbuild, no Bazel needed.
#
# Usage:
#   scripts/host/build-gki.sh <common-src> <out-dir> <stock.config> [clang-dir]
#
# Environment knobs (defaults reproduce the stock banner):
#   JOBS                 parallel jobs (default: nproc)
#   GKI_TARGETS          make goals (default: "Image modules")
#   KEEP_RELEASE_STRING  1 = reproduce "6.1.157-android14-11-g<sha>-ab16012876"
#
# What it does NOT do: it does not sign with Google's key (impossible), does not
# produce boot.img, and never talks to a phone.
set -Eeuo pipefail

SRC=$(realpath "${1:?common source dir}")
OUT=$(realpath -m "${2:?output dir}")
STOCK_CONFIG=$(realpath "${3:?stock .config extracted from boot.img}")
CLANG_DIR=$(realpath "${4:-${CLANG_DIR:-/work/toolchain/clang-r487747c}}")
JOBS=${JOBS:-$(nproc)}
GKI_TARGETS=${GKI_TARGETS:-"Image modules"}

[[ -x "$CLANG_DIR/bin/clang" ]] || { echo "clang not found in $CLANG_DIR" >&2; exit 1; }
mkdir -p "$OUT"
LOG_DIR=${LOG_DIR:-$OUT/logs}
mkdir -p "$LOG_DIR"

export PATH="$CLANG_DIR/bin:$PATH"
# Values taken from build.config.{constants,common} of the same tree and from
# the stock "Linux version" banner of boot.img (build 16012876).
export ARCH=arm64 LLVM=1 LLVM_IAS=1
export KCFLAGS="-D__ANDROID_COMMON_KERNEL__"
export BRANCH=android14-6.1 KMI_GENERATION=11
if [[ "${KEEP_RELEASE_STRING:-1}" == 1 ]]; then
  export BUILD_NUMBER=${BUILD_NUMBER:-16012876}
  export KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host KBUILD_BUILD_VERSION=1
  export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Tue Aug  4 11:44:32 UTC 2026"}
fi
# NOTE: Google's CI builds the commit before the release tag exists.  If HEAD
# is exactly at a tag, scripts/setlocalversion drops "-g<sha>" from the
# release string; fetch-sources.sh therefore checks out the commit detached
# and deletes the tag ref.
if git -C "$SRC" describe --exact-match >/dev/null 2>&1; then
  echo "WARNING: HEAD of $SRC is exactly at tag $(git -C "$SRC" describe --exact-match);" \
       "kernelrelease will lack -g<sha>. Delete the local tag ref to reproduce the stock string." >&2
fi
MAKE=(make -C "$SRC" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 "BRANCH=$BRANCH" "KMI_GENERATION=$KMI_GENERATION")

# 1. KMI symbol list used by CONFIG_TRIM_UNUSED_KSYMS (Kleaf flattens the main
#    list plus every list of the aarch64_additional_kmi_symbol_lists filegroup).
python3 -I - "$SRC" <<'EOF'
import re, sys, os
src = sys.argv[1]
bazel = open(os.path.join(src, "BUILD.bazel")).read()
m = re.search(r'name = "aarch64_additional_kmi_symbol_lists",\s*srcs = \[(.*?)\]', bazel, re.S)
lists = ["android/abi_gki_aarch64"] + re.findall(r'"(android/abi_gki_aarch64_[^"]+)"', m.group(1))
syms = set()
for l in lists:
    for line in open(os.path.join(src, l)):
        line = line.split("#", 1)[0].strip()
        if line and not line.startswith("["):
            syms.add(line)
with open(os.path.join(src, "abi_symbollist.raw"), "w") as f:
    f.write("\n".join(sorted(syms)) + "\n")
print(f"abi_symbollist.raw: {len(syms)} symbols from {len(lists)} lists")
EOF

# 2. Configuration = stock IKCONFIG, re-validated by Kconfig.
cp "$STOCK_CONFIG" "$OUT/.config"
"${MAKE[@]}" olddefconfig 2>&1 | tee "$LOG_DIR/olddefconfig.log"
# Show every difference to the stock file (expected: none, or only toolchain
# version lines such as CONFIG_PAHOLE_VERSION).
diff -u <(grep -E '^(CONFIG_|# CONFIG_)' "$STOCK_CONFIG" | sort) \
        <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/.config" | sort) > "$LOG_DIR/config-vs-stock.diff" || true
echo "config differences vs stock: $(grep -c '^[-+]C\|^[-+]#' "$LOG_DIR/config-vs-stock.diff" || true) lines (see $LOG_DIR/config-vs-stock.diff)"

# 3. Build.
start=$(date +%s)
# shellcheck disable=SC2086
"${MAKE[@]}" -j"$JOBS" $GKI_TARGETS 2>&1 | tee "$LOG_DIR/build.log"
echo "build time: $(( $(date +%s) - start )) s" | tee -a "$LOG_DIR/build.log"

# 4. Evidence.
{
  echo "kernelrelease: $(cat "$OUT/include/config/kernel.release")"
  (strings "$OUT/arch/arm64/boot/Image" | grep -m1 "Linux version") || true
  sha256sum "$OUT/arch/arm64/boot/Image" "$OUT/vmlinux.symvers" "$OUT/Module.symvers" 2>/dev/null
} | tee "$LOG_DIR/artifacts.txt"
