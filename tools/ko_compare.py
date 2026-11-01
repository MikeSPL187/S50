#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
ko_compare.py - compare a rebuilt kernel module with the stock binary.

  ko_compare.py STOCK.ko REBUILT.ko [--expect-params p1,p2]

Checks (all read-only):
  exports   : names + CRCs of every exported symbol must be identical.  The CRC
              is computed by genksyms from the fully expanded C types of each
              exported prototype, so equality proves that the rebuilt module saw
              the same structure layouts / config as the stock build.
  imports   : __versions (symbol -> CRC the module requires) must be identical,
              except for symbols listed in --allow-new-imports.
  modinfo   : license/depends/name/vermagic(flags part) identical; module
              parameters may differ only by --expect-params.
  sections  : sizes of .text/.rodata/.data/.bss etc. are reported (informative:
              small differences come from embedded source paths).
Exit 0 when exports/imports/modinfo checks pass.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kmi_check import Elf  # noqa: E402


def sec_sizes(e):
    want = (".text", ".init.text", ".exit.text", ".rodata", ".rodata.str1.1", ".data",
            ".bss", "__tracepoints", "__param", ".modinfo", "__versions")
    return {s["name"]: s["size"] for s in e.sections if s["name"] in want}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stock")
    ap.add_argument("rebuilt")
    ap.add_argument("--expect-params", default="", help="comma separated new module params")
    ap.add_argument("--allow-new-imports", default="", help="comma separated symbols")
    a = ap.parse_args()
    s, r = Elf(a.stock), Elf(a.rebuilt)
    ok = True
    name = os.path.basename(a.stock)

    es, er = s.exported_crcs(), r.exported_crcs()
    mism = [k for k in es if k in er and es[k] != er[k]]
    missing = sorted(set(es) - set(er))
    extra = sorted(set(er) - set(es))
    print(f"[{name}] exports: stock={len(es)} rebuilt={len(er)} crc_mismatch={len(mism)} "
          f"missing={len(missing)} extra={len(extra)}")
    for k in mism[:20]:
        print(f"   CRC {k}: stock {es[k]:#010x} rebuilt {er[k]:#010x}")
    for k in missing[:20]:
        print(f"   MISSING export {k}")
    ok &= not mism and not missing and not extra

    vs, vr = s.versions(), r.versions()
    allow = {x for x in a.allow_new_imports.split(",") if x}
    imism = [k for k in vs if k in vr and vs[k] != vr[k]]
    gone = sorted(set(vs) - set(vr))
    new = sorted(set(vr) - set(vs) - allow)
    print(f"[{name}] imports: stock={len(vs)} rebuilt={len(vr)} crc_mismatch={len(imism)} "
          f"dropped={len(gone)} new={len(new)}")
    for k in imism[:20]:
        print(f"   CRC {k}: stock {vs[k]:#010x} rebuilt {vr[k]:#010x}")
    for k in gone[:20]:
        print(f"   dropped import {k}")
    for k in new[:20]:
        print(f"   NEW import {k}")
    ok &= not imism and not new

    ms, mr = s.modinfo(), r.modinfo()
    for k in ("license", "depends", "name", "intree", "retpoline"):
        if sorted(ms.get(k, [])) != sorted(mr.get(k, [])):
            print(f"   modinfo {k}: stock={ms.get(k)} rebuilt={mr.get(k)}")
            ok = False
    vm_s = (ms.get("vermagic") or [""])[0].split(" ", 1)[-1]
    vm_r = (mr.get("vermagic") or [""])[0].split(" ", 1)[-1]
    if vm_s != vm_r:
        print(f"   vermagic flags differ: '{vm_s}' vs '{vm_r}'"); ok = False
    ps = {p.split(":")[0] for p in ms.get("parm", []) + ms.get("parmtype", [])}
    pr = {p.split(":")[0] for p in mr.get("parm", []) + mr.get("parmtype", [])}
    exp = {x for x in a.expect_params.split(",") if x}
    if pr - ps != exp or ps - pr:
        print(f"   params: added={sorted(pr - ps)} removed={sorted(ps - pr)} expected_added={sorted(exp)}")
        ok &= pr - ps == exp and not (ps - pr)
    else:
        print(f"[{name}] params: added={sorted(pr - ps)} (as expected)")

    ss, sr = sec_sizes(s), sec_sizes(r)
    print(f"[{name}] section sizes (stock -> rebuilt):")
    for k in sorted(set(ss) | set(sr)):
        print(f"   {k:<16} {ss.get(k, 0):>9} -> {sr.get(k, 0):>9}  ({sr.get(k, 0) - ss.get(k, 0):+d})")
    print(f"[{name}] RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
