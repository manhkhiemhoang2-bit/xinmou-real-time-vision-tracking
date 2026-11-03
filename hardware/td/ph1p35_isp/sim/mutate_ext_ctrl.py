# -*- coding: utf-8 -*-
"""mutate_ext_ctrl.py —— ext_ctrl 的变异自证台

对每个变异：把 src/ext_ctrl.v 改一处**非注释代码** → 写进 _mut_ext/ → 重新
vlog/vsim（TB 不覆盖任何 parameter，所以默认参数变异也能打进来）→ 跑同一个
checker → 记录 PASS/FAIL 以及"被哪几条断言抓住"。

M0 是"原样复制"的对照组：它必须 PASS，用来证明这套变异流程本身不会产生假失败。

用法： python mutate_ext_ctrl.py [--only M3] [--list]
"""
import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src", "ext_ctrl.v"))
MUT_DIR = os.path.join(HERE, "_mut_ext")
WORK_DIR = os.path.join(HERE, "_mutwork")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = sys.executable

# ------------------------------------------------------------------
# 变异表：(tag, 说明, [(old, new), ...])
#   old 必须**恰好出现一次**，且所在行不能是注释行。
# ------------------------------------------------------------------
MUTS = [
    ("M0", "对照组：原样复制（必须 PASS）", []),

    ("M1", "象限判断翻转：左/右分界改成 <=",
     [("wire w_left = (w_cx < X_MID);",
       "wire w_left = (w_cx <= X_MID);")]),

    ("M2", "象限映射错：左上改点亮 LED2",
     [("O_led <= 4'b0001;", "O_led <= 4'b0100;")]),

    ("M3", "bbox 不锁存：象限直接用实时输入算",
     [("wire [11:0] w_sum_x = {1'b0, r_x0} + {1'b0, r_x1};",
       "wire [11:0] w_sum_x = {1'b0, I_bbox_x0} + {1'b0, I_bbox_x1};"),
      ("wire [11:0] w_sum_y = {1'b0, r_y0} + {1'b0, r_y1};",
       "wire [11:0] w_sum_y = {1'b0, I_bbox_y0} + {1'b0, I_bbox_y1};")]),

    ("M4", "蜂鸣节流帧数改错：20 → 19",
     [("parameter integer BEEP_GAP_FRAMES = 20,",
       "parameter integer BEEP_GAP_FRAMES = 19,")]),

    ("M5", "beep 包络长度改错：400000 → 200000",
     [("parameter integer BEEP_ON_CYCLES  = 400000,",
       "parameter integer BEEP_ON_CYCLES  = 200000,")]),

    ("M6", "无目标时不清 LED（删掉 r_val 门控分支）",
     [("""        else if (!r_val)
            O_led <= 4'b0000;                       // 本帧无目标：四灯全灭
""", "")]),

    ("M7", "复位不清 LED",
     [("""        if (!I_rst_n)
            O_led <= 4'b0000;                       // 复位：四灯全灭""",
       """        if (!I_rst_n)
            O_led <= O_led;                          // 变异：复位不清""")]),

    ("M8", "蜂鸣器不按“有目标”门控：r_beep_on & r_val → r_beep_on",
     [("wire w_buzz = r_beep_on & r_val;",
       "wire w_buzz = r_beep_on;")]),

    # ---- v2 新增：针对"重新检出立刻响 + 真·不可重触发 + 倒置框保护" ----
    ("M9", "上升沿判据恒 0（退回 v1 的“要连续 N 帧才响”）",
     [("end else if (!r_pres_d) begin",
       "end else if (1'b0) begin")]),

    ("M10", "上升沿判据恒 1（每个有效帧都请求）",
     [("end else if (!r_pres_d) begin",
       "end else if (1'b1) begin")]),

    ("M11", "去掉包络不可重触发门控（请求到达就重装计数器）",
     [("end else if (r_beep_req && !r_beep_on) begin",
       "end else if (r_beep_req) begin")]),

    ("M12", "去掉倒置框保护（倒置框也按算术中点解象限）",
     [("& w_bb_ok;", "& 1'b1;")]),
]


def apply_mut(base_text, edits, tag):
    txt = base_text
    for old, new in edits:
        n = txt.count(old)
        if n != 1:
            raise RuntimeError("%s: 待替换片段出现 %d 次（要求恰好 1 次）:\n%s" % (tag, n, old))
        off = txt.index(old)
        line_start = txt.rfind("\n", 0, off) + 1
        line = txt[line_start:txt.find("\n", line_start)]
        if line.lstrip().startswith("//"):
            raise RuntimeError("%s: 替换点落在注释行上（不允许）: %s" % (tag, line.strip()))
        txt = txt.replace(old, new, 1)
    if txt == base_text and edits:
        raise RuntimeError("%s: 替换后内容未变化" % tag)
    return txt


def run(cmd, cwd, logpath):
    with open(logpath, "w", encoding="utf-8", errors="replace") as lf:
        p = subprocess.run(cmd, cwd=cwd, stdout=lf, stderr=subprocess.STDOUT)
    return p.returncode


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    if "--list" in sys.argv:
        for t, d, _ in MUTS:
            print("%-4s %s" % (t, d))
        return 0

    os.makedirs(MUT_DIR, exist_ok=True)
    os.makedirs(WORK_DIR, exist_ok=True)
    base_text = open(SRC, "r", encoding="utf-8").read()

    rows = []
    for tag, desc, edits in MUTS:
        if only and tag != only:
            continue
        txt = apply_mut(base_text, edits, tag)
        mfile = os.path.join(MUT_DIR, "ext_ctrl_%s.v" % tag)
        with open(mfile, "w", encoding="utf-8", newline="\n") as f:
            f.write(txt)

        lib = os.path.join(WORK_DIR, tag)
        if os.path.isdir(lib):
            shutil.rmtree(lib)
        run([os.path.join(MS, "vlib.exe"), lib], HERE,
            os.path.join(MUT_DIR, "vlib_%s.log" % tag))
        rc = run([os.path.join(MS, "vlog.exe"), "-work", lib, "-quiet",
                  "tb_ext_ctrl.v", "tb_ext_ctrl_flicker.v", mfile], HERE,
                 os.path.join(MUT_DIR, "vlog_%s.log" % tag))
        if rc != 0:
            rows.append((tag, desc, "COMPILE-FAIL", "-"))
            continue

        caught = []

        def collect(logpath):
            log = open(logpath, "r", encoding="utf-8", errors="replace").read()
            got = []
            for m in re.finditer(r"^RESULT\|(\S+)\|(\d+)\|(\d+)\s*$", log, re.M):
                nm, chk, fail = m.group(1), int(m.group(2)), int(m.group(3))
                if fail > 0 or chk == 0:
                    got.append(nm)
            return got

        # ---- 套件 1：主回归（80 帧 / P=24000）----
        run([os.path.join(MS, "vsim.exe"), "-c", "-lib", lib,
             "-do", "run -all; quit -f", "tb_ext_ctrl"], HERE,
            os.path.join(MUT_DIR, "vsim_%s.log" % tag))
        shutil.copyfile(os.path.join(HERE, "dump_ext.txt"),
                        os.path.join(MUT_DIR, "dump_%s.txt" % tag))
        r1 = run([PY, "check_ext_ctrl.py", os.path.join(MUT_DIR, "dump_%s.txt" % tag)], HERE,
                 os.path.join(MUT_DIR, "check_%s.log" % tag))
        caught += collect(os.path.join(MUT_DIR, "check_%s.log" % tag))

        # ---- 套件 2/3：抖动（P=600）+ 不可重触发（P=100）----
        r2 = r3 = 0
        for sfx, gp, gnc, mode, pl in (("flk", "600", "72100", "flicker", "600"),
                                       ("rtg", "100", "2500000", "retrig", "100")):
            run([os.path.join(MS, "vsim.exe"), "-c", "-lib", lib,
                 "-gP=" + gp, "-gNCYC=" + gnc,
                 "-do", "run -all; quit -f", "tb_ext_ctrl_flicker"], HERE,
                os.path.join(MUT_DIR, "vsim_%s_%s.log" % (tag, sfx)))
            md = os.path.join(MUT_DIR, "dump_%s_%s.txt" % (tag, sfx))
            shutil.copyfile(os.path.join(HERE, "dump_flk.txt"), md)
            rr = run([PY, "check_ext_ctrl_flicker.py", md, "--mode", mode, "--p", pl], HERE,
                     os.path.join(MUT_DIR, "check_%s_%s.log" % (tag, sfx)))
            caught += collect(os.path.join(MUT_DIR, "check_%s_%s.log" % (tag, sfx)))
            if sfx == "flk":
                r2 = rr
            else:
                r3 = rr

        seen = []
        for x in caught:
            if x not in seen:
                seen.append(x)
        verdict = "PASS" if (r1 == 0 and r2 == 0 and r3 == 0) else "FAIL"
        rows.append((tag, desc, verdict, ",".join(seen) if seen else "-"))

    print("=" * 100)
    print("%-4s %-44s %-13s %s" % ("变异", "说明", "结论", "抓住它的断言"))
    print("-" * 100)
    for tag, desc, verdict, caught in rows:
        print("%-4s %-44s %-13s %s" % (tag, desc, verdict, caught))
    print("-" * 100)
    n_ok = sum(1 for r in rows if (r[0] == "M0") == (r[2] == "PASS"))
    print("总计 %d 个变异：M0 对照组 %s；其余 %d 个真变异 %s"
          % (len(rows),
             "PASS(正常)" if any(r[0] == "M0" and r[2] == "PASS" for r in rows) else "未 PASS(异常)",
             len(rows) - 1,
             "全部被抓" if all(r[2] == "FAIL" for r in rows if r[0] != "M0") else "有漏网！"))
    return 0 if n_ok == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
