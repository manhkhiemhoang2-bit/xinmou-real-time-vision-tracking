#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""临时测量（任务B取证用）：把**已有的**含消隐 dump 直接喂给 check_alg_top.py 的判据，
看哪些判据在消隐激励下会红。不改判据、不改 TB，只输出原始数字。"""
from __future__ import annotations
import sys, os
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_alg_top as K

for name in sys.argv[1:]:
    p = os.path.join(HERE, name)
    rows = K.parse(p)
    print("=" * 78)
    print("%s : %d 拍" % (name, len(rows)))
    iv = [r for r in rows if r["Iv"] == 1]
    ov = [r for r in rows if r["Ov"] == 1]
    print("  输入有效拍 %d（首 cyc=%d 末 cyc=%d），输入无效拍 %d"
          % (len(iv), iv[0]["cyc"], iv[-1]["cyc"], len(rows) - len(iv)))
    print("  输出有效拍 %d（首 cyc=%d 末 cyc=%d）" % (len(ov), ov[0]["cyc"], ov[-1]["cyc"]))
    # 消隐段统计
    gaps = []
    run = 0
    for r in rows:
        if r["Iv"] == 0:
            run += 1
        elif run:
            gaps.append(run)
            run = 0
    if run:
        gaps.append(run)
    print("  输入 tvalid=0 的连续段：%d 段，长度取值 %s"
          % (len(gaps), sorted(set(gaps))[:6]))
    # 延迟5拍（时钟域）与（有效拍域）两种口径
    bad_cyc = sum(1 for t in range(5, len(rows))
                  if rows[t]["Ov"] != rows[t - 5]["Iv"])
    print("  [时钟域] O_tvalid(c) != I_tvalid(c-5) 的拍数 = %d / %d"
          % (bad_cyc, len(rows) - 5))
    ic = [r["cyc"] for r in rows if r["Iv"] == 1]
    oc = [r["cyc"] for r in rows if r["Ov"] == 1]
    n = min(len(ic), len(oc))
    bad_beat = sum(1 for i in range(n) if oc[i] != ic[i] + 5)
    print("  [有效拍域] 第 i 个输出有效拍 != 第 i 个输入有效拍 + 5 的个数 = %d / %d"
          % (bad_beat, n))
    if bad_beat:
        for i in range(n):
            if oc[i] != ic[i] + 5:
                print("     首个：i=%d 输入 cyc=%d 期望输出 cyc=%d 实得 %d（差 %+d）"
                      % (i, ic[i], ic[i] + 5, oc[i], oc[i] - ic[i] - 5))
                break
    counts, fails = K.run_all(rows, None, verbose=False)
    tot = sum(a for a, _ in counts.values())
    for k, (na, nb) in counts.items():
        print("  %-16s 断言 %6d  不符 %-5d  %s" % (k, na, nb, "PASS" if nb == 0 else "FAIL"))
    print("  合计断言 %d" % tot)
    for s in fails:
        print("    FAIL: %s" % s)
    print("  结论：%s" % ("PASS" if not fails else "FAIL"))
