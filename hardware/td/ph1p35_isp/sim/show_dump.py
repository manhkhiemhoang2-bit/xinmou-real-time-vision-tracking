#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""打印 dump 原始字段，核对列序。"""
import sys

sys.stdout.reconfigure(encoding="utf-8")
p = r"D:\TD\bin\work_for_all\ph1p35_isp\sim\osd_work\dump_osd.txt"
lines = [l for l in open(p, encoding="ascii", errors="replace").read().split("\n") if l.strip()]
print("H:", lines[0])
for l in lines[2830:2836]:
    f = l.split()
    print("n=%d | %s" % (len(f), l))
