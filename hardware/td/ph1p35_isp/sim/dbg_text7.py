#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""修完列基址后，把剩余 TEXT 面不符逐条列出并分类。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")
dl = open(os.path.join(W, "dump_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
pl = open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8], "Id": f[4],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16), "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
probe = {}
for ln in pl:
    f = ln.split()
    if len(f) >= 7: probe[int(f[0])] = tuple(int(x, 16) if i in (1, 2, 4, 5, 6) else int(x)
                                             for i, x in enumerate(f[1:7]))
cfg = C.Config(*hdr)
TCOL = 0xFFFFFF

buckets = collections.Counter()
samples = collections.defaultdict(list)
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    b = 0
    for ch in range(4):
        x = 4 * crx + ch
        got = (int(r["Od"], 16) >> (72 - 24 * ch)) & 0xFFFFFF
        vt, kt = C.expect_pix_at(cfg, 0, crx, cry, ch)
        if kt != "text": continue          # 只看文字面应有的像素
        if got == TCOL: continue
        dx = x - cfg.TEXT_X
        key = "ci=%d col=%2d row=%2d" % (dx // 16, dx % 16, cry - cfg.TEXT_Y)
        buckets[key] += 1
        if len(samples[key]) < 2:
            samples[key].append("cyc=%d x=%d got=%06X want=%06X romi=%d grow=%d gb=%04X hit=%s"
                                % (r["cyc"], x, got, TCOL, p["romi"], p["grow"], p["gbits"],
                                   "".join(str(z) for z in p["hit"])))
print("=== 漏画（模型说该白、DUT 没白）共 %d 类 / %d 像素 ===" % (len(buckets), sum(buckets.values())))
for k, v in sorted(buckets.items())[:40]:
    print("  %-22s x%-3d  %s" % (k, v, samples[k][0] if samples[k] else ""))
