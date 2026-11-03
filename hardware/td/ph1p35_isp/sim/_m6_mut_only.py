#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""只跑指定的两条 M6 变异（走 mutate_alg_top_full 的同一套 setup/build/judge），
用来看"编译/仿真失败"到底是真失败还是瞬时故障。"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["ALG_W"], os.environ["ALG_H"] = "160", "64"
sys.path.insert(0, HERE)

import mutate_alg_top_full as M       # noqa: E402

ONLY = [
    ("M3 提亮增量 K 128->64（复核瞬时失败）", "alg_top.v",
     "parameter [8:0]   EDGE_K   = 9'd128,", "parameter [8:0]   EDGE_K   = 9'd64,"),
    ("M6 运动格子不累加", "alg_framediff_96.v",
     "    else if (r_smp_d1 && w_motion)\n        r_cnt <= r_cnt + 32'd1;",
     "    else if (1'b0)\n        r_cnt <= r_cnt + 32'd1;"),
    ("M6 白点通路断开", "alg_top.v",
     "            r_m6_mot <= w_mot_pix0;", "            r_m6_mot <= 1'b0;"),
    ("M6 格子计数器不 tuser 复位", "alg_framediff_96.v",
     "        if (I_tuser) begin\n            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};",
     "        if (1'b0) begin\n            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};"),
    ("M6 bbox 用格子坐标", "alg_framediff_96.v",
     "        r_smp_x <= {r_x_grp, 2'b00};",
     "        r_smp_x <= {{(11-XW){1'b0}}, r_x_grp};"),
    ("M6 白点涂整拍", "alg_top.v",
     "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
     "            wire w_m6_wht = r_m6_mot;"),
    ("M6 白点早 1 拍", "alg_top.v",
     "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
     "            wire w_m6_wht = w_mot_pix0 && (g6 == 0);"),
]

M.setup()
ok, out = M.build_and_run(7)
print("基线 build_and_run:", ok)
base = open(os.path.join(M.WORK, "dump_top_full.txt"), "rb").read()
b, _n = M.judge(os.path.join(M.WORK, "dump_top_full.txt"), 7)
print("基线 judge:", {k: v for k, v in b.items() if v} or "全绿", "dump=%d B" % len(base))

for name, fn, a, b_ in ONLY:
    M.setup()
    p = os.path.join(M.WORK, fn)
    txt = open(p, encoding="utf-8").read()
    if a not in txt:
        print("%-24s !! 锚点找不到" % name)
        continue
    open(p, "w", encoding="utf-8", newline="").write(txt.replace(a, b_, 1))
    ok, out = M.build_and_run(7)
    if not ok:
        print("%-24s build_and_run=False（编译/仿真失败）out tail=%s"
              % (name, (out or "")[-400:].replace("\n", " | ")))
        continue
    mb = open(os.path.join(M.WORK, "dump_top_full.txt"), "rb").read()
    bad, _n = M.judge(os.path.join(M.WORK, "dump_top_full.txt"), 7)
    red = {k: v for k, v in bad.items() if v}
    print("%-24s dump %d->%d B 相同=%s 报红=%s"
          % (name, len(base), len(mb), mb == base, red or "无"))
