#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在"坐标源=总线相位"的前提下，穷举 列基址/字符下标/门控 的表达式。"""
import itertools, os, re, subprocess, sys

sys.stdout.reconfigure(encoding="utf-8")
ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
SIM = os.path.join(ROOT, "sim")
OSDW = os.path.join(SIM, "osd_work")
WORK = os.path.join(SIM, "_sweepwork")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = r"C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"
ORIG = open(SRC, encoding="utf-8").read()

CB = {"cur32": "w_txt_dx_cur[3:2]", "cur54": "w_txt_dx_cur[5:4]", "cur10": "w_txt_dx_cur[1:0]"}
CI = {"cur84": "w_txt_dx_cur[8:4]",  "cur96": "w_txt_dx_cur[9:6]",  "cur52": "w_txt_dx_cur[5:2]"}
GT = {
 "base":  "(w_x_base >= TEXT_X) && (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)))",
 "none":  "1'b1",
 "b3":    "(w_x_base >= TEXT_X) && (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W))) && r_in_txt_row",
}


def make(cb, ci, gt, hit):
    s = ORIG
    for a, b in (("r_txt_col_base <= w_txt_dx_cur[3:2];", "r_txt_col_base <= %s;" % CB[cb]),
                 ("r_txt_ci       <= w_txt_dx_cur[8:4];", "r_txt_ci       <= %s;" % CI[ci])):
        assert a in s
        s = s.replace(a, b)
    old = """r_in_txt_col   <= (w_x_base >= TEXT_X) &&
                          (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)));"""
    assert old in s
    s = s.replace(old, "r_in_txt_col   <= %s;" % GT[gt])
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
        return "%s | CFAIL" % tag
    r = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-lib", WORK, "tb_osd_mixer",
                        "-do", "run -all; quit -f"], cwd=OSDW, capture_output=True,
                       text=True, errors="replace")
    if "Errors: 0" not in r.stdout:
        return "%s | SFAIL" % tag
    r = subprocess.run([PY, os.path.join(SIM, "check_osd.py"), "--dump",
                        os.path.join(OSDW, "dump_osd.txt")],
                       capture_output=True, text=True, errors="replace")
    mt = re.search(r"TEXT plane bad\s*:\s*(\d+)", r.stdout)
    ml = re.search(r"LOGO plane bad\s*:\s*(\d+)", r.stdout)
    return "%s | TEXT=%-5s LOGO=%s" % (tag, mt.group(1) if mt else "?",
                                       ml.group(1) if ml else "?")


res = []
try:
    for cb, ci in itertools.product(CB, CI):
        for gt in ("base",):
            for hs, hx in (("h0", "w_pix_text_hit"), ("h1", "r_pix_text_hit1"),
                           ("h2", "r_pix_text_hit2")):
                tag = "cb=%-6s ci=%-6s %s" % (cb, ci, hs)
                line = run(tag, make(cb, ci, gt, hx))
                print(line, flush=True)
                res.append(line)
finally:
    open(SRC, "w", encoding="utf-8", newline="\n").write(ORIG)
    print("--- restored ---")
    print("\n".join(l for l in res if "TEXT=0 " in l) or "no zero-error combo")
