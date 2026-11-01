#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
superimg.py - read-only inspector/extractor for Android dynamic-partition
"super" images, working directly on one or more Android *sparse* chunks
(e.g. Motorola super.img_sparsechunk.0 .. .30) or on a raw super image.

It never writes to any device.  It only reads the given files and writes
extracted partition images to the output directory you choose.

  superimg.py list    super.img_sparsechunk.*
  superimg.py extract super.img_sparsechunk.* -p vendor_dlkm_a -o out/
  superimg.py extract super.raw -p system_dlkm_a -p vendor_a -o out/

Formats implemented from AOSP sources:
  - system/core/libsparse/sparse_format.h          (sparse image)
  - system/core/fs_mgr/liblp/include/liblp/metadata_format.h (LP metadata)
"""
import argparse
import bisect
import hashlib
import os
import struct
import sys

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW, CHUNK_FILL, CHUNK_DONT_CARE, CHUNK_CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4

LP_PARTITION_RESERVED_BYTES = 4096
LP_METADATA_GEOMETRY_SIZE = 4096
LP_GEOMETRY_MAGIC = 0x616C4467
LP_HEADER_MAGIC = 0x414C5030
LP_SECTOR = 512
LP_TARGET_TYPE_LINEAR, LP_TARGET_TYPE_ZERO = 0, 1


class SparseSet:
    """Union view over one or more sparse images (or a single raw image)."""

    def __init__(self, paths):
        self.segments = []  # (out_off, length, kind, fh, src_off_or_fill)
        self.size = 0
        self.files = []
        for p in paths:
            fh = open(p, "rb")
            self.files.append(fh)
            hdr = fh.read(28)
            if len(hdr) == 28 and struct.unpack("<I", hdr[:4])[0] == SPARSE_MAGIC:
                self._index_sparse(fh, hdr)
            else:
                if len(paths) != 1:
                    raise SystemExit(f"{p}: not a sparse image; raw input must be a single file")
                st = os.fstat(fh.fileno())
                self.segments.append((0, st.st_size, "raw", fh, 0))
                self.size = st.st_size
        self.segments.sort(key=lambda s: s[0])
        self.starts = [s[0] for s in self.segments]

    def _index_sparse(self, fh, hdr):
        (_magic, _maj, _min, file_hdr_sz, chunk_hdr_sz, blk_sz,
         total_blks, total_chunks, _csum) = struct.unpack("<IHHHHIIII", hdr)
        fh.seek(file_hdr_sz)
        out = 0
        for _ in range(total_chunks):
            ch = fh.read(chunk_hdr_sz)
            ctype, _res, chunk_sz, total_sz = struct.unpack("<HHII", ch[:12])
            data_sz = total_sz - chunk_hdr_sz
            length = chunk_sz * blk_sz
            if ctype == CHUNK_RAW:
                self.segments.append((out, length, "raw", fh, fh.tell()))
                fh.seek(data_sz, 1)
            elif ctype == CHUNK_FILL:
                fill = fh.read(4)
                self.segments.append((out, length, "fill", fh, fill))
            elif ctype == CHUNK_DONT_CARE:
                pass
            elif ctype == CHUNK_CRC32:
                fh.seek(data_sz, 1)
            else:
                raise SystemExit(f"unknown sparse chunk type {ctype:#x}")
            out += length
        self.size = max(self.size, total_blks * blk_sz)

    def read(self, off, length):
        buf = bytearray(length)  # DONT_CARE regions read as zero
        end = off + length
        i = max(0, bisect.bisect_right(self.starts, off) - 1)
        while i < len(self.segments):
            s_off, s_len, kind, fh, src = self.segments[i]
            if s_off >= end:
                break
            a, b = max(off, s_off), min(end, s_off + s_len)
            if a < b:
                if kind == "raw":
                    fh.seek(src + (a - s_off))
                    buf[a - off:b - off] = fh.read(b - a)
                else:
                    rep = src * ((b - a) // 4 + 2)
                    k = (a - s_off) % 4
                    buf[a - off:b - off] = rep[k:k + (b - a)]
            i += 1
        return bytes(buf)


def parse_lp(img, slot=0):
    g = img.read(LP_PARTITION_RESERVED_BYTES, LP_METADATA_GEOMETRY_SIZE)
    magic, struct_size = struct.unpack("<II", g[:8])
    if magic != LP_GEOMETRY_MAGIC:
        raise SystemExit("LP geometry magic not found at 4096: not a super image?")
    csum = g[8:40]
    metadata_max_size, slot_count, logical_block_size = struct.unpack("<III", g[40:52])
    chk = bytearray(g[:struct_size]); chk[8:40] = b"\0" * 32
    geom_ok = hashlib.sha256(chk).digest() == csum
    meta_off = LP_PARTITION_RESERVED_BYTES + 2 * LP_METADATA_GEOMETRY_SIZE + slot * metadata_max_size
    h = img.read(meta_off, metadata_max_size)
    (hmagic, major, minor, header_size) = struct.unpack("<IHHI", h[:12])
    if hmagic != LP_HEADER_MAGIC:
        raise SystemExit("LP metadata header magic mismatch")
    tables_size = struct.unpack("<I", h[44:48])[0]
    tables_csum = h[48:80]
    descs = struct.unpack("<12I", h[80:128])
    tables = h[header_size:header_size + tables_size]
    tables_ok = hashlib.sha256(tables).digest() == tables_csum

    def table(idx):
        off, num, esz = descs[idx * 3:idx * 3 + 3]
        return [tables[off + i * esz: off + (i + 1) * esz] for i in range(num)]

    parts = []
    for e in table(0):
        name = e[:36].split(b"\0", 1)[0].decode()
        attrs, first_ext, num_ext, group = struct.unpack("<IIII", e[36:52])
        parts.append(dict(name=name, attrs=attrs, first=first_ext, num=num_ext, group=group))
    extents = []
    for e in table(1):
        num_sectors, ttype, tdata, tsrc = struct.unpack("<QIQI", e[:24])
        extents.append(dict(sectors=num_sectors, type=ttype, data=tdata, src=tsrc))
    groups = [e[:36].split(b"\0", 1)[0].decode() for e in table(2)]
    return dict(version=f"{major}.{minor}", geometry_ok=geom_ok, tables_ok=tables_ok,
                slot_count=slot_count, block_size=logical_block_size,
                partitions=parts, extents=extents, groups=groups)


def part_size(md, p):
    return sum(md["extents"][p["first"] + i]["sectors"] for i in range(p["num"])) * LP_SECTOR


def cmd_list(args):
    img = SparseSet(args.images)
    md = parse_lp(img, args.slot)
    print(f"LP metadata v{md['version']}  geometry_checksum_ok={md['geometry_ok']} "
          f"tables_checksum_ok={md['tables_ok']}  slots={md['slot_count']}")
    print(f"groups: {', '.join(md['groups'])}")
    for p in md["partitions"]:
        print(f"  {p['name']:<24} {part_size(md, p):>14} bytes  extents={p['num']}  "
              f"group={md['groups'][p['group']] if p['group'] < len(md['groups']) else p['group']}")


def cmd_extract(args):
    img = SparseSet(args.images)
    md = parse_lp(img, args.slot)
    os.makedirs(args.out, exist_ok=True)
    by_name = {p["name"]: p for p in md["partitions"]}
    for name in args.partition:
        if name not in by_name:
            raise SystemExit(f"partition {name!r} not in metadata; use 'list'")
        p = by_name[name]
        dst = os.path.join(args.out, name + ".img")
        sha = hashlib.sha256()
        with open(dst, "wb") as out:
            for i in range(p["num"]):
                ext = md["extents"][p["first"] + i]
                n = ext["sectors"] * LP_SECTOR
                if ext["type"] == LP_TARGET_TYPE_ZERO:
                    chunk_iter = (b"\0" * min(1 << 20, n - k) for k in range(0, n, 1 << 20))
                else:
                    base = ext["data"] * LP_SECTOR
                    chunk_iter = (img.read(base + k, min(1 << 20, n - k)) for k in range(0, n, 1 << 20))
                for c in chunk_iter:
                    out.write(c)
                    sha.update(c)
        print(f"{name}: {os.path.getsize(dst)} bytes -> {dst}  sha256={sha.hexdigest()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("list", "extract"):
        sp = sub.add_parser(n)
        sp.add_argument("images", nargs="+", help="sparse chunks (in any order) or one raw super image")
        sp.add_argument("--slot", type=int, default=0, help="LP metadata slot (default 0)")
        if n == "extract":
            sp.add_argument("-p", "--partition", action="append", required=True)
            sp.add_argument("-o", "--out", required=True)
    args = ap.parse_args()
    {"list": cmd_list, "extract": cmd_extract}[args.cmd](args)


if __name__ == "__main__":
    main()
