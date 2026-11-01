#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
erofs_meta.py - read per-file metadata (mode, uid, gid, SELinux label,
content SHA-256) from an EROFS image, read-only.

fsck.erofs --extract does not restore the security.selinux xattr, and
Android images keep that label in an EROFS *shared* xattr.  This tool reads
it directly from the on-disk format (linux/fs/erofs/erofs_fs.h), so that a
repacked vendor_dlkm image can be checked file-by-file against stock.

  erofs_meta.py dump  IMAGE ROOTDIR            > meta.tsv
  erofs_meta.py fcontexts IMAGE ROOTDIR --mount-point /vendor_dlkm > fc
  erofs_meta.py diff  STOCK.img STOCK_ROOT  NEW.img NEW_ROOT

ROOTDIR is a tree previously extracted from IMAGE with
`fsck.erofs --extract=ROOTDIR --preserve IMAGE` (used for the path list and
content hashes; NIDs are looked up with dump.erofs).
"""
import hashlib
import os
import re
import struct
import subprocess
import sys

SB_OFF = 1024
EROFS_MAGIC = 0xE0F5E1E2
XATTR_INDEX = {1: "user.", 2: "system.posix_acl_access", 3: "system.posix_acl_default",
               4: "trusted.", 6: "security."}


class Erofs:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        sb = self._read(SB_OFF, 128)
        magic, = struct.unpack_from("<I", sb, 0)
        if magic != EROFS_MAGIC:
            raise SystemExit(f"{path}: not EROFS")
        self.blkszbits = sb[12]
        self.blksz = 1 << self.blkszbits
        self.meta_blkaddr, self.xattr_blkaddr = struct.unpack_from("<II", sb, 40)

    def _read(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def inode(self, nid):
        off = self.meta_blkaddr * self.blksz + nid * 32
        raw = self._read(off, 64)
        fmt, icount, mode = struct.unpack_from("<HHH", raw, 0)
        extended = fmt & 1
        if extended:
            uid, gid = struct.unpack_from("<II", raw, 24)
            core = 64
        else:
            uid, gid = struct.unpack_from("<HH", raw, 24)
            core = 32
        xattrs = {}
        if icount:
            xsize = 12 + (icount - 1) * 4
            xb = self._read(off + core, xsize)
            shared_count = xb[4]
            for i in range(shared_count):
                xid, = struct.unpack_from("<I", xb, 12 + 4 * i)
                k, v = self._xattr_entry(self.xattr_blkaddr * self.blksz + xid * 4)
                xattrs[k] = v
            p = 12 + 4 * shared_count
            while p + 4 <= xsize:
                k, v, ln = self._xattr_inline(xb, p)
                if k is None:
                    break
                xattrs[k] = v
                p += ln
        return dict(mode=mode, uid=uid, gid=gid, xattrs=xattrs)

    def _xattr_entry(self, off):
        h = self._read(off, 4)
        nlen, idx, vlen = struct.unpack("<BBH", h)
        body = self._read(off + 4, nlen + vlen)
        name = XATTR_INDEX.get(idx, f"idx{idx}.") + body[:nlen].decode()
        return name, body[nlen:nlen + vlen]

    @staticmethod
    def _xattr_inline(buf, p):
        nlen, idx, vlen = struct.unpack_from("<BBH", buf, p)
        if nlen == 0 and vlen == 0:
            return None, None, 0
        name = XATTR_INDEX.get(idx, f"idx{idx}.") + buf[p + 4:p + 4 + nlen].decode()
        val = buf[p + 4 + nlen:p + 4 + nlen + vlen]
        ln = (4 + nlen + vlen + 3) & ~3
        return name, val, ln


def nid_of(image, path):
    out = subprocess.run(["dump.erofs", f"--path={path}", image], capture_output=True, text=True).stdout
    m = re.search(r"NID:\s*(\d+)", out)
    if not m:
        raise SystemExit(f"dump.erofs could not resolve {path} in {image}")
    return int(m.group(1))


def walk(root):
    yield "/"
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs) + sorted(files):
            yield "/" + os.path.relpath(os.path.join(d, n), root)


def collect(image, root):
    fs = Erofs(image)
    res = {}
    for p in walk(root):
        ino = fs.inode(nid_of(image, p))
        label = ino["xattrs"].get("security.selinux", b"").rstrip(b"\0").decode()
        local = os.path.join(root, p.lstrip("/"))
        sha = ""
        if os.path.isfile(local) and not os.path.islink(local):
            with open(local, "rb") as f:
                sha = hashlib.sha256(f.read()).hexdigest()
        res[p] = (f"{ino['mode']:o}", ino["uid"], ino["gid"], label, sha)
    return res


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "dump":
        for p, (mode, uid, gid, label, sha) in collect(sys.argv[2], sys.argv[3]).items():
            print(f"{p}\t{mode}\t{uid}\t{gid}\t{label}\t{sha}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "fcontexts":
        mp = "/"
        if "--mount-point" in sys.argv:
            mp = sys.argv[sys.argv.index("--mount-point") + 1].rstrip("/")
        for p, (_m, _u, _g, label, _s) in collect(sys.argv[2], sys.argv[3]).items():
            if label:
                full = mp if p == "/" else mp + p
                print(f"{re.escape(full)} {label}")
    elif len(sys.argv) == 6 and sys.argv[1] == "diff":
        a, b = collect(sys.argv[2], sys.argv[3]), collect(sys.argv[4], sys.argv[5])
        changed = 0
        for p in sorted(set(a) | set(b)):
            if a.get(p) != b.get(p):
                changed += 1
                print(f"DIFF {p}\n  stock: {a.get(p)}\n  new  : {b.get(p)}")
        print(f"paths: stock={len(a)} new={len(b)} differing={changed}")
        sys.exit(0 if changed >= 0 else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
