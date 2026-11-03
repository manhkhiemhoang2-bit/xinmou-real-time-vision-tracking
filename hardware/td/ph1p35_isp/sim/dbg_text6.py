#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""关联 dump_osd.txt 与 probe_osd.txt，钉死列基址问题。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")

dl = open(os.path.join(W, "dump_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
pl = open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
hdr, rows, probe = None, [], {}
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16), "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
for ln in pl:
    f = ln.split()
    if len(f) < 7: continue
    probe[int(f[0])] = (int(f[1], 16), int(f[2], 16), int(f[3]), int(f[4], 16),
                        int(f[5], 16), int(f[6], 16))
cfg = C.Config(*hdr)

print("cyc    rx  ry   dx   ci  romi grow  cb  ci_r  inrow  gb    dut      exp(col=dx%16)")
cnt = 0
poss = collections.Counter()
match_col0 = match_colbase = 0
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    if not (cfg.TEXT_Y <= r["ry"] < cfg.TEXT_Y + 16): continue
    xb = 4 * r["rx"]
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    dx = xb - cfg.TEXT_X
    p = probe.get(r["cyc"], (0, 0, 0, 0, 0, 0))
    cb, ci_r, inrow, nx_cb, dx_cb, col0 = p
    exp_cb = (dx % 16) // 4
    exp_col0 = dx % 16
    if col0 == exp_col0: match_col0 += 1
    if cb == exp_cb: match_colbase += 1
    dut = "".join(str(b) for b in r["hit"])
    exp = "".join(str((r["gbits"] >> (15 - (dx % 16 + k))) & 1) for k in range(4))
    if cnt < 20:
        print("%-6d %-3d %-4d %-4d %-3d %-4d %-4d %-3d %-4d %-5d %04X  %s  %s"
              % (r["cyc"], r["rx"], r["ry"], dx, dx // 16, r["romi"], r["grow"], cb, ci_r,
                 inrow, r["gbits"], dut, exp))
    cnt += 1
print("--- 汇总（文字行内 %d 拍）---" % cnt)
print("DUT w_txt_col0 == dx%%16 : %d / %d" % (match_col0, cnt))
print("DUT r_txt_col_base == (dx%%16)//4 : %d / %d" % (match_colbase, cnt))
