#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
kmi_check.py - offline KMI / modversions compatibility gate.

The Linux module loader (kernel/module/version.c: check_version()) refuses
to load a module when the CRC that the module recorded for an imported
symbol (ELF section "__versions") differs from the CRC the running kernel
(or a providing module) exports.  It also compares "vermagic".

This tool performs the same comparison offline:

  * stock modules  : every *.ko found under the given directories
                     (e.g. extracted vendor_boot ramdisk, vendor_dlkm,
                     system_dlkm of the firmware that is installed)
  * candidate      : Module.symvers (+ optional extra .ko dirs) of the
                     kernel / modules we built.

  kmi_check.py --symvers out/Module.symvers --modules stock/vendor_dlkm \
               --modules stock/vendor_boot_ramdisk [--release 6.1.157-...]

Exit code 0 = no CRC mismatch and no unresolved symbol; 1 otherwise.
Pure python, no third party dependencies; read-only.
"""
import argparse
import collections
import json
import os
import struct
import sys

SHN_ABS = 0xFFF1


class Elf:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
            raise ValueError("not a little-endian ELF64 file")
        (self.e_shoff,) = struct.unpack_from("<Q", d, 0x28)
        self.e_shentsize, self.e_shnum, self.e_shstrndx = struct.unpack_from("<HHH", d, 0x3A)
        self.sections = []
        for i in range(self.e_shnum):
            o = self.e_shoff + i * self.e_shentsize
            name, typ, flags, addr, off, size, link, info, align, entsize = \
                struct.unpack_from("<IIQQQQIIQQ", d, o)
            self.sections.append(dict(name_off=name, type=typ, off=off, size=size,
                                      link=link, entsize=entsize))
        shstr = self.sections[self.e_shstrndx]
        for s in self.sections:
            s["name"] = self._cstr(shstr["off"] + s["name_off"])
        self.by_name = {s["name"]: s for s in self.sections}

    def _cstr(self, off):
        end = self.data.index(b"\0", off)
        return self.data[off:end].decode("utf-8", "replace")

    def section(self, name):
        s = self.by_name.get(name)
        if not s:
            return None
        return self.data[s["off"]:s["off"] + s["size"]]

    def symbols(self):
        st = self.by_name.get(".symtab")
        if not st:
            return
        strtab = self.sections[st["link"]]
        for i in range(st["size"] // 24):
            o = st["off"] + i * 24
            name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", self.data, o)
            yield self._cstr(strtab["off"] + name), shndx, value

    def modinfo(self):
        raw = self.section(".modinfo") or b""
        out = collections.defaultdict(list)
        for item in raw.split(b"\0"):
            if b"=" in item:
                k, v = item.split(b"=", 1)
                out[k.decode()].append(v.decode("utf-8", "replace"))
        return out

    def versions(self):
        """__versions: array of struct modversion_info {unsigned long crc; char name[56];}"""
        raw = self.section("__versions") or b""
        res = {}
        for i in range(0, len(raw), 64):
            crc = struct.unpack_from("<Q", raw, i)[0] & 0xFFFFFFFF
            name = raw[i + 8:i + 64].split(b"\0", 1)[0].decode()
            res[name] = crc
        return res

    def exported_crcs(self):
        """CRCs of symbols this object exports.

        Linux >= 5.19 (incl. 6.1): modpost emits SYMBOL_CRC() into *.mod.c,
        i.e. a label "__crc_<sym>" inside section "___kcrctab[_gpl]+<sym>"
        (merged into __kcrctab*), the 32-bit CRC stored at that label.
        Older kernels / vmlinux may instead carry absolute __crc_ symbols.
        """
        res = {}
        for name, shndx, value in self.symbols():
            if not name.startswith("__crc_"):
                continue
            if shndx == SHN_ABS:
                res[name[6:]] = value & 0xFFFFFFFF
            elif 0 < shndx < len(self.sections):
                sec = self.sections[shndx]
                if sec["name"].startswith("__kcrctab") or sec["name"].startswith("___kcrctab"):
                    off = sec["off"] + value
                    res[name[6:]] = struct.unpack_from("<I", self.data, off)[0]
        return res

    def exported_names(self):
        """Names of exported symbols (from __ksymtab_strings)."""
        raw = self.section("__ksymtab_strings") or b""
        return [s.decode() for s in raw.split(b"\0") if s]


def load_symvers(path):
    res = {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4:
                crc, sym, mod = parts[0], parts[1], parts[2]
                res[sym] = (int(crc, 16), mod)
    return res


def find_kos(dirs):
    for d in dirs:
        for root, _, files in os.walk(d):
            for fn in files:
                if fn.endswith(".ko"):
                    yield os.path.join(root, fn)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--symvers", required=True, action="append",
                    help="Module.symvers of the candidate kernel (may repeat)")
    ap.add_argument("--modules", required=True, action="append",
                    help="directory with stock *.ko to verify (may repeat)")
    ap.add_argument("--candidate-modules", action="append", default=[],
                    help="directory with rebuilt *.ko that replace stock ones by name")
    ap.add_argument("--vermagic-flags", default="SMP preempt mod_unload modversions aarch64",
                    help="flags part of the kernel's VERMAGIC_STRING; kernel/module/version.c "
                         "same_magic() skips the release word when the module has CRCs")
    ap.add_argument("--json", help="write full report as JSON here")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    provided = {}
    for p in a.symvers:
        for sym, (crc, mod) in load_symvers(p).items():
            provided[sym] = (crc, f"symvers:{mod}")

    stock = {}
    for ko in find_kos(a.modules):
        stock.setdefault(os.path.basename(ko), ko)
    replaced = {}
    for ko in find_kos(a.candidate_modules):
        replaced[os.path.basename(ko)] = ko

    mods = {}
    for base, path in sorted(stock.items()):
        mods[base] = Elf(replaced.get(base, path))
    for base, path in replaced.items():
        if base not in mods:
            mods[base] = Elf(path)

    # Exports of the module set itself (vendor modules depend on each other).
    for base, elf in mods.items():
        for sym, crc in elf.exported_crcs().items():
            provided.setdefault(sym, (crc, f"ko:{base}"))

    report = {"modules": {}, "summary": {}}
    n_mismatch = n_missing = n_vermagic = 0
    vermagics = collections.Counter()
    for base, elf in sorted(mods.items()):
        mi = elf.modinfo()
        vm = (mi.get("vermagic") or [""])[0]
        vermagics[vm] += 1
        entry = {"path": elf.path, "vermagic": vm, "mismatch": [], "missing": []}
        has_crcs = bool(elf.section("__versions"))
        flags = vm.split(" ", 1)[1] if (has_crcs and " " in vm) else vm
        if a.vermagic_flags and flags != a.vermagic_flags:
            entry["vermagic_mismatch"] = True
            n_vermagic += 1
        for sym, crc in elf.versions().items():
            if sym == "module_layout":
                # Present only on older kernels; 6.1 has no module_layout.
                pass
            if sym not in provided:
                entry["missing"].append(sym)
                continue
            pcrc, src = provided[sym]
            if pcrc != crc:
                entry["mismatch"].append({"symbol": sym, "module_expects": f"{crc:#010x}",
                                          "provided": f"{pcrc:#010x}", "provider": src})
        n_mismatch += len(entry["mismatch"])
        n_missing += len(entry["missing"])
        report["modules"][base] = entry

    report["summary"] = {
        "modules_checked": len(mods),
        "modules_replaced_by_candidate": sorted(replaced),
        "crc_mismatches": n_mismatch,
        "unresolved_symbols": n_missing,
        "vermagic_mismatches": n_vermagic,
        "vermagic_values": dict(vermagics),
    }
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1, sort_keys=True)

    for base, e in sorted(report["modules"].items()):
        if e["mismatch"] or e["missing"] or e.get("vermagic_mismatch") or a.verbose:
            print(f"{base}: mismatch={len(e['mismatch'])} unresolved={len(e['missing'])}"
                  f"{' VERMAGIC' if e.get('vermagic_mismatch') else ''}")
            for m in e["mismatch"][:20]:
                print(f"    CRC  {m['symbol']}: module expects {m['module_expects']}, "
                      f"{m['provider']} provides {m['provided']}")
            for s in e["missing"][:20]:
                print(f"    MISSING {s}")
    print(json.dumps(report["summary"], indent=1))
    ok = n_mismatch == 0 and n_missing == 0 and n_vermagic == 0
    print("KMI GATE:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
