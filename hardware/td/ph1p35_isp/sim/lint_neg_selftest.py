# -*- coding: utf-8 -*-
"""lint_neg_selftest.py —— lint 自检：故意破坏 RTL 的一处复位值，lint 必须抓到

做法：把 src/ext_ctrl.v 复制一份，把**某一个 reg 的复位赋值**改掉（非注释代码），
再跑 check_ext_ctrl_lint.py，要求 L3/L4 至少一条 FAIL。
"""
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src", "ext_ctrl.v"))
PY = sys.executable

BASE = ("            r_beep_on  <= 1'b0;",
        "            r_beep_on  <= r_beep_on;   // 变异：复位不清")

cases = [("复位不清 r_beep_on",) + BASE]


def run(cmd):
    p = subprocess.run(cmd, cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout.decode("utf-8", "replace")


src = open(SRC, "r", encoding="utf-8").read()
ok = True
for name, old, new in cases:
    if src.count(old) != 1:
        print("FAIL: 锚点出现 %d 次：%s" % (src.count(old), old))
        ok = False
        continue
    tmp = os.path.join(HERE, "_lint_neg.v")
    open(tmp, "w", encoding="utf-8", newline="\n").write(src.replace(old, new, 1))
    rc, out = run([PY, "check_ext_ctrl_lint.py", tmp])
    hit = [l.split()[0] for l in out.splitlines() if "<== " in l]
    print("%-24s lint rc=%d  抓到=%s" % (name, rc, ",".join(hit) if hit else "无（漏检！）"))
    if rc == 0 or not hit:
        ok = False
    os.remove(tmp)
print("lint 自检: %s" % ("PASS（破坏必被抓）" if ok else "FAIL"))
sys.exit(0 if ok else 1)
