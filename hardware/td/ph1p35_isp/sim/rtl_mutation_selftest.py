#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_mutation_selftest.py —— **真 RTL 变异**自证（比"改期望值"更硬的一层）

check_alg_ops.py --selftest 改的是**期望值**；本脚本反过来：把 RTL 源码改错一行，
重新编译、重新仿真，确认 check_alg_ops 的判据**报错**。
抓不住的测试 = 没测；连真 RTL 改错都抓不住，那这套判据就是摆设。

做法（全部在 sim\\_mut_rtl\\ 里，不碰交付的 src\\ 与 sim\\ 文件）：
    1. 把 4 个 .v 与两个 .hex 拷进 _mut_rtl\\
    2. 对指定文件做一次文本替换（变异）
    3. vlog + vsim 跑出 dump_alg.txt
    4. 用 check_alg_ops 的同一套判据比对，统计不符拍数
    5. 报错拍数 > 0 才算"抓住"

用法：python rtl_mutation_selftest.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
WORK = os.path.join(HERE, "_mut_rtl")
MS = r"D:\modelsim\modelsim_ase\win32aloem"

sys.path.insert(0, HERE)
from check_alg_ops import MODS, EXPF, has_xz, parse, _h  # noqa: E402

RTLS = ["win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v", "alg_smooth_96.v"]
HEXS = ["stim_alg.hex", "rgb_alg.hex"]

# (说明, 文件名, [(原文, 替换)])
MUTS = [
    ("M2 均值右移 >>9 改成 >>8", "alg_binarize_96.v",
     [("wire [7:0] w_m0 = w_p0[16:9];", "wire [7:0] w_m0 = w_p0[15:8];")]),
    ("M2 判决 > 改成 >=", "alg_binarize_96.v",
     [("wire w_b0 = ({1'b0, w_t11[ 7: 0]} > w_th0);",
       "wire w_b0 = ({1'b0, w_t11[ 7: 0]} >= w_th0);")]),
    ("M2 输出像素序接反（真实踩过的 bug）", "alg_binarize_96.v",
     [("wire [95:0] w_result = {w_pix0, w_pix1, w_pix2, w_pix3};",
       "wire [95:0] w_result = {w_pix3, w_pix2, w_pix1, w_pix0};")]),
    ("M3 阈值不乘 4", "alg_sobel_96.v",
     [("wire [9:0] w_th0 = {w_thm0, 2'b00};", "wire [9:0] w_th0 = {1'b0, w_thm0};")]),
    ("M3 src 像素序接反（pix0 取到 [23:0]）", "alg_sobel_96.v",
     [("wire [23:0] w_src0 = I_rgb_center[24*3 +: 24];",
       "wire [23:0] w_src0 = I_rgb_center[24*0 +: 24];")]),
    ("M3 提亮量 K 128 -> 64", "alg_sobel_96.v",
     [("parameter [8:0]   EDGE_K      = 9'd128", "parameter [8:0]   EDGE_K      = 9'd64")]),
    ("M4 最终右移 >>4 改成 >>3", "alg_smooth_96.v",
     [("wire [11:0] w_s0 = (w_r0_0 + {w_r1_0, 1'b0} + w_r2_0) >> 4;",
       "wire [11:0] w_s0 = (w_r0_0 + {w_r1_0, 1'b0} + w_r2_0) >> 3;")]),
    ("M4 纵向权重 1-2-1 改成 1-3-1", "alg_smooth_96.v",
     [("wire [11:0] w_s0 = (w_r0_0 + {w_r1_0, 1'b0} + w_r2_0) >> 4;",
       "wire [11:0] w_s0 = (w_r0_0 + {w_r1_0, 1'b0} + w_r1_0 + w_r2_0) >> 4;")]),
    ("M4 输出像素序接反", "alg_smooth_96.v",
     [("wire [95:0] w_result = {w_pix0, w_pix1, w_pix2, w_pix3};",
       "wire [95:0] w_result = {w_pix3, w_pix2, w_pix1, w_pix0};")]),
]


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def setup():
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    for f in RTLS:
        shutil.copy(os.path.join(SRC, f), os.path.join(WORK, f))
    for f in HEXS:
        shutil.copy(os.path.join(HERE, f), os.path.join(WORK, f))
    shutil.copy(os.path.join(HERE, "tb_alg_ops.v"), os.path.join(WORK, "tb_alg_ops.v"))


def build_and_run(verbose=False):
    rc, out = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
    if rc != 0:
        return False, out
    rc, out = run([os.path.join(MS, "vlog.exe"), "-work", "work",
                   "win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v",
                   "alg_smooth_96.v", "tb_alg_ops.v"], WORK)
    if rc != 0 or "Errors: 0" not in out:
        return False, out
    dump = os.path.join(WORK, "dump_alg.txt")
    if os.path.isfile(dump):
        os.remove(dump)
    rc, out = run([os.path.join(MS, "vsim.exe"), "-c", "-lib", "work",
                   "tb_alg_ops", "-do", "run -all; quit -f"], WORK)
    return os.path.isfile(dump), out


def count_bad(dump):
    rows = parse(dump)
    bad = 0
    for t in range(1, len(rows)):
        b = rows[t - 1]
        if b["Iv"] == 0 or has_xz(b["win"]) or has_xz(b["rgb"]):
            continue
        for nm, _c0, _c1, _c2, _c3, _t in MODS:
            if _h(rows[t][nm]) != EXPF[nm](_h(b["win"]), _h(b["rgb"]), None):
                bad += 1
    return bad, len(rows)


def main():
    setup()
    print("=" * 70)
    print("真 RTL 变异自证：改错 RTL 一行 -> 重编译重仿真 -> 判据必须报错")
    print("=" * 70)
    ok, out = build_and_run()
    if not ok:
        print("基线编译/仿真失败：\n" + out[-2000:])
        return 2
    bad, n = count_bad(os.path.join(WORK, "dump_alg.txt"))
    print("  基线（未变异）              不符 %4d 拍 / %d 拍   %s"
          % (bad, n, "PASS" if bad == 0 else "基线就不对，先查基线"))
    if bad:
        return 2

    caught = 0
    for name, fname, subs in MUTS:
        setup()
        txt = open(os.path.join(WORK, fname), encoding="utf-8").read()
        for a, b in subs:
            if a not in txt:
                print("  %-38s  替换原文没找到，变异未生效 -> 算漏掉" % name)
                continue
            txt = txt.replace(a, b, 1)
        open(os.path.join(WORK, fname), "w", encoding="utf-8").write(txt)
        ok, out = build_and_run()
        if not ok:
            print("  %-38s  编译/仿真失败（也算抓住）" % name)
            caught += 1
            continue
        bad, _n = count_bad(os.path.join(WORK, "dump_alg.txt"))
        good = bad > 0
        caught += 1 if good else 0
        print("  %-38s  不符 %5d 拍   %s" % (name, bad, "抓住" if good else "!! 漏掉 !!"))
    print("-" * 70)
    print("  真 RTL 变异鉴别力：%d/%d  -> %s"
          % (caught, len(MUTS), "PASS" if caught == len(MUTS) else "FAIL"))
    print("=" * 70)
    return 0 if caught == len(MUTS) else 1


if __name__ == "__main__":
    sys.exit(main())
