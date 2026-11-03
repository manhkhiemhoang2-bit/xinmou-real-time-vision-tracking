#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_win_gen.py —— 生成"点阵探针"激励 + 检查 RTL 窗口几何
（一次性诊断工具，不是交付物）

激励设计：16x6 的图，只在**偶数行**上、**偶数列**上放白点（棋盘式稀疏点阵）。
每个白点独立，3x3 邻域互不重叠，于是：
  · 某个拍被装配时，若窗口几何正确，底行抽头里恰好有 1 个白点，
    而中行/顶行抽头全黑（因为点阵隔行）；
  · 由"白点出现在第几个抽头"就能反推出该抽头对应的**绝对列**，
    由"哪一行抽头亮"就能反推 Δy。
比读时序推理可靠得多。

产出：
    _probe_stim.hex    激励（每拍一行 24 个十六进制字符）
    _probe_win.txt     vsim 打印的窗口抽头（--run 时生成）
用法：
    python _probe_win_gen.py --run
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 16, 6
BPL = W // 4
BPF = BPL * H
NBEAT = BPF * 2
MS = r"D:\modelsim\modelsim_ase\win32aloem"
WHITE = 0xFFFFFF

# 点阵：只在**第 3 行**放白点，列 0/2/4/6/8/10/12/14
# （单行点阵是最干净的判据：哪一行的抽头亮 => 该抽头采到了第 3 行）
dots = [(3, x) for x in range(0, W, 2)]


def write_stim():
    img = np.zeros((H, W), dtype=np.uint32)
    for (y, x) in dots:
        img[y, x] = WHITE
    beats = img.reshape(H, BPL, 4).reshape(NBEAT // 2, 4)
    beats = np.vstack([beats, beats])                     # 两帧
    lines = ["%06X%06X%06X%06X" % tuple(int(v) for v in b) for b in beats]
    with open(os.path.join(HERE, "_probe_stim.hex"), "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote _probe_stim.hex: %d beats, dots=%s" % (len(lines), dots))
    return img


def run_vsim():
    rc, out = _run([os.path.join(MS, "vlog.exe"), "-work", "work",
                    r"..\src\alg_region_fill_96.v", "tb_probe_win.v"])
    if "Errors: 0" not in out:
        print("vlog 失败:\n%s" % out[-2000:])
    p = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-do", "run -all; quit -f",
                        "tb_probe_win"], cwd=HERE, capture_output=True, text=True,
                       errors="replace")
    so = (p.stdout or "") + (p.stderr or "")
    if "probe done" not in so:
        print("vsim 未正常结束，末尾输出:\n%s" % so[-1500:])
    path = os.path.join(HERE, "_probe_win.txt")
    n = 0
    if os.path.isfile(path):
        n = sum(1 for _ in open(path, encoding="ascii"))
    print("_probe_win.txt 行数 = %d" % n)
    return


def _run(cmd):
    p = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


LP = re.compile(r"W c=(\d+) beat=(\d+) rx=(\d+) ry=(\d+) "
                r"T=(\d)(\d)(\d)(\d)(\d)(\d) M=(\d)(\d)(\d)(\d)(\d)(\d) B=(\d)(\d)(\d)(\d)(\d)(\d)")


def analyse(img):
    """把每个窗口行解析出来，判断白点落在哪个抽头上，并换算成绝对列。"""
    txt = open(os.path.join(HERE, "_probe_win.txt"), encoding="ascii").read()
    recs = []
    for ln in txt.splitlines():
        m = LP.search(ln)
        if m:
            g = [int(v) for v in m.groups()]
            recs.append(g)
    print("解析到窗口记录 %d 条" % len(recs))
    # 每个 r_y 只打印一条（同一个 r_y 的第二帧内容相同）
    seen = set()
    for g in recs:
        cyc, beat, rx, ry = g[0], g[1], g[2], g[3]
        if ry in seen:
            continue
        seen.add(ry)
        T = g[4:10]
        M = g[10:16]
        B = g[16:22]
        print("r_y=%d r_x=%d beat=%d | T=%s | M=%s | B=%s"
              % (ry, rx, beat,
                 "".join(str(v) for v in T), "".join(str(v) for v in M),
                 "".join(str(v) for v in B)))
    # 白点出现在哪些 (行, 抽头) 组合
    hits = {}
    for g in recs:
        cyc, beat, rx, ry = g[0], g[1], g[2], g[3]
        for name, row in (("T", g[4:10]), ("M", g[10:16]), ("B", g[16:22])):
            for k, v in enumerate(row):
                if v:
                    hits.setdefault(name, {}).setdefault(k, 0)
                    hits[name][k] += 1
    print("白点按抽头统计：")
    for name in ("T", "M", "B"):
        d = hits.get(name, {})
        print("   %s 行: %s" % (name, {k: d[k] for k in sorted(d)}))
    return hits


def main():
    img = write_stim()
    run_vsim()
    analyse(img)
    return 0


if __name__ == "__main__":
    sys.exit(main())
