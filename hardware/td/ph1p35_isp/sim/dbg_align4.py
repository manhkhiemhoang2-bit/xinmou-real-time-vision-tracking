#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""决定性实验：O_tdata 的每个像素坐标是自明的（反解 beat）！
直接把 '该 beat 的规格命中' 与 DUT 的 hit 探针对齐，扫描延迟。
"""
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
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8]})
cfg = C.Config(*hdr)
pl = open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
PR = {}
for ln in pl:
    f = ln.split()
    if len(f) < 16: continue
    PR[int(f[0])] = {"h": [int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                     "rx": int(f[5], 16), "ry": int(f[6], 16), "col0": int(f[7], 16),
                     "gb": int(f[8], 16), "cb": int(f[9], 16), "ci": int(f[10], 16),
                     "inc": int(f[12]), "inr": int(f[13]), "row": int(f[14], 16),
                     "romi": int(f[15], 16)}
TCOL = 0xFFFFFF


def px_beat(v, ch):
    """O_tdata 第 ch 通道若是原始像素，反解它的 beat；否则 None。"""
    g = (v >> (72 - 24 * ch)) & 0xFFFFFF
    if g == TCOL: return None
    b, x, c = C.decode_pix(g)
    return b if c == ch else None


res = collections.Counter()
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    for ch in range(4):
        b = px_beat(v, ch)
        if b is None: continue
        y, xb = b // cfg.BPL, (b % cfg.BPL) * 4
        if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
        if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
        dx = xb - cfg.TEXT_X
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx // 16, cfg)), (y - cfg.TEXT_Y) & 0xF)
        want_bit = (gb >> (15 - (dx % 16 + ch))) & 1
        if want_bit: continue          # 只看"应当被白掉却没白"的像素
        res["orig_nonwhite"] += 1
print("O_tdata 中文字区内、规格说应为原像素的通道数：%d" % res["orig_nonwhite"])

# 现在看这些像素有没有被误涂白 -> 与 check_osd 的 extra 一致
n_extra = 0
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    for ch in range(4):
        g = (v >> (72 - 24 * ch)) & 0xFFFFFF
        if g != TCOL: continue
        # 该通道被涂白，但它的原 beat 未知（被替换）。看探针是否说应白。
        p = PR.get(r["cyc"])
        if p is None: continue
        n_extra += 1
print("O_tdata 中被涂白的通道数：%d" % n_extra)
