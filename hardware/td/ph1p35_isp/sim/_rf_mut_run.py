#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_rf_mut_run.py —— 本轮回归：真实分辨率轮 + 变异表（每条都要"被抓 + dump 与基线不同"）
                   + 气泡长度诊断（skip=1，查那个"与前瞻无关"的失配是不是真的）。

在 sim\\ 下跑：python _rf_mut_run.py
产物：sim\\_rf_mut_table.txt（变异表）、sim\\_rf_hd_check.log、sim\\_rf_bub_skip1.log
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MV = r"D:\modelsim\modelsim_ase\win32aloem"
WORK = os.path.join(HERE, "_rfmut_work")
RTL = os.path.join(ROOT, "src", "alg_region_fill_96.v")

# ---- 变异表：(名字, 说明, 补丁列表[(old,new)], 类别) ----
MUTS = [
    ("M1_rise_every_white",
     "上升沿判据退回'每个白像素都翻转'（旧缺陷）",
     [("wire w_rise0 = w_e0 & ~r_edge_prev;", "wire w_rise0 = w_e0;"),
      ("wire w_rise1 = w_e1 & ~w_e0;", "wire w_rise1 = w_e1;"),
      ("wire w_rise2 = w_e2 & ~w_e1;", "wire w_rise2 = w_e2;"),
      ("wire w_rise3 = w_e3 & ~w_e2;", "wire w_rise3 = w_e3;")], "rtl"),
    ("M2_no_rowhead_clear",
     "去掉行首清零（inside/prev 跨行残留）",
     [("wire w_row_end = (r_x == LAST_BEAT);", "wire w_row_end = 1'b0;")], "rtl"),
    ("M3_left_neighbor_bit3",
     "横向对齐链：左邻由 s2[0] 改成 s2[3]（本轮修的那一处退化）",
     [("r_rd2_s2[0];", "r_rd2_s2[3];"), ("r_rd1_s2[0];", "r_rd1_s2[3];")], "rtl"),
    ("M4_win_valid_rows2",
     "w_win_valid 行门槛改回 2",
     [("(r_y >= 11'd3)", "(r_y >= 11'd2)")], "rtl"),
    ("M5_right_neighbor_stage",
     "右邻取错一级（取 s1 而不是读口新值）= v3.1 那种横向对齐退化",
     [("wire w_top_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd2[3];",
       "wire w_top_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd2_s1[3];"),
      ("wire w_mid_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd1[3];",
       "wire w_mid_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd1_s1[3];")], "rtl"),
    ("M6_inside_parallel",
     "inside 4 像素并行算（输出等价、只有内部电平不同）",
     [("wire w_ins2  = w_ins1 ^ w_rise1;", "wire w_ins2  = w_ins0 ^ w_rise1;"),
      ("wire w_ins3  = w_ins2 ^ w_rise2;", "wire w_ins3  = w_ins0 ^ w_rise2;"),
      ("wire w_ins4  = w_ins3 ^ w_rise3;", "wire w_ins4  = w_ins0 ^ w_rise3;")], "rtl"),
    ("M5old_bot4_zero",
     "底行右邻恒 0【死逻辑：本激励下该前瞻只在一处起作用、而那一处本来就是气泡】",
     [("wire w_bot_4  = (r_x == LAST_BEAT) ? 1'b0 : w_w0;",
       "wire w_bot_4  = 1'b0;")], "vacuous"),
]


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def sim(rtl_src, tb, stim, dump_name, tag, plusargs=(), work=WORK):
    if os.path.isdir(work):
        shutil.rmtree(work)
    os.makedirs(work)
    shutil.copy(rtl_src, os.path.join(work, "alg_region_fill_96.v"))
    shutil.copy(os.path.join(HERE, tb), work)
    shutil.copy(os.path.join(HERE, stim), work)
    subprocess.run([os.path.join(MV, "vlib.exe"), "work"], cwd=work,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    r = subprocess.run([os.path.join(MV, "vlog.exe"), "-work", "work",
                        "alg_region_fill_96.v", tb], cwd=work,
                       capture_output=True, text=True)
    if "Errors: 0" not in r.stdout:
        return None, "vlog 失败", r.stdout[-600:]
    import re as _re
    top = _re.search(r"module\s+(\w+)", open(os.path.join(HERE, tb), encoding="utf-8").read()).group(1)
    cmd = [os.path.join(MV, "vsim.exe"), "-c", "-lib", "work", top,
           "-do", "run -all; quit -f"] + list(plusargs)
    r = subprocess.run(cmd, cwd=work, capture_output=True, text=True)
    d = os.path.join(work, dump_name)
    if not os.path.exists(d):
        return None, "没有 dump", r.stdout[-600:]
    return d, ("TB-RESULT: PASS" in r.stdout), r.stdout


def run_check(dump, stim, meta, muts=None):
    import check_region_fill as C
    import json
    m = json.load(open(os.path.join(HERE, meta), encoding="utf-8"))
    rep = C.check(dump, os.path.join(HERE, stim), m["W"], m["H"], selftest_muts=muts)
    return rep


def main():
    out = []
    base_dump = os.path.join(HERE, "dump_rf.txt")
    base_md5 = md5(base_dump)
    out.append("基线 dump = sim\\dump_rf.txt  md5=%s" % base_md5)
    out.append("RTL = src\\alg_region_fill_96.v  md5=%s" % md5(RTL))
    out.append("")

    # ---------- 1) 真实分辨率轮（1280x720，3 帧）----------
    print("== HD 轮开始 ==")
    d, ok, log = sim(RTL, "tb_region_fill_hd.v", "stim_rf_hd.hex", "dump_rf_hd.txt", "hd")
    if d is None:
        out.append("HD 轮: 失败 %s" % ok)
    else:
        rep = run_check(d, "stim_rf_hd.hex", "meta_rf_hd.json")
        c, e = rep.dump("")
        lines = ["", "== ① 真实分辨率轮 1280x720 x 3 帧 ==",
                 "TB-RESULT: %s   dump md5=%s" % ("PASS" if ok else "FAIL", md5(d))]
        for name, cnt, err, det in rep.items:
            lines.append("  %-5s 检查 %7d 失配 %7d  %s" % (name, cnt, err, det))
        lines.append("  合计检查 %d 失配 %d  RESULT: %s"
                     % (c, e, "PASS" if (e == 0 and c > 0) else "FAIL"))
        out.extend(lines)
        print("\n".join(lines))
        shutil.copy(d, os.path.join(HERE, "dump_rf_hd.txt"))     # 把 HD dump 落回 sim\
    out.append("")

    # ---------- 2) 变异表 ----------
    print("== 变异开始 ==")
    rows = []
    for name, desc, patches, kind in MUTS:
        src = open(RTL, encoding="utf-8").read()
        bad = False
        for old, new in patches:
            if old not in src:
                bad = True
                break
            src = src.replace(old, new, 1)
        if bad:
            rows.append((name, desc, "补丁锚点没找到", "-", "-"))
            continue
        mp = os.path.join(HERE, "_mut_tmp.v")
        open(mp, "w", encoding="utf-8", newline="\n").write(src)
        d, ok, log = sim(mp, "tb_region_fill.v", "stim_rf.hex", "dump_rf.txt", name)
        if d is None:
            rows.append((name, desc, "仿真失败", ok, "-"))
            continue
        dm = md5(d)
        rep = run_check(d, "stim_rf.hex", "meta_rf.json")
        _c, e = rep.dump("")
        caught = [n for n, cnt, err, det in rep.items if err > 0]
        rows.append((name, desc, "%s | dump %s" % (md5(d) != base_md5 and "与基线不同" or "!!与基线相同",
                                                   dm[:12]),
                     ("VACUOUS(死逻辑，不计入有效变异)" if kind == "vacuous"
                      else ("被抓" if e > 0 else "!!没抓到")),
                     ",".join(caught)))
        print("  %-22s %s" % (name, rows[-1][2:]))
    # M7：判据侧的"去掉晚一行位移"变异（期望改成 shift0）
    rep = run_check(base_dump, "stim_rf.hex", "meta_rf.json", muts={"expect_shift0": True})
    _c, e = rep.dump("")
    caught = [n for n, cnt, err, det in rep.items if err > 0]
    rows.append(("M7_checker_shift0", "判据用 shift0 期望（去掉'晚一行'位移）",
                 "判据侧变异（不改 RTL，dump 同基线）", "被抓" if e > 0 else "!!没抓到",
                 ",".join(caught)))
    out.append("== ② 变异表（每条：dump 必须与基线不同 + 必须被抓 + 被哪条断言抓住）==")
    out.append("  %-22s %-46s %-34s %-8s %s" % ("变异", "说明", "dump", "结果", "抓住它的断言"))
    for r in rows:
        out.append("  %-22s %-46s %-34s %-8s %s" % r)
    out.append("")
    for name, desc, dd, res, ca in rows:
        print("  %-22s %s -> %s [%s]" % (name, res, ca, dd))

    # ---------- 3) 气泡长度诊断（skip=1）----------
    print("== 气泡诊断 skip=1 ==")
    tb1 = os.path.join(HERE, "_tb_bub1.v")
    t = open(os.path.join(HERE, "tb_region_fill.v"), encoding="utf-8").read()
    t2 = t.replace("localparam BUB_SKIP   = 2;", "localparam BUB_SKIP   = 1;")
    open(tb1, "w", encoding="utf-8", newline="\n").write(t2)
    d, ok, log = sim(RTL, "_tb_bub1.v", "stim_rf.hex", "dump_rf.txt", "bub1")
    if d is None:
        out.append("skip=1 诊断: 失败")
    else:
        rep = run_check(d, "stim_rf.hex", "meta_rf.json")
        c, e = rep.dump("")
        line = "气泡长度 1（BUB_SKIP=1）: 合计检查 %d 失配 %d（真 RTL）；模型预测 35" % (c, e)
        out.append(line)
        print("  " + line)
        for name, cnt, err, det in rep.items:
            if err:
                out.append("     %-5s 失配 %d  %s" % (name, err, det))
    out.append("")
    out.append("（M7 是判据侧变异：不改 RTL，dump 与基线相同是预期的。）")

    txt = "\n".join(out)
    open(os.path.join(HERE, "_rf_mut_table.txt"), "w", encoding="utf-8", newline="\n").write(txt + "\n")
    print("已写 sim\\_rf_mut_table.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
