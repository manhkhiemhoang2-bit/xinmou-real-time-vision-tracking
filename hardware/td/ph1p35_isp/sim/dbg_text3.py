#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""验证假设：DUT 的 w_txt_col0 恒 = 0..3（即字内列 = 0..3 而不是 (dx%16)）。"""
import sys, os
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

# 假设 A：字内列 = 0,1,2,3（col_base 恒 0）
# 假设 B：字内列 = (dx % 16)（规格）
stat = {"A": 0, "B": 0, "other": 0}
first_other = []
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
    A = "".join(str((gb >> (15 - ((0 << 2) + k))) & 1) for k in range(4))
    B = "".join(str((gb >> (15 - (dx % 16 + k))) & 1) for k in range(4))
    if dut == A and dut != B: stat["A"] += 1
    elif dut == B: stat["B"] += 1
    else:
        stat["other"] += 1
        if len(first_other) < 6:
            first_other.append("cyc=%d xb=%d dx=%d gb=%04X dut=%s A=%s B=%s"
                               % (r["cyc"], xb, dx, gb, dut, A, B))
print("假设A(字内列恒0..3): %d 拍" % stat["A"])
print("假设B(规格 dx%%16) : %d 拍" % stat["B"])
print("其它              : %d 拍" % stat["other"])
for s in first_other: print("  " + s)
