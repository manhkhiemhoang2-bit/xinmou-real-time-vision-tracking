#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""判断 osd_mixer.v 的损坏范围：中文注释是否还在。"""
import sys

sys.stdout.reconfigure(encoding="utf-8")
p = r"D:\TD\bin\work_for_all\ph1p35_isp\src\osd_mixer.v"
raw = open(p, "rb").read()
print("bytes:", len(raw))
try:
    s = raw.decode("utf-8")
    print("decodes as UTF-8: OK")
except UnicodeDecodeError as e:
    print("decodes as UTF-8: FAIL", e)
    s = raw.decode("utf-8", errors="replace")
cjk = sum(1 for c in s if "\u4e00" <= c <= "\u9fff")
qm = s.count("?")
print("CJK chars:", cjk, " '?' chars:", qm)
lines = s.split("\n")
print("lines:", len(lines))
nonascii = [i + 1 for i, l in enumerate(lines) if any(ord(c) > 127 for c in l)]
print("lines with non-ASCII:", len(nonascii), nonascii[:10])
