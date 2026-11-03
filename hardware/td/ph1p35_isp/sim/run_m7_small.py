#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""run_m7_small.py —— 小尺寸集成基线：160x64 / 8 帧（f0..f7 = M0..M7）。

为什么只跑小尺寸（任务书 §五.3）：1280x720 一次 3 分钟 + 147 MB dump，而且那套 12 帧
档位表里本来就没有 M6/M7 帧；填充模块自己已经在 1280x720 x 3 帧上 0 失配验过，
这里只要证明"接进去没接错"。

做的事：
  1. 建 `_m7work\\`，拷 RTL + TB + stim（不动交付目录）
  2. vlib / vlog（**统计 Errors 与 Warnings 条数**，0 error 0 warning 是交付门禁）
  3. vsim -c -do "run -all; quit -f" +frames=8
  4. dump 另存一份 `dump_m7_small.txt`（当证据）
  5. check_alg_top_full.py --dump ... --frames 8（全判据 A~M）

用法：python run_m7_small.py [--frames 8]
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "src")
WORK = os.path.join(HERE, "_m7work")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = sys.executable

W, H = 160, 64
FRAMES = 8
HEXNAME = "stim_top_%dx%d.hex" % (W, H)

RTLS = ["gray_bt601_96.v", "win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v",
        "alg_smooth_96.v", "alg_color_detect_96.v", "alg_framediff_96.v",
        "alg_region_fill_96.v",
        "rgb_row_delay_96.v", "alg_top.v"]


def run(cmd, cwd, timeout=1800, env=None, enc=None):
    """enc 显式给 UTF-8 时按 UTF-8 解码子进程输出。

    ⚠ 必须显式给：checker 自己把 stdout 重配成 UTF-8，而 Windows 的默认管道编码是 GBK，
       text=True 会按 GBK 解 → 中文全成乱码（内容没错，但日志没法读）。
    """
    t0 = time.time()
    kw = dict(capture_output=True, text=True, errors="replace", timeout=timeout,
              env=env)
    if enc:
        kw["encoding"] = enc
    p = subprocess.run(cmd, cwd=cwd, **kw)
    return p.returncode, (p.stdout or "") + (p.stderr or ""), time.time() - t0


def main():
    frames = FRAMES
    if "--frames" in sys.argv:
        frames = int(sys.argv[sys.argv.index("--frames") + 1])
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    for f in RTLS:
        shutil.copy(os.path.join(SRC, f), os.path.join(WORK, f))
    shutil.copy(os.path.join(HERE, "tb_alg_top_full.v"), os.path.join(WORK,
                                                                     "tb_alg_top_full.v"))
    hexsrc = os.path.join(HERE, HEXNAME)
    if not os.path.isfile(hexsrc):
        raise SystemExit("找不到激励 %s —— 先跑 ALG_W=%d ALG_H=%d gen_stim_top_full.py"
                         % (HEXNAME, W, H))
    shutil.copy(hexsrc, os.path.join(WORK, "stim_top_full.hex"))
    shutil.copy(hexsrc, os.path.join(WORK, HEXNAME))
    print("  工作目录 %s：%d 个 RTL + TB + %s" % (WORK, len(RTLS), HEXNAME))

    rc, out, _ = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
    if rc != 0:
        print(out[-3000:])
        return 2
    rc, out, dt = run([os.path.join(MS, "vlog.exe"), "-work", "work",
                       "+define+ALG_IMG_W=%d" % W, "+define+ALG_IMG_H=%d" % H]
                      + RTLS + ["tb_alg_top_full.v"], WORK)
    open(os.path.join(HERE, "_m7_vlog.log"), "w", encoding="utf-8").write(out)
    nerr = len(re.findall(r"^\*\* Error", out, re.M))
    nwarn = len(re.findall(r"^\*\* Warning", out, re.M))
    m = re.search(r"Errors:\s*(\d+),\s*Warnings:\s*(\d+)", out)
    print("  vlog：rc=%d  Errors/Warnings 行 = %d/%d；汇总 = %s  (%.1f s)"
          % (rc, nerr, nwarn, m.group(0) if m else "未找到", dt))
    if nerr or nwarn or rc != 0:
        print(out[-3000:])
        return 2

    dump = os.path.join(WORK, "dump_top_full.txt")
    if os.path.isfile(dump):
        os.remove(dump)
    rc, out, dt = run([os.path.join(MS, "vsim.exe"), "-c", "-lib", "work",
                       "tb_alg_top_full", "-do", "run -all; quit -f",
                       "+frames=%d" % frames], WORK)
    open(os.path.join(HERE, "_m7_vsim.log"), "w", encoding="utf-8").write(out)
    for ln in out.splitlines():
        if "TB:" in ln:
            print("  " + ln.strip())
    if "Fatal" in out:
        print("!! vsim 报 Fatal：")
        print("\n".join([l for l in out.splitlines() if "Fatal" in l][:5]))
        return 2
    if not os.path.isfile(dump):
        print("!! 没有 dump 文件")
        print(out[-3000:])
        return 2
    shutil.copy(dump, os.path.join(HERE, "dump_m7_small.txt"))
    print("  dump %d 字节（另存 sim\\dump_m7_small.txt）  仿真 %.1f s"
          % (os.path.getsize(dump), dt))

    env = dict(os.environ, ALG_W=str(W), ALG_H=str(H))
    rc, out, dt = run([PY, os.path.join(HERE, "check_alg_top_full.py"),
                       "--dump", dump, "--frames", str(frames)], HERE, timeout=3600,
                      env=env, enc="utf-8")
    open(os.path.join(HERE, "_m7_check.log"), "w", encoding="utf-8").write(out)
    print(out)
    print("  判定 rc=%d (%.1f s)" % (rc, dt))
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
