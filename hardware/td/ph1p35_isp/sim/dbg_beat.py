#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""逐拍核对：探针坐标是否等于 O_tdata 那份像素的坐标，gb 命中是否与 DUT 命中一致。"""
import sys, os
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")
hdr, rows = C.parse(os.path.join(W, "dump_osd.txt"))
cfg = C.Config(*hdr)
BPL = cfg.BPL
PR = {}
for ln in open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace"):
    f = ln.split()
    if len(f) < 16: continue
    PR[int(f[0])] = dict(h=[int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                         rx=int(f[5], 16), ry=int(f[6], 16), col0=int(f[7], 16),
                         gb=int(f[8], 16), cb=int(f[9], 16), ci=int(f[10], 16), Od=f[11])

same = diff = 0
coord_ok = coord_bad = 0
ex = []
for i, r in enumerate(rows):
    if r["Ov"] != 1: continue
    db = r["beat"] - 1                      # O_tdata 那份像素的 beat
    y, xb = db // BPL, (db % BPL) * 4
    if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + 16): continue
    if not (cfg.TEXT_X <= xb < cfg.TEXT_X + 256): continue
    p = PR.get(r["cyc"])
    if p is None: continue
    col = xb % 16
    exp = "".join(str((p["gb"] >> (15 - (col + k))) & 1) for k in range(4))
    dut = "".join(str(z) for z in p["h"])
    if p["rx"] == xb // 4 and p["ry"] == y: coord_ok += 1
    else:
        coord_bad += 1
        if len(ex) < 8:
            ex.append("COORD cyc=%d pixBeat=%d (x=%d,y=%d) probe rx=%d ry=%d"
                      % (r["cyc"], db, xb, y, p["rx"], p["ry"]))
    if exp == dut: same += 1
    else:
        diff += 1
        if len(ex) < 14:
            ex.append("HIT   cyc=%d pixBeat=%d (x=%d,y=%d) col=%d dut=%s exp=%s gb=%04X"
                      % (r["cyc"], db, xb, y, col, dut, exp, p["gb"]))
print("探针坐标 == 像素坐标 : %d 拍（不符 %d）" % (coord_ok, coord_bad))
print("同拍 gb 命中 == DUT 命中 : %d 拍（不符 %d）" % (same, diff))
for e in ex: print("  " + e)
