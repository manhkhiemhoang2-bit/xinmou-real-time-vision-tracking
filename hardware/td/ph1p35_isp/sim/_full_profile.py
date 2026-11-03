#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_full_profile.py —— 定位全尺寸 checker 的时间/内存瓶颈（每步单独计时）。

用法：python _full_profile.py [frames]
"""
from __future__ import annotations

import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_alg_top_full as C  # noqa: E402


def step(tag, fn):
    """⚠ 不要用 tracemalloc：它会给每次 numpy 分配记账，把大数组操作拖慢上百倍
    （实测：加了 tracemalloc 的 _full_profile 跑 10 分钟没输出）。"""
    t0 = time.time()
    r = fn()
    print("  %-28s %8.1f s" % (tag, time.time() - t0), flush=True)
    return r


frames = int(sys.argv[1]) if len(sys.argv) > 1 else 1
print("=" * 74)
print("全尺寸 checker 分步计时  frames=%d" % frames)
print("=" * 74)
d = step("parse", lambda: C.parse(os.path.join(HERE, C.DUMP)))
print("     n=%d beats=%d" % (d["ncycles"], d["nbeats"]))
exp_img, exp_pack, bb = step("expected_frames", lambda: C.expected_frames(frames, None))
print("     bbox=%s" % (bb,))
step("check_a", lambda: C.check_a(d, None, True))
step("check_b", lambda: C.check_b(d, exp_pack, frames, None, True))
step("check_c", lambda: C.check_c(d, exp_img, frames, None, True))
step("check_d", lambda: C.check_d(d, frames, None, True))
step("check_e", lambda: C.check_e(d, frames, None, True))
step("check_blanking", lambda: C.check_blanking(d, frames, True))
step("check_xz", lambda: C.check_xz(d, True))
step("check_shape", lambda: C.check_shape(d, frames, True))
step("check_bbox", lambda: C.check_bbox(d, bb, frames, True))
step("check_stim", lambda: C.check_stim(d, frames, True))
step("self_consistency", lambda: C.self_consistency(frames))
print("=" * 74)
