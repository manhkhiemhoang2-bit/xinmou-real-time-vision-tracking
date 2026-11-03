#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""穷举候选模型，找出与 DUT 命中集合 100% 相符的那一个。"""
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
    rows.append({"Ov": int(f[5]), "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)
TL = cfg.TEXT_Y


def bitMSB(gb, c):
    return (gb >> (15 - (c & 15))) & 1


def bitLSB(gb, c):
    return (gb >> (c & 15)) & 1


def pick(gb, base, order):
    f = bitMSB if order == "MSB" else bitLSB
    return "".join(str(f(gb, base + k)) for k in range(4))


results = collections.Counter()
detail = {}
for i in range(len(rows)):
    r = rows[i]
    if r["Ov"] != 1: continue
    if not (TL <= r["ry"] < TL + 16): continue        # 用 DUT 自己的 y
    xb = 4 * r["rx"]
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    dx = xb - cfg.TEXT_X
    dut = "".join(str(b) for b in r["hit"])
    gb = r["gbits"]
    cands = []
    for order in ("MSB", "LSB"):
        for name, base in (("dx%16", dx % 16), ("0", 0), ("dx>>4", (dx >> 4) % 16),
                           ("dx%8*2", (dx % 8) * 2), ("dx%4*4", (dx % 4) * 4),
                           ("(dx%16)^15", (dx % 16) ^ 15)):
            if pick(gb, base, order) == dut:
                cands.append(order + ":" + name)
    if not cands:
        cands = ["NONE"]
    results[tuple(cands)] += 1
    detail.setdefault(tuple(cands), (r["rx"], r["ry"], dx, gb, dut))

print("=== 同拍（用 rows[i] 自己的 rx/ry/gbits）===")
for k, v in results.most_common(10):
    print("  %-52s : %d 拍   例 %s" % (str(k)[:52], v, detail[k]))
print("总拍数 %d" % sum(results.values()))
