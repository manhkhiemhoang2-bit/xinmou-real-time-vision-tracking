#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_mutation_align.py —— 对齐修复的**变异自证**：把 4 行修复逐条改回去 + 数据链少一级

判据：sim/check_contract.py（输出流必须恰好等于输入流延迟 2 拍、四路同拍）。
每个变异都必须让它 **FAIL**；抓不住 = 契约测试有盲区。

变异（都改非注释代码，锚点命中次数必须精确）：
  AL1  O_tdata 门控改回"再延一拍"的控制  → else if (r_vld1_d)
  AL2  O_tvalid 改回再延一拍              → O_tvalid <= r_vld1_d
  AL3  O_tlast  改回再延一拍              → O_tlast  <= r_tlast_d
  AL4  O_tuser  改回再延一拍              → O_tuser  <= r_tuser_d
       （r_vld1_d/r_tlast_d/r_tuser_d = 与修复前 r_vld2/r_tlast2/r_tuser2 等价的
         "多打一拍"寄存器，由公共插入块一并加进去）
  AL5  数据链少一级：第 2 级混合直接用当前拍 I_tdata（等价于数据链只有 1 级）

用法：
    python rtl_mutation_align.py
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")
SIM = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SIM, ".."))
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
WRK = os.path.join(SIM, "_contract_work")
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = sys.executable

# 公共插入块：多打一拍的三个控制寄存器（等价于修复前的 r_vld2/r_tlast2/r_tuser2）
ANCHOR_OUT = ("always @ (posedge I_clk or negedge I_rst_n) begin\n"
              "    if (!I_rst_n)\n"
              "        O_tdata <= 96'd0;")
EXTRA = ("// ---- 变异用：把控制再延一拍的寄存器（等价于修复前的 r_vld2/r_tlast2/r_tuser2）----\n"
         "reg r_vld1_d, r_tlast_d, r_tuser_d;\n\n"
         "always @ (posedge I_clk or negedge I_rst_n) begin\n"
         "    if (!I_rst_n) begin\n"
         "        r_vld1_d  <= 1'b0;\n"
         "        r_tlast_d <= 1'b0;\n"
         "        r_tuser_d <= 1'b0;\n"
         "    end else begin\n"
         "        r_vld1_d  <= r_vld1;\n"
         "        r_tlast_d <= r_tlast;\n"
         "        r_tuser_d <= r_tuser;\n"
         "    end\n"
         "end\n\n") + ANCHOR_OUT

MUTS = {
    "AL1_otdata_gate_reverted": [(ANCHOR_OUT, EXTRA, 1),
                                 ("    else if (r_vld1)\n        O_tdata <= w_mix;",
                                  "    else if (r_vld1_d)\n        O_tdata <= w_mix;", 1)],
    "AL2_otvalid_reverted":     [(ANCHOR_OUT, EXTRA, 1),
                                 ("        O_tvalid <= r_vld1;", "        O_tvalid <= r_vld1_d;", 1)],
    "AL3_otlast_reverted":      [(ANCHOR_OUT, EXTRA, 1),
                                 ("        O_tlast <= r_tlast;", "        O_tlast <= r_tlast_d;", 1)],
    "AL4_otuser_reverted":      [(ANCHOR_OUT, EXTRA, 1),
                                 ("        O_tuser <= r_tuser;", "        O_tuser <= r_tuser_d;", 1)],
    "AL5_data_chain_short":     [("r_pix_data_p1[", "I_tdata[", 4)],
}

PAT = re.compile(r"^\s*(A\d[a-z]?)\s+.*?检查\s+(\d+)\s*次\s*/\s*失配\s+(\d+)")


def compile_run(dut_path):
    r = subprocess.run([os.path.join(MS, "vlog.exe"), "-sv", "tb_contract.v",
                        dut_path, os.path.join(ROOT, "src", "my_logo_rom.v"),
                        os.path.join(ROOT, "src", "my_charlib.v")],
                       cwd=WRK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return "VLOG_FAIL: " + (r.stdout or "").strip().splitlines()[-1][:100]
    r = subprocess.run([os.path.join(MS, "vsim.exe"), "-c", "-do", "run -all; quit -f",
                        "tb_contract"], cwd=WRK, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        return "VSIM_FAIL"
    shutil.copy(os.path.join(WRK, "dump_contract.txt"), os.path.join(WRK, "dump_last.txt"))
    return ""


def check(path):
    r = subprocess.run([PY, os.path.join(SIM, "check_contract.py"), "--dump", path],
                       cwd=SIM, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    fails = []
    for ln in out.splitlines():
        m = PAT.match(ln)
        if m and int(m.group(3)) > 0:
            fails.append("%s(失配 %s)" % (m.group(1), m.group(3)))
        if m and int(m.group(2)) == 0:
            fails.append("%s(0 次检查)" % m.group(1))
    return r.returncode, fails


def main():
    orig = open(SRC, encoding="utf-8", newline="").read()
    print("== baseline（当前 src，修复版，必须 PASS）==")
    msg = compile_run(SRC)
    assert not msg, msg
    rc, fails = check(os.path.join(WRK, "dump_contract.txt"))
    print("   rc=%d  未通过断言=%s" % (rc, fails if fails else "无"))
    assert rc == 0, "BASELINE FAILED"

    results = {}
    for name, subs in MUTS.items():
        txt = orig
        ok = True
        for a, b, n in subs:
            c = txt.count(a)
            if c != n:
                print("== %-26s == VACUOUS: 锚点 %r 命中 %d 次（期望 %d）" % (name, a[:40], c, n))
                results[name] = "VACUOUS"
                ok = False
                break
            txt = txt.replace(a, b)
        if not ok:
            continue
        mp = os.path.join(WRK, "_mut_%s.v" % name)
        with open(mp, "w", encoding="utf-8", newline="") as f:
            f.write(txt)
        msg = compile_run(mp)
        if msg:
            results[name] = "COMPILE_FAIL"
            print("== %-26s == %s" % (name, msg))
            continue
        dst = os.path.join(WRK, "dump_mut_%s.txt" % name)
        shutil.copy(os.path.join(WRK, "dump_last.txt"), dst)
        rc, fails = check(dst)
        results[name] = "CAUGHT" if rc != 0 else "MISSED"
        print("== %-26s == %-6s 被抓住的断言：%s"
              % (name, results[name], ", ".join(fails) if fails else "（无）"))

    print("\n== restore（回到修复版）==")
    msg = compile_run(SRC)
    assert not msg, msg
    rc, fails = check(os.path.join(WRK, "dump_contract.txt"))
    print("   rc=%d  未通过断言=%s" % (rc, fails if fails else "无"))
    assert rc == 0, "RESTORE FAILED"

    bad = [k for k, v in results.items() if v != "CAUGHT"]
    print("\nsummary: %d 个变异，%d 个被抓住；未抓住/落空：%s"
          % (len(results), len(results) - len(bad), bad if bad else "无"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
