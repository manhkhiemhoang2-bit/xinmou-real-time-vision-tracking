# -*- coding: utf-8 -*-
"""check_ext_ctrl_lint.py —— ext_ctrl.v 的静态纪律检查（编码规范自检）

检查项（每条都给"检查次数/不通过数"，0 次检查判失败）：
  L1 无组合 always（组合逻辑全部用 assign）⇒ 无 latch 风险
  L2 每个时序 always 的敏感表都是 `posedge I_clk or negedge I_rst_n`（低有效异步复位）
  L3 每个 reg 在**复位分支**里都有赋值（值 = 复位值）
  L4 每个 reg 在 **initial 块**里都有赋值，且字面量与复位分支**逐一相同**
  L5 无 function / task / fork / wait / force / #delay（注释行不计）
  L6 每个 reg 只被一个 always 块赋值（不存在多驱动）
  L7 端口表可解析，且 O_led / O_buzzer 都在端口表里

用法： python check_ext_ctrl_lint.py [文件]
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "src", "ext_ctrl.v")

RES = []


def chk(name, n, bad, note=""):
    RES.append((name, n, bad, note))


def strip_comments(txt):
    out = []
    for line in txt.split("\n"):
        i = line.find("//")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


raw = open(PATH, "r", encoding="utf-8").read()
code = strip_comments(raw)

# ---- 拆分 always 块 ----
blocks = []
for m in re.finditer(r"\balways\b\s*(@\s*(?:\([^)]*\)|\*))?", code):
    start = m.start()
    # 找该 always 的 begin..end（用最简单的括号配对：从第一个 begin 到配对的 end）
    b = code.find("begin", m.end())
    if b < 0:
        continue
    depth = 0
    i = b
    while i < len(code):
        if code.startswith("begin", i):
            depth += 1
            i += 5
            continue
        if code.startswith("end", i) and not code.startswith("endmodule", i):
            depth -= 1
            i += 3
            if depth == 0:
                break
            continue
        i += 1
    blocks.append((m.group(1) or "", code[m.start():i]))

# ---- L1：无组合 always ----
comb = [b for b in blocks if "@(*)" in b[0] or (b[0] and "posedge" not in b[0] and "negedge" not in b[0])]
chk("L1 无组合 always（无 latch 风险）", len(blocks), len(comb))

# ---- L2：敏感表口径 ----
bad2 = [b for b in blocks if b[0].replace(" ", "") != "@(posedgeI_clkornegedgeI_rst_n)"]
chk("L2 时序 always 敏感表 = posedge I_clk or negedge I_rst_n", len(blocks), len(bad2))

# ---- reg 列表 ----
regs = re.findall(r"^\s*reg\s+(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*;",
                  code, re.M)
reglist = []
for r in regs:
    reglist += [x.strip() for x in r.split(",")]

def stmt_end(s, start):
    """从 start 起（begin 复合语句或单语句）返回该语句结束下标（不含）"""
    i = start
    while i < len(s) and s[i].isspace():
        i += 1
    if s.startswith("begin", i):
        depth = 0
        j = i
        while j < len(s):
            if s.startswith("begin", j):
                depth += 1; j += 5; continue
            if s.startswith("end", j) and not s.startswith("endmodule", j):
                depth -= 1; j += 3
                if depth == 0:
                    return j
                continue
            j += 1
        return len(s)
    k = s.find(";", i)
    return len(s) if k < 0 else k + 1


def reset_slice(blk):
    """取 `if (!I_rst_n)` 那个分支的语句体（复位分支）"""
    m = re.search(r"if\s*\(\s*!\s*I_rst_n\s*\)", blk)
    if not m:
        return ""
    return blk[m.end():stmt_end(blk, m.end())]


def initial_slice(txt):
    i = txt.find("initial")
    if i < 0:
        return ""
    return txt[i:stmt_end(txt, i + len("initial"))]


# ---- L3/L4/L6 ----
init_body = initial_slice(code)
no_rst, no_ini, multi = [], [], []
for rg in reglist:
    rst_vals, ini_vals, owners = set(), set(), 0
    for blk in blocks:
        if re.search(r"\b%s\b\s*<=" % rg, blk[1]):
            owners += 1
        for m in re.finditer(r"\b%s\b\s*<=\s*([^;]+);" % rg, reset_slice(blk[1])):
            rst_vals.add(m.group(1).strip())
    for m in re.finditer(r"\b%s\b\s*=\s*([^;]+);" % rg, init_body):
        ini_vals.add(m.group(1).strip())
    if owners > 1:
        multi.append(rg)
    if not rst_vals:
        no_rst.append(rg)
    if not ini_vals or (rst_vals and ini_vals != rst_vals):
        no_ini.append("%s(复位=%s initial=%s)" % (rg, sorted(rst_vals), sorted(ini_vals)))

chk("L3 每个 reg 都有复位赋值", len(reglist), len(no_rst), ",".join(no_rst))
chk("L4 每个 reg 都有 initial 且与复位值逐一相同", len(reglist), len(no_ini), ",".join(no_ini))
chk("L6 每个 reg 只被一个 always 赋值", len(reglist), len(multi), ",".join(multi))

# ---- L5：禁用构造 ----
bad5 = []
for kw in ["function", "task", "fork", "wait", "force", "release", "initial begin\n        #",
           "disable"]:
    if re.search(r"\b%s\b" % kw, code):
        bad5.append(kw)
if re.search(r"#\s*\d", code):
    bad5.append("#delay")
chk("L5 无 function/task/fork/wait/force/#delay", 8, len(bad5), ",".join(bad5))

# ---- L7：端口 ----
ports = re.findall(r"\b(input|output|inout)\b[^,;)]*?([A-Za-z_]\w*)\s*(?=[,;)\n])", code)
pnames = [p[1] for p in ports]
miss = [p for p in ("O_led", "O_buzzer", "I_frame", "I_bbox_valid") if p not in pnames]
chk("L7 端口表含 O_led/O_buzzer/I_frame/I_bbox_valid", 4, len(miss), ",".join(miss))

print("=" * 72)
print("check_ext_ctrl_lint —— %s" % os.path.normpath(PATH))
print("  时序 always 块 %d 个；寄存器 %d 个：%s" % (len(blocks), len(reglist), ",".join(reglist)))
print("-" * 72)
print("%-50s %10s %10s" % ("检查项", "检查数", "不通过"))
print("-" * 72)
badn = 0
for name, n, b, note in RES:
    f = ""
    if b:
        f = "  <== " + (note if note else "不通过")
        badn += 1
    if n == 0:
        f += "  <== 0 次检查"
        badn += 1
    print("%-50s %10d %10d%s" % (name, n, b, f))
print("-" * 72)
print("结论: %s" % ("FAIL" if badn else "PASS"))
sys.exit(1 if badn else 0)
