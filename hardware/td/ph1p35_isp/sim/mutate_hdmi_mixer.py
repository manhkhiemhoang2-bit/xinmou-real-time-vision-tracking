#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""mutate_hdmi_mixer.py —— 变异自证伪：证明 tb_hdmi_mixer.v 的 PASS 不是"永远 PASS"

思路：拿**故意改错**的 RTL（改写版 / 官方版各若干处）重跑同一个 testbench，
要求每一处变异都被**指定的那条断言**抓住（errs > 0 或检查集合为空 -> RESULT: FAIL）。
任何一处变异被漏掉 = 相关断言无鉴别力 = 主结果的 PASS 不可信。

变异清单（每条都必须恰好替换 1 处，替换数 != 1 直接判脚本失败，杜绝"空变异假通过"）：

 M1 改写版数据流水 3 级 -> 2 级       期望被抓：A5（data 延迟 3）+ A6a
 M2 改写版 O_video_rd_en 由组合改寄存 期望被抓：A2（同拍直通）+ A1a
 M3 改写版复位分支不再清零 O_hdmi_data 期望被抓：A1b（复位期输出必须为 0）
 M4 官方版旁路不再逐位相等（^1）      期望被抓：A6a（未命中像素必须相同）
 M5 官方版 Logo 命中强制为 0          期望被抓：A6b 集合为空 -> 直接 FAIL

用法： python mutate_hdmi_mixer.py
退出码：0 = 全部变异都被对应的断言抓住；非 0 = 有变异被漏掉（检测有盲区）
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

SIM = Path(__file__).resolve().parent
HDL = SIM.parent / "prj" / "board" / "lab_ex3_osd" / "user_source" / "hdl_source"
OSD = HDL / "_removed_official_osd"
ROM = OSD / "anlogic_logo_rom.v" if (OSD / "anlogic_logo_rom.v").exists() else HDL / "anlogic_logo_rom.v"
LIB = OSD / "osd_char_lib.v" if (OSD / "osd_char_lib.v").exists() else HDL / "osd_char_lib.v"

MS = Path(r"D:\modelsim\modelsim_ase\win32aloem")
WORK = SIM / "_mutwork"
MUTDIR = SIM / "_mut"

REWRITE_SRC = (HDL / "hdmi_mixer.v").read_text(encoding="utf-8")
OFFICIAL_SRC = (SIM / "hdmi_mixer_official.v").read_text(encoding="utf-8")

# name, source, pattern, replacement, expected catchers (assertion id -> must have errs>0)
MUTANTS = [
    dict(
        name="M1_rewrite_data_pipe_3to2",
        desc="rewrite: drop one data pipeline stage (3 -> 2)",
        src="rewrite",
        pat=r"^[ \t]*O_hdmi_data[ \t]*<=[ \t]*S_video_data_2d;",
        rep="O_hdmi_data      <= S_video_data_1d;   // MUTANT",
        catcher=["A5"],
    ),
    dict(
        name="M2_rewrite_rd_en_registered",
        desc="rewrite: register O_video_rd_en instead of combinational",
        src="rewrite",
        pat=r"^[ \t]*assign[ \t]+O_video_rd_en[ \t]*=[ \t]*I_video_de;",
        rep=("reg S_mut_rd_en;\n"
             "    always @(posedge I_clk or negedge I_rst_n)\n"
             "        if(!I_rst_n) S_mut_rd_en <= 1'b0; else S_mut_rd_en <= I_video_de;\n"
             "    assign O_video_rd_en = S_mut_rd_en;   // MUTANT"),
        catcher=["A2"],
    ),
    dict(
        name="M3_rewrite_reset_no_clear_data",
        desc="rewrite: reset branch no longer clears O_hdmi_data",
        src="rewrite",
        pat=r"^[ \t]*O_hdmi_data[ \t]*<=[ \t]*24'd0;",
        rep="O_hdmi_data      <= 24'hFFFFFF;   // MUTANT",
        catcher=["A1b"],
    ),
    dict(
        name="M4_official_bypass_not_exact",
        desc="official: bypass path xor 1 outside the OSD box",
        src="official",
        pat=r"^[ \t]*O_hdmi_data[ \t]*<=[ \t]*S_video_data_2d;",
        rep="O_hdmi_data <= S_video_data_2d ^ 24'h000001;   // MUTANT",
        catcher=["A6a"],
    ),
    dict(
        name="M5_official_osd_never_hits",
        desc="official: force logo hit to 0 (makes the A6b set empty)",
        src="official",
        pat=r"(if\(S_logo_pixel\[24\]\) begin[ \t]*\n[ \t]*)S_osd_hit([ \t]*)=([ \t]*)1'b1;",
        rep=r"\1S_osd_hit\2=\3 1'b0;   // MUTANT",
        catcher=["EMPTY"],          # 唯一判据：A6b 集合必须变空 -> TB 必须判 FAIL
    ),
]


def strip_comments(t: str) -> str:
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r"//[^\n]*", "", t)
    return t


ERR_LINE = re.compile(r"^\s*#?\s*(A1a|A1b|A2|A3|A4v|A4h|A5|A6a|A6b|A6x)\s+.*?(\d+)\s+(\d+)\s*$")


def run(cmd, cwd=SIM):
    p = subprocess.run(cmd, cwd=str(cwd), stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    return p.returncode


def parse_summary(log: Path):
    """返回 (result, {assertion: (checks, errs)})"""
    txt = log.read_text(encoding="utf-8", errors="replace")
    res = None
    if "RESULT: PASS" in txt:
        res = "PASS"
    elif "RESULT: FAIL" in txt:
        res = "FAIL"
    table = {}
    for line in txt.splitlines():
        m = ERR_LINE.match(line)
        if m:
            table[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return res, table


def main():
    print("=" * 78)
    print("mutate_hdmi_mixer.py -- mutation self-proof for tb_hdmi_mixer.v")
    print("=" * 78)

    MUTDIR.mkdir(exist_ok=True)
    if WORK.exists():
        shutil.rmtree(WORK)

    n_fail = 0
    rows = []

    for i, mut in enumerate(MUTANTS, 1):
        base = REWRITE_SRC if mut["src"] == "rewrite" else OFFICIAL_SRC
        new, n = re.subn(mut["pat"], mut["rep"], base, count=1, flags=re.M)
        if n != 1:
            print("\n[%d] %s\n    !! mutation substituted %d times (expected 1) -- ABORT"
                  % (i, mut["name"], n))
            n_fail += 1
            rows.append((mut["name"], "SUBSTITUTION FAILED", "-", "-", "FAIL"))
            continue
        if strip_comments(new) == strip_comments(base):
            # 变异只落在注释里 = RTL 没变 = 假变异（本项目踩过这个坑），必须直接判失败
            print("\n[%d] %s\n    !! mutation landed in a comment only -- ABORT" % (i, mut["name"]))
            n_fail += 1
            rows.append((mut["name"], "COMMENT-ONLY MUTATION", "-", "-", "FAIL"))
            continue

        fname = "hdmi_mixer.v" if mut["src"] == "rewrite" else "hdmi_mixer_official.v"
        (MUTDIR / fname).write_text(new, encoding="utf-8", newline="\n")
        rewrite_v = MUTDIR / "hdmi_mixer.v"
        official_v = MUTDIR / "hdmi_mixer_official.v"
        if mut["src"] == "rewrite":
            official_v.write_text(OFFICIAL_SRC, encoding="utf-8", newline="\n")
        else:
            rewrite_v.write_text(REWRITE_SRC, encoding="utf-8", newline="\n")

        log = SIM / ("_mut_%s.log" % mut["name"])
        lib = WORK
        if lib.exists():
            shutil.rmtree(lib)
        run([str(MS / "vlib.exe"), str(lib)])
        rc = run([str(MS / "vlog.exe"), "-work", str(lib), str(rewrite_v), str(official_v),
                  str(ROM), str(LIB), str(SIM / "tb_hdmi_mixer.v")])
        if rc != 0:
            print("\n[%d] %s\n    !! vlog failed" % (i, mut["name"]))
            n_fail += 1
            rows.append((mut["name"], "VLOG FAILED", "-", "-", "FAIL"))
            continue
        run([str(MS / "vsim.exe"), "-c", "-lib", str(lib),
             "-wlf", str(MUTDIR / (mut["name"] + ".wlf")), "-l", str(log),
             "tb_hdmi_mixer", "-do", "run -all; quit -f"])

        res, table = parse_summary(log)
        catchers = []
        ok = (res == "FAIL")
        for c in mut["catcher"]:
            if c == "EMPTY":
                # A6b 检查次数必须为 0（集合为空 -> 测试无效 -> 必须判失败）
                chk = table.get("A6b", (None, None))[0]
                good = (chk == 0)
                catchers.append("A6b_set_empty=%s" % ("yes" if good else "no"))
            else:
                chk, err = table.get(c, (0, 0))
                good = (chk > 0 and err > 0)
                catchers.append("%s_errs=%s" % (c, err))
            ok = ok and good
        if res is None:
            ok = False
            catchers.append("NO_RESULT_LINE")
        if not ok:
            n_fail += 1
        rows.append((mut["name"], mut["desc"], res, " ".join(catchers),
                     "CAUGHT" if ok else "MISSED"))
        print("\n[%d] %s" % (i, mut["name"]))
        print("    %s" % mut["desc"])
        print("    result=%s  %s  -> %s" % (res, " ".join(catchers), "CAUGHT" if ok else "MISSED"))

    print("\n" + "=" * 78)
    print(" mutation self-proof summary")
    print("-" * 78)
    for r in rows:
        print("  %-34s %-8s %-46s %s" % (r[0], r[2] if len(r) > 2 else "-", r[3] if len(r) > 3 else "-", r[-1]))
    print("-" * 78)
    if n_fail == 0:
        print(" MUTATION SELF-PROOF: PASS (every mutant was caught by its assertion)")
    else:
        print(" MUTATION SELF-PROOF: FAIL (%d mutant(s) not caught)" % n_fail)
    print("=" * 78)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
