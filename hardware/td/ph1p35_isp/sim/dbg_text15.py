#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""对每一拍：从 O_tdata 反解真实像素坐标，与该拍探针坐标 + 命中位对照。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
pl = open(os.path.join(HERE, "osd_work", "probe_osd.txt"), encoding="ascii",
          errors="replace").read().splitlines()
rows = []
for ln in pl:
    f = ln.split()
    if len(f) < 12: continue
    rows.append({"cyc": int(f[0]), "h": [int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                 "rx": int(f[5], 16), "ry": int(f[6], 16), "col0": int(f[7], 16),
                 "gb": int(f[8], 16), "cb": int(f[9], 16), "ci": int(f[10], 16),
                 "Od": f[11]})
cfg = C.Config(128, 128, 40, 8, 0, 88, 3, 0x42, 137, 2047)
TC = 0xFFFFFF

print("cyc   probe(rx,ry,col0,cb,ci,gb)   O_tdata真值(x,y,ch)         一致?")
n = 0
mism = 0
for r in rows:
    if not (88 <= r["ry"] < 104): continue
    if r["rx"] > 8: continue
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    pix = []
    for ch in range(4):
        g = (v >> (72 - 24 * ch)) & 0xFFFFFF
        if g == TC:
            pix.append("W")
        else:
            b, x, c = C.decode_pix(g)
            pix.append("b%d/x%d/c%d" % (b, x, c))
    # 该拍探针的坐标
    print("%-5d (%2d,%3d,col0=%2d,cb=%d,ci=%2d,gb=%04X)  %-34s"
          % (r["cyc"], r["rx"], r["ry"], r["col0"], r["cb"], r["ci"], r["gb"],
             " ".join(pix)))
    n += 1
    if n > 22: break
