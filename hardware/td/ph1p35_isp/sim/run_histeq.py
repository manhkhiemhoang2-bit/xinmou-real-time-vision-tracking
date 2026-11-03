#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
run_histeq.py —— alg_histeq_96 的一键回归：生成激励 → vlib/vlog → 逐场景 vsim → 判据

用法：
    python run_histeq.py                # 全部场景
    python run_histeq.py --scen lowc    # 只跑一个场景
    python run_histeq.py --check-only   # 只跑判据（dump 已存在）

纪律（本项目踩过的坑）：
  · vsim 一律 `-c -do "run -all; quit -f"`，跑完自己 quit；结束时自查有没有残留 vsim 进程。
  · vlog 的 Errors/Warnings 都打印出来（0 error 是硬要求，warning 也要看见）。
  · 每次仿真写单独的日志 run_he_<场景>.log（含 TB_SUMMARY），判据从日志里读汇总。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src"))
MS = r"D:\modelsim\modelsim_ase\win32aloem"
WORK = os.path.join(HERE, "work_he")

DUT = os.path.join(SRC, "alg_histeq_96.v")
TB = os.path.join(HERE, "tb_histeq.v")


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def compile_all():
    os.makedirs(WORK, exist_ok=True)
    if not os.path.isdir(os.path.join(WORK, "work")):
        rc, out = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
        if rc != 0:
            print("vlib 失败：\n" + out)
            return False
    rc, out = run([os.path.join(MS, "vlog.exe"), "-work", "work", DUT, TB], WORK)
    print("--- vlog ---")
    for ln in out.splitlines():
        if ("Errors:" in ln) or ("Warnings:" in ln) or ("** Error" in ln) or ("** Warning" in ln) or ("-- Compiling" in ln):
            print("   " + ln.strip())
    ok = (rc == 0) and ("Errors: 0" in out)
    if not ok:
        print(out[-3000:])
    return ok


def sim_one(s):
    args = [os.path.join(MS, "vsim.exe"), "-c", "-lib", "work", "tb_histeq",
            "-gIMG_WIDTH=%d" % s["W"], "-gIMG_HEIGHT=%d" % s["H"],
            "-gFRAMES=%d" % s["frames"], "-gGAP_CYC=%d" % s["gap"],
            "-gLGAP_CYC=%d" % s["lgap"], "-gBUB_PERIOD=%d" % s["bub_period"],
            "-gBUB_LEN=%d" % s["bub_len"], "-gEN_MASK=%d" % s["en_mask"],
            "-gDUMP_ALL=%d" % s["dump_all"], "-gDUMP_HEAD_B=%d" % s["head"],
            "-gDUMP_TAIL_B=%d" % s["tail"],
            "+STIM=%s" % os.path.join(HERE, s["stim"]).replace("\\", "/"),
            "+DUMP=%s" % os.path.join(HERE, s["dump"]).replace("\\", "/"),
            "-do", "run -all; quit -f"]
    t0 = time.time()
    rc, out = run(args, WORK)
    dt = time.time() - t0
    with open(os.path.join(HERE, s["log"]), "w", encoding="utf-8", errors="replace") as fh:
        fh.write(out)
    summ = [ln.strip() for ln in out.splitlines() if "TB_SUMMARY" in ln]
    err = [ln.strip() for ln in out.splitlines() if ("** Error" in ln or "Fatal" in ln)]
    print("  %-10s %4dx%-4d %d 帧  %6.1fs  rc=%d  %s" %
          (s["name"], s["W"], s["H"], s["frames"], dt, rc, summ[0] if summ else "(没有 TB_SUMMARY)"))
    for e in err[:3]:
        print("      " + e)
    return rc == 0 and bool(summ) and not err


def stray_vsim():
    rc, out = run(["tasklist", "/FI", "IMAGENAME eq vsim.exe"], HERE)
    lines = [l for l in out.splitlines() if "vsim.exe" in l.lower()]
    return lines


def main():
    argv = sys.argv[1:]

    print("=" * 88)
    print("alg_histeq_96 回归")
    print("=" * 88)

    if "--check-only" not in argv:
        # 先重生成激励与场景清单，**再**读清单（否则 vsim 会用上一版参数：踩过这个坑）
        rc, out = run([sys.executable, os.path.join(HERE, "gen_stim_histeq.py")], HERE)
        if rc != 0:
            print(out)
            return 2

    man = json.load(open(os.path.join(HERE, "histeq_scen.json"), encoding="utf-8"))
    scens = man["scenarios"]
    if "--scen" in argv:
        want = argv[argv.index("--scen") + 1]
        scens = [s for s in scens if s["name"] == want]
    print("场景数：%d" % len(scens))

    if "--check-only" not in argv:
        if not compile_all():
            print("编译不过，停。")
            return 2
        print("--- vsim ---")
        bad = []
        for s in scens:
            if not sim_one(s):
                bad.append(s["name"])
        st = stray_vsim()
        print("--- 残留 vsim 进程：%s" % ("无" if not st else st))
        if bad:
            print("!! 这些场景仿真没跑干净：%s" % ",".join(bad))
            return 1

    print("--- 判据 ---")
    cmd = [sys.executable, os.path.join(HERE, "check_histeq.py")]
    if "--scen" in argv:
        cmd += ["--scen", argv[argv.index("--scen") + 1]]
    if "--verbose" in argv:
        cmd += ["--verbose"]
    p = subprocess.run(cmd, cwd=HERE)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
