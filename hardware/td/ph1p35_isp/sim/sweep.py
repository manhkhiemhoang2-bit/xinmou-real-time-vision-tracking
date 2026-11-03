#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""文字面相位穷举：把"坐标源 + 命中打拍数"的每种组合都编译仿真一遍，报错数。"""
import os, re, subprocess, sys

sys.stdout.reconfigure(encoding="utf-8")
ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
SIM = os.path.join(ROOT, "sim")
OSDW = os.path.join(SIM, "osd_work")
WORK = os.path.join(SIM, "_sweepwork")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = r"C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"
LOG = os.path.join(SIM, "sweep_log.txt")

ORIG = open(SRC, encoding="utf-8").read()

# 坐标源：把 (x_base, y, glyph_row, col_base, ci) 从哪一拍取
SRC_EXPR = {
    # A: 当前 r_x/r_y（= r_x_now，与 Logo 同相）
    "A_cur":  ("w_x_base", "r_y", "(r_y - TEXT_Y) & 4'hF", "w_txt_dx_cur[3:2]", "w_txt_dx_cur[8:4]",
               "(w_x_base >= TEXT_X) && (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)))"),
    # B: 下一拍 w_x_nx / w_y_nx（最早那版）
    "B_nx":   ("w_x_base_nx", "w_y_nx", "(w_y_nx - TEXT_Y) & 4'hF", "w_txt_dx_nx[3:2]", "w_txt_dx_nx[8:4]",
               "(w_x_base_nx >= TEXT_X) && (w_x_base_nx < (TEXT_X + (N_CHAR_MAX * TEXT_W)))"),
    # C: 计数器原值 r_x_grp / r_y_pos（总线真值相位）
    "C_cnt":  ("w_x_base_cnt", "w_y_cnt", "(w_y_cnt - TEXT_Y) & 4'hF", "w_txt_dx_cnt[3:2]", "w_txt_dx_cnt[8:4]",
               "(w_x_base_cnt >= TEXT_X) && (w_x_base_cnt < (TEXT_X + (N_CHAR_MAX * TEXT_W)))"),
}

HELPERS = """
wire [10:0] w_x_base_nx   = {w_x_nx[8:0], 2'b00};
wire [11:0] w_txt_dx_nx   = {1'b0, w_x_base_nx} - {1'b0, TEXT_X};
wire [10:0] w_x_base_cnt  = {2'b00, r_x_grp, 2'b00};
wire [10:0] w_y_cnt       = {r_y_pos};
wire [11:0] w_txt_dx_cnt  = {1'b0, w_x_base_cnt} - {1'b0, TEXT_X};
"""


def variant(stage, hit_stages):
    s = ORIG
    xb, yv, grow, cb, ci, cgate = SRC_EXPR[stage]
    s = s.replace("// @@HELPERS@@", HELPERS)
    s = s.replace("r_glyph_row    <= (r_y - TEXT_Y) & 4'hF;",
                  "r_glyph_row    <= %s;" % grow)
    s = s.replace("r_in_txt_row   <= (r_y >= TEXT_Y) && (r_y < (TEXT_Y + TEXT_H));",
                  "r_in_txt_row   <= (%s >= TEXT_Y) && (%s < (TEXT_Y + TEXT_H));" % (yv, yv))
    s = s.replace("""r_in_txt_col   <= (w_x_base >= TEXT_X) &&
                          (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)));""",
                  "r_in_txt_col   <= %s;" % cgate)
    s = s.replace("r_txt_col_base <= w_txt_dx_cur[3:2];", "r_txt_col_base <= %s;" % cb)
    s = s.replace("r_txt_ci       <= w_txt_dx_cur[8:4];", "r_txt_ci       <= %s;" % ci)
    # 命中打拍
    s = s.replace("wire [23:0] w_mix0 = w_pix_text_hit[3] ?",
                  "wire [23:0] w_mix0 = %s[3] ?" % hit_stages)
    s = s.replace("wire [23:0] w_mix1 = w_pix_text_hit[2] ?",
                  "wire [23:0] w_mix1 = %s[2] ?" % hit_stages)
    s = s.replace("wire [23:0] w_mix2 = w_pix_text_hit[1] ?",
                  "wire [23:0] w_mix2 = %s[1] ?" % hit_stages)
    s = s.replace("wire [23:0] w_mix3 = w_pix_text_hit[0] ?",
                  "wire [23:0] w_mix3 = %s[0] ?" % hit_stages)
    return s


def run(tag):
    subprocess.run([os.path.join(MS, "vlib.exe"), WORK], cwd=SIM,
                   capture_output=True, text=True, errors="replace")
    r = subprocess.run([os.path.join(MS, "vlog.exe"), "-sv", "-work", WORK,
                        os.path.join(SIM, "tb_osd_mixer.v"), SRC,
                        os.path.join(ROOT, "src", "my_logo_rom.v"),
                        os.path.join(ROOT, "src", "my_charlib.v")],
                       cwd=SIM, capture_output=True, text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return "%s | COMPILE-FAIL | %s" % (tag, " ".join(r.stdout.split())[-200:])
    r = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-lib", WORK, "tb_osd_mixer",
                        "-do", "run -all; quit -f"], cwd=OSDW, capture_output=True,
                       text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return "%s | SIM-FAIL | %s" % (tag, " ".join(r.stdout.split())[-200:])
    r = subprocess.run([PY, os.path.join(SIM, "check_osd.py"), "--dump",
                        os.path.join(OSDW, "dump_osd.txt")],
                       capture_output=True, text=True, errors="replace")
    o = r.stdout
    mt = re.search(r"TEXT plane bad\s*:\s*(\d+)", o)
    ml = re.search(r"LOGO plane bad\s*:\s*(\d+)", o)
    return "%s | TEXT=%-5s LOGO=%-4s" % (tag, mt.group(1) if mt else "?",
                                         ml.group(1) if ml else "?")


out = []
for stage in ("A_cur", "B_nx", "C_cnt"):
    for hs, expr in (("hit0(w)", "w_pix_text_hit"),
                     ("hit1(r1)", "r_pix_text_hit1"),
                     ("hit2(r2)", "r_pix_text_hit2")):
        txt = variant(stage, expr)
        line = run("%-8s %-9s" % (stage, hs))
        out.append(line)
        print(line, flush=True)
        open(LOG, "w", encoding="utf-8").write("\n".join(out))

open(SRC, "w", encoding="utf-8", newline="\n").write(ORIG)
print("原文件已恢复")
