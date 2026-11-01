#!/usr/bin/env bash
# Download the exact toolchain and AOSP host tools (pinned revisions):
#   * clang-r487747c (17.0.2) — the compiler named in the stock "Linux version"
#   * avbtool.py, mkbootimg.py, unpack_bootimg.py
#
#   setup-toolchain.sh <dir>     (e.g. ~/moto-kernel)
# Creates <dir>/clang-r487747c and <dir>/hosttools.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
DIR=$(realpath -m "${1:?target dir}")
LOCK="$HERE/manifest/sources.lock"
mkdir -p "$DIR/hosttools/gki"
rev() { awk -v u="$1" '$1==u {print $3}' "$LOCK"; }

CLANG_REV=$(rev https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86)
if [[ ! -x "$DIR/clang-r487747c/bin/clang" ]]; then
  echo "downloading clang-r487747c @ $CLANG_REV (~720 MB)"
  mkdir -p "$DIR/clang-r487747c"
  curl -fL --retry 5 "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/$CLANG_REV/clang-r487747c.tar.gz" \
    | tar -xz -C "$DIR/clang-r487747c"
fi
"$DIR/clang-r487747c/bin/clang" --version | head -n1 | grep -q 'based on r487747c' \
  || { echo "unexpected clang version" >&2; exit 1; }

AVB_REV=$(rev https://android.googlesource.com/platform/external/avb)
MKB_REV=$(rev https://android.googlesource.com/platform/system/tools/mkbootimg)
get() { curl -fsSL "$1?format=TEXT" | base64 -d > "$2"; }
get "https://android.googlesource.com/platform/external/avb/+/$AVB_REV/avbtool.py" "$DIR/hosttools/avbtool.py"
for f in mkbootimg.py unpack_bootimg.py repack_bootimg.py gki/generate_gki_certificate.py; do
  get "https://android.googlesource.com/platform/system/tools/mkbootimg/+/$MKB_REV/$f" "$DIR/hosttools/$f"
done
python3 -I "$DIR/hosttools/avbtool.py" version
echo "toolchain ready in $DIR"
