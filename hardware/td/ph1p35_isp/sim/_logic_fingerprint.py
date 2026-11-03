#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逻辑指纹比对：去掉注释与空行后两个 .v 必须逐字节相同（证明改动是纯注释）。"""
import re, sys
sys.stdout.reconfigure(encoding="utf-8")


def fingerprint(path):
    txt = open(path, encoding="utf-8").read()
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)     # 块注释
    out = []
    for ln in txt.splitlines():
        ln = re.sub(r"//.*$", "", ln)                   # 行注释
        ln = ln.strip()
        if ln:
            out.append(ln)
    return "\n".join(out)


a, b = sys.argv[1], sys.argv[2]
fa, fb = fingerprint(a), fingerprint(b)
print("指纹 A %s：%d 字符" % (a, len(fa)))
print("指纹 B %s：%d 字符" % (b, len(fb)))
print("逻辑逐字节相同：%s" % ("是（改动纯注释）" if fa == fb else "!! 否（改到了逻辑）!!"))
if fa != fb:
    import difflib
    for ln in list(difflib.unified_diff(fa.splitlines(), fb.splitlines(),
                                        "A", "B", lineterm=""))[:40]:
        print("  " + ln)
sys.exit(0 if fa == fb else 1)
