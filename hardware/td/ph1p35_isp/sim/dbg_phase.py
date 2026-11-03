#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""扫描：w_pix_text_hit 需要打几拍才与"正在被处理的像素"对齐。

不依赖任何 RTL 内部相位假设：像素坐标直接从 I_tdata 反解（TB 的单射值图），
命中位取 dump 的 T 列（= w_pix_text_hit）。对每个延迟 sh，检查
    hit[cyc]  是否等于  规格模型(像素坐标 of I_tdata[cyc+sh])
"""
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
    rows.append({"cyc": int(f[0]), "Id": f[4], "T": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)
BPL = cfg.BPL


def beat_of(tdata_hex):
    v = int(tdata_hex, 16)
    # 第一个像素 [95:72] 的 beat（TB 值图：pix = (beat<<7)|((beat%32)<<2)|ch）
    return ((v >> 72) & 0xFFFFFF) >> 7


# 索引 -> cyc
idx = {r["cyc"]: i for i, r in enumerate(rows)}
res = collections.Counter()
detail = collections.defaultdict(list)
for sh in range(0, 5):
    ok = bad = 0
    for i, r in enumerate(rows):
        src = rows[i + sh] if i + sh < len(rows) else None
        if src is None: continue
        b = beat_of(src["Id"])
        y, xb = b // BPL, (b % BPL) * 4
        if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
        if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
        dx = xb - cfg.TEXT_X
        code = C.char_code(dx // 16, cfg)
        gb = C.CHAR_BITS(C.char_rom_idx(code), (y - cfg.TEXT_Y) & 0xF)
        exp = "".join(str((gb >> (15 - (dx % 16 + k))) & 1) for k in range(4))
        dut = "".join(str(z) for z in r["T"])
        if exp == dut: ok += 1
        else:
            bad += 1
            if len(detail[sh]) < 3:
                detail[sh].append("cyc=%d I_tdata@+%d beat=%d (x=%d,y=%d) dx=%d gb=%04X dut=%s exp=%s"
                                  % (r["cyc"], sh, b, xb, y, dx, gb, dut, exp))
    res[sh] = (ok, bad)
print("延迟 sh 的含义：hit[cyc] 对应 I_tdata[cyc+sh] 的那个像素")
for sh in sorted(res):
    print("  sh=%d : 命中集合相符 %5d / 不符 %5d" % (sh, res[sh][0], res[sh][1]))
for sh in sorted(detail):
    for d in detail[sh]: print("    sh=%d %s" % (sh, d))
