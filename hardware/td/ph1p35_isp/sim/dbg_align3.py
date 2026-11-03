#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""判定 w_pix_text_hit 属于哪一拍的像素：对每个延迟，用该拍 hit+gb 去预测 O_tdata。"""
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
    rows.append({"cyc": int(f[0]), "Id": f[4], "Ov": int(f[5]), "Od": f[8]})
cfg = C.Config(*hdr)
pl = open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
PR = {}
for ln in pl:
    f = ln.split()
    if len(f) < 17: continue
    PR[int(f[0])] = {"h": [int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                     "rx": int(f[5], 16), "ry": int(f[6], 16), "col0": int(f[7], 16),
                     "gb": int(f[8], 16), "cb": int(f[9], 16), "ci": int(f[10], 16),
                     "inc": int(f[12]), "inr": int(f[13]), "row": int(f[14], 16)}
TCOL = 0xFFFFFF


def decoded_beat(Od):
    """O_tdata 若含未替换像素，反解其 beat；全替换则 None。"""
    v = int(Od, 16) & ((1 << 96) - 1)
    for ch in range(4):
        g = (v >> (72 - 24 * ch)) & 0xFFFFFF
        if g == TCOL: continue
        b, x, c = C.decode_pix(g)
        if c == ch: return b
    return None


print("cyc    O_tdata beat(x,y)      probe(rx,ry,inc,inr,cb,ci,gb,hit)   gb 预测 hit")
n = 0
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    b = decoded_beat(r["Od"])
    if b is None: continue
    y, xb = b // cfg.BPL, (b % cfg.BPL) * 4
    if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    pr = PR.get(r["cyc"])
    if pr is None: continue
    dx = xb - cfg.TEXT_X
    code = C.char_code(dx // 16, cfg)
    gbexp = C.CHAR_BITS(C.char_rom_idx(code), (y - cfg.TEXT_Y) & 0xF)
    hit_exp = "".join(str((gbexp >> (15 - (dx % 16 + k))) & 1) for k in range(4))
    print("%-6d b=%-5d (x=%3d,y=%3d)  (%2d,%3d,%d,%d,%d,%2d,%04X,%s)  exp hit %s  probe gb %04X"
          % (r["cyc"], b, xb, y, pr["rx"], pr["ry"], pr["inc"], pr["inr"],
             pr["cb"], pr["ci"], pr["gb"], "".join(str(z) for z in pr["h"]),
             hit_exp, pr["gb"]))
    n += 1
    if n >= 14: break
