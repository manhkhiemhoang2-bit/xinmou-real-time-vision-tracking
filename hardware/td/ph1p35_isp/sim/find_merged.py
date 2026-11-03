#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""找出 .mangled 里"注释与代码被合并到同一行"的位置（用于精确修复）。"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
p = r"D:\TD\bin\work_for_all\ph1p35_isp\src\osd_mixer.v.mangled"
lines = open(p, encoding="utf-8").read().split("\n")
print("total lines", len(lines))
pat = re.compile(r"(;|\bend\b|\bbegin\b|<=|\bmodule\b|\bassign\b|\bwire\b|\breg\b)")
hits = 0
for i, l in enumerate(lines, 1):
    if "//" not in l:
        continue
    after = l.split("//", 1)[1]
    # 去掉注释文本里的英文单词干扰：只看是否存在明显的 RTL 片段
    if pat.search(after) and ("'" in after or ";" in after or "<=" in after):
        hits += 1
        print("%4d| %s" % (i, l[:180]))
print("merged lines:", hits)
