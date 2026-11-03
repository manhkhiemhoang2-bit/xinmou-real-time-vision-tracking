#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_dbg_rows.py —— 把 DUT / 参考的若干行打成 0/1 字符串，肉眼看位移与形貌。

用法：ALG_W=160 ALG_H=64 python _m7_dbg_rows.py
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np              # noqa: E402
import check_alg_top_full as C    # noqa: E402
import _m7_dbg_frame as D         # noqa: E402


def bits(row):
    return "".join("#" if v else "." for v in row)


def main():
    d = C.parse(D.DUMP, quiet=True)
    img = C.images(8)[7]
    got = D.dut_frame(d, 7)
    bin3 = C.m7_binarize(C.m3_raw(img), C.RF_TH)
    edge_img = (bin3[:, :, 0] == 255)
    ref = D.cand(img, 1, True)
    refm = (ref[:, :, 0] == 255)
    print("列号 : 0         1         2         3         4         5")
    print("       0123456789012345678901234567890123456789012345678901234567890123")
    for y in [5, 6, 7, 8, 9, 10, 23, 24, 25]:
        print("y=%-3d 填充输入(M3 二值, 已下移1行) : %s" % (y, bits(edge_img[y, :64])))
        print("      DUT 输出                    : %s" % bits(got[y, :64, 0] == 255))
        print("      参考 shift1+masked          : %s" % bits(refm[y, :64]))
        print("      参考 shift0+masked          : %s"
              % bits(D.cand(img, 0, True)[y, :64, 0] == 255))
        print("      参考 shift1+unmasked        : %s"
              % bits(D.cand(img, 1, False)[y, :64, 0] == 255))
        print("")
    # 逐行统计"哪个位移候选最好"
    print("-" * 70)
    best = {}
    for sh in (0, 1, 2, 3):
        e = (D.cand(img, sh, True)[:, :, 0] == 255)
        g = (got[:, :, 0] == 255)
        per = (e != g).sum(axis=1)
        best[sh] = per
        print("shift=%d 逐行失配：0 行数=%d，行 8..15 = %s"
              % (sh, int((per == 0).sum()), per[8:16].tolist()))
    print("-" * 70)
    g = (got[:, :, 0] == 255)
    e1 = (D.cand(img, 1, True)[:, :, 0] == 255)
    print("DUT vs 参考(shift1) 每行失配（前 32 行）：%s" % (e1 != g).sum(axis=1)[:32].tolist())
    return 0


if __name__ == "__main__":
    sys.exit(main())
