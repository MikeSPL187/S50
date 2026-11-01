#!/usr/bin/env bash
# Inventory of the stock firmware package (host-only, read-only on the inputs).
#
#   analyze-firmware.sh <extracted-firmware-dir> <out-dir>
#
# <extracted-firmware-dir> is the directory that contains flashfile.xml,
# boot.img, vendor_boot.img, vbmeta*.img and super.img_sparsechunk.* — on the
# Steam Deck:
#   ~/moto-firmware/extracted/VIENNA_G_SYS_W1UI36H.39_25_11_4_subsidy_DEFAULT_regulatory_DEFAULT_cid50_CFC.xml
#
# Produces <out-dir>/inventory.md plus extracted stock images that the other
# scripts use (boot/Image, stock.config, vendor_boot ramdisk, vendor_dlkm_a.img,
# system_dlkm_a.img, module trees).  Needs: python3, lz4, cpio, fsck.erofs,
# dump.erofs (erofs-utils), AOSP avbtool.py and unpack_bootimg.py
# (scripts/host/setup-toolchain.sh downloads them to $HOSTTOOLS).
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
FW=$(realpath "${1:?extracted firmware dir}")
OUT=$(realpath -m "${2:?output dir}")
HOSTTOOLS=${HOSTTOOLS:-$HOME/moto-kernel/hosttools}
AVBTOOL=${AVBTOOL:-$HOSTTOOLS/avbtool.py}
UNPACK=${UNPACK:-$HOSTTOOLS/unpack_bootimg.py}
KSRC_SCRIPTS=${KSRC_SCRIPTS:-}   # optional: kernel tree for extract-ikconfig
mkdir -p "$OUT"
R="$OUT/inventory.md"
py() { python3 -I "$@"; }

{
echo "# Инвентаризация стоковой прошивки"
echo
echo "Источник: \`$FW\`  "
echo "Сформировано: $(date -u +%Y-%m-%dT%H:%M:%SZ) скриптом scripts/host/analyze-firmware.sh"
echo
echo "## Пакет"
echo '```'
sed -n '1,12p' "$FW"/*info.txt 2>/dev/null || true
grep -E 'HAB_|enforce_anti_rollback|BOOTLOADER_ANTIROLLBACK' "$FW/signing-info.txt" 2>/dev/null || true
echo '```'
echo
echo "## Контрольные суммы ключевых образов (SHA-256)"
echo '```'
( cd "$FW" && sha256sum flashfile.xml servicefile.xml boot.img init_boot.img vendor_boot.img dtbo.img vbmeta.img vbmeta_system.img )
echo '```'
} > "$R"

# MD5 vs flashfile.xml
py - "$FW" >> "$R" <<'EOF'
import sys, os, hashlib, xml.etree.ElementTree as ET
fw = sys.argv[1]; ok = bad = 0
for st in ET.parse(os.path.join(fw, "flashfile.xml")).getroot().iter("step"):
    if st.get("MD5"):
        fn = os.path.join(fw, st.get("filename"))
        if not os.path.exists(fn):
            missing = locals().setdefault("missing", [])
            missing.append(st.get("filename")); continue
        h = hashlib.md5()
        with open(fn, "rb") as f:
            for c in iter(lambda: f.read(1 << 22), b""): h.update(c)
        if h.hexdigest() == st.get("MD5"): ok += 1
        else: bad += 1; print(f"- MD5 MISMATCH: {st.get('filename')}")
miss = locals().get("missing", [])
print(f"\nMD5 из flashfile.xml: совпало {ok}, не совпало {bad}, файлов нет на диске {len(miss)}\n")
EOF

# boot / init_boot / vendor_boot
for i in boot init_boot vendor_boot; do
  py "$UNPACK" --boot_img "$FW/$i.img" --out "$OUT/$i" --format info > "$OUT/$i.info.txt" 2>&1
done
( gzip -dc "$OUT/boot/kernel" 2>/dev/null || lz4 -dc "$OUT/boot/kernel" 2>/dev/null || cat "$OUT/boot/kernel" ) > "$OUT/boot/Image"
BANNER=$(strings "$OUT/boot/Image" | grep -m1 'Linux version' || true)
if [[ -n "$KSRC_SCRIPTS" && -x "$KSRC_SCRIPTS/scripts/extract-ikconfig" ]]; then
  bash "$KSRC_SCRIPTS/scripts/extract-ikconfig" "$OUT/boot/Image" > "$OUT/boot/stock.config" || true
else
  py - "$OUT/boot/Image" > "$OUT/boot/stock.config" <<'EOF'
import sys, gzip
d = open(sys.argv[1], "rb").read()
i = d.find(b"IKCFG_ST"); j = d.find(b"IKCFG_ED", i)
sys.stdout.write(gzip.decompress(d[i + 8:j]).decode() if i >= 0 else "")
EOF
fi
for r in "$OUT"/vendor_boot/vendor_ramdisk0*; do
  [[ -f "$r" ]] || continue
  d="$OUT/vendor_boot/rd_$(basename "$r")"; mkdir -p "$d"
  ( cd "$d" && ( lz4 -dc "$r" 2>/dev/null || gzip -dc "$r" ) | cpio -idm --quiet 2>/dev/null ) || true
done
{
echo "## Ядро в boot.img"
echo '```'
grep -E 'kernel_size|header version|signature size' "$OUT/boot.info.txt"
echo "$BANNER"
echo "IKCONFIG: $(wc -l < "$OUT/boot/stock.config") строк"
echo '```'
echo
echo "## vendor_boot"
echo '```'
grep -E 'vendor command line|dtb size|vendor ramdisk total|name:|header version' "$OUT/vendor_boot.info.txt"
echo "modules.load (first stage): $(wc -l < "$OUT/vendor_boot/rd_vendor_ramdisk00/lib/modules/modules.load" 2>/dev/null) модулей"
echo '```'
echo
echo "## vbmeta"
echo '```'
py "$AVBTOOL" info_image --image "$FW/vbmeta.img" | grep -vE '^\s+(Salt|Root Digest|Digest):'
echo '```'
echo
echo "Ожидаемое значение \`ro.boot.vbmeta.digest\` (сверяется на телефоне без root):"
echo '```'
TMP=$(mktemp -d); cp "$FW/vbmeta.img" "$FW/vbmeta_system.img" "$TMP/"
py "$AVBTOOL" calculate_vbmeta_digest --image "$TMP/vbmeta.img" --hash_algorithm sha256
rm -rf "$TMP"
echo '```'
} >> "$R"

# super
mkdir -p "$OUT/super"
mapfile -t CH < <(ls "$FW"/super.img_sparsechunk.* 2>/dev/null | sort -t. -k3 -n)
if [[ ${#CH[@]} -gt 0 ]]; then
  { echo; echo "## super (LP metadata)"; echo '```'; py "$HERE/tools/superimg.py" list "${CH[@]}"; echo '```'; } >> "$R"
  py "$HERE/tools/superimg.py" extract "${CH[@]}" -p vendor_dlkm_a -p system_dlkm_a -o "$OUT/super" >> "$OUT/super/extract.log"
fi
for p in vendor_dlkm_a system_dlkm_a; do
  [[ -f "$OUT/super/$p.img" ]] || continue
  rm -rf "$OUT/super/$p"; fsck.erofs --extract="$OUT/super/$p" --preserve "$OUT/super/$p.img" >/dev/null
done
{
echo
echo "## Модули ядра"
echo '```'
for d in "$OUT/vendor_boot/rd_vendor_ramdisk00/lib/modules" "$OUT/super/vendor_dlkm_a/lib/modules" "$OUT/super/system_dlkm_a"; do
  [[ -d "$d" ]] && echo "$(find "$d" -name '*.ko' | wc -l) .ko в ${d#$OUT/}"
done
M="$OUT/super/vendor_dlkm_a/lib/modules"
[[ -d "$M" ]] && for m in scheduler cpufreq_sugov_ext mtk_core_ctl moto_sched task_turbo mtk_fpsgo fpsgo; do
  [[ -f "$M/$m.ko" ]] && echo "vendor_dlkm: $m.ko  $(sha256sum "$M/$m.ko" | cut -c1-16)…  vermagic=$(strings "$M/$m.ko" | grep -m1 '^vermagic=' | cut -d= -f2)"
done
echo '```'
} >> "$R"
echo "inventory: $R"
