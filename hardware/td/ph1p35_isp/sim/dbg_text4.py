#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""反解：对每拍找出能让 DUT 命中集合成立的 4 位起始列（前导0模式 4 位）。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

DUMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osd_work", "dump_osd.txt")
lines = open(DUMP, "r", encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in lines:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16),
                 "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)

sols = collections.Counter()
rows_out = []
for i in range(len(rows)):
    r = rows[i]
    if r["Ov"] != 1: continue
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    xb = 4 * crx
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    dx = xb - cfg.TEXT_X
    gb = p["gbits"]
    dut = "".join(str(b) for b in r["hit"])
    cand = []
    for base in range(16):
        pat = "".join(str((gb >> (15 - ((base + k) & 15))) & 1) for k in range(4))
        if pat == dut:
            cand.append(base)
    dxmod = dx % 16
    rows_out.append((r["cyc"], dx, dxmod, cand, dut, gb))
    sols[tuple(cand)] += 1

print("=== 反解出的起始列候选分布（key=候选集合, val=拍数）===")
for k, v in sols.most_common(12):
    print("  候选 %-28s : %d 拍" % (str(k), v))

# 检查候选里是否总含 dx%16
n_contain = sum(1 for (_, _, dxmod, cand, _, _) in rows_out if dxmod in cand)
n_uniq = sum(1 for (_, _, _, cand, _, _) in rows_out if len(cand) == 1)
print("总拍数        : %d" % len(rows_out))
print("候选含 dx%%16 : %d" % n_contain)
print("候选唯一      : %d" % n_uniq)
print()
print("cyc      dx  dx%16  候选集合         DUT     gb")
for (cyc, dx, dxmod, cand, dut, gb) in rows_out[:24]:
    print("%-8d %-3d %-5d %-15s %s  %04X" % (cyc, dx, dxmod, str(cand), dut, gb))
