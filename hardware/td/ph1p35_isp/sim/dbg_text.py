#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""定位文字面 447 错的根因：把 dump 里 DUT 的中间信号与规格模型逐项对照。"""
import sys, os
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

DUMP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "osd_work", "dump_osd.txt")

lines = open(DUMP, "r", encoding="ascii", errors="replace").read().splitlines()
hdr = None
rows = []
for ln in lines:
    f = ln.split()
    if not f:
        continue
    if f[0] == "H":
        hdr = [int(v) for v in f[1:]]
        continue
    if len(f) < 29:
        continue
    rows.append({"cyc": int(f[0]), "Ov": int(f[5]), "Od": f[8],
                 "rx": int(f[17], 16), "ry": int(f[18], 16),
                 "nx": int(f[19], 16), "ny": int(f[20], 16),
                 "xg": int(f[21], 16), "yp": int(f[22], 16),
                 "beat": int(f[23]), "rxq": int(f[24], 16), "ryq": int(f[25], 16),
                 "romi": int(f[26], 16), "grow": int(f[27], 16),
                 "gbits": int(f[28], 16),
                 "hit": [int(f[16]), int(f[15]), int(f[14]), int(f[13])]})

cfg = C.Config(*hdr)
print("hdr W=%d H=%d LOGO=(%d,%d) TEXT=(%d,%d) MODE=%d FPS=%hx LAT=%d INFX=%d" % tuple(hdr))

TEXT_X, TEXT_Y = cfg.TEXT_X, cfg.TEXT_Y
TEXT_H = 16

bad = 0
shown = {"row": 0, "romi": 0, "gbits": 0, "col": 0, "rowphase": 0, "ci": 0, "colbase": 0}
for i, r in enumerate(rows):
    if r["Ov"] != 1:
        continue
    # 第 i 拍判据坐标 = rows[i-1] 的探针（与 check_osd.py 同口径）
    p = rows[max(i - 1, 0)]
    crx, cry = p["rx"], p["ry"]
    if not (TEXT_Y <= cry < TEXT_Y + TEXT_H):
        continue
    x_base = 4 * crx
    if x_base < TEXT_X or x_base >= TEXT_X + 16 * 16:
        continue
    # 拍级期望
    e_ci = (x_base - TEXT_X) // 16
    e_col = (x_base - TEXT_X) % 16
    e_grow = (cry - TEXT_Y) & 0xF
    e_code = C.char_code(e_ci, cfg)
    e_idx = C.char_rom_idx(e_code)
    e_gb = C.CHAR_BITS(e_idx, e_grow)
    # 与 DUT 的中间信号比
    if p["romi"] != e_idx:
        shown["romi"] += 1
    gb_dut = p["gbits"]
    if gb_dut != e_gb:
        shown["gbits"] += 1
        if shown["gbits"] <= 6:
            print("GBITS cyc=%d x=%d y=%d ci=%d idx(DUT=%d EXP=%d) row(DUT=%d EXP=%d) "
                  "DUT=%04X EXP=%04X" % (r["cyc"], x_base, cry, e_ci, p["romi"], e_idx,
                                         p["grow"], e_grow, gb_dut, e_gb))
    if p["grow"] != e_grow:
        shown["row"] += 1
    if p["romi"] != e_idx:
        if shown["romi"] <= 6:
            print("ROMI cyc=%d x=%d ci=%d DUT=%d EXP=%d" % (r["cyc"], x_base, e_ci, p["romi"], e_idx))

print("--- 汇总 ---")
print("探针行不符 gbits : %d" % shown["gbits"])
print("探针行不符 romi  : %d" % shown["romi"])
print("探针行不符 grow  : %d" % shown["row"])
