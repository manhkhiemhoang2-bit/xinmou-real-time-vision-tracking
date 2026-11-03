#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""诊断：dump 里的输入拍序列 vs stim 文件 vs 参考输出。"""
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, ".")
import check_region_fill as C
import ref_region_fill as R

d = C.load_dump("dump_rf.txt")
in_beats = C.beats_of(d["id"], d["iv"])
out_beats = C.beats_of(d["od"], d["ov"])
stim = C.load_hex_beats("stim_rf.hex")

print("dump 输入拍数 %d  stim 拍数 %d  输出拍数 %d"
      % (in_beats.shape[0], stim.shape[0], out_beats.shape[0]))
n = min(in_beats.shape[0], stim.shape[0])
bad = np.nonzero((in_beats[:n] != stim[:n]).any(axis=1))[0]
print("输入拍与 stim 不一致的拍号（前 20）:", bad[:20].tolist(), " 共", bad.size)
for k in bad[:6]:
    b = int(k)
    print("  beat %d: dump=%s stim=%s" %
          (b, [hex(int(x)) for x in in_beats[b]], [hex(int(x)) for x in stim[b]]))

exp = R.ref_region_fill(R.ref_frames_from_beats(stim, 32, 10), 32, 10)
exp_beats = R.frames_to_beats(exp, 32, 10)
bad2 = np.nonzero((out_beats[:n] != exp_beats[:n]).any(axis=1))[0]
print("输出拍与参考不一致的拍号（前 20）:", bad2[:20].tolist(), " 共", bad2.size)
for k in bad2[:6]:
    b = int(k)
    print("  beat %d (frame %d row %d): got=%s exp=%s in=%s" %
          (b, b // 80, (b % 80) // 8, [hex(int(x)) for x in out_beats[b]],
           [hex(int(x)) for x in exp_beats[b]], [hex(int(x)) for x in in_beats[b]]))
