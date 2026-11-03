#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_mutation_pipe.py —— 针对**新增流水级**的真实 RTL 变异门禁

做法：把 src/osd_mixer.v（v1.2，含新流水级）按锚点改坏 → 重新编译 →
      重跑 tb_pipe_equiv（改造前 RTL 当参考）→ 要求 check_pipe_equiv.py **FAIL**。
      抓不住的变异 = 测试有盲区，必须报出来。

变异都改**非注释代码**，且锚点必须精确命中（命中次数不符 = VACUOUS，算失败）。

用法：
    python rtl_mutation_pipe.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

SIM = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SIM, ".."))
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
WRK = os.path.join(SIM, "_pipe_work")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = sys.executable

# 每项：(变异名, [(锚点, 替换, 期望命中次数), ...])
MUTS = {
    # ---- 像素数据没寄存（第 2 级直接用端口 I_tdata）----
    "P1_tdata_not_reg": [
        ("r_pix_data_p1[", "I_tdata[", 4),
    ],
    # ---- Logo 命中/颜色没寄存（第 2 级直接用第 1 级的组合值）----
    "P2_logo_not_reg": [
        ("r_logo_hit0_p1   ? r_logo_col0_p1", "w_logo_hit0      ? w_logo_col0  ", 1),
        ("r_logo_hit1_p1   ? r_logo_col1_p1", "w_logo_hit1      ? w_logo_col1  ", 1),
        ("r_logo_hit2_p1   ? r_logo_col2_p1", "w_logo_hit2      ? w_logo_col2  ", 1),
        ("r_logo_hit3_p1   ? r_logo_col3_p1", "w_logo_hit3      ? w_logo_col3  ", 1),
    ],
    # ---- 控制信号忘了跟着延时 ----
    "P3_tvalid_not_delayed": [("O_tvalid <= r_vld2;", "O_tvalid <= r_vld1;", 1)],
    "P4_tlast_not_delayed":  [("O_tlast <= r_tlast2;", "O_tlast <= r_tlast;", 1)],
    "P5_tuser_not_delayed":  [("O_tuser <= r_tuser2;", "O_tuser <= r_tuser;", 1)],
    # ---- 十进制各位没寄存（LAT: 的百位/十位，屏幕上看得到）----
    "P6_lat_digit_not_reg": [
        ("{4'h0, r_lat_h_p1}", "{4'h0, w_lat_h}", 1),
        ("{4'h0, r_lat_t_p1}", "{4'h0, w_lat_t}", 1),
        ("{4'h0, r_lat_o_p1}", "{4'h0, w_lat_o}", 1),
    ],
    # ---- X: 的十进制各位没寄存（屏幕上画不出来，见下面的盲区实验）----
    "P7_x_digit_not_reg": [
        ("{4'h0, r_x_th_p1}", "{4'h0, w_x_th}", 1),
        ("{4'h0, r_x_h_p1}", "{4'h0, w_x_h}", 1),
        ("{4'h0, r_x_t_p1}", "{4'h0, w_x_t}", 1),
        ("{4'h0, r_x_o_p1}", "{4'h0, w_x_o}", 1),
    ],
    # ---- 位置侧没寄存：字符下标 / 字模行 / 字内列基址 / 行列区间 ----
    "P8_char_index_not_reg": [("case (r_txt_ci_p1)", "case (w_txt_ci)", 1)],
    "P9_glyph_row_not_reg":  [(".I_row   (r_txt_row_p1),", ".I_row   (w_txt_row),", 1)],
    "P10_col_base_not_reg":  [("wire [3:0] w_txt_col0 = {r_txt_col_base_p1, 2'b00};",
                               "wire [3:0] w_txt_col0 = {w_txt_col_base, 2'b00};", 1)],
    "P11_inrow_incol_not_reg": [
        ("r_txt_inrow_p1 && r_txt_incol_p1", "w_txt_inrow && w_txt_incol", 4),
    ],
    # ---- 两个"活叶子"没寄存：档位 ASCII（来自端口）与 FPS 半字节 ----
    "P12_mode_chars_not_reg": [
        ("r_mode_chars_p1[15:8]", "w_mode_chars[15:8]", 1),
        ("r_mode_chars_p1[7:0]", "w_mode_chars[7:0]", 1),
    ],
    "P13_fps_nibble_not_reg": [
        ("{4'h0, r_fps_hi_p1}", "{4'h0, r_info_fps[7:4]}", 1),
        ("{4'h0, r_fps_lo_p1}", "{4'h0, r_info_fps[3:0]}", 1),
    ],
}

# 盲区实验：只把**参考实现**的 X: 十进制位打死，DUT 不动。
# 若比对仍然 PASS，就证明"槽 20..23"这条通路根本到不了输出（N_CHAR_MAX=16）。
OBS_REF_XDIGIT = [
    ("wire [7:0] w_ch_x_o   = {4'h0, w_x_o}   + 8'h30;", "wire [7:0] w_ch_x_o   = 8'h3F;", 1),
    ("wire [7:0] w_ch_x_t   = {4'h0, w_x_t}   + 8'h30;", "wire [7:0] w_ch_x_t   = 8'h3F;", 1),
    ("wire [7:0] w_ch_x_h   = {4'h0, w_x_h}   + 8'h30;", "wire [7:0] w_ch_x_h   = 8'h3F;", 1),
    ("wire [7:0] w_ch_x_th  = {4'h0, w_x_th}  + 8'h30;", "wire [7:0] w_ch_x_th  = 8'h3F;", 1),
]


def sh(args):
    r = subprocess.run(args, cwd=WRK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def compile_and_run(dut_path):
    rc, out = sh([os.path.join(MS, "vlog.exe"), "-sv", "tb_pipe_equiv.v",
                  "osd_mixer_ref.v", dut_path,
                  os.path.join(ROOT, "src", "my_logo_rom.v"),
                  os.path.join(ROOT, "src", "my_charlib.v")])
    if rc != 0:
        return rc, "VLOG FAIL: " + out.strip().splitlines()[-1][:120]
    rc2, out2 = sh([os.path.join(MS, "vsim.exe"), "-c", "-do", "run_pe.do",
                    "tb_pipe_equiv"])
    if rc2 != 0:
        return rc2, "VSIM FAIL: " + out2.strip().splitlines()[-1][:120]
    return 0, ""


def check(dump):
    r = subprocess.run([PY, os.path.join(SIM, "check_pipe_equiv.py"), "--dump", dump],
                       cwd=SIM, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    keep = [l.strip() for l in out.splitlines()
            if l.strip().startswith(("A 正确性", "PASS", "FAIL"))]
    return r.returncode, " | ".join(keep[:3])


def apply_mut(text, subs):
    for a, b, n in subs:
        c = text.count(a)
        if c != n:
            return None, "锚点 %r 命中 %d 次（期望 %d）—— 变异落空" % (a[:50], c, n)
        text = text.replace(a, b)
    return text, ""


def main():
    orig = open(SRC, encoding="utf-8", newline="").read()
    fails = []

    # ---- 基线：未改动的 RTL 必须 PASS ----
    print("== baseline（未改动，必须 PASS）==")
    rc, msg = compile_and_run(SRC)
    assert rc == 0, msg
    rc, tail = check(os.path.join(WRK, "dump_pe.txt"))
    print("   rc=%d  %s" % (rc, tail))
    assert rc == 0, "BASELINE FAILED"

    results = {}
    for name, subs in MUTS.items():
        txt, why = apply_mut(orig, subs)
        if txt is None:
            results[name] = "VACUOUS"
            print("== %-26s == VACUOUS: %s" % (name, why))
            continue
        mp = os.path.join(WRK, "_mut_%s.v" % name)
        with open(mp, "w", encoding="utf-8", newline="") as f:
            f.write(txt)
        rc, msg = compile_and_run(mp)
        if rc != 0:
            results[name] = "COMPILE_FAIL"
            print("== %-26s == COMPILE_FAIL: %s" % (name, msg))
            continue
        dst = os.path.join(WRK, "dump_mut_%s.txt" % name)
        shutil.copy(os.path.join(WRK, "dump_pe.txt"), dst)
        rc, tail = check(dst)
        caught = rc != 0
        results[name] = "CAUGHT" if caught else "MISSED"
        print("== %-26s == %-6s  %s" % (name, results[name], tail))

    # ---- 盲区实验：把**参考实现**的 X: 十进制位打死，DUT 不动 ----
    print("\n== 盲区实验：只改参考实现的 X: 十进制位（若仍 PASS ⇒ 该通路到不了输出）==")
    refp = os.path.join(WRK, "osd_mixer_ref.v")
    reforig = open(refp, encoding="utf-8", newline="").read()
    rtxt, why = apply_mut(reforig, OBS_REF_XDIGIT)
    if rtxt is None:
        print("   锚点落空：%s" % why)
        obs = "VACUOUS"
    else:
        rmp = os.path.join(WRK, "_obs_ref_xdig_dead.v")
        with open(rmp, "w", encoding="utf-8", newline="") as f:
            f.write(rtxt)
        rc, msg = sh([os.path.join(MS, "vlog.exe"), "-sv", "tb_pipe_equiv.v",
                      rmp, SRC,
                      os.path.join(ROOT, "src", "my_logo_rom.v"),
                      os.path.join(ROOT, "src", "my_charlib.v")])
        assert rc == 0, msg
        rc, msg = sh([os.path.join(MS, "vsim.exe"), "-c", "-do", "run_pe.do",
                      "tb_pipe_equiv"])
        assert rc == 0, msg
        shutil.copy(os.path.join(WRK, "dump_pe.txt"),
                    os.path.join(WRK, "dump_obs_ref_xdig_dead.txt"))
        rc, tail = check(os.path.join(WRK, "dump_obs_ref_xdig_dead.txt"))
        obs = "DEAD(输出完全不变)" if rc == 0 else "ALIVE(输出变了)"
        print("    -> %s   %s" % (obs, tail))
        # 恢复参考实现
        with open(refp, "w", encoding="utf-8", newline="") as f:
            f.write(reforig)

    # ---- 恢复干净版本 ----
    print("\n== restore ==")
    rc, msg = compile_and_run(SRC)
    assert rc == 0, msg
    rc, tail = check(os.path.join(WRK, "dump_pe.txt"))
    print("   rc=%d  %s" % (rc, tail))
    assert rc == 0, "RESTORE FAILED"

    bad = [k for k, v in results.items() if v != "CAUGHT"]
    print("\nsummary: %d 个变异，%d 个被抓住，未抓住/落空: %s"
          % (len(results), len(results) - len(bad), bad if bad else "无"))
    print("盲区实验（参考实现 X: 十进制位打死）: %s" % obs)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
