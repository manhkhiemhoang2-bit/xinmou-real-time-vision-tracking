#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逐拍：DUT 命中探针 vs 模型期望（用该拍自己的坐标与 gbits）。"""
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
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16), "gbits": int(f[28], 16),
                 "T": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)

res = collections.Counter()
ex = collections.defaultdict(list)
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    if not (cfg.TEXT_Y <= r["ry"] < cfg.TEXT_Y + 16): continue
    xb = 4 * r["rx"]
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    dx = xb - cfg.TEXT_X
    gb = r["gbits"]
    exp = "".join(str((gb >> (15 - (dx % 16 + k))) & 1) for k in range(4))
    dut = "".join(str(b) for b in r["T"])
    if exp == dut:
        res["match"] += 1
    else:
        res["diff"] += 1
        key = (dx % 16, r["ry"] - cfg.TEXT_Y, r["grow"])
        if len(ex[key]) < 1:
            ex[key].append("cyc=%d dx=%d romi=%d grow=%d gb=%04X dut=%s exp=%s"
                           % (r["cyc"], dx, r["romi"], r["grow"], gb, dut, exp))
print("同拍命中集合：%s" % dict(res))
for k in sorted(ex)[:20]:
    print("  col=%2d row=%2d grow=%2d  %s" % (k[0], k[1], k[2], ex[k][0]))
