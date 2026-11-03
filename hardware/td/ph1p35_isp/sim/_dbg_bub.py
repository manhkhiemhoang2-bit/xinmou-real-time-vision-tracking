#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""一次性诊断：气泡长度 x 底行右邻(前瞻)可得性 的组合 —— 给"1 个像素能不能消掉"定量。"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _probe_rtlmodel as M

W, H, F = 32, 10, 8
stim = M.load_stim(os.path.join(HERE, "stim_rf.hex"))

print("行口径固定为：taps=fixed(横向对齐已修) + reset=rowhead_la + mask_rows=3 + 参考下移一行")
print("%-8s %-8s %s" % ("气泡长度", "前瞻口径", "逐像素失配"))
for skip in (1, 2, 3):
    for bm in ("bus", "bus1", "late", "ideal"):
        res = M.model(stim, W, H, taps_mode="fixed", reset_mode="rowhead_la",
                      mask_rows=3, bot4_mode=bm, bub_skip=skip)
        # 就地比对（参考下移一行）
        import numpy as np
        import ref_region_fill as R
        BPL, BPF = res["BPL"], res["BPF"]
        ob = np.array(res["out_beats"], dtype=np.uint32).reshape(-1, 4)
        bad = 0
        for f in range(F):
            b = stim[f * BPF:(f + 1) * BPF]
            mask = (b == R.WHITE).reshape(H, W)
            filled, _ = R.scanline_fill_masked(R.dilate3x3(mask), W, H)
            exp = R.bool_to_mask(filled).reshape(H, W)
            exp_s = np.zeros_like(exp)
            exp_s[1:, :] = exp[:-1, :]
            d = exp_s.reshape(-1, 4) != ob[f * BPF:(f + 1) * BPF]
            bad += int(d.sum())
        name = {"bus": "本拍总线(=现在)", "bus1": "允许+1周期(一拍修正)",
                "late": "允许+2周期(零代价重定时)", "ideal": "永远拿得到(上界)"}[bm]
        print("%-8d %-22s %4d" % (skip, name, bad))
