# -*- coding: utf-8 -*-
"""
_osd_probe_pos.py —— 数出文字带里**每个字符格子到底画没画东西**

口径：dump 里同一拍有输入(I)和输出(O)。文字面"命中"的像素会被替换成文字色，
所以 **O != I 的像素 = 被 OSD 改过的像素**。按 16 像素一格统计，就能看出
哪几格在画、哪几格是空的 —— 不用猜，直接数。
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_osd as C  # noqa: E402

DUMP = os.path.join(HERE, "_osd_he", "dump_osd.txt")
TEXT_X, TEXT_Y = 0, 40          # 与 tb_osd_mixer.v 一致
W = 640

rows = C.parse_dump(DUMP)
by_cyc = {r["cyc"]: r for r in rows}
print("dump 解析：%d 行；画面 %dx%d" % (len(rows), W, 128))

# 逐像素：只看文字带 y ∈ [TEXT_Y, TEXT_Y+16)
hit = {}          # (x, y) -> True 若被 OSD 改过
for r in rows:
    if not r["ov"]:
        continue
    src = by_cyc.get(r["cyc"] - 2)
    if src is None or not src["iv"]:
        continue
    y = (src["ibeat"] // (W // 4)) % 128
    if not (TEXT_Y <= y < TEXT_Y + 16):
        continue
    xb = (src["ibeat"] % (W // 4)) * 4
    o = r["odata"]; i = src["idata"]
    for k in range(4):
        ob = o[24 - 6 * k - 6: 24 - 6 * k]
        ib = i[24 - 6 * k - 6: 24 - 6 * k]
        if ob != ib:
            hit[(xb + k, y)] = True

print("\n每个字符格子（16x16）被 OSD 改过的像素数：")
print("  格号: " + "".join("%5d" % p for p in range(32)))
cnt = []
for p in range(32):
    c = 0
    for x in range(TEXT_X + p * 16, TEXT_X + p * 16 + 16):
        for y in range(TEXT_Y, TEXT_Y + 16):
            if hit.get((x, y)):
                c += 1
    cnt.append(c)
print("  数量: " + "".join("%5d" % c for c in cnt))

drew = [p for p in range(32) if cnt[p] > 0]
blank = [p for p in range(32) if cnt[p] == 0]
print("\n画了东西的格号：%s" % drew)
print("全空的格号    ：%s" % blank)
