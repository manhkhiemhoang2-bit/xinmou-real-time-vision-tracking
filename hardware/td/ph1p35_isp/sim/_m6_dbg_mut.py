#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""复现 mutate_alg_top_full.py 里两条"编译/仿真失败"的变异，看真正的错误是什么。

严格照 mutate 的做法：Python 读/写 + 只替换第一处 + newline=""（不引入 BOM/CRLF）。
"""
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
T = os.path.join(HERE, "_m6dbg2")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
RTLS = ["gray_bt601_96.v", "win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v",
        "alg_smooth_96.v", "alg_color_detect_96.v", "alg_framediff_96.v",
        "rgb_row_delay_96.v", "alg_top.v"]

CASES = [
    ("白点通路断开", "alg_top.v",
     "            r_m6_mot <= w_mot_pix0;", "            r_m6_mot <= 1'b0;"),
    ("运动格子不累加", "alg_framediff_96.v",
     "    else if (r_smp_d1 && w_motion)\n        r_cnt <= r_cnt + 32'd1;",
     "    else if (1'b0)\n        r_cnt <= r_cnt + 32'd1;"),
    ("格子计数器不 tuser 复位", "alg_framediff_96.v",
     "        if (I_tuser) begin\n            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};",
     "        if (1'b0) begin\n            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};"),
    ("bbox 用格子坐标", "alg_framediff_96.v",
     "        r_smp_x <= {r_x_grp, 2'b00};",
     "        r_smp_x <= {{(11-XW){1'b0}}, r_x_grp};"),
    ("白点涂整拍", "alg_top.v",
     "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
     "            wire w_m6_wht = r_m6_mot;"),
    ("白点早 1 拍", "alg_top.v",
     "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
     "            wire w_m6_wht = w_mot_pix0 && (g6 == 0);"),
]


def vlog(tag):
    p = subprocess.run([os.path.join(MS, "vlog.exe"), "-work", "work",
                        "+define+ALG_IMG_W=160", "+define+ALG_IMG_H=64"] + RTLS,
                       cwd=T, capture_output=True, text=True, errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    errs = [ln for ln in out.splitlines() if "Error" in ln or ln.startswith("Errors:")]
    print("  [%s] rc=%d  %s" % (tag, p.returncode, " | ".join(errs[-4:]) or "(no error line)"))
    return p.returncode == 0 and "Errors: 0" in out


if os.path.isdir(T):
    shutil.rmtree(T)
os.makedirs(T)
for f in RTLS:
    shutil.copy(os.path.join(SRC, f), os.path.join(T, f))
subprocess.run([os.path.join(MS, "vlib.exe"), "work"], cwd=T, capture_output=True)
print("基线 vlog：", vlog("base"))

for name, fn, a, b in CASES:
    for f in RTLS:
        shutil.copy(os.path.join(SRC, f), os.path.join(T, f))
    p = os.path.join(T, fn)
    txt = open(p, encoding="utf-8").read()
    n = txt.count(a)
    code = re.sub(r"//[^\n]*", "", txt)
    print("%-22s 原文出现 %d 次；去注释后出现 %d 次" % (name, n, code.count(a)))
    if a not in txt:
        print("   !! 找不到")
        continue
    new = txt.replace(a, b, 1)
    open(p, "w", encoding="utf-8", newline="").write(new)
    print("   替换后文件变化：%s" % (new != txt))
    vlog(name)
