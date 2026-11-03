#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""M6 前期数值探针：确认 160x64 / 7 帧下运动格子非空、且常见变异可分辨。"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
os.environ["ALG_W"], os.environ["ALG_H"] = "160", "64"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
for _d in (r"C:\Users\29072\PycharmProjects\PythonProject8", HERE):
    if os.path.isfile(os.path.join(_d, "alg_ref.py")):
        sys.path.insert(0, _d)
        break

import numpy as np            # noqa: E402
import alg_ref as A           # noqa: E402
from gen_stim_top_full import build_image, W, H, RED_COL0, RED_COL_W, RED_ROW0, RED_ROW1  # noqa: E402

DS = 8
CX, CY = W // DS, H // DS
TH = 24
imgs = [build_image(f) for f in range(7)]
print("W=%d H=%d CX=%d CY=%d depth=%d" % (W, H, CX, CY, CX * CY))


def grid(img):
    g = A.gray_bt601(img).astype(np.int32)
    return g[0::DS, 0::DS]


def bbox_of(mot):
    ys, xs = np.nonzero(mot)
    if ys.size == 0:
        return None
    return (int(xs.min()) * DS, int(xs.max()) * DS + DS - 1,
            int(ys.min()) * DS, int(ys.max()) * DS + DS - 1)


for f in range(7):
    r0, r1, c0, c1 = (RED_ROW0, RED_ROW1,
                      RED_COL0 + (W // 32) * f, RED_COL0 + (W // 32) * f + RED_COL_W)
    if f == 0:
        mot_abs = np.zeros((CY, CX), dtype=bool)
        mot_sgn = np.zeros((CY, CX), dtype=bool)
    else:
        d = grid(imgs[f]) - grid(imgs[f - 1])
        mot_abs = np.abs(d) > TH
        mot_sgn = d > TH                      # 变异：只认"变亮"方向
    dcnt = int((mot_abs != mot_sgn).sum())
    print("f=%d red cols[%d,%d] rows[%d,%d]  红块采样列=%s"
          % (f, c0, c1, r0, r1, sorted(set(x for x in range(c0, c1 + 1) if x % 8 == 0))))
    print("   运动格子=%d  bbox=%s  有符号变异差异格子=%d"
          % (int(mot_abs.sum()), bbox_of(mot_abs), dcnt))
    ys, xs = np.nonzero(mot_abs)
    if ys.size:
        print("   格子(x=%s, y=%s) 灰度 cur=%s prev=%s" %
              (list(xs * DS), list(ys * DS),
               list(grid(imgs[f])[ys, xs]),
               list(grid(imgs[f - 1])[ys, xs]) if f else []))

# 首帧（f=0）模拟"存储器为 0"的错误期望会带来多少差异格子
g0 = grid(imgs[0])
print("若首帧 prev=0：运动格子 = %d / %d（任务书 2.1 的假设不成立）"
      % (int((g0 > TH).sum()), g0.size))
print("逐帧 bbox（运动）：", [bbox_of(np.zeros((CY, CX), bool)) if f == 0 else
                              bbox_of(np.abs(grid(imgs[f]) - grid(imgs[f - 1])) > TH)
                              for f in range(7)])
