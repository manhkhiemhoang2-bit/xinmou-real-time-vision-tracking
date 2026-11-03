#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_full_diag.py —— 1 帧 dump 的定性诊断：输入/输出/期望三方对照（不跑 ModelSim）。"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np            # noqa: E402
import check_alg_top_full as C  # noqa: E402  (它会先把 alg_ref 所在目录加进 sys.path)
import alg_ref as A           # noqa: E402
from gen_stim_top_full import BPL, H, W, BPF  # noqa: E402


def h(v):
    return "%024X" % int(v)


d = C.parse(os.path.join(HERE, C.DUMP))
exp_img, exp_pack, bb = C.expected_frames(1, None)
print("bbox=%s  exp_pack.shape=%s" % (bb, exp_pack.shape))
print("dump: cycles=%d beats=%d" % (d["ncycles"], d["nbeats"]))
print("\n前 8 个输入有效拍：")
for i in range(8):
    print("  beat %d (cyc %d): I=%s O=%s want=%s  %s"
          % (i, d["vidx"][i], h(d["idv"][i]), h(d["odv"][i]), h(exp_pack[0, i]),
             "OK" if d["odv"][i] == exp_pack[0, i] else "MISMATCH"))
print("\n前 6 拍（含非有效）的原始列：")
for i in range(6):
    print("  cyc=%d Iv=%d Ov=%d id=%s od=%s" %
          (d["cyc"][i], d["Iv"][i], d["Ov"][i], h(d["id"][i]), h(d["od"][i])))

got = d["odv"]
want = exp_pack[0]
eq = (got == want)
print("\n逐拍相等：%d/%d；不符 %d" % (int(eq.sum()), eq.size, int((~eq).sum())))
bad = np.nonzero(~eq)[0]
print("不符拍号：首 %s ... 末 %s" % (bad[:8].tolist(), bad[-4:].tolist()))
print("不符拍的行分布：")
yy = (bad // BPL) % H
xg = bad % BPL
import collections
print("  行号直方图（前 10）：%s" % collections.Counter(yy.tolist()).most_common(10))
print("  拍号直方图（全部）：%s" % sorted(collections.Counter(xg.tolist()).items())[:12])
print("  行号范围：%d..%d" % (yy.min(), yy.max()))
print("\n不符样本（前 6 个）：")
for i in bad[:6]:
    print("  beat %-7d 行 %-4d 拍号 %-4d got=%s want=%s  I=%s"
          % (i, (i // BPL) % H, i % BPL, h(got[i]), h(want[i]), h(d["idv"][i])))
print("\n图像行 0 的像素（前 8 列）：%s" % exp_img[0][0, :8].tolist())
print("图像行 1 的像素（前 8 列）：%s" % exp_img[0][1, :8].tolist())
print("图像行 2 的像素（前 8 列）：%s" % exp_img[0][2, :8].tolist())
