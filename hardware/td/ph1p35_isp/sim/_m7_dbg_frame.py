#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_dbg_frame.py —— 把 DUT 的 M7 帧从 dump 里取出来，与多个候选金标准逐个比。

候选：shift s ∈ {0,1,2,3} × masked ∈ {True,False}，以及"阈值后直接填充"的变体。
目的：定位 B 判据那 1051 拍的失配到底是"位移口径"还是"掩蔽口径"还是别的。

用法：ALG_W=160 ALG_H=64 python _m7_dbg_frame.py [dump]
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np            # noqa: E402
import check_alg_top_full as C  # noqa: E402
import ref_region_fill as RF    # noqa: E402

DUMP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "_m7work", "dump_top_full.txt")
FR = 7


def dut_frame(d, fr):
    """把 dump 里第 fr 帧的输出有效拍还原成 (H,W,3) uint8。"""
    oc = np.nonzero(d["Ov"])[0]
    k = np.arange(oc.size, dtype=np.int64)
    sel = (k // C.BPF) == fr
    hi, lo = d["odv_hi"][sel], d["odv_lo"][sel]
    n = int(sel.sum())
    assert n == C.BPF, "帧 %d 输出有效拍 %d != %d" % (fr, n, C.BPF)
    px = np.stack([C._pix_of_pair(hi, lo, p) for p in range(4)], axis=1)   # (BPF,4)
    img = px.reshape(C.H, C.W)
    out = np.empty((C.H, C.W, 3), dtype=np.uint8)
    out[:, :, 0] = (img >> 16) & 0xFF
    out[:, :, 1] = (img >> 8) & 0xFF
    out[:, :, 2] = img & 0xFF
    return out


def cand(img, sh, masked, thr=C.RF_TH):
    bin3 = C.m7_binarize(C.m3_raw(img), thr)
    mask = (bin3[:, :, 0] == 255)
    filled = RF.ref_region_fill([mask], C.W, C.H, masked=masked)[0]
    o = np.where((filled == 0xFFFFFF)[:, :, None], np.uint8(255), np.uint8(0))
    for _ in range(sh):
        o = C._shift1(o)
    return o


def main():
    d = C.parse(DUMP, quiet=True)
    img = C.images(8)[FR]
    got = dut_frame(d, FR)
    print("DUT 帧 %d 前景 %d / %d" % (FR, int((got[:, :, 0] == 255).sum()), C.H * C.W))
    print("-" * 70)
    for masked in (True, False):
        for sh in (0, 1, 2, 3):
            e = cand(img, sh, masked)
            nb = int((e != got).any(axis=2).sum())
            print("  masked=%-5s shift=%d : 不符 %6d 像素  %s"
                  % (masked, sh, nb, "<== 完全一致" if nb == 0 else ""))
    # 逐行看 shift1/masked 的差异分布
    e = cand(img, 1, True)
    bad = (e != got).any(axis=2)
    rows = np.nonzero(bad.any(axis=1))[0]
    print("-" * 70)
    print("shift1+masked 的失配行 = %s（共 %d 行）" % (rows.tolist()[:20], rows.size))
    for y in rows[:6]:
        cols = np.nonzero(bad[y])[0]
        print("  行 %2d：失配 %3d 列，列号 %s" % (y, cols.size, cols.tolist()[:24]))
        if y < C.H:
            print("       got %s" % " ".join("%02X" % v for v in got[y, cols[:8], 0]))
            print("       want%s" % " ".join("%02X" % v for v in e[y, cols[:8], 0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
