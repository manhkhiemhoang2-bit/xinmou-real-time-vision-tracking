#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""M6 交付：**全尺寸 1280x720 的期望值生成路径自测**（纯 Python，不启动 vsim）。

主控统一跑全尺寸时，这里自测过的路径就是要用的那条：
  · gen_stim_top_full 的几何/档位表（1280x720 / 12 帧）；
  · 0b 节 M6 黄金模型在全尺寸下的形状/取值（CX=160, CY=90, 深度 14400）；
  · M6 逐像素写法 与 M6 逐拍写法 的自洽（判据 self_consistency 的那一条）；
  · expected_frames 整条期望流水线（前 2 帧，够证明不炸）。
"""
from __future__ import annotations

import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
os.environ["ALG_W"], os.environ["ALG_H"] = "1280", "720"   # 必须先于 import
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np                       # noqa: E402
import check_alg_top_full as C           # noqa: E402

t0 = time.time()
print("=" * 78)
print("全尺寸期望值生成路径自测  W=%d H=%d 每行 %d 拍 帧数 %d" % (C.W, C.H, C.BPL, C.FRAMES_ALL))
print("档位时序 MODE_SCHED = %s" % (C.MODE_SCHED,))
print("M6 几何：CX=%d CY=%d 深度=%d DIFF_TH=%d  %s"
      % (C.CX, C.CY, C.CX * C.CY, C.M6_DIFF_TH,
         "含 M6 帧" if C.MODE_M6 in C.MODE_SCHED else "!! 该时序里没有 M6 帧 !!"))
print("-" * 78)

frames = C.FRAMES_ALL
t1 = time.time()
mots, mbbs, mcnt = C.m6_stats(frames)
print("1) m6_stats(%d)：%.1f s" % (frames, time.time() - t1))
for f in range(frames):
    print("   帧 %2d 模式 M%d  运动格子 %4d  bbox(像素 x0,x1,y0,y1)=%s"
          % (f, C.MODE_SCHED[f], mcnt[f], mbbs[f]))
assert all(m.shape == (C.CY, C.CX) for m in mots), "运动图形状不是 (CY,CX)"
print("   运动图形状 %s 全部正确；有运动的帧 %d/%d"
      % ((C.CY, C.CX), sum(1 for c in mcnt if c > 0), frames))

# ---- M6 两种写法自洽（逐像素 vs 逐拍），在全尺寸下跑一遍 ----
t2 = time.time()
imgs = C.images(frames)
bad = 0
picked = [f for f in range(frames) if mcnt[f] > 0][:2] or [0]
for f in picked:
    bp = mbbs[f - 1] if f >= 1 else None
    ref = C.m6_frame(imgs[f], mots[f], bp, mbbs[f], None)
    var = C.m6_beats_out(imgs, mots, mbbs, f, None).reshape(C.H, C.W, 3)
    n = int((ref != var).any(axis=2).sum())
    bad += n
    nw = int((ref == 255).all(axis=2).sum())
    nr = int(((ref[:, :, 0] == 255) & (ref[:, :, 1] == 0) & (ref[:, :, 2] == 0)).sum())
    print("2) 帧 %d：逐像素 vs 逐拍 不符像素 %d（白点像素 %d，红框像素 %d）  %s"
          % (f, n, nw, nr, "PASS" if n == 0 else "FAIL"))
print("   两种写法自洽：不符合计 %d  %.1f s  %s"
      % (bad, time.time() - t2, "PASS" if bad == 0 else "FAIL"))

# ---- 期望流水线整体（前 2 帧）----
t3 = time.time()
exp, pack, bb = C.expected_frames(2, None)
hi, lo = pack
print("3) expected_frames(2)：exp%s  pack hi%s lo%s  M5 bbox=%s  %.1f s"
      % (exp.shape, hi.shape, lo.shape, bb, time.time() - t3))
print("   注意：本时序第 0/1 帧是 M0/M1 —— 即全尺寸 12 帧跑**不会**走到 M6 分支；"
      "M6 的像素级验证在 160x64/7 帧（帧 i = 档位 i）里完成。")
print("=" * 78)
print("结论：%s（总耗时 %.1f s）" % ("PASS" if bad == 0 else "FAIL", time.time() - t0))
sys.exit(0 if bad == 0 else 1)
