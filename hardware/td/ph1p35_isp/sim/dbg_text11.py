#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""完全复刻 check_osd.py 的取数口径，逐字符打印 DUT vs 模型。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "osd_work", "dump_osd.txt")
hdr, rows = C.parse(DUMP)
cfg = C.Config(*hdr)
print("cfg TEXT=(%d,%d) W=%d H=%d BPL=%d" % (cfg.TEXT_X, cfg.TEXT_Y, cfg.W, cfg.H, cfg.BPL))

# 字符 1（'3'）的完整 16x16 对照：DUT 输出 vs 模型
CI = 1
print("=== 字符 ci=%d  code=%02X idx=%d ===" % (CI, C.char_code(CI, cfg), C.char_rom_idx(C.char_code(CI, cfg))))
for row in range(16):
    y = cfg.TEXT_Y + row
    # 找到 y 这一行的探针拍（beat 编号按整帧线性）
    dut_bits = []
    for beat_in_row in range(cfg.BPL):
        for i, r in enumerate(rows):
            if r["Ov"] != 1: continue
            src = rows[max(i - 1, 0)]
            b = (int(src["Id"], 16) >> 72) >> 7
            if b != y * cfg.BPL + beat_in_row: continue
            crx, cry = rows[max(i - 1, 0)]["rx"], rows[max(i - 1, 0)]["ry"]
            if cry != y or crx != beat_in_row: continue
            v = int(r["Od"], 16) & ((1 << 96) - 1)
            for ch in range(4):
                x = 4 * crx + ch
                if CI * 16 <= x - cfg.TEXT_X < CI * 16 + 16:
                    got = (v >> (72 - 24 * ch)) & 0xFFFFFF
                    dut_bits.append((x - cfg.TEXT_X) % 16 if got == 0xFFFFFF else None)
            break
        if len(dut_bits) >= 16: break
    gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(CI, cfg)), row)
    exp = ["#" if (gb >> (15 - c)) & 1 else "." for c in range(16)]
    dut = ["#" if c in dut_bits else "." for c in range(16)]
    mark = "" if dut == exp else "   <-- DIFF"
    print("  row%-2d exp %s   dut %s%s" % (row, "".join(exp), "".join(dut), mark))
