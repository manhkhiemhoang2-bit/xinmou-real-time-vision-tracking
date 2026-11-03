#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""判定 O_tdata[i] 与 w_pix_text_hit 的相位：同一沿？i-1？还是 hit 属于下一拍？"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
pl = open(os.path.join(HERE, "osd_work", "probe_osd.txt"), encoding="ascii",
          errors="replace").read().splitlines()
P = {}
for ln in pl:
    f = ln.split()
    if len(f) < 12: continue
    P[int(f[0])] = {"h": [int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                    "rx": int(f[5], 16), "ry": int(f[6], 16), "col0": int(f[7], 16),
                    "gb": int(f[8], 16), "cb": int(f[9], 16), "ci": int(f[10], 16),
                    "Od": f[11]}
TC = 0xFFFFFF

# 只统计文字行内的拍：DUT 的白色像素集合 vs 探针白色位集合，试 3 种相位
res = collections.Counter()
for sh in (-2, -1, 0, 1, 2):
    ok = bad = 0
    for cyc, r in P.items():
        if not (88 <= r["ry"] < 104): continue
        o = P.get(cyc + sh)
        if o is None: continue
        v = int(o["Od"], 16) & ((1 << 96) - 1)
        for ch in range(4):
            g = (v >> (72 - 24 * ch)) & 0xFFFFFF
            white = (g == TC)
            # 探针说这一拍的第 ch 个通道是否命中
            prb = bool(r["h"][3 - ch])
            if white == prb: ok += 1
            else: bad += 1
    res[sh] = (ok, bad)
print("相位偏移 sh 的含义：O_tdata 取 P[cyc+sh]，命中位取 P[cyc]")
for sh in sorted(res):
    print("  sh=%+d : 一致 %6d / 不符 %6d" % (sh, res[sh][0], res[sh][1]))
