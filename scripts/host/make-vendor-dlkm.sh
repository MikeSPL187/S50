#!/usr/bin/env bash
# Repack the STOCK vendor_dlkm image with a set of replacement kernel modules
# and produce a matching vbmeta image.  Host-only; never talks to a phone.
#
#   make-vendor-dlkm.sh <stock_vendor_dlkm.img> <stock_vbmeta.img> <out-dir> [replacement.ko ...]
#
# With no replacement modules this is a "null repack" used to validate the
# pipeline (content and metadata must be identical to stock).
#
# Steps
#   1. extract stock EROFS (fsck.erofs --preserve) and read every file's
#      mode/uid/gid/SELinux label from the image itself (tools/erofs_meta.py);
#   2. replace only modules that already exist under lib/modules/ (refuses new
#      names, so modules.dep/modules.load stay valid);
#   3. mkfs.erofs with lz4hc, fixed timestamp, stock UUID, exact per-path
#      file_contexts generated from stock labels;
#   4. file-by-file comparison against stock (only replaced .ko may differ);
#   5. avbtool add_hashtree_footer (sha256, 4 KiB blocks, as stock; no FEC);
#   6. new vbmeta = all stock descriptors (props, vbmeta_system chain, boot,
#      dtbo, init_boot, vendor_boot, product, system_dlkm, vendor) with ONLY
#      the vendor_dlkm hashtree descriptor replaced; rollback index 27, flags 0;
#      signed with a locally generated key (the OEM key is not available; on an
#      UNLOCKED bootloader this yields an "orange" boot, same as now).
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
STOCK_IMG=$(realpath "${1:?stock vendor_dlkm image}")
STOCK_VBMETA=$(realpath "${2:?stock vbmeta image}")
OUT=$(realpath -m "${3:?output dir}")
shift 3
REPL=("$@")
AVBTOOL=${AVBTOOL:-/work/hosttools/avbtool.py}
TOOLS=$HERE/tools
mkdir -p "$OUT"; rm -rf "$OUT/stock-root" "$OUT/new-root"
log() { printf '[make-vendor-dlkm] %s\n' "$*"; }

log "1/6 extract stock"
fsck.erofs --extract="$OUT/stock-root" --preserve "$STOCK_IMG" >/dev/null
fsck.erofs --extract="$OUT/new-root" --preserve "$STOCK_IMG" >/dev/null
UUID=$(dump.erofs -s "$STOCK_IMG" | awk -F': *' '/Filesystem UUID/{print $2}')

log "2/6 replace modules: ${#REPL[@]}"
for ko in "${REPL[@]}"; do
  base=$(basename "$ko")
  dst="$OUT/new-root/lib/modules/$base"
  [[ -f "$dst" ]] || { echo "refusing to add new module $base (not in stock vendor_dlkm)" >&2; exit 1; }
  install -m 0644 -o 0 -g 0 "$ko" "$dst"
  log "   replaced $base"
done

log "3/6 mkfs.erofs"
python3 -I "$TOOLS/erofs_meta.py" fcontexts "$STOCK_IMG" "$OUT/stock-root" --mount-point /vendor_dlkm > "$OUT/file_contexts"
rm -f "$OUT/vendor_dlkm.img"
mkfs.erofs -zlz4hc,9 -T 1230768000 -U "$UUID" --mount-point=/vendor_dlkm \
  --file-contexts="$OUT/file_contexts" "$OUT/vendor_dlkm.img" "$OUT/new-root" > "$OUT/mkfs.log" 2>&1
fsck.erofs "$OUT/vendor_dlkm.img" >/dev/null

log "4/6 compare with stock"
rm -rf "$OUT/check-root"; fsck.erofs --extract="$OUT/check-root" --preserve "$OUT/vendor_dlkm.img" >/dev/null
python3 -I "$TOOLS/erofs_meta.py" diff "$STOCK_IMG" "$OUT/stock-root" "$OUT/vendor_dlkm.img" "$OUT/check-root" > "$OUT/diff-vs-stock.txt" || true
ndiff=$(grep -c '^DIFF ' "$OUT/diff-vs-stock.txt" || true)
expect=${#REPL[@]}
unexpected=$(grep '^DIFF ' "$OUT/diff-vs-stock.txt" | grep -v -E "^DIFF /lib/modules/($(printf '%s|' "${REPL[@]##*/}" | sed 's/\./\\./g; s/|$//'))$" || true)
if [[ -n "$unexpected" || "$ndiff" -ne "$expect" ]]; then
  echo "UNEXPECTED differences vs stock (see $OUT/diff-vs-stock.txt):" >&2; echo "$unexpected" >&2; exit 1
fi
log "   only the $expect replaced module(s) differ; labels/modes/owners identical"

log "5/6 AVB hashtree footer"
SALT=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
IMG_SIZE=$(stat -c %s "$OUT/vendor_dlkm.img")
# Prefer the stock logical-partition size (the extracted stock image file is
# exactly the logical partition), so that fastbootd does not need to resize
# anything in super.  Grow in 64 KiB steps only if the data does not fit.
PART=$(stat -c %s "$STOCK_IMG")
while :; do
  MAX=$(python3 -I "$AVBTOOL" add_hashtree_footer --partition_size "$PART" --calc_max_image_size \
        --hash_algorithm sha256 --do_not_generate_fec)
  [[ "$MAX" -ge "$IMG_SIZE" ]] && break
  PART=$(( PART + 65536 ))
done
echo "partition_size=$PART image_size=$IMG_SIZE" > "$OUT/sizes.txt"
python3 -I "$AVBTOOL" add_hashtree_footer --image "$OUT/vendor_dlkm.img" --partition_name vendor_dlkm \
  --partition_size "$PART" --hash_algorithm sha256 --salt "$SALT" --do_not_generate_fec \
  --prop com.android.build.vendor_dlkm.os_version:14 >/dev/null
python3 -I "$AVBTOOL" info_image --image "$OUT/vendor_dlkm.img" > "$OUT/vendor_dlkm.avbinfo.txt"

log "6/6 vbmeta"
[[ -f "$OUT/test_vbmeta_key.pem" ]] || openssl genrsa -out "$OUT/test_vbmeta_key.pem" 2048 2>/dev/null
python3 -I "$AVBTOOL" make_vbmeta_image --output "$OUT/vbmeta.img" \
  --algorithm SHA256_RSA2048 --key "$OUT/test_vbmeta_key.pem" \
  --rollback_index 27 --rollback_index_location 0 --flags 0 --padding_size 4096 \
  --include_descriptors_from_image "$STOCK_VBMETA" \
  --include_descriptors_from_image "$OUT/vendor_dlkm.img"
python3 -I "$AVBTOOL" info_image --image "$OUT/vbmeta.img" > "$OUT/vbmeta.avbinfo.txt"
python3 -I "$AVBTOOL" info_image --image "$STOCK_VBMETA" > "$OUT/vbmeta.stock.avbinfo.txt"
python3 -I "$TOOLS/vbmeta_diff.py" "$STOCK_VBMETA" "$OUT/vbmeta.img" | tee "$OUT/vbmeta-diff.txt"

( cd "$OUT" && sha256sum vendor_dlkm.img vbmeta.img > SHA256SUMS )
log "done: $OUT/vendor_dlkm.img $OUT/vbmeta.img"
