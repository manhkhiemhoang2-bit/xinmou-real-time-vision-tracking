"""rtl_mutation_lat.py —— lat_measure 的真 RTL 变异自证。

每个变异都直接改**非注释代码**（改前用注释状态机确认锚点不在 // 或 /* */ 里，
历史上踩过"正则命中注释行导致假漏检"），然后重新编译、重新仿真，
要求 check_lat_measure.py 判 FAIL —— 抓不住就是测试有盲区。

用法：python rtl_mutation_lat.py [--only M3]
"""
import argparse
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

SIM = r"D:\TD\bin\work_for_all\ph1p35_isp\sim"
SRC = r"D:\TD\bin\work_for_all\ph1p35_isp\src"
PY = sys.executable
RTL = os.path.join(SRC, "lat_measure.v")
MUTDIR = os.path.join(SIM, "_lat_mut")

CHK_RE = re.compile(r"\[CHK\]\s+(\S+)\s+cnt=(\d+)\s+err=(\d+)")

MUTS = {
    # 1) 帧计数少加 1（等价于永远不累加）
    "M1_frame_cnt_no_inc": [(
        "else if (w_in_frame)   O_frame_cnt <= O_frame_cnt + 32'd1;",
        "else if (w_in_frame)   O_frame_cnt <= O_frame_cnt + 32'd0;",
    )],
    # 2) BCD 十位/个位对调（错位）
    "M2_bcd_nibble_swap": [(
        "r_bcd_pre    <= {r_div_quot[3:0], r_div_rem[3:0]};",
        "r_bcd_pre    <= {r_div_rem[3:0], r_div_quot[3:0]};",
    )],
    # 3) 除法少移一位（最低位不处理）
    "M3_div_one_less_iter": [(
        "if (r_div_idx == 5'd0) begin          // 最低位处理完 → 结束",
        "if (r_div_idx == 5'd1) begin          // 最低位处理完 → 结束",
    )],
    # 4) 延迟计数器不锁存
    "M4_lat_never_latch": [(
        "O_lat_clk <= (r_lat_cnt == LAT_MAX) ? LAT_MAX : (r_lat_cnt + 11'd1);",
        "O_lat_clk <= O_lat_clk;",
    )],
    # 5) 复位不清 FPS 状态机
    "M5_reset_no_clear_state": [(
        "        r_meas_state <= S_IDLE;\n        r_dvd_in     <= 32'd0;",
        "        r_dvd_in     <= 32'd0;",
    )],
    # 6) 帧率范围判定上界放松到 100（超范围的值被当有效值显示）
    "M6_fps_range_le100": [(
        "(r_div_quot >= 32'd1) && (r_div_quot <= 32'd99)",
        "(r_div_quot >= 32'd1) && (r_div_quot <= 32'd100)",
    )],
    # 7) 周期超量程标志恒 0（饱和计数被当成真周期）
    "M7_period_over_never": [(
        "wire        w_per_over  = (w_per_now > w_per_lim);",
        "wire        w_per_over  = 1'b0;",
    )],
    # 8) BCD 拆分用 16 进制基数（把 /10 写成 /16）
    "M8_bcd_divisor_16": [(
        "r_dvs_in     <= 24'd10;",
        "r_dvs_in     <= 24'd16;",
    )],
}


def in_comment(text, idx):
    """idx 是否落在注释里（// 行注释或 /* */ 块注释）。"""
    i, state = 0, None
    while i < idx:
        if state is None:
            if text.startswith("//", i):
                state, i = "line", i + 2
                continue
            if text.startswith("/*", i):
                state, i = "block", i + 2
                continue
        elif state == "line":
            if text[i] == "\n":
                state = None
        else:
            if text.startswith("*/", i):
                state, i = None, i + 2
                continue
        i += 1
    return state is not None


def run_check(rtl_path, tag):
    r = subprocess.run([PY, os.path.join(SIM, "check_lat_measure.py"),
                        "--rtl", rtl_path, "--tag", tag],
                       cwd=SIM, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=7200)
    return r.returncode, (r.stdout or "")


def caught_by(tag):
    """从变异日志里读出哪些断言失配（用来报告"被哪条断言抓住"）。"""
    p = os.path.join(SIM, "_lat_run_%s.log" % tag)
    if not os.path.exists(p):
        return [], False
    text = open(p, encoding="utf-8", errors="replace").read()
    bad = []
    for m in CHK_RE.finditer(text):
        if int(m.group(3)) != 0:
            bad.append("%s(err=%s)" % (m.group(1), m.group(3)))
    return bad, ("[TB] ALL DONE" in text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    a = ap.parse_args()
    os.makedirs(MUTDIR, exist_ok=True)

    orig = open(RTL, encoding="utf-8").read()
    results = {}

    print("== baseline（未变异，必须 PASS）==")
    rc, out = run_check(RTL, "base")
    print("   rc=%d" % rc)
    for l in out.splitlines():
        if "总检查次数" in l or "VERDICT" in l:
            print("   " + l.strip())
    if rc != 0:
        print("!! 基线都没过，先修 TB/RTL，变异自证无意义")
        return 2
    results["baseline"] = "PASS"

    for name, subs in MUTS.items():
        if a.only and name != a.only:
            continue
        txt = orig
        ok = True
        for anchor, repl in subs:
            n = txt.count(anchor)
            if n != 1:
                print("== %-26s == VACUOUS：锚点出现 %d 次" % (name, n))
                ok = False
                break
            idx = txt.find(anchor)
            if in_comment(txt, idx):
                print("== %-26s == VACUOUS：锚点在注释里" % name)
                ok = False
                break
            txt = txt.replace(anchor, repl)
        if not ok:
            results[name] = "VACUOUS"
            continue
        if txt == orig:
            print("== %-26s == VACUOUS：变异后文本没变" % name)
            results[name] = "VACUOUS"
            continue
        mp = os.path.join(MUTDIR, "%s.v" % name)
        with open(mp, "w", encoding="utf-8", newline="\n") as f:
            f.write(txt)
        rc, out = run_check(mp, name)
        bad, finished = caught_by(name)
        if rc == 2:
            results[name] = "COMPILE/ENV FAIL（不算抓住）"
            print("== %-26s == COMPILE FAIL" % name)
            continue
        caught = (rc == 1)
        results[name] = "CAUGHT" if caught else "MISSED"
        print("== %-26s == %s  终止=%s  失配断言=%s"
              % (name, results[name], "跑完" if finished else "未跑完",
                 ", ".join(bad) if bad else "无"))

    bad_names = [k for k, v in results.items() if v not in ("PASS", "CAUGHT")]
    print("\nsummary: %s" % results)
    print("VERDICT: " + ("全部变异被抓" if not bad_names
                         else "盲区/异常: %s" % bad_names))
    return 0 if not bad_names else 1


if __name__ == "__main__":
    sys.exit(main())
