#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""文字面组合穷举。每题都先断言"替换真的生效"，再编译仿真跑 check_osd。"""
import os, re, subprocess, sys

sys.stdout.reconfigure(encoding="utf-8")
ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
SIM = os.path.join(ROOT, "sim")
OSDW = os.path.join(SIM, "osd_work")
WORK = os.path.join(SIM, "_sweepwork")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = r"C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"

ORIG = open(SRC, encoding="utf-8").read()

HELP = """
wire [10:0] w_x_base_nx  = {w_x_nx[8:0], 2'b00};
wire [11:0] w_txt_dx_nx  = {1'b0, w_x_base_nx} - {1'b0, TEXT_X};
wire [10:0] w_x_base_cnt = {2'b00, r_x_grp, 2'b00};
wire [10:0] w_y_cnt      = {r_y_pos};
wire [11:0] w_txt_dx_cnt = {1'b0, w_x_base_cnt} - {1'b0, TEXT_X};
"""

# (列基准, 行号源, 列门, 列基址, 字符下标)
CFG = {
 "A_cur": ("w_x_base",     "r_y",    "w_x_base",     "w_txt_dx_cur[3:2]", "w_txt_dx_cur[8:4]"),
 "B_nx":  ("w_x_base_nx",  "w_y_nx", "w_x_base_nx",  "w_txt_dx_nx[3:2]",  "w_txt_dx_nx[8:4]"),
 "C_cnt": ("w_x_base_cnt", "w_y_cnt","w_x_base_cnt", "w_txt_dx_cnt[3:2]", "w_txt_dx_cnt[8:4]"),
}


def make(stage, hit):
    s = ORIG.replace("// @@HELPERS@@", HELP)
    assert "// @@HELPERS@@" not in s, "HELPERS marker missing"
    xb, yv, cg, cb, ci = CFG[stage]
    reps = [
        ("r_glyph_row    <= (r_y - TEXT_Y) & 4'hF;",
         "r_glyph_row    <= (%s - TEXT_Y) & 4'hF;" % yv),
        ("r_in_txt_row   <= (r_y >= TEXT_Y) && (r_y < (TEXT_Y + TEXT_H));",
         "r_in_txt_row   <= (%s >= TEXT_Y) && (%s < (TEXT_Y + TEXT_H));" % (yv, yv)),
        ("r_txt_col_base <= w_txt_dx_cur[3:2];", "r_txt_col_base <= %s;" % cb),
        ("r_txt_ci       <= w_txt_dx_cur[8:4];", "r_txt_ci       <= %s;" % ci),
    ]
    for a, b in reps:
        assert a in s, "pattern missing: %s" % a
        s = s.replace(a, b)
    s = s.replace("""r_in_txt_col   <= (w_x_base >= TEXT_X) &&
                          (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)));""",
                  "r_in_txt_col   <= (%s >= TEXT_X) && (%s < (TEXT_X + (N_CHAR_MAX * TEXT_W)));"
                  % (cg, cg))
    for k in range(4):
        s = s.replace("wire [23:0] w_mix%d = w_pix_text_hit[%d] ?" % (k, 3 - k),
                      "wire [23:0] w_mix%d = %s[%d] ?" % (k, hit, 3 - k))
    return s


def run(tag, text):
    open(SRC, "w", encoding="utf-8", newline="\n").write(text)
    subprocess.run([os.path.join(MS, "vlib.exe"), WORK], cwd=SIM,
                   capture_output=True, text=True, errors="replace")
    r = subprocess.run([os.path.join(MS, "vlog.exe"), "-sv", "-work", WORK,
                        os.path.join(SIM, "tb_osd_mixer.v"), SRC,
                        os.path.join(ROOT, "src", "my_logo_rom.v"),
                        os.path.join(ROOT, "src", "my_charlib.v")],
                       cwd=SIM, capture_output=True, text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return "%s | COMPILE-FAIL | %s" % (tag, " ".join(r.stdout.split())[-160:])
    r = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-lib", WORK, "tb_osd_mixer",
                        "-do", "run -all; quit -f"], cwd=OSDW, capture_output=True,
                       text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return "%s | SIM-FAIL | %s" % (tag, " ".join(r.stdout.split())[-160:])
    r = subprocess.run([PY, os.path.join(SIM, "check_osd.py"), "--dump",
                        os.path.join(OSDW, "dump_osd.txt")],
                       capture_output=True, text=True, errors="replace")
    mt = re.search(r"TEXT plane bad\s*:\s*(\d+)", r.stdout)
    ml = re.search(r"LOGO plane bad\s*:\s*(\d+)", r.stdout)
    return "%s | TEXT=%-5s LOGO=%s" % (tag, mt.group(1) if mt else "?",
                                       ml.group(1) if ml else "?")


res = []
try:
    for stage in ("A_cur", "B_nx", "C_cnt"):
        for hs, hx in (("hit0", "w_pix_text_hit"), ("hit1", "r_pix_text_hit1"),
                       ("hit2", "r_pix_text_hit2")):
            line = run("%-6s %-5s" % (stage, hs), make(stage, hx))
            print(line, flush=True)
            res.append(line)
finally:
    open(SRC, "w", encoding="utf-8", newline="\n").write(ORIG)
    print("--- 原文件已恢复 ---")
    best = [l for l in res if "TEXT=0 " in l]
    print("零错组合: %s" % (best if best else "无"))
