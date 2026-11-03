#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_probe_align.py —— 把 M7 那 1 个多余输出有效拍定位到具体周期/帧/行/拍号。

只读 dump（不跑仿真）。用法：ALG_W=160 ALG_H=64 python _m7_probe_align.py [dump]
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np            # noqa: E402
import check_alg_top_full as C  # noqa: E402

DUMP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "_m7work", "dump_top_full.txt")


def main():
    d = C.parse(DUMP, quiet=True)
    ic = np.nonzero(d["Iv"])[0]
    oc = np.nonzero(d["Ov"])[0]
    lat = C.lat_of_beat(d)
    exp = ic + lat
    print("输入有效拍 %d / 输出有效拍 %d" % (ic.size, oc.size))
    print("期望输出有效拍 %d（逐档延迟 M7=%d）" % (exp.size, C.LAT_M7))
    m = min(oc.size, exp.size)
    badpos = np.nonzero(oc[:m] != exp[:m])[0]
    print("前 %d 个输出拍里位置不符的有 %d 个；首个不符 index=%s"
          % (m, badpos.size, badpos[:6].tolist()))
    # 输出有效拍里"多出来"的那些（不在期望集合里的周期）
    expset = set(int(x) for x in exp)
    extra = [int(t) for t in oc if int(t) not in expset]
    missing = [int(t) for t in exp if t not in set(int(x) for x in oc)]
    print("多出来的输出有效拍周期 = %s" % (extra,))
    print("缺失的输出有效拍周期   = %s" % (missing[:10],))
    for t in extra + missing[:5]:
        j = int(np.searchsorted(ic, t - C.LAT)) if t >= C.LAT else 0
        print("   周期 %d：附近输入有效拍 %d（帧 %d 行 %d 拍号 %d）  O_mode=%d O_tlast=%d O_tuser=%d"
              % (t, int(ic[min(j, ic.size - 1)]),
                 int((min(j, ic.size - 1)) // C.BPF),
                 int((min(j, ic.size - 1) // C.BPL) % C.H),
                 int((min(j, ic.size - 1)) % C.BPL),
                 int(d["omode"][t]), int(d["Ol"][t]), int(d["Ou"][t])))
    # 逐帧统计
    k = np.arange(ic.size, dtype=np.int64)
    frm_in = k // C.BPF
    for fr in range(8):
        src = ic[frm_in == fr]
        dst5 = src + C.LAT
        dst8 = src + C.LAT_M7
        n5 = int(np.isin(dst5, oc).sum())
        n8 = int(np.isin(dst8, oc).sum())
        print("  帧 %d（M%d）：输入 %d 拍；按 LAT=5 命中的输出拍 %d；按 LAT=8 命中 %d"
              % (fr, C.MODE_SCHED[fr], src.size, n5, n8))
    ou = np.nonzero(d["Ou"])[0]
    print("O_tuser 周期 = %s" % (ou.tolist(),))
    print("O_tlast 个数 = %d（期望 %d）" % (int(d["Ol"][oc].sum()), 8 * C.H))
    return 0


if __name__ == "__main__":
    sys.exit(main())
