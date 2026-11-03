#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逐 (拍,像素) 分析取位错误：DUT 命中集合 vs 规格命中集合。"""
import sys, os
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

DUMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "osd_work", "dump_osd.txt")
lines = open(DUMP, "r", encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in lines:
    f = ln.split()
    if not f:
        continue
    if f[0] == "H":
        hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append((int(f[0]), f[8], int(f[17], 16), int(f[18], 16), int(f[26], 16),
                 int(f[27], 16), int(f[28], 16),
                 [int(f[16]), int(f[15]), int(f[14]), int(f[13])]))
cfg = C.Config(*hdr)

# 打印文字行内某几拍的完整对照表
n = 0
for i, (cyc, Od, rx, ry, romi, grow, gbits, hit) in enumerate(rows):
    if not (cfg.TEXT_Y + 2 <= ry <= cfg.TEXT_Y + 3):
        continue
    if 4 * rx > 64:
        continue
    p = rows[max(i - 1, 0)]
    crx, cry = p[2], p[3]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16):
        continue
    # DUT 用的位图是 rows[i-1] 的探针值
    prx, pry, promi, pgrow, pgbits, phit = p[2], p[3], p[4], p[5], p[6], p[7]
    xb = 4 * crx
    ci = (xb - cfg.TEXT_X) // 16
    code = C.char_code(ci, cfg)
    exp_gb = C.CHAR_BITS(C.char_rom_idx(code), (cry - cfg.TEXT_Y) & 0xF)
    print("cyc=%d xbase=%d y=%d ci=%d romi=%d grow=%d DUTgb=%04X EXPgb=%04X DUTbit=%s EXPbit=%s"
          % (cyc, xb, cry, ci, promi, pgrow, pgbits, exp_gb,
             "".join(str(b) for b in phit),
             "".join(str((exp_gb >> (15 - ((xb - cfg.TEXT_X) % 16 + k))) & 1) for k in range(4))))
    n += 1
    if n > 12:
        break
