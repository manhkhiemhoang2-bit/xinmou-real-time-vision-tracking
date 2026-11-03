#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""复刻 check_osd.py 主循环，输出每 (ci,row) 的 DUT/模型 bitmap 对照。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "osd_work", "dump_osd.txt")
hdr, rows = C.parse(DUMP)
cfg = C.Config(*hdr)
TC = 0xFFFFFF

# dut[ci][row] = 16 chars, exp 同理；逐像素按 check_osd 的主循环口径取
dut = collections.defaultdict(lambda: ["."] * 16)
exp = collections.defaultdict(lambda: ["."] * 16)
DS = 1
for i in range(len(rows)):
    r = rows[i]
    if r["Ov"] != 1: continue
    src = rows[max(i - DS, 0)]
    b = (int(src["Id"], 16) >> 72) >> 7
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    crx, cry = rows[max(i - 1, 0)]["rx"], rows[max(i - 1, 0)]["ry"]
    if not (cfg.TEXT_Y <= cry < cfg.TEXT_Y + 16): continue
    for ch in range(4):
        x = 4 * crx + ch
        if not (cfg.TEXT_X <= x < cfg.TEXT_X + 256): continue
        dx = x - cfg.TEXT_X
        ci, col = dx // 16, dx % 16
        got = (v >> (72 - 24 * ch)) & 0xFFFFFF
        dut[(ci, cry - cfg.TEXT_Y)][col] = "#" if got == TC else "."
        vt, kt = C.expect_pix_at(cfg, b, crx, cry, ch)
        exp[(ci, cry - cfg.TEXT_Y)][col] = "#" if kt == "text" else "."

ndiff = 0
for ci in range(4):
    print("=== ci=%d code=%02X idx=%d ===" % (ci, C.char_code(ci, cfg), C.char_rom_idx(C.char_code(ci, cfg))))
    for row in range(16):
        e = "".join(exp[(ci, row)]); d = "".join(dut[(ci, row)])
        m = "" if e == d else "  <-- DIFF"
        if e != d: ndiff += 1
        print("  r%-2d exp %s  dut %s%s" % (row, e, d, m))
print("不符行数 %d" % ndiff)
