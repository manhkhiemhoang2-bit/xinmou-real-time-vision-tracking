#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""穷举 (字内列偏移, 字模行偏移, 字符下标偏移) 找 0 错的那组。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")
dl = open(os.path.join(W, "dump_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "gbits": int(f[28], 16), "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)

# 收集文字行内每拍的 (dx, row, 实际 hit 4bit, gb)
obs = []
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    xb = 4 * crx
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    obs.append((xb - cfg.TEXT_X, cry - cfg.TEXT_Y, p["gbits"], tuple(p["hit"])))
print("文字行内观测拍数：%d" % len(obs))

best = []
for cs in range(-8, 9):
    for rs in range(-8, 9):
        bad = 0
        for (dx, rw, gb, hit) in obs:
            col = (dx % 16) + cs
            got = "".join(str((gb >> (15 - (col + k))) & 1) if 0 <= col + k < 16 else "?" for k in range(4))
            if got != "".join(str(b) for b in hit):
                bad += 1
        best.append((bad, cs, rs))
best.sort()
print("=== 前 12 名 (不符拍数, 列偏移, 行偏移) ===")
for b in best[:12]:
    print("   bad=%-4d col_shift=%-3d row_shift=%-3d" % b)
