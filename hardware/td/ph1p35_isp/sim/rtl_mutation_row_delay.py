#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_mutation_row_delay.py —— **真 RTL 变异**自证（rgb_row_delay_96）：
                              改 RTL 一行 -> 重新 vlog/vsim -> 判据必须报错

为什么需要这一层（它是任务 A 的核心证据）：
  check_row_delay.py --selftest 改的是**期望值**；本脚本反过来改**被测 RTL 本体**，
  其中 M1 就是把 RTL 退回**旧时钟语义**（写口/读口/计数器全部不按 I_tvalid 门控）。
  判据如果把 M1 判成 PASS，那"新合同"就只是"照抄了 RTL 现在的行为"；
  实测判据在 M1 上报错（数量/泄漏/冻结三类），才说明它**正面否定了旧语义**。

        M1 复现的正是改判据之前那版 RTL：输出会在输入停止后继续"排空" 318 个字。
        旧判据 check_row_delay.py（v1）在 M1 上是通过的 —— 这就是旧合同的错处；
        新判据在 M1 上必须红。

防空转（今天已经抓到过两次"变异是空操作、全靠失败基线撑着"的假绿）：
  · 基线必须先跑通（判据全绿），否则直接退出；
  · 每条变异都要实测【变异后的 dump 与基线 dump 逐字节不同】，不是就不算抓住；
  · 替换原文找不到（变异未生效）也不算抓住。

做法（全部在 sim\\_mut_rd\\ 里，不碰交付的 src\\ 与 sim\\ 文件）：
    1. 拷 rgb_row_delay_96.v + tb_rgb_row_delay.v + stim_rd.hex 进 _mut_rd\\
    2. 对 rgb_row_delay_96.v 做文本替换（变异）
    3. vlib + vlog + vsim 跑出 dump_rd.txt
    4. 与基线 dump 逐字节比（必须不同）+ 用 check_row_delay.py 的同一套判据判
    5. 指定要抓的那条判据报错 > 0 才算"抓住"

用法：python rtl_mutation_row_delay.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
WORK = os.path.join(HERE, "_mut_rd")
MS = r"D:\modelsim\modelsim_ase\win32aloem"

sys.path.insert(0, HERE)
import check_row_delay as R  # noqa: E402

DUT = "rgb_row_delay_96.v"
TB = "tb_rgb_row_delay.v"
HEX = "stim_rd.hex"

# (说明, 期望抓住的判据, [(替换原文, 替换成), ...])
MUTS = [
    ("M1 退回旧时钟语义（写/读/计数器不门控 -> 排空尾巴回来）", "B", [
        ("always @ (posedge I_clk) begin\n"
         "    if (I_tvalid) begin\n"
         "        r_mem[r_x_grp] <= w_wr_word;\n"
         "        r_q <= r_mem[w_rd_addr];\n"
         "    end\n"
         "end",
         "always @ (posedge I_clk) begin\n"
         "    r_mem[r_x_grp] <= w_wr_word;\n"
         "    r_q <= r_mem[w_rd_addr];\n"
         "end"),
        ("    else if (I_tvalid) begin\n        if (I_tuser)",
         "    else begin\n        if (I_tuser)"),
    ]),
    ("M2 读地址领先 2 改成 1（延迟变 319 拍）", "B", [
        ("wire [XW-1:0] w_rd_addr = (r_x_grp <= RD_NO_WRAP) ? (r_x_grp + 2'd2)",
         "wire [XW-1:0] w_rd_addr = (r_x_grp <= RD_NO_WRAP) ? (r_x_grp + 2'd1)"),
    ]),
    ("M3 去掉输出级 C-4 清零（无效字也当数据吐）", "B", [
        ("    else\n        O_tdata <= 96'd0;                        // C-4：延迟后 tvalid=0 的拍输出清零",
         "    else\n        O_tdata <= r_q[95:0];"),
    ]),
    ("M4 tlast 不进阵列（同拍直通）", "B", [
        ("        O_tlast <= r_q[97];                      // = I_tlast 延迟 320 拍",
         "        O_tlast <= I_tlast;"),
    ]),
    ("M5 tuser 不进阵列（同拍直通）", "B", [
        ("        O_tuser <= r_q[96];                      // = I_tuser 延迟 320 拍",
         "        O_tuser <= I_tuser;"),
    ]),
    ("M6 阵列字里 tuser 恒为 1（每拍都标帧首）", "B", [
        ("wire [98:0] w_wr_word = {I_tvalid, I_tlast, I_tuser, I_tdata};",
         "wire [98:0] w_wr_word = {I_tvalid, I_tlast, 1'b1, I_tdata};"),
    ]),
    # ⚠ 2026-09-14 实测记录（防空转断言当场抓到的一个假变异，留着当证据）：
    #   原本这里写的是 "tvalid 恒为 1：{1'b1, I_tlast, I_tuser, I_tdata}"，
    #   实测变异后的 dump 与基线**逐字节相同**（213680 == 213680）——因为写口本身就在
    #   `if (I_tvalid)` 里，能写进阵列的拍必然 I_tvalid=1，把这个位钉成 1 是**空操作**。
    #   这就是"变异是空操作、全靠失败基线撑着"的假绿来源；本脚本的逐字节断言把它拦下了。
    #   换成 tuser 恒 1（tuser 不受写口门控影响，是真变异）。
]

CK = {"A": "A", "B": "B", "C": "C"}


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def setup():
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    shutil.copy(os.path.join(SRC, DUT), os.path.join(WORK, DUT))
    shutil.copy(os.path.join(HERE, TB), os.path.join(WORK, TB))
    shutil.copy(os.path.join(HERE, HEX), os.path.join(WORK, HEX))


def build_and_run():
    rc, out = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
    if rc != 0:
        return False, out
    rc, out = run([os.path.join(MS, "vlog.exe"), "-work", "work", DUT, TB], WORK)
    if rc != 0 or "Errors: 0" not in out:
        return False, out
    dump = os.path.join(WORK, "dump_rd.txt")
    if os.path.isfile(dump):
        os.remove(dump)
    rc, out = run([os.path.join(MS, "vsim.exe"), "-c", "-lib", "work",
                   "tb_rgb_row_delay", "-do", "run -all; quit -f"], WORK)
    return os.path.isfile(dump), out


def judge(dump):
    rows = R.parse(dump)
    na, fa = R.check_stim(rows, verbose=False)
    nb, fb = R.check_contract(rows, verbose=False)
    nc, fc = R.check_x(rows, verbose=False)
    return {"A": (na, fa), "B": (nb, fb), "C": (nc, fc)}


def main():
    setup()
    print("=" * 78)
    print("真 RTL 变异自证：改错 rgb_row_delay_96.v -> 重编译重仿真 -> 指定判据必须报错")
    print("=" * 78)
    ok, out = build_and_run()
    if not ok:
        print("基线编译/仿真失败：\n" + out[-2000:])
        return 2
    base_dump = os.path.join(WORK, "dump_rd.txt")
    base_bytes = open(base_dump, "rb").read()
    res = judge(base_dump)
    red = {k: len(v[1]) for k, v in res.items() if v[1]}
    print("  基线（未变异）   dump %d 字节  报错判据：%s   %s"
          % (len(base_bytes), red if red else "无",
             "PASS" if not red else "基线就不对，先查基线"))
    if red:
        return 2
    # 基线 dump 必须与交付目录里那份逐字节相同（证明变异跑的就是同一激励/同一 TB）
    shipped = os.path.join(HERE, "dump_rd.txt")
    same = os.path.isfile(shipped) and open(shipped, "rb").read() == base_bytes
    print("  基线 dump 与 sim\\dump_rd.txt 逐字节相同：%s" % ("是" if same else "!! 否 !!"))

    caught = 0
    for name, who, subs in MUTS:
        setup()
        p = os.path.join(WORK, DUT)
        txt = open(p, encoding="utf-8").read()
        hit = True
        for a, b in subs:
            if a not in txt:
                print("  %-44s  替换原文没找到，变异未生效 -> 算漏掉" % name)
                hit = False
                continue
            txt = txt.replace(a, b, 1)
        open(p, "w", encoding="utf-8").write(txt)
        if not hit:
            continue
        ok, out = build_and_run()
        if not ok:
            print("  %-44s  编译/仿真失败（也算抓住）" % name)
            caught += 1
            continue
        d = os.path.join(WORK, "dump_rd.txt")
        mut_bytes = open(d, "rb").read()
        # 防空转：变异必须真的改变 dump（逐字节）
        if mut_bytes == base_bytes:
            print("  %-44s  !! 空操作变异：dump 与基线逐字节相同 -> 算漏掉 !!" % name)
            continue
        res = judge(d)
        redk = {k: len(v[1]) for k, v in res.items() if v[1]}
        good = len(res[CK[who]][1]) > 0
        caught += 1 if good else 0
        print("  %-44s  期望抓=%-2s dump %7d->%7d 字节 报错判据: %-22s %s"
              % (name, who, len(base_bytes), len(mut_bytes),
                 ",".join("%s(%d)" % (k, v) for k, v in redk.items()) if redk else "无",
                 "抓住" if good else "!! 漏掉 !!"))
    print("-" * 78)
    print("  真 RTL 变异鉴别力：%d/%d  -> %s"
          % (caught, len(MUTS), "PASS" if caught == len(MUTS) else "FAIL"))
    print("  （M1 = 旧时钟语义：新判据必须把它判红 —— 这是『旧合同是错的』的直接证据）")
    print("=" * 78)
    return 0 if caught == len(MUTS) else 1


if __name__ == "__main__":
    sys.exit(main())
