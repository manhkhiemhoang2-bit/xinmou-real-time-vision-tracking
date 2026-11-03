#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逐像素精确对照（含 beat 与 cyc），定位 270 错的真实位置。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
dl = open(os.path.join(HERE, "osd_work", "dump_osd.txt"), encoding="ascii",
          errors="replace").read().splitlines()
hdr, rows = None, []
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8], "Id": f[4],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16), "gbits": int(f[28], 16),
                 "T": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)
TC = 0xFFFFFF

nbad = 0
bykey = collections.Counter()
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    xb = 4 * crx
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    line = []
    for ch in range(4):
        x = xb + ch
        dx = x - cfg.TEXT_X
        got = (v >> (72 - 24 * ch)) & 0xFFFFFF
        gg = (r["gbits"] >> (15 - (dx % 16))) & 1
        wht = (got == TC)
        if wht != bool(gg):
            nbad += 1
            line.append("  BAD x=%d ci=%d col=%2d row=%2d got=%06X gb_bit=%d hit=%d"
                        % (x, dx // 16, dx % 16, cry - cfg.TEXT_Y, got, gg, p["T"][3 - ch]))
            bykey[(dx % 16, cry - cfg.TEXT_Y)] += 1
    if line and nbad <= 24:
        print("cyc=%d rx=%d ry=%d romi=%d grow=%d gb=%04X" %
              (r["cyc"], crx, cry, p["romi"], p["grow"], r["gbits"]))
        for l in line: print(l)
print("总 BAD 像素 = %d" % nbad)
print("按 (col,row) 分布（前 20）: %s" % sorted(bykey.items())[:20])
