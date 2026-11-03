#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""用输出像素反解 (beat,x,ch)，钉死 O_tdata 与 r_x_now 的相位。"""
import sys, os, collections
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")
dl = open(os.path.join(W, "dump_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Iv": int(f[1]), "Ov": int(f[5]), "Od": f[8], "Id": f[4],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "nx": int(f[19], 16), "ny": int(f[20], 16),
                 "beat": int(f[23]), "romi": int(f[26], 16), "grow": int(f[27], 16),
                 "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})
cfg = C.Config(*hdr)

# 1) 输出拍 i 的非 OSD 像素反解出的 beat，与 r_x_now/r_y_now 的关系
print("=== 输出(非替换)像素反解 beat  vs  r_x_now/r_y_now 应有 beat ===")
cnt = 0
shift_stat = collections.Counter()
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    for ch in range(4):
        got = (int(r["Od"], 16) >> (72 - 24 * ch)) & 0xFFFFFF
        gb, gx, gc = C.decode_pix(got)
        if gc != ch: continue
        if gx != (4 * r["rx"] + ch) % 32: continue
        want_beat = r["ry"] * cfg.BPL + r["rx"]
        shift_stat[gb - want_beat] += 1
        if cnt < 8:
            print("  cyc=%d ch=%d beat_got=%d beat_want=%d rx=%d ry=%d"
                  % (r["cyc"], ch, gb, want_beat, r["rx"], r["ry"]))
        cnt += 1
        break
print("  beat 偏差分布: %s" % dict(shift_stat))
