"""check_lat_measure.py —— lat_measure 验证的编译/仿真/判读一体脚本。

用法：
    python check_lat_measure.py [--rtl <lat_measure.v>] [--tag <名字>]
                               [--top tb_lat_measure|tb_lat_integ]

做三件事：
  1. 在 sim 目录下用独立库 work_lat 编译指定的 TB + 指定的 RTL；
  2. vsim -c -do run_lat.do 跑完 -all 并 quit（不留残留进程）；
  3. 判读日志：必须有 [TB] ALL DONE；不能有 [TB] TIMEOUT 或任何 [ERR]；
     每条 [CHK] 断言必须有 cnt>0（0 次检查 = 失败）且 err=0。

--top tb_lat_integ 时编译的是 tb_lat_integ.v + alg_top.v + osd_mixer.v +
my_charlib.v + my_logo_rom.v + lat_measure.v（真集成 TB）。

退出码：0 = 全绿；1 = 有失配/空跑；2 = 编译或运行环境出错。
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

SIM = r"D:\TD\bin\work_for_all\ph1p35_isp\sim"
SRC = r"D:\TD\bin\work_for_all\ph1p35_isp\src"
MS = r"D:\modelsim\modelsim_ase\win32aloem"

# 期望存在的全部断言 ID（少一条 = TB 没跑到/空跑，判失败）
EXPECT_UNIT = [
    "A_first", "A_cnt", "A_lat7", "A_fps60", "A_rstclr",
    "A_aftcnt", "A_aftlat", "A_aftfps", "A_ref",
    "B_cnt1", "B_lat7", "B_fps04", "B_fps05", "B_fps91", "B_fps83",
    "B_inv100", "B_inv250", "B_inv1k", "B_maxg", "B_over", "B_recov",
    "B_lat13", "B_rstclr", "B_rstfps", "B_rstcnt", "B_ref",
    "C_fps99", "C_fps50", "C_over", "C_recov", "C_rstdv", "C_rstfp", "C_ref",
]

EXPECT_INTEG = [
    "I_lat_m0_1m", "I_osd_lat_m0_1m", "I_fps_m0_1m", "I_cnt_m0_1m", "I_mode_m0_1m",
    "I_lat_m3_1m", "I_osd_lat_m3_1m", "I_fps_m3_1m", "I_cnt_m3_1m", "I_mode_m3_1m",
    "I_lat_m0_59", "I_osd_lat_m0_59", "I_fps_m0_59", "I_cnt_m0_59", "I_mode_m0_59",
    "I_lat_m3_59", "I_osd_lat_m3_59", "I_fps_m3_59", "I_cnt_m3_59", "I_mode_m3_59",
    "I_lat_1m917", "I_osd_lat_1m917", "I_fps_1m917", "I_cnt_1m917", "I_mode_1m917",
    "I_ref",
]

EXPECT = {"tb_lat_measure": EXPECT_UNIT, "tb_lat_integ": EXPECT_INTEG}

CHK_RE = re.compile(r"\[CHK\]\s+(\S+)\s+cnt=(\d+)\s+err=(\d+)")


def run(args, logf):
    logf.write("\n$ " + " ".join(args) + "\n")
    logf.flush()
    return subprocess.run(args, cwd=SIM, stdout=logf,
                          stderr=subprocess.STDOUT, timeout=7200).returncode


def sources_for(top, rtl):
    if top == "tb_lat_integ":
        # alg_top 当前实例化的全部子模块（2026-09-17 17:56 的 alg_top 版本）+
        # osd_mixer 依赖（含官方 Logo ROM）+ lat_measure。
        # ※ 不用 src\*.v 全量编译：别的模块可能正被别人改到一半（alg_histeq_96.v
        #   此刻就编不过），会连累本 TB。
        alg = ["alg_top.v", "gray_bt601_96.v", "win3x3_96.v", "rgb_row_delay_96.v",
               "alg_binarize_96.v", "alg_sobel_96.v", "alg_smooth_96.v",
               "alg_color_detect_96.v", "alg_framediff_96.v",
               "osd_mixer.v", "alg_logo_eram.v", "my_charlib.v", "my_logo_rom.v"]
        rom = os.path.join(os.path.dirname(SRC), "prj", "_fullchip", "mixer_ab",
                           "anlogic_logo_rom.v")
        return ([os.path.join(SIM, "tb_lat_integ.v")]
                + [os.path.join(SRC, f) for f in alg] + [rom, rtl])
    return [os.path.join(SIM, "tb_lat_measure.v"), rtl]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=os.path.join(SRC, "lat_measure.v"))
    ap.add_argument("--tag", default="base")
    ap.add_argument("--top", default="tb_lat_measure")
    ap.add_argument("--keep-log", action="store_true")
    a = ap.parse_args()

    expected = EXPECT[a.top]
    logpath = os.path.join(SIM, "_lat_run_%s.log" % a.tag)
    worklib = os.path.join(SIM, "work_lat")
    if os.path.isdir(worklib):
        shutil.rmtree(worklib, ignore_errors=True)

    with open(logpath, "w", encoding="utf-8", errors="replace") as logf:
        rc = run([os.path.join(MS, "vlib.exe"), "work_lat"], logf)
        if rc != 0:
            print("[ENV] vlib 失败，见 %s" % logpath)
            return 2
        rc = run([os.path.join(MS, "vlog.exe"), "-work", "work_lat"]
                 + sources_for(a.top, a.rtl), logf)
        if rc != 0:
            print("[COMPILE FAIL] %s" % logpath)
            return 2
        rc = run([os.path.join(MS, "vsim.exe"), "-c", "-do", "run_lat.do",
                  "work_lat.%s" % a.top], logf)

    text = open(logpath, encoding="utf-8", errors="replace").read()

    chks = {}
    for m in CHK_RE.finditer(text):
        name, cnt, err = m.group(1), int(m.group(2)), int(m.group(3))
        chks[name] = (chks.get(name, (0, 0))[0] + cnt,
                      chks.get(name, (0, 0))[1] + err)

    err_lines = [l.strip() for l in text.splitlines() if "[ERR]" in l]
    done = "[TB] ALL DONE" in text
    timeout = "[TB] TIMEOUT" in text
    missing = [k for k in expected if k not in chks]
    empty = [k for k in expected if k in chks and chks[k][0] == 0]
    bad = [k for k in expected if k in chks and chks[k][1] != 0]

    print("---- %s ----" % a.tag)
    for k in expected:
        if k in chks:
            print("  %-16s cnt=%-8d err=%d" % (k, chks[k][0], chks[k][1]))
    total_cnt = sum(v[0] for v in chks.values())
    total_err = sum(v[1] for v in chks.values())
    print("  总检查次数 = %d，断言失配 = %d，[ERR] 行 = %d"
          % (total_cnt, total_err, len(err_lines)))
    for l in err_lines[:20]:
        print("   ! " + l)
    for l in text.splitlines():
        if "[RPT]" in l:
            print("   " + l.strip())

    ok = True
    if not done:
        print("  [FAIL] 没有 [TB] ALL DONE")
        ok = False
    if timeout:
        print("  [FAIL] 看门狗超时")
        ok = False
    if missing:
        print("  [FAIL] 缺断言（TB 没跑到或崩溃）：%s" % missing)
        ok = False
    if empty:
        print("  [FAIL] 0 次检查的断言：%s" % empty)
        ok = False
    if bad:
        print("  [FAIL] 有失配的断言：%s" % bad)
        ok = False
    if err_lines:
        print("  [FAIL] 存在 [ERR] 行")
        ok = False
    print("  VERDICT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
