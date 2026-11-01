#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
bootimg_kernel.py - print the "Linux version ..." banner of the kernel inside
an Android boot image (header v3/v4, page size 4096), read-only, stdlib only.

  bootimg_kernel.py boot.img            # prints the banner (= /proc/version)
  bootimg_kernel.py boot.img --raw > k  # writes the kernel payload as stored
"""
import gzip
import struct
import sys


def kernel_payload(path):
    with open(path, "rb") as f:
        hdr = f.read(4096)
        if hdr[:8] != b"ANDROID!":
            raise SystemExit(f"{path}: not an Android boot image")
        kernel_size, = struct.unpack_from("<I", hdr, 8)
        header_version, = struct.unpack_from("<I", hdr, 40)
        if header_version < 3:
            raise SystemExit(f"{path}: boot header v{header_version} not supported (v3/v4 only)")
        f.seek(4096)
        return f.read(kernel_size)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    k = kernel_payload(sys.argv[1])
    if "--raw" in sys.argv:
        sys.stdout.buffer.write(k)
        return
    if k[:2] == b"\x1f\x8b":
        k = gzip.decompress(k)
    i = k.find(b"Linux version ")
    if i < 0:
        sys.exit("banner not found (unsupported kernel compression?)")
    end = min(x for x in (k.find(b"\n", i), k.find(b"\0", i)) if x > 0)
    print(k[i:end].decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
