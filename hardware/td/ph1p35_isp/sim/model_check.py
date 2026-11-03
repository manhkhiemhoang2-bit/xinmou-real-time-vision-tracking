#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在 Python 里把 osd_mixer 的相位关系建出来，跑 check_osd 的模型，找出零错的配置。

关键的已知事实（全部从 dump 直接量得，不再靠推理）：
  · 探针 rows[i]["rx"/"ry"] = 第 i 拍 r_x_now/r_y_now（装载沿之前的初值）
  · 探针 rows[i]["nx"/"ny"] = 第 i 拍 w_x_nx/w_y_nx（组合，就是本拍数据的坐标）
  · 探针 rows[i]["beat"]    = 第 i 拍总线上那份 stim 的编号
  · rows[i]["Od"] 那份像素的 beat  = rows[i]["beat"] - 1     （实测）
  · 判据坐标探针 rows[i]["rx"/"ry"] 描述的 beat = rows[i-1]["beat"] （实测）
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "osd_work", "dump_osd.txt")
hdr, rows = C.parse(DUMP)
cfg = C.Config(*hdr)
BPL = cfg.BPL


def beat_of(tdata_hex):
    return ((int(tdata_hex, 16) >> 72) & 0xFFFFFF) >> 7


print("=== 核对两条实测关系 ===")
n1 = n2 = 0
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    if beat_of(r["Od"]) == r["beat"] - 1: n1 += 1
    if r["Ov"] == 1 and i > 0 and rows[i]["rx"] == rows[i - 1]["nx"]: n2 += 1
print("  O_tdata beat == beat-1 : %d 拍" % n1)
print("  rx[i] == nx[i-1]       : %d 拍" % n2)

# 判据坐标描述的是哪个 beat？
mism = 0
tot = 0
for i, r in enumerate(rows):
    if r["Ov"] != 1 or i == 0: continue
    tot += 1
    b_prev = rows[i - 1]["beat"]
    if not (r["rx"] == (b_prev % BPL) and r["ry"] == b_prev // BPL):
        mism += 1
print("  判据坐标 == 上一拍总线 beat 的坐标 : %d/%d 相符" % (tot - mism, tot))
