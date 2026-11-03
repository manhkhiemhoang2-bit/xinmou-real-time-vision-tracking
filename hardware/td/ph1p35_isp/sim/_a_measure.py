#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""临时测量脚本（任务A取证用）：把 dump_rd.txt 里"旧判据为什么红"逐条归因。
不改任何判据，只输出原始数字。"""
from __future__ import annotations
import sys, os
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
import check_row_delay as C

rows = C.parse(os.path.join(HERE, "dump_rd.txt"))
print("dump 拍数 = %d（cyc %d..%d）" % (len(rows), rows[0]["cyc"], rows[-1]["cyc"]))

iv = [r for r in rows if r["Iv"] == 1]
ov = [r for r in rows if r["Ov"] == 1]
print("输入有效拍 = %d，首个 cyc=%s，末个 cyc=%s" % (len(iv), iv[0]["cyc"], iv[-1]["cyc"]))
print("输入 tvalid=0 的拍区间: cyc %d..%d（共 %d 拍）"
      % (rows[0]["cyc"], rows[len(iv) - 1]["cyc"] + 0,
         sum(1 for r in rows if r["Iv"] == 0)))
# 输入无效拍的实际集合
bad_c = [r["cyc"] for r in rows if r["Iv"] == 0]
print("输入 tvalid=0 拍的 cyc 段：%d..%d（连续）=%s"
      % (min(bad_c), max(bad_c), (max(bad_c) - min(bad_c) + 1) == len(bad_c)))
print("输出有效拍 = %d" % len(ov))
print("输出 tvalid=1 的 cyc 段：%d..%d" % (min(r["cyc"] for r in ov), max(r["cyc"] for r in ov)))
print("输出 tvalid 由 1 变 0 的第一次：%s"
      % next((("%d->%d" % (rows[i]["cyc"], rows[i + 1]["cyc"]))
              for i in range(len(rows) - 1)
              if rows[i]["Ov"] == 1 and rows[i + 1]["Ov"] == 0), "从未变 0（一直保持 1）"))
print("输出 tvalid 由 0 变 1 的第一次：%s"
      % next((("%d->%d" % (rows[i]["cyc"], rows[i + 1]["cyc"]))
              for i in range(len(rows) - 1)
              if rows[i]["Ov"] == 0 and rows[i + 1]["Ov"] == 1), "无"))
print("dump 末尾 3 拍 O_tvalid/O_tdata：%s"
      % [(r["cyc"], r["Ov"], r["Od"]) for r in rows[-3:]])
print("输入停止后（cyc>%d）输出 O_tvalid 取值集合：%s"
      % (iv[-1]["cyc"], sorted(set(r["Ov"] for r in rows if r["cyc"] > iv[-1]["cyc"]))))
print("输入停止后 O_tdata 取值集合：%s"
      % sorted(set(C.norm(r["Od"]) for r in rows if r["cyc"] > iv[-1]["cyc"])))
# 输出"字序"：把停顿期的重复字压缩掉（激励保证每拍字两两不同）
seq = []
for r in ov:
    w = (C.norm(r["Od"]), r["Ol"], r["Ou"])
    if not seq or seq[-1] != w:
        seq.append(w)
print("输出字序长度（压缩重复后）= %d；N_in - BPL = %d" % (len(seq), len(iv) - C.BPL))
print("前 3 个字序 = %s" % [s[0] for s in seq[:3]])
print("对应 I[0..2] = %s" % [C.norm(r["Id"]) for r in iv[:3]])
print("末 3 个字序 = %s" % [s[0] for s in seq[-3:]])
print("对应 I[1597..1599] = %s" % [C.norm(r["Id"]) for r in iv[1597:1600]])

# ---- 有效拍语义下逐位比对：O 的第 k 个有效拍 vs I 的第 k-320 个有效拍 ----
print("\n--- 有效拍语义（新合同）逐位比对 ---")
n = min(len(ov), len(iv))
bad_d = bad_l = bad_u = 0
first = None
for k in range(320, n):
    a, b = ov[k], iv[k - 320]
    if C.norm(a["Od"]) != C.norm(b["Id"]):
        bad_d += 1
        if first is None:
            first = ("data", k, a["cyc"], b["cyc"])
    if a["Ol"] != b["Il"]:
        bad_l += 1
        if first is None:
            first = ("tlast", k, a["cyc"], b["cyc"])
    if a["Ou"] != b["Iu"]:
        bad_u += 1
        if first is None:
            first = ("tuser", k, a["cyc"], b["cyc"])
print("比对拍 %d（k=320..%d）；不符 data=%d tlast=%d tuser=%d 首错=%s"
      % (n - 320, n - 1, bad_d, bad_l, bad_u, first))
print("有效拍数：输入 %d / 输出 %d  差 %+d（=0 表示无排空尾巴）"
      % (len(iv), len(ov), len(ov) - len(iv)))

# ---- 旧判据 401 条归因 ----
print("\n--- 旧判据（时钟延迟 320）401 条归因 ---")
fails, ncmp = C.check_delay(rows, verbose=False)
print("比较 %d 拍，不符 %d 条" % (ncmp, len(fails)))
import re
cat = {}
for s in fails:
    m = re.match(r"拍(\d+) (O_\w+)", s)
    cat.setdefault(m.group(2), []).append(int(m.group(1)))
for k, v in cat.items():
    print("  %-9s %4d 条，cyc %d..%d" % (k, len(v), min(v), max(v)))
# 相符区间的上界
allfail = sorted(int(re.match(r"拍(\d+)", s).group(1)) for s in fails)
match_cyc = [r["cyc"] for r in rows if r["cyc"] >= C.CMP_START and r["cyc"] < allfail[0]]
print("首个不符 cyc = %d；此前相符的比对拍数 = %d" % (allfail[0], len(match_cyc)))
print("输入停止（末有效输入 cyc=%d）后旧判据期望的排空尾巴 = cyc %d..%d"
      % (iv[-1]["cyc"], iv[-1]["cyc"] + 1, iv[-1]["cyc"] + 320))
