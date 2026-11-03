#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""比较三份命中集合：DUT 实际输出像素 / dump 的 hit 探针 / 规格模型。"""
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
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8], "Id": f[4],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16), "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)
TCOL = 0xFFFFFF

c_pix_vs_model = collections.Counter()
c_probe_vs_model = collections.Counter()
extra = collections.Counter()
miss = collections.Counter()
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    for ch in range(4):
        x = 4 * crx + ch
        if not (cfg.TEXT_X <= x < cfg.TEXT_X + 256): continue
        dx = x - cfg.TEXT_X
        got = (int(r["Od"], 16) >> (72 - 24 * ch)) & 0xFFFFFF
        vt, kt = C.expect_pix_at(cfg, 0, crx, cry, ch)
        want_white = (kt == "text")
        got_white = (got == TCOL)
        # probe 用的是 p 那一拍的 hit
        prb = bool(p["hit"][3 - ch])
        if got_white != want_white:
            k = "col=%2d ci=%d" % (dx % 16, dx // 16)
            (extra if got_white else miss)[k] += 1
        c_pix_vs_model[(got_white, want_white)] += 1
        c_probe_vs_model[(prb, want_white)] += 1

print("=== DUT 输出像素 vs 模型 (got_white, want_white) ===")
for k, v in sorted(c_pix_vs_model.items()):
    print("   got_white=%-5s want_white=%-5s : %d" % (k[0], k[1], v))
print("=== dump hit 探针(p 拍) vs 模型 ===")
for k, v in sorted(c_probe_vs_model.items()):
    print("   probe=%-5s want=%-5s : %d" % (k[0], k[1], v))
print("=== 多画(extra) 按字内列 ===")
print("   " + str(dict(sorted(extra.items()))))
print("=== 漏画(miss) 按字内列 ===")
print("   " + str(dict(sorted(miss.items()))))
