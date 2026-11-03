#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""离线找一个自洽的坐标配置：用 dump 的 beat 列做唯一基准。

RTL 事实（从 dump 读出，不再猜）：
  · rows[i]["beat"]      = 第 i 拍总线上那份 stim 的编号
  · O_tdata[i] 里那份像素 = beat - 1
  · rows[j]["rx"/"ry"]   = 第 j 拍 r_x_now/r_y_now 探针
扫：命中判据应当由"哪一拍的探针坐标"给出，才能让 O_tdata 的白像素落对。
"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
hdr, rows = C.parse(os.path.join(HERE, "osd_work", "dump_osd.txt"))
cfg = C.Config(*hdr)
TC, BPL = 0xFFFFFF, cfg.BPL

# 每个 (cyc, ch) 的 O_tdata 像素：白 / 原像素(反解 beat) / Logo
obs = []
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    v = int(r["Od"], 16) & ((1 << 96) - 1)
    db = r["beat"] - 1
    y, xb = db // BPL, (db % BPL) * 4
    for ch in range(4):
        g = (v >> (72 - 24 * ch)) & 0xFFFFFF
        white = (g == TC)
        is_orig = False
        if not white:
            b, x, c = C.decode_pix(g)
            is_orig = (c == ch)
        obs.append((i, r["cyc"], xb + ch, y, ch, white, is_orig))

res = collections.Counter()
for off in (-1, 0, 1, 2):
    ok = bad = 0
    for (i, cyc, x, y, ch, white, is_orig) in obs:
        j = i + off
        if j < 0 or j >= len(rows): continue
        pr = rows[j]
        if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
        if not (cfg.TEXT_X <= x < cfg.TEXT_X + 256): continue
        dx = x - cfg.TEXT_X
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx // 16, cfg)), (y - cfg.TEXT_Y) & 0xF)
        want_white = bool((gb >> (15 - dx % 16)) & 1)
        # 只能判"应白"的位：应白必须真白；应黑且输出的是原像素则不白
        if want_white:
            if white: ok += 1
            else: bad += 1
        else:
            if white: bad += 1
            elif is_orig: ok += 1
    res[off] = (ok, bad)
print("判据坐标取 rows[i+off]（O_tdata 像素 = beat-1）：")
for off in sorted(res):
    print("  off=%+d : 对 %5d / 错 %5d" % (off, res[off][0], res[off][1]))
