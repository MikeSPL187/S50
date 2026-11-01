#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
analyze_profile.py - summarise (and optionally compare) result directories
produced by scripts/device/10-baseline-profile.sh.

  analyze_profile.py RUN_DIR                 # summary of one series
  analyze_profile.py STOCK_DIR PATCHED_DIR   # A/B comparison

Statistics: median, p90 and a two-sided Mann-Whitney U test (normal
approximation, tie-corrected).  A difference is only called "significant"
at p < 0.05 AND |median delta| >= 3 %, otherwise it is reported as
"no measurable difference".  Nothing here invents numbers: a metric that
is absent from the inputs is printed as "n/a".
"""
import math
import os
import re
import statistics
import sys


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * q
    f, c = math.floor(k), math.ceil(k)
    return s[f] if f == c else s[f] + (s[c] - s[f]) * (k - f)


def mann_whitney(a, b):
    if len(a) < 3 or len(b) < 3:
        return None
    allv = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks, i = [0.0] * len(allv), 0
    ties = 0.0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        r = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = r
        t = j - i + 1
        ties += t ** 3 - t
        i = j + 1
    r1 = sum(r for r, (_, g) in zip(ranks, allv) if g == 0)
    n1, n2 = len(a), len(b)
    u1 = r1 - n1 * (n1 + 1) / 2
    mu = n1 * n2 / 2
    n = n1 + n2
    sigma = math.sqrt(n1 * n2 / 12 * ((n + 1) - ties / (n * (n - 1))))
    if sigma == 0:
        return 1.0
    z = (u1 - mu) / sigma
    return math.erfc(abs(z) / math.sqrt(2))


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip()]


def launches(d):
    res = {}
    for row in read_tsv(os.path.join(d, "launch.tsv")):
        if len(row) >= 4 and row[3].isdigit():
            res.setdefault(f"launch {row[1]} {row[0]}", []).append(int(row[3]))
    for row in read_tsv(os.path.join(d, "switch.tsv")):
        if len(row) >= 3 and row[2].isdigit():
            res.setdefault(f"switch {row[0]}", []).append(int(row[2]))
    return res


def gfx(d):
    res = {}
    for fn in sorted(os.listdir(d)):
        if not fn.startswith("scroll-gfxinfo-"):
            continue
        txt = open(os.path.join(d, fn), errors="replace").read()
        m = re.search(r"Total frames rendered: (\d+)", txt)
        j = re.search(r"Janky frames: (\d+) \(([\d.]+)%\)", txt)
        if m:
            res.setdefault("frames total", []).append(int(m.group(1)))
        if j:
            res.setdefault("janky frames %", []).append(float(j.group(2)))
        for p in ("50th", "90th", "95th", "99th"):
            mm = re.search(rf"{p} percentile: (\d+)ms", txt)
            if mm:
                res.setdefault(f"frame time {p} ms", []).append(int(mm.group(1)))
        for k in ("Missed Vsync", "High input latency", "Slow UI thread", "Slow bitmap uploads",
                  "Slow issue draw commands", "Frame deadline missed"):
            mm = re.search(rf"Number {k}: (\d+)", txt)
            if mm:
                res.setdefault(k, []).append(int(mm.group(1)))
    return res


def sustained(d):
    rows = read_tsv(os.path.join(d, "sustained.tsv"))[1:]
    if not rows:
        return {}
    res = {"cpu7 kHz": [], "batt temp dC": []}
    zone_max = {}
    for r in rows:
        try:
            res["cpu7 kHz"].append(int(r[3]))
            res["batt temp dC"].append(int(r[4]))
        except (ValueError, IndexError):
            pass
        for z in r[7:]:
            if "=" in z:
                name, val = z.split("=", 1)
                if val.lstrip("-").isdigit():
                    zone_max[name] = max(zone_max.get(name, -10 ** 9), int(val))
    out = {k: v for k, v in res.items() if v}
    for k, v in sorted(zone_max.items()):
        out[f"max {k}"] = [v]
    return out


def collect(d):
    m = {}
    for f in (launches, gfx, sustained):
        m.update(f(d))
    return m


def fmt(v):
    return "n/a" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))


def main():
    if len(sys.argv) == 2:
        m = collect(sys.argv[1])
        print(f"{'metric':<48}{'n':>4}{'median':>10}{'p90':>10}")
        for k, v in sorted(m.items()):
            print(f"{k:<48}{len(v):>4}{fmt(statistics.median(v)):>10}{fmt(pct(v, .9)):>10}")
        return
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = collect(sys.argv[1]), collect(sys.argv[2])
    print(f"A = {sys.argv[1]}\nB = {sys.argv[2]}\n")
    print(f"{'metric':<44}{'A med':>9}{'B med':>9}{'delta':>9}{'p':>8}  verdict")
    for k in sorted(set(a) | set(b)):
        va, vb = a.get(k, []), b.get(k, [])
        if not va or not vb:
            print(f"{k:<44}{'n/a':>9}{'n/a':>9}")
            continue
        ma, mb = statistics.median(va), statistics.median(vb)
        delta = (mb - ma) / ma * 100 if ma else float("nan")
        p = mann_whitney(va, vb)
        sig = p is not None and p < 0.05 and abs(delta) >= 3
        verdict = ("B lower" if mb < ma else "B higher") if sig else "no measurable difference"
        print(f"{k:<44}{fmt(ma):>9}{fmt(mb):>9}{delta:>8.1f}%{fmt(p if p is None else round(p, 3)):>8}  {verdict}")
    print("\nlower is better for times, jank, temperatures; interpret 'frames total' as workload size.")


if __name__ == "__main__":
    main()
