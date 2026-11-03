#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""临时取证：把 RTL 退回旧时钟语义（M1），打印新判据报的错（报告里要引用原话）。"""
from __future__ import annotations
import os, sys
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rtl_mutation_row_delay as M
import check_row_delay as R

name, who, subs = M.MUTS[0]
M.setup()
p = os.path.join(M.WORK, M.DUT)
txt = open(p, encoding="utf-8").read()
for a, b in subs:
    assert a in txt, "替换原文没找到"
    txt = txt.replace(a, b, 1)
open(p, "w", encoding="utf-8").write(txt)
ok, out = M.build_and_run()
print("变异 M1 编译/仿真：%s" % ("OK" if ok else "FAILED"))
d = os.path.join(M.WORK, "dump_rd.txt")
rows = R.parse(d)
print("变异 dump 拍数 %d（基线 2285）" % len(rows))
print()
n, f = R.check_contract(rows, verbose=True)
print()
print("B 判据：断言 %d，不符 %d" % (n, len(f)))
for s in f:
    print("   * " + s)
print()
print("M1 的呈现字序前 3 / 末 3：",
      [x["Od"] for x in R.presentations(rows)[:3]],
      [x["Od"] for x in R.presentations(rows)[-3:]])

# ---- 反向对照：旧判据 v1（时钟语义 320 拍延迟 + 含排空尾巴）在 M1 上是不是 PASS ----
print()
print("--- 反向对照：用【旧判据 v1 的 B 逻辑】判 M1 dump ---")
by = {r["cyc"]: r for r in rows}
old_fails = []
ncmp = 0
for r in rows:
    c = r["cyc"]
    if c < R.START_CYC + R.BPL:
        continue
    src = by.get(c - R.BPL)
    if src is None:
        continue
    ncmp += 1
    if r["Ov"] != src["Iv"]:
        old_fails.append("拍%d O_tvalid 期望 %s 实得 %s" % (c, src["Iv"], r["Ov"]))
    if r["Ol"] != src["Il"]:
        old_fails.append("拍%d O_tlast 期望 %s 实得 %s" % (c, src["Il"], r["Ol"]))
    if r["Ou"] != src["Iu"]:
        old_fails.append("拍%d O_tuser 期望 %s 实得 %s" % (c, src["Iu"], r["Ou"]))
    want_d = R.norm(src["Id"]) if src["Iv"] else "%024x" % 0
    if R.has_xz(r["Od"]):
        old_fails.append("拍%d O_tdata 含 X/Z" % c)
    elif R.norm(r["Od"]) != want_d:
        old_fails.append("拍%d O_tdata 期望 %s 实得 %s" % (c, want_d, R.norm(r["Od"])))
print("旧判据 v1 比较 %d 拍，不符 %d 条  -> %s"
      % (ncmp, len(old_fails), "FAIL" if old_fails else "PASS"))
print("（这就是任务书里说的 'V0 原版 PASS'：旧 RTL + 旧判据 = 绿；"
      "旧 RTL + 新判据 = 红，新 RTL + 旧判据 = 红，新 RTL + 新判据 = 绿）")
