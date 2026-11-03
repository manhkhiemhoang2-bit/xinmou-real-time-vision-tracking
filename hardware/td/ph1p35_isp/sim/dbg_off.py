#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""不猜相位：用 dump 的 beat 列做唯一基准，扫描"判据坐标哪一拍"。

dump 的 beat 列 = RTL 眼里本拍总线的 beat（r_beat），而与 O_tdata 同拍的那份
像素是 beat-1。判据坐标（r_x/r_y 探针）到底是哪一拍，用数据自己说话。
"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "osd_work", "dump_osd.txt")
hdr, rows = C.parse(DUMP)
cfg = C.Config(*hdr)
TC = 0xFFFFFF
BPL = cfg.BPL

# rows[i]["beat"] = 本拍总线 beat；O_tdata 那份像素 = beat-1
# 判据坐标探针 rows[j]["rx"/"ry"]，扫 j = i, i-1, i-2, i-3
res = collections.Counter()
for off in (0, -1, -2, -3):
    ok = bad = 0
    for i, r in enumerate(rows):
        if r["Ov"] != 1: continue
        j = i + off
        if j < 0: continue
        pr = rows[j]
        dst_beat = r["beat"] - 1        # O_tdata 那一份像素的 beat
        if dst_beat < 0: continue
        y = dst_beat // BPL
        if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
        xb = (dst_beat % BPL) * 4
        if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
        dx = xb - cfg.TEXT_X
        gb = C.CHAR_BITS(C.char_rom_idx(C.char_code(dx // 16, cfg)), (y - cfg.TEXT_Y) & 0xF)
        exp = [str((gb >> (15 - (dx % 16 + k))) & 1) for k in range(4)]
        v = int(r["Od"], 16) & ((1 << 96) - 1)
        got = []
        for ch in range(4):
            g = (v >> (72 - 24 * ch)) & 0xFFFFFF
            got.append("1" if g == TC else "0")
        # 只能比较"应白"的位（应黑但被 Logo 或原像素覆盖时无法判）
        for k in range(4):
            if exp[k] == "1":
                if got[k] == "1": ok += 1
                else: bad += 1
    res[off] = (ok, bad)
print("判据坐标取 rows[i+off]；O_tdata 像素 = beat-1")
for off in sorted(res):
    print("  off=%+d : 应白且真白 %5d / 应白却黑 %5d" % (off, res[off][0], res[off][1]))
