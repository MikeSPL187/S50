#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
vbmeta_diff.py - compare the descriptors of two vbmeta images (read-only).

  vbmeta_diff.py STOCK_vbmeta.img NEW_vbmeta.img [--allow vendor_dlkm ...]

Uses AOSP avbtool.py as a library (AVBTOOL env var or /work/hosttools).
Prints every descriptor that was added, removed or changed, plus header
fields.  Exit 1 if anything other than the --allow'ed partitions changed,
or if rollback index / flags differ.
"""
import importlib.util
import os
import sys

AVBTOOL = os.environ.get("AVBTOOL", "/work/hosttools/avbtool.py")
spec = importlib.util.spec_from_file_location("avbtool", AVBTOOL)
avb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(avb)


def load(path):
    tool = avb.Avb()
    footer, header, descriptors, _ = tool._parse_image(avb.ImageHandler(path, read_only=True))
    out = {}
    for d in descriptors:
        name = type(d).__name__.replace("Avb", "").replace("Descriptor", "")
        if hasattr(d, "partition_name"):
            key = f"{name}:{d.partition_name}"
        elif hasattr(d, "key"):
            key = f"{name}:{d.key}:{d.value[:40]!r}"
        else:
            key = f"{name}:{len(out)}"
        out[key] = d.encode()
    hdr = dict(rollback_index=header.rollback_index, flags=header.flags,
               rollback_index_location=header.rollback_index_location,
               algorithm=avb.lookup_algorithm_by_type(header.algorithm_type)[0],
               release=header.release_string.rstrip("\0") if isinstance(header.release_string, str)
               else header.release_string)
    return hdr, out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    allow = set()
    args = sys.argv[3:]
    while args:
        if args[0] == "--allow" and len(args) > 1:
            allow.add(args[1]); args = args[2:]
        else:
            sys.exit(__doc__)
    if not allow:
        allow = {"vendor_dlkm"}
    ha, a = load(sys.argv[1])
    hb, b = load(sys.argv[2])
    bad = False
    for k in ("rollback_index", "flags", "rollback_index_location"):
        same = ha[k] == hb[k]
        print(f"header {k}: stock={ha[k]} new={hb[k]} {'OK' if same else 'CHANGED'}")
        bad |= not same
    print(f"header algorithm: stock={ha['algorithm']} new={hb['algorithm']} (key differs by design)")
    for k in sorted(set(a) | set(b)):
        if a.get(k) == b.get(k):
            print(f"  same     {k}")
            continue
        part = k.split(":")[1] if k.count(":") >= 1 else ""
        state = "added" if k not in a else "removed" if k not in b else "changed"
        ok = part in allow and state == "changed"
        print(f"  {state:<8} {k} {'(allowed)' if ok else '(NOT ALLOWED)'}")
        bad |= not ok
    print("VBMETA DIFF:", "OK" if not bad else "FAIL")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
