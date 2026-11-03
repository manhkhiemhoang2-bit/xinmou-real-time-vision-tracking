#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_dbg_inside.py —— 把失配拆成"膨胀结果 e 不同"还是"填充电平 inside 不同"。

做法：假设 DUT 的 e 与参考的 e 相同（参考 e = dilate3x3(mask) & ~barrier），
从 DUT 输出反推它的 inside（= out & ~e），再与参考的 inside 逐像素比。

用法：ALG_W=160 ALG_H=64 python _m7_dbg_inside.py
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np               # noqa: E402
import check_alg_top_full as C     # noqa: E402
import ref_region_fill as RF       # noqa: E402
import _m7_dbg_frame as D          # noqa: E402


def bits(row, n=64):
    return "".join("#" if v else "." for v in row[:n])


def main():
    d = C.parse(D.DUMP, quiet=True)
    img = C.images(8)[7]
    got = (D.dut_frame(d, 7)[:, :, 0] == 255)
    bin3 = C.m7_binarize(C.m3_raw(img), C.RF_TH)
    mask = (bin3[:, :, 0] == 255)
    e_raw = RF.dilate3x3(mask)
    e_masked = e_raw & ~RF.barrier_mask(C.W, C.H)
    ref_out, ref_ins = RF.scanline_fill_masked(e_raw, C.W, C.H)
    ref_out = C._shift1(ref_out)
    ref_ins_s = C._shift1(ref_ins)
    e_s = C._shift1(e_masked)

    print("DUT 前景 %d，参考(shift1+masked) 前景 %d" % (got.sum(), ref_out.sum()))
    bad = got != ref_out
    rows = np.nonzero(bad.any(axis=1))[0]
    print("失配行 = %s" % rows.tolist())
    for y in rows[:4]:
        # DUT 反推 inside
        dut_ins = got[y] & ~e_s[y]
        print("-" * 96)
        print("行 %d" % y)
        print("  e(shift1,masked) : %s" % bits(e_s[y]))
        print("  参考 inside      : %s" % bits(ref_ins_s[y]))
        print("  参考 out         : %s" % bits(ref_out[y]))
        print("  DUT  out         : %s" % bits(got[y]))
        print("  DUT  反推 inside : %s" % bits(dut_ins))
        diff = np.nonzero(bad[y])[0]
        print("  失配列 %s" % diff.tolist()[:30])
        # 失配处：是 e 不同还是 inside 不同？（e 相同前提下只能 inside 不同）
        print("  失配处 参考inside=%s / DUT反推=%s"
              % (ref_ins_s[y][diff].astype(int).tolist()[:20],
                 dut_ins[diff].astype(int).tolist()[:20]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
