#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_mutation_top.py —— **真 RTL 变异**自证：改 alg_top.v 一行 -> 重新 vlog/vsim -> 判据必须报错

check_alg_top.py --selftest 改的是**期望值**；本脚本反过来改**被测 RTL 本体**。
抓不住的测试等于没测：连真 RTL 改错都抓不住，那这套判据就是摆设。

做法（全部在 sim\\_mut_top\\ 里，不碰交付的 src\\ 与 sim\\ 文件）：
    1. 把 8 个 .v + tb_alg_top.v + stim_top.hex 拷进 _mut_top\\
    2. 对 alg_top.v 做一次文本替换（变异）
    3. vlib + vlog + vsim 跑出 dump_top.txt（默认激励 = 含行消隐的真实工况）
    4. 用 check_alg_top.py 的同一套判据比对，看哪些判据报错
    5. 指定要抓的那条判据报错 > 0 才算"抓住"

防空转（2026-09-14，今天已经抓到过两次"变异是空操作、全靠失败基线撑着"的假绿）：
    · 基线必须先跑通（判据全绿），否则直接退出（不跑变异）；
    · 每条变异都要实测【变异后的 dump 与基线 dump **逐字节不同**】——相同就说明这个
      文本替换没改变任何行为（空操作变异），一律算"漏掉"并在屏幕上打出来；
    · 替换原文找不到（变异未生效）同样算漏掉。

用法：python rtl_mutation_top.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
WORK = os.path.join(HERE, "_mut_top")
MS = r"D:\modelsim\modelsim_ase\win32aloem"

sys.path.insert(0, HERE)
from check_alg_top import parse, run_all  # noqa: E402

# ⚠ 2026-09-28 修复：本清单原来只有 9 个文件，**漏了 alg_region_fill_96.v**。
#    alg_top.v 例化了它（第 462 行 u_rf），所以 vlog 能过、但 vsim 加载时报
#      `vsim-3033 Instantiation of 'alg_region_fill_96' failed. The design unit was not found.`
#    ⇒ 本变异自证自 M7 region_fill 加入之后**一直是坏的**，而且没人发现，
#      因为它的宿主脚本 run_all_alg_top.ps1 是个孤儿（没有任何总入口调用它）。
#    同一个清单在 run_all_alg_top.ps1 L26-31 里是**有**这个文件的 —— 两边必须同改。
RTLS = ["gray_bt601_96.v", "win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v",
        "alg_smooth_96.v", "alg_color_detect_96.v", "alg_framediff_96.v",
        "alg_region_fill_96.v",
        "rgb_row_delay_96.v", "alg_top.v"]
HEXS = ["stim_top.hex"]

# (说明, alg_top.v 里的替换, 必须报错的判据)
MUTS = [
    ("M0 对齐 4 拍 -> 3 拍（本拍少一级）", "A",
     [("wire [95:0] w_a0_dat = r_m0_dat[3];", "wire [95:0] w_a0_dat = r_m0_dat[2];"),
      ("wire [2:0]  w_a0_ctl = r_m0_ctl[3];", "wire [2:0]  w_a0_ctl = r_m0_ctl[2];")]),
    ("M1 补拍 3 拍 -> 2 拍", "B",
     [("wire [95:0] w_a1_dat = r_m1_dat[2];", "wire [95:0] w_a1_dat = r_m1_dat[1];"),
      ("wire [2:0]  w_a1_ctl = r_m1_ctl[2];", "wire [2:0]  w_a1_ctl = r_m1_ctl[1];")]),
    ("M5 补拍 2 拍 -> 1 拍", "B",
     [("wire [95:0] w_a5_dat = r_m5_dat[1];", "wire [95:0] w_a5_dat = r_m5_dat[0];"),
      ("wire [2:0]  w_a5_ctl = r_m5_ctl[1];", "wire [2:0]  w_a5_ctl = r_m5_ctl[0];")]),
    ("掩蔽取反（mask ? mux : 原图 -> 反过来）", "C",
     [("wire [95:0] w_masked_dat = r_mask_d ? w_mux_dat : w_a0_dat;",
       "wire [95:0] w_masked_dat = r_mask_d ? w_a0_dat : w_mux_dat;")]),
    ("掩蔽期'原图'改成喂灰度流 w_w_dat", "C",
     [("wire [95:0] w_masked_dat = r_mask_d ? w_mux_dat : w_a0_dat;",
       "wire [95:0] w_masked_dat = r_mask_d ? w_mux_dat : w_w_dat;")]),
    ("档位锁存改用输入 I_tuser（早 4 拍换档）", "D",
     [("else if (w_a0_ctl[2] && w_a0_ctl[0])", "else if (w_a0_ctl[2] && I_tuser)")]),
    ("u_rgb3 改喂 w_w_dat（灰度，规格记的坑）", "E",
     [("            r_rgb3_dat[0] <= I_tdata;", "            r_rgb3_dat[0] <= w_w_dat;")]),
    ("去掉 rgb_row_delay 前的 3 拍延迟", "E",
     [(".I_tdata  (r_rgb3_dat[2]),", ".I_tdata  (I_tdata),")]),
]

CKEY = {"A": "A 延迟5拍", "B": "B 六档对金标准", "C": "C 掩蔽区=原图",
        "D": "D 档位锁存", "E": "E M3的src行"}


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
    shutil.copy(os.path.join(HERE, "tb_alg_top.v"), os.path.join(WORK, "tb_alg_top.v"))


def build_and_run():
    rc, out = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
    if rc != 0:
        return False, out
    rc, out = run([os.path.join(MS, "vlog.exe"), "-work", "work"] + RTLS + ["tb_alg_top.v"], WORK)
    if rc != 0 or "Errors: 0" not in out:
        return False, out
    dump = os.path.join(WORK, "dump_top.txt")
    if os.path.isfile(dump):
        os.remove(dump)
    rc, out = run([os.path.join(MS, "vsim.exe"), "-c", "-lib", "work",
                   "tb_alg_top", "-do", "run -all; quit -f"], WORK)
    return os.path.isfile(dump), out


def judge(dump):
    rows = parse(dump)
    counts, _fails = run_all(rows, None, verbose=False)
    return {k: v[1] for k, v in counts.items()}, len(rows)


def main():
    setup()
    print("=" * 78)
    print("真 RTL 变异自证：改错 alg_top.v -> 重编译重仿真 -> 指定判据必须报错")
    print("=" * 78)
    ok, out = build_and_run()
    if not ok:
        print("基线编译/仿真失败：\n" + out[-2000:])
        return 2
    bad, n = judge(os.path.join(WORK, "dump_top.txt"))
    red = {k: v for k, v in bad.items() if v}
    print("  基线（未变异）   dump %d 拍   报错判据：%s   %s"
          % (n, red if red else "无", "PASS" if not red else "基线就不对，先查基线"))
    if red:
        return 2
    base_dump = os.path.join(WORK, "dump_top.txt")
    base_bytes = open(base_dump, "rb").read()
    shipped = os.path.join(HERE, "dump_top.txt")
    same = os.path.isfile(shipped) and open(shipped, "rb").read() == base_bytes
    print("  基线 dump（%d 字节）与 sim\\dump_top.txt 逐字节相同：%s"
          % (len(base_bytes), "是" if same else "否（多半是最近一次跑的是 +nokey/+noblank）"))

    caught = 0
    for name, who, subs in MUTS:
        setup()
        p = os.path.join(WORK, "alg_top.v")
        txt = open(p, encoding="utf-8").read()
        hit = True
        for a, b in subs:
            if a not in txt:
                print("  %-38s  替换原文没找到，变异未生效 -> 算漏掉" % name)
                hit = False
                continue
            txt = txt.replace(a, b, 1)
        open(p, "w", encoding="utf-8").write(txt)
        if not hit:
            continue
        ok, out = build_and_run()
        if not ok:
            print("  %-38s  编译/仿真失败（也算抓住）" % name)
            caught += 1
            continue
        mut_bytes = open(os.path.join(WORK, "dump_top.txt"), "rb").read()
        # 防空转：变异必须真的改变 dump（逐字节）
        if mut_bytes == base_bytes:
            print("  %-38s  !! 空操作变异：dump 与基线逐字节相同（%d 字节）-> 算漏掉 !!"
                  % (name, len(mut_bytes)))
            continue
        bad, _n = judge(os.path.join(WORK, "dump_top.txt"))
        red = {k: v for k, v in bad.items() if v}
        good = bad.get(CKEY[who], 0) > 0
        caught += 1 if good else 0
        print("  %-38s  期望抓=%-2s dump %7d->%7d 字节 报错判据: %-46s %s"
              % (name, who, len(base_bytes), len(mut_bytes),
                 ",".join("%s(%d)" % (k.split()[0], v) for k, v in red.items()) if red else "无",
                 "抓住" if good else "!! 漏掉 !!"))
    print("-" * 78)
    print("  真 RTL 变异鉴别力：%d/%d  -> %s"
          % (caught, len(MUTS), "PASS" if caught == len(MUTS) else "FAIL"))
    print("=" * 78)
    return 0 if caught == len(MUTS) else 1


if __name__ == "__main__":
    sys.exit(main())
