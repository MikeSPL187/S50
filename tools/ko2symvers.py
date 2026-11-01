#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
ko2symvers.py - write a Module.symvers-format file describing the symbols
EXPORTED by a set of already-built (e.g. stock firmware) kernel modules.

Used to build replacement modules against the exact CRCs that the other,
untouched stock modules export (KBUILD_EXTRA_SYMBOLS=...).

  ko2symvers.py <dir-with-ko> [...] -o stock-vendor.symvers
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kmi_check import Elf, SHN_ABS, find_kos  # noqa: E402


def exports(elf):
    out = []
    for name, shndx, value in elf.symbols():
        if not name.startswith("__crc_") or shndx == SHN_ABS or not 0 < shndx < len(elf.sections):
            continue
        sec = elf.sections[shndx]
        if "kcrctab" not in sec["name"]:
            continue
        crc = struct.unpack_from("<I", elf.data, sec["off"] + value)[0]
        kind = "EXPORT_SYMBOL_GPL" if "_gpl" in sec["name"] else "EXPORT_SYMBOL"
        out.append((name[6:], crc, kind))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--exclude", action="append", default=[],
                    help="module file name to skip (e.g. the one being rebuilt)")
    ap.add_argument("--skip-provided-by", action="append", default=[],
                    help="Module.symvers whose symbols must not be repeated (e.g. the GKI build)")
    a = ap.parse_args()
    already = set()
    for sv in a.skip_provided_by:
        with open(sv) as f:
            already.update(l.split("\t")[1] for l in f if l.count("\t") >= 3)
    seen_mod, seen_sym, lines = set(), {}, []
    # The same module may ship in vendor_boot and vendor_dlkm: keep one copy.
    for ko in sorted(find_kos(a.dirs)):
        base = os.path.basename(ko)
        if base in a.exclude or base in seen_mod:
            continue
        seen_mod.add(base)
        mod = base[:-3]
        for sym, crc, kind in exports(Elf(ko)):
            if sym in already:
                continue
            if sym in seen_sym:
                if seen_sym[sym] != crc:
                    print(f"warning: {sym} exported by two stock modules with different CRCs", file=sys.stderr)
                continue
            seen_sym[sym] = crc
            lines.append(f"0x{crc:08x}\t{sym}\tstock/{mod}\t{kind}\t")
    with open(a.out, "w") as f:
        f.write("\n".join(sorted(lines)) + "\n")
    print(f"{a.out}: {len(lines)} exported symbols from {len(seen_mod)} modules")


if __name__ == "__main__":
    main()
