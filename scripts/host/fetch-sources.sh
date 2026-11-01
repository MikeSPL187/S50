#!/usr/bin/env bash
# Fetch every source tree at the exact commit pinned in manifest/sources.lock
# (shallow, depth 1) and verify the peeled commit SHA.  Idempotent.
#
#   fetch-sources.sh <src-root>
#
# Layout produced:
#   <src-root>/common            AOSP kernel/common   @ android14-6.1-2025-12_r29 (GKI of boot.img)
#   <src-root>/kernel-mtk        Motorola kernel-mtk  @ MMI-W1UI36H.39-25-11-4  (KERNEL_DIR for vendor modules)
#   <src-root>/kdm               kernel_device_modules-6.1 @ MMI-W1UI36H.39-25-11-4
#   <src-root>/kdm-patched       same + patches/kernel_device_modules-6.1/*.patch (git am)
#   <src-root>/motorola-kernel-modules, <src-root>/bazel_mgk_rules  (reference)
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=$(realpath -m "${1:?src root}")
LOCK="$HERE/manifest/sources.lock"
mkdir -p "$ROOT"

pin() { awk -v u="$1" '$1==u {print $2, $3}' "$LOCK"; }

fetch() {  # fetch <dir> <url>
  local dir="$1" url="$2" ref sha
  read -r ref sha < <(pin "$url")
  [[ -n "$sha" ]] || { echo "no pin for $url" >&2; exit 1; }
  if [[ -d "$dir/.git" ]] && [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$sha" ]]; then
    echo "ok   $dir @ $sha"; return
  fi
  rm -rf "$dir"; git init -q "$dir"
  git -C "$dir" fetch -q --depth=1 "$url" "$ref"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  local got; got=$(git -C "$dir" rev-parse HEAD)
  [[ "$got" == "$sha" ]] || { echo "SHA MISMATCH $url: got $got want $sha" >&2; exit 1; }
  # No tag refs: setlocalversion must see an untagged commit (as Google CI did).
  git -C "$dir" tag -l | xargs -r git -C "$dir" tag -d >/dev/null
  echo "got  $dir @ $sha"
}

fetch "$ROOT/common"     https://android.googlesource.com/kernel/common
fetch "$ROOT/kernel-mtk" https://github.com/MotorolaMobilityLLC/kernel-mtk
fetch "$ROOT/kdm"        https://github.com/MotorolaMobilityLLC/kernel-kernel_device_modules-6.1
fetch "$ROOT/motorola-kernel-modules" https://github.com/MotorolaMobilityLLC/motorola-kernel-modules
fetch "$ROOT/bazel_mgk_rules" https://github.com/MotorolaMobilityLLC/kernel-build-bazel_mgk_rules

# Patched copy of the device-modules tree as a separate worktree-like clone.
if [[ ! -d "$ROOT/kdm-patched/.git" ]]; then
  git clone -q --no-checkout "$ROOT/kdm" "$ROOT/kdm-patched"
  git -C "$ROOT/kdm-patched" -c advice.detachedHead=false checkout -q "$(git -C "$ROOT/kdm" rev-parse HEAD)"
  git -C "$ROOT/kdm-patched" checkout -q -b vienna-perf
  git -C "$ROOT/kdm-patched" -c user.name=s50 -c user.email=s50@localhost \
    am -q "$HERE"/patches/kernel_device_modules-6.1/*.patch
  echo "patched $ROOT/kdm-patched: $(git -C "$ROOT/kdm-patched" log --oneline | head -n 3 | tr '\n' ';')"
fi
