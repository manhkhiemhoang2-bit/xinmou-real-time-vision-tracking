#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_taps_run.py —— 跑 7 轮位平面扫描，把 _probe_taps_rf.v 打印的 15 个抽头
还原成**绝对坐标 (行, 列)**，并打印"相对本拍的 (dy, dx)"表。

用法（在 sim\\ 下）：
    python _probe_taps_run.py            # 前 3 行
    python _probe_taps_run.py --rows 4   # 前 4 行
    python _probe_taps_run.py --beats 8  # 每行前 8 拍

产物：
    sim\\_probe_taps_table.txt   完整还原表（含每个 tap 的 (行,列)）
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MV = r"D:\modelsim\modelsim_ase\win32aloem"
WORK = os.path.join(HERE, "_taps_work")
W_IMG, H_IMG = 16, 6
NTAP = 18
TAP_NAMES = (["top_m1"] + ["top_%d" % i for i in range(5)] +
             ["mid_m1"] + ["mid_%d" % i for i in range(5)] +
             ["bot_m1"] + ["bot_%d" % i for i in range(5)])


def run_probe():
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    shutil.copy(os.path.join(ROOT, "src", "alg_region_fill_96.v"), WORK)
    shutil.copy(os.path.join(HERE, "_probe_taps_rf.v"), WORK)
    subprocess.run([os.path.join(MV, "vlib.exe"), "work"], cwd=WORK,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    r = subprocess.run([os.path.join(MV, "vlog.exe"), "-work", "work",
                        "alg_region_fill_96.v", "_probe_taps_rf.v"],
                       cwd=WORK, capture_output=True, text=True)
    if "Errors: 0" not in r.stdout:
        print(r.stdout[-2000:])
        raise SystemExit("vlog 失败")
    runs = []
    for k in range(7):
        r = subprocess.run([os.path.join(MV, "vsim.exe"), "-c", "-lib", "work",
                            "_probe_taps_rf", "-do", "run -all; quit -f", "+k=%d" % k],
                           cwd=WORK, capture_output=True, text=True)
        if "PROBE DONE" not in r.stdout:
            print(r.stdout[-1500:])
            raise SystemExit("k=%d 仿真没跑完" % k)
        with open(os.path.join(WORK, "taps_probe.txt"), "r", encoding="ascii") as f:
            runs.append(f.read().splitlines())
    return runs


def parse_line(ln):
    """→ (c, beat, rx, ry, wv, bits, unk)；x/z 位记 0 并标进 unk（行缓存未初始化）。"""
    head, *grp = ln.split("|")
    hd = dict(p.split("=") for p in head.split())
    vals, unk = [], set()
    for g in grp:
        body = g.split("=", 1)[1].strip()
        for j, v in enumerate(body.split(",")):
            if v in ("0", "1"):
                vals.append(int(v))
            else:
                vals.append(0)
                unk.add(len(vals) - 1)
    return (int(hd["c"]), int(hd["beat"]), int(hd["rx"]), int(hd["ry"]),
            int(hd["wv"]), vals, unk)


def decode(runs, rows, beats):
    n = min(len(r) for r in runs)
    pars = [[parse_line(runs[k][i]) for i in range(n)] for k in range(7)]
    tbl = []
    for i in range(n):
        c, beat, rx, ry, wv, _, _ = pars[0][i]
        taps, bad = [], []
        for t in range(NTAP):
            idx = 0
            unknown = False
            for k in range(7):
                if t in pars[k][i][6]:
                    unknown = True
                idx |= (pars[k][i][5][t] & 1) << k
            if idx == 0:
                taps.append(None)                      # 图外补零 / 从未写过
                bad.append(t)
            else:
                i2 = idx - 1
                taps.append((i2 // W_IMG, i2 % W_IMG))
                if unknown:
                    bad.append(t)
        tbl.append((c, beat, rx, ry, wv, taps, bad))
    return tbl


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--beats", type=int, default=4)
    a = ap.parse_args()
    runs = run_probe()
    tbl = decode(runs, a.rows, a.beats)

    out = []
    out.append("== 抽头绝对坐标表（真 RTL / 7 轮位平面扫描还原 / 图 %dx%d）==" % (W_IMG, H_IMG))
    out.append("   每行列出：本拍坐标 (r_y, r_x) 与 15 个抽头的绝对 (行, 列)；")
    out.append("   括号里是相对本拍的 (dy, dx)，其中本拍基准 = (r_y, 4*r_x)。")
    out.append("   pad = 图外补零或从未写过的行缓存地址。")
    out.append("")
    for (c, beat, rx, ry, wv, taps, bad) in tbl:
        if ry >= a.rows or (rx + 1) > a.beats:
            continue
        def f(t):
            if t is None:
                return "pad"
            return "(%d,%d)" % (t[0] - ry, t[1] - 4 * rx)
        out.append("c=%-3d beat=%-3d r_y=%d r_x=%-2d wv=%d%s" % (
            c, beat, ry, rx, wv,
            "  [含未初始化位: %s]" % ",".join(TAP_NAMES[t] for t in bad) if bad else ""))
        out.append("     top : " + " ".join("%-8s" % f(t) for t in taps[0:6]))
        out.append("     mid : " + " ".join("%-8s" % f(t) for t in taps[6:12]))
        out.append("     bot : " + " ".join("%-8s" % f(t) for t in taps[12:18]))
        out.append("     abs  top=%s mid=%s bot=%s" % (
            " ".join(str(t) for t in taps[0:6]),
            " ".join(str(t) for t in taps[6:12]),
            " ".join(str(t) for t in taps[12:18])))
    txt = "\n".join(out)
    print(txt)
    with open(os.path.join(HERE, "_probe_taps_table.txt"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(txt + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
