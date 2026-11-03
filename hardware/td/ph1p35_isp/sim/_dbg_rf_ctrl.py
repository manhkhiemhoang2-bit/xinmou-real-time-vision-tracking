#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""一次性诊断：把 dump_rf.txt 的 tlast/tuser 时序按拍摊开。"""
import sys

sys.stdout.reconfigure(encoding="utf-8")

rows = [l.split() for l in open("dump_rf.txt", encoding="ascii") if l.strip()]
byc = {int(r[0]): r for r in rows}
Il = {int(r[0]): r[2] for r in rows}
Iu = {int(r[0]): r[3] for r in rows}
Iv = {int(r[0]): r[1] for r in rows}

print("cyc  Iv Il Iu | Ov Ol Ou | rtl rtU rv2")
for c in range(6, 40):
    r = byc.get(c)
    if r is None:
        continue
    exp_l = Il.get(c - 3, "?")
    exp_u = Iu.get(c - 3, "?")
    flag = ""
    if r[6] != exp_l:
        flag += " <L"
    if r[7] != exp_u:
        flag += " <U"
    print("%3d  %s  %s  %s |  %s  %s  %s |  %s   %s   %s%s"
          % (c, r[1], r[2], r[3], r[5], r[6], r[7], r[10], r[11], r[12], flag))

print()
print("I_tlast cycles :", [c for c in sorted(Il) if Il[c] == "1"][:20])
print("O_tlast cycles :", [c for c in sorted(Il) if byc[c][6] == "1"][:20])
print("I_tuser cycles :", [c for c in sorted(Iu) if Iu[c] == "1"])
print("O_tuser cycles :", [c for c in sorted(Il) if byc[c][7] == "1"][:20])
