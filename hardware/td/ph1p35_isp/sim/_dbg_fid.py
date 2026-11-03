#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""模型保真性（对**当前** RTL 的 dump）：13 个字段必须逐行完全相同。"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_region_fill as C
import _probe_rtlmodel as M

d = C.load_dump(os.path.join(HERE, "dump_rf.txt"))
stim = M.load_stim(os.path.join(HERE, "stim_rf.hex"))
res = M.model(stim, 32, 10, taps_mode="fixed", reset_mode="rowhead_la", mask_rows=3,
              bot4_mode="bus")
dl = res["dump"]
n = min(len(dl), len(d["cyc"]))
keys = ("cyc", "iv", "il", "iu", "id", "ov", "ol", "ou", "od", "ins", "rtl", "rtu", "rv1")
bad = {k: 0 for k in keys}
first = None
for i in range(n):
    got = (int(d["cyc"][i]), int(d["iv"][i]), int(d["il"][i]), int(d["iu"][i]),
           int(d["id"][i]), int(d["ov"][i]), int(d["ol"][i]), int(d["ou"][i]),
           int(d["od"][i]), int(d["ins"][i]), int(d["rtl"][i]), int(d["rtu"][i]),
           int(d["rv1"][i]))
    exp = dl[i]
    for j, k in enumerate(keys):
        if got[j] != exp[j]:
            bad[k] += 1
            if first is None:
                first = (i, k, got[j], exp[j])
print("模型 vs 当前 RTL dump：比对 %d 行（真 %d / 模型 %d）" % (n, len(d["cyc"]), len(dl)))
for k in keys:
    print("   %-4s 失配 %d" % (k, bad[k]))
print("   首个不一致:", first)
print("   RESULT: %s" % ("FIDELITY-OK" if sum(bad.values()) == 0 else "FIDELITY-FAIL"))
