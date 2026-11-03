#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_win_check.py —— 用**绝对坐标**核对 RTL 的 3x3 窗口几何。

配套 TB：sim\\_probe_win.v（16x6 图，激励 = gen_stim_region_fill.small_frames 的 F0）
  运行方式：
      vsim -c -do "run -all; quit -f" _probe_win
  该 TB 对**每一个有效拍**打印一行：
      c=<cyc> beat=<拍号> r_x=<组号> r_y=<行号> | top m1=.. r=.. | mid .. | bot ..

本脚本按"绝对坐标"推导每个抽头**应该**是什么，逐项比对，并把首批差异打印出来。
这是唯一能一次定死 Δx/Δy 的判据（比读 RTL 猜时序可靠）。
"""
from __future__ import annotations

import re
import subprocess
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, ".")
import ref_region_fill as R  # noqa: E402
import gen_stim_region_fill as G  # noqa: E402

W, H = G.SW, G.SH
BPL = W // 4
BPF = BPL * H

LINE = re.compile(
    r"c=(\d+) beat=(\d+) r_x=(\d+) r_y=(\d+) \| "
    r"top m1=(\d) (\d)(\d)(\d)(\d) r=(\d) \| "
    r"mid m1=(\d) (\d)(\d)(\d)(\d) r=(\d) \| "
    r"bot m1=(\d) (\d)(\d)(\d)(\d) r=(\d)")


def run_probe():
    ms = r"D:\modelsim\modelsim_ase\win32aloem"
    subprocess.run([ms + r"\vlog.exe", "-work", "work", r"..\src\alg_region_fill_96.v",
                    "_probe_win.v"], capture_output=True, text=True)
    p = subprocess.run([ms + r"\vsim.exe", "-c", "-do", "run -all; quit -f", "_probe_win"],
                       capture_output=True, text=True, errors="replace")
    out = []
    for ln in (p.stdout or "").splitlines():
        m = LINE.search(ln)
        if m:
            out.append([int(x) for x in m.groups()])
    return out


def expected_taps(mask, cyc, beat, ry, rx):
    """按绝对坐标给出 18 个抽头的期望值（顺序与 TB 的打印一致）。

    窗口属于"第 r_y 行、第 r_x 组"（TB 打印的 r_x/r_y 就是装配用的坐标），
    每个抽头的物理列见下面注释；图外补 0；每行第 0 拍左邻居强制 0，
    行末拍右邻居强制 0（与 win3x3_96 的掩蔽一致）。
    """
    def px(y, x):
        if y < 0 or y >= H or x < 0 or x >= W:
            return 0
        return 1 if mask[y, x] else 0
    base = 4 * rx
    top = [px(ry - 2, base - 1), px(ry - 2, base + 0), px(ry - 2, base + 1),
           px(ry - 2, base + 2), px(ry - 2, base + 3), px(ry - 2, base + 4)]
    mid = [px(ry - 1, base - 1), px(ry - 1, base + 0), px(ry - 1, base + 1),
           px(ry - 1, base + 2), px(ry - 1, base + 3), px(ry - 1, base + 4)]
    bot = [px(ry, base - 1), px(ry, base + 0), px(ry, base + 1),
           px(ry, base + 2), px(ry, base + 3), px(ry, base + 4)]
    if rx == 0:
        top[0] = mid[0] = bot[0] = 0
    if rx == BPL - 1:
        top[5] = mid[5] = bot[5] = 0
    return top, mid, bot


def main():
    frames = G.small_frames()
    mask = frames[0][1]                      # F0：2 像素宽闭合矩形轮廓
    rows = run_probe()
    print("probe 打印窗口行数 = %d" % len(rows))
    bad = 0
    bad_detail = []
    for r in rows:
        cyc, beat, rx, ry = r[0], r[1], r[2], r[3]
        top = r[4:10]
        mid = r[10:16]
        bot = r[16:22]
        et, em, eb = expected_taps(mask, cyc, beat, ry, rx)
        for name, e, g in (("top", et, top), ("mid", em, mid), ("bot", eb, bot)):
            if e != g:
                bad += 1
                if len(bad_detail) < 12:
                    bad_detail.append((cyc, beat, ry, rx, name, e, g))
    print("窗口抽头失配 %d 处" % bad)
    for d in bad_detail:
        print("   c=%d beat=%d r_y=%d r_x=%d %s: exp=%s got=%s" % d)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
