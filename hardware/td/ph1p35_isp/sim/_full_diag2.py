#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_full_diag2.py —— 逐拍定位全尺寸 Q1 现象：第 0 输出行右半段的"全 0"从哪来。

只读 dump（不读 RTL 内部量），用激励侧坐标 + 金标准判断。
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np            # noqa: E402
import check_alg_top_full as C  # noqa: E402
from gen_stim_top_full import BPL, H, BPF  # noqa: E402


def h(v):
    return "%024X" % int(v)


d = C.parse(os.path.join(HERE, C.DUMP), quiet=True)
exp_img, exp_pack, bb = C.expected_frames(1, None)
f, y, xg, valid = C.beat_axes(d, 1)
got = d["odv"]
want = exp_pack[0, y * BPL + xg]
eq = (got == want) | (~valid)
bad = np.nonzero(~eq)[0]
print("不符输出有效拍 %d / %d" % (bad.size, eq.size))
print("不符拍的行分布：")
rows = y[bad]
for r in np.unique(rows):
    n = int((rows == r).sum())
    xr = xg[bad][rows == r]
    print("  行 %-4d 不符 %-6d 拍（拍号 %d..%d）" % (r, n, xr.min(), xr.max()))
print("\n不符的输入拍号分布（前 20 个不同值）：%s" % np.unique(xg[bad])[:20].tolist())
print("全 0 的不符拍数：%d / %d" % (int((got[bad] == 0).sum()), bad.size))

print("\n=== 第 0 输出行（输入 y=0）逐段样本 ===")
for x in (0, 1, 4, 100, 155, 156, 157, 158, 200, 317, 318, 319):
    i = int(np.nonzero(valid & (y == 0) & (xg == x))[0][0])
    print("  拍号 %-4d 输入 %s  输出 %s  期望 %s  %s"
          % (x, h(d["idv"][i]), h(got[i]), h(want[i]), "OK" if eq[i] else "MISMATCH"))
print("\n=== 第 1 输出行（输入 y=1）逐段样本 ===")
for x in (0, 1, 4, 155, 156, 157, 158, 200, 319):
    i = int(np.nonzero(valid & (y == 1) & (xg == x))[0][0])
    print("  拍号 %-4d 输入 %s  输出 %s  期望 %s  %s"
          % (x, h(d["idv"][i]), h(got[i]), h(want[i]), "OK" if eq[i] else "MISMATCH"))
print("\n=== 第 2 输出行（输入 y=2）逐段样本 ===")
for x in (0, 1, 2, 4, 200, 319):
    i = int(np.nonzero(valid & (y == 2) & (xg == x))[0][0])
    print("  拍号 %-4d 输入 %s  输出 %s  期望 %s  %s"
          % (x, h(d["idv"][i]), h(got[i]), h(want[i]), "OK" if eq[i] else "MISMATCH"))

print("\n=== 输入激励第 0 行末尾几拍（确认激励本身非 0）===")
for x in (313, 314, 315, 316, 317, 318, 319):
    i = int(np.nonzero(valid & np.arange(d["nbeats"]) - C.LAT >= 0
                       if False else valid & (y == 0) & (xg == x))[0][0])
    print("  xg=%d  I=%s" % (x, h(d["idv"][i])))
