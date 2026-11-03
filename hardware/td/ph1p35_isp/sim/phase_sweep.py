#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""扫描文字面相位组合：把每种组合写进 RTL，跑 ModelSim + check_osd，报错数。

思路：文字面需要的三个量（列基址、字符下标、行号）各自可以从
"当前拍"或"下一拍"的坐标装载，命中再选择打 0/1 拍。穷举这些组合。
"""
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
SIM = os.path.join(ROOT, "sim")
WORK = os.path.join(SIM, "_phasesweep")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = r"C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"

ORIG = open(SRC, encoding="utf-8").read()

# 三个"相位旋钮"：PX(像素真值) / CUR(本拍 w_x_base,r_y) / NX(下一拍)
CI_EXPR = {
    "PX":  "w_txt_dx_px[8:4]",
    "CUR": "w_txt_dx[8:4]",
    "NX":  "w_txt_dx_nx[8:4]",
}
CB_EXPR = {
    "PX":  "w_txt_dx_px[3:2]",
    "CUR": "w_txt_dx[3:2]",
    "NX":  "w_txt_dx_nx[3:2]",
}
ROW_EXPR = {
    "PX":  "(r_y_px - TEXT_Y) & 4'hF",
    "CUR": "(r_y - TEXT_Y) & 4'hF",
    "NX":  "(w_y_nx - TEXT_Y) & 4'hF",
}
ROWEN_EXPR = {
    "PX":  "(r_y_px >= TEXT_Y) && (r_y_px < (TEXT_Y + TEXT_H))",
    "CUR": "(r_y >= TEXT_Y) && (r_y < (TEXT_Y + TEXT_H))",
    "NX":  "(w_y_nx >= TEXT_Y) && (w_y_nx < (TEXT_Y + TEXT_H))",
}
COLEN_EXPR = {
    "PX":  "(r_x_base_px >= TEXT_X) && (r_x_base_px < (TEXT_X + (N_CHAR_MAX * TEXT_W)))",
    "CUR": "(w_x_base >= TEXT_X) && (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)))",
    "NX":  "(w_x_base_nx >= TEXT_X) && (w_x_base_nx < (TEXT_X + (N_CHAR_MAX * TEXT_W)))",
}


def build_src(ci, cb, row, hit_stage):
    s = ORIG
    # 确保辅助 wire 都存在
    if "w_txt_dx_nx" not in s:
        s = s.replace("reg [3:0] r_glyph_row;",
                      "wire [10:0] w_x_base_nx = {w_x_nx[8:0], 2'b00};\n"
                      "wire [11:0] w_txt_dx_nx = {1'b0, w_x_base_nx} - {1'b0, TEXT_X};\n"
                      "reg [3:0] r_glyph_row;")
    if "wire [11:0] w_txt_dx " not in s and "w_txt_dx[" not in s:
        s = s.replace("wire [11:0] w_txt_dx_px",
                      "wire [11:0] w_txt_dx = {1'b0, w_x_base} - {1'b0, TEXT_X};\n"
                      "wire [11:0] w_txt_dx_px")
    s = s.replace("r_txt_ci       <= w_txt_dx_px[8:4];", "r_txt_ci       <= %s;" % CI_EXPR[ci])
    s = s.replace("r_txt_col_base <= w_txt_dx_px[3:2];", "r_txt_col_base <= %s;" % CB_EXPR[cb])
    s = s.replace("r_glyph_row    <= (r_y_px - TEXT_Y) & 4'hF;", "r_glyph_row    <= %s;" % ROW_EXPR[row])
    s = s.replace("r_in_txt_row   <= (r_y_px >= TEXT_Y) && (r_y_px < (TEXT_Y + TEXT_H));",
                  "r_in_txt_row   <= %s;" % ROWEN_EXPR[row])
    s = s.replace("r_in_txt_col   <= (r_x_base_px >= TEXT_X) &&",
                  "r_in_txt_col   <= %s && (" % COLEN_EXPR[ci if False else col])
    s = s.replace("(r_x_base_px < (TEXT_X + (N_CHAR_MAX * TEXT_W)));",
                  "(1'b1));")
    # 命中打拍级数
    if hit_stage == 0:
        s = s.replace("wire [23:0] w_mix0 = r_pix_text_hit_dbg[3] ?",
                      "wire [23:0] w_mix0 = w_pix_text_hit[3] ?")
        s = s.replace("wire [23:0] w_mix1 = r_pix_text_hit_dbg[2] ?",
                      "wire [23:0] w_mix1 = w_pix_text_hit[2] ?")
        s = s.replace("wire [23:0] w_mix2 = r_pix_text_hit_dbg[1] ?",
                      "wire [23:0] w_mix2 = w_pix_text_hit[1] ?")
        s = s.replace("wire [23:0] w_mix3 = r_pix_text_hit_dbg[0] ?",
                      "wire [23:0] w_mix3 = w_pix_text_hit[0] ?")
    return s


COL = {"PX": "r_x_base_px", "CUR": "w_x_base", "NX": "w_x_base_nx"}


def run_one(tag, text):
    os.makedirs(WORK, exist_ok=True)
    open(SRC, "w", encoding="utf-8", newline="\n").write(text)
    r = subprocess.run([os.path.join(MS, "vlog.exe"), "-sv", "-work", WORK,
                        os.path.join(SIM, "tb_osd_mixer.v"), SRC,
                        os.path.join(ROOT, "src", "my_logo_rom.v"),
                        os.path.join(ROOT, "src", "my_charlib.v")],
                       cwd=SIM, capture_output=True, text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return tag, "COMPILE-FAIL", r.stdout[-400:]
    r = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-lib", WORK, "tb_osd_mixer",
                        "-do", "run -all; quit -f"],
                       cwd=os.path.join(SIM, "osd_work"), capture_output=True, text=True,
                       errors="replace")
    if "Errors: 0" not in r.stdout:
        return tag, "SIM-FAIL", r.stdout[-400:]
    r = subprocess.run([PY, os.path.join(SIM, "check_osd.py"), "--dump",
                        os.path.join(SIM, "osd_work", "dump_osd.txt")],
                       capture_output=True, text=True, errors="replace")
    out = r.stdout
    m = re.search(r"TEXT plane bad\s*:\s*(\d+)", out)
    l = re.search(r"LOGO plane bad\s*:\s*(\d+)", out)
    return tag, ("TEXT=%s LOGO=%s" % (m.group(1) if m else "?",
                                      l.group(1) if l else "?")), ""


if __name__ == "__main__":
    results = []
    for ci in ("PX", "CUR", "NX"):
        for cb in ("PX", "CUR", "NX"):
            for row in ("PX", "CUR", "NX"):
                for hs in (0, 1):
                    tag = "ci=%s cb=%s row=%s hit=%d" % (ci, cb, row, hs)
                    try:
                        txt = build_src(ci, cb, row, hs)
                    except Exception as e:
                        results.append((tag, "BUILD-FAIL: %s" % e, ""))
                        continue
                    t, res, extra = run_one(tag, txt)
                    print("%-34s -> %s %s" % (t, res, extra[:120]))
                    results.append((t, res, extra))
                    if "TEXT=0 " in res:
                        print("*** ZERO FOUND: %s" % t)
    open(SRC, "w", encoding="utf-8", newline="\n").write(ORIG)
    print("原文件已恢复")
