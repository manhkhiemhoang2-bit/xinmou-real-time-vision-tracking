#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch_align.py —— 修复 v1.2 的「数据链比控制链早 1 拍」错位（v1.2 → v1.3）

背景（已由 sim/_skew_work/tb_skew_probe.v + sim/check_skew.py 实测钉死）：
    旧版 O_tdata 来自输入第 n-1 拍，而 O_tvalid/O_tlast/O_tuser 来自输入第 n-2 拍。
    实测：O_tuser=1 那一拍，O_tdata 反解出的拍号是 1（应当是 0）。
    即整帧相对 tuser 错开 1 拍（4 像素），且每段流"丢首拍 + 尾部多吐 1 拍陈旧数据"。

修法（方案 A，只动控制链，数据链一级不动 ⇒ 总延迟仍是 2 拍、时序收益全保留）：
    1. O_tdata 门控   `else if (r_vld2)` → `else if (r_vld1)`
    2. `O_tvalid <= r_vld2;` → `O_tvalid <= r_vld1;`
    3. `O_tlast  <= r_tlast2;` → `O_tlast  <= r_tlast;`
    4. `O_tuser  <= r_tuser2;` → `O_tuser  <= r_tuser;`
    第 1 级里的 r_vld2 / r_tlast2 / r_tuser2 随之变成死代码，本脚本**一并删除**
    （声明、复位分支、捕获分支、initial 初值四处）。

写文件用 UTF-8 无 BOM + LF（PowerShell 的 Set-Content -Encoding UTF8 会写 BOM）。

用法：
    python patch_align.py --check   # 只校验锚点
    python patch_align.py           # 打补丁（自动备份 + 同步三份副本）
"""
from __future__ import annotations

import os
import shutil
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
COPIES = [
    os.path.join(ROOT, "prj", "_fullchip", "alg", "osd_mixer.v"),
    os.path.join(ROOT, "prj", "board", "lab_ex3_osd", "user_source",
                 "hdl_source", "alg", "osd_mixer.v"),
]

# (锚点, 替换, 期望命中次数)
SUBS = [
    # ---- 版本号 + 文件头补写「错位修复」----
    ("// 版本     : v1.2", "// 版本     : v1.3", 1),
    ("""//  ---------------------------------------------------------------------------
//  【三、坐标定义（与 S0-02 §2.1 一致，逐字）】""",
     """//  ---------------------------------------------------------------------------
//  【二·补2、数据/控制错位修复（v1.3，2026-09-16）】
//  ---------------------------------------------------------------------------
//  v1.1 与 v1.2 都有同一个**真 bug**：O_tdata 走的是"第 1 级"（v1.1 只有一级），
//  而 O_tvalid/O_tlast/O_tuser 走的是"第 2 级"（r_vld1/r_tlast/r_tuser 各自多打了
//  一拍）。实测（sim/_skew_work/tb_skew_probe.v + sim/check_skew.py）：
//      I_tuser=1 在 beat 0 那一拍 ⇒ O_tuser=1 那一拍的 O_tdata 反解出**拍号 1**。
//  后果：整帧相对 tuser 错开 1 拍（= 4 像素）、每段流丢掉首拍数据、段尾多吐出
//  1 个"O_tvalid=1 却携带陈旧数据"的拍（气泡里塞 0x0BAD 标记可以现场照出来）。
//
//  修法（**只动控制链，数据链一级不动**）：把 O_tdata 的门控与 O_tvalid/O_tlast/
//  O_tuser 的源头从"多打一拍的那只寄存器"换回"与数据链同级的那只"：
//      O_tdata 门控 r_vld2 → r_vld1 ；O_tvalid <= r_vld1 ；
//      O_tlast <= r_tlast ；O_tuser <= r_tuser
//  ⇒ 4 路输出重新**同拍**，总延迟**仍是 2 拍**（时序收益一分不减）。
//  r_vld2/r_tlast2/r_tuser2 随之成为死代码，已删除。
//
//  ⚠ 因此 v1.2 的"与改造前逐拍等价"证明（sim/check_pipe_equiv.py）**不再适用**：
//    它把"控制比数据晚 1 拍"这个 bug 当成了金标准。v1.3 的主判据改成了
//    **契约测试** sim/check_contract.py（输出流必须恰好 = 输入流延迟 2 拍、
//    四路同拍、O_tuser 那拍必须是 beat 0、有效期不许携带气泡数据）。
//
//  ---------------------------------------------------------------------------
//  【三、坐标定义（与 S0-02 §2.1 一致，逐字）】""", 1),
    # ---- 死代码：声明 ----
    ("""reg [95:0] r_pix_data_p1;                                   // 原像素（4 x RGB888）
reg        r_vld2, r_tlast2, r_tuser2;                      // 控制：r_vld1/r_tlast/r_tuser 再延一拍
""",
     """reg [95:0] r_pix_data_p1;                                   // 原像素（4 x RGB888）
""", 1),
    # ---- 死代码：复位分支 ----
    ("""        r_pix_data_p1   <= 96'd0;
        r_vld2          <= 1'b0;
        r_tlast2        <= 1'b0;
        r_tuser2        <= 1'b0;
""",
     """        r_pix_data_p1   <= 96'd0;
""", 1),
    # ---- 死代码：捕获分支 ----
    ("""        r_pix_data_p1   <= I_tdata;
        r_vld2          <= r_vld1;
        r_tlast2        <= r_tlast;
        r_tuser2        <= r_tuser;
""",
     """        r_pix_data_p1   <= I_tdata;
""", 1),
    # ---- 注释同步（§11 清单里的控制位说法）----
    ("""//      Logo 4+96 = 100      · 原像素 96      · 控制 r_vld2/r_tlast2/r_tuser2
//  本模块**不门控**这一级（与老版本输出级同语义）：有效与否只由控制位决定，
//  第 2 级在控制位为 0 时把 O_tdata 强制置 0 —— 所以气泡期捕获到什么值都不影响。""",
     """//      Logo 4+96 = 100      · 原像素 96
//  本模块**不门控**这一级（与老版本输出级同语义）：有效与否只由 r_vld1 决定，
//  第 2 级在 r_vld1（= 与本级数据同一拍的那份有效）为 0 时把 O_tdata 强制置 0 ——
//  所以气泡期捕获到什么值都不影响。⚠ v1.3 起控制用 r_vld1/r_tlast/r_tuser，
//  与数据链**同级**（v1.2 曾用 r_vld2/r_tlast2/r_tuser2，导致控制比数据晚 1 拍）。""", 1),
    # ---- §13 输出级：4 行修复 ----
    ("""// 13. 输出级（第 2 级寄存器）：4 路输出全部在同一级装载
//     ⇒ 延迟严格 2 拍、天然同拍；有效标志用 r_vld2（= I_tvalid 延迟 2 拍）""",
     """// 13. 输出级（第 2 级寄存器）：4 路输出全部在同一级装载
//     ⇒ 延迟严格 2 拍、天然同拍；有效标志用 r_vld1（= I_tvalid 延迟 2 拍）
//     ⚠ v1.3：控制信号必须与数据链**同级**（r_vld1/r_tlast/r_tuser）。
//       曾经用 r_vld2/r_tlast2/r_tuser2 使控制比数据晚 1 拍（见文件头 §二·补2）。""", 1),
    ("""    else if (r_vld2)
        O_tdata <= w_mix;""",
     """    else if (r_vld1)
        O_tdata <= w_mix;""", 1),
    ("""        O_tvalid <= r_vld2;             // = I_tvalid 延迟 2 拍""",
     """        O_tvalid <= r_vld1;             // = I_tvalid 延迟 2 拍（与 O_tdata 同拍）""", 1),
    ("""        O_tlast <= r_tlast2;""", """        O_tlast <= r_tlast;""", 1),
    ("""        O_tuser <= r_tuser2;""", """        O_tuser <= r_tuser;""", 1),
    # ---- 死代码：initial 初值 ----
    ("""    r_pix_data_p1   = 96'd0;
    r_vld2          = 1'b0;
    r_tlast2        = 1'b0;
    r_tuser2        = 1'b0;
""",
     """    r_pix_data_p1   = 96'd0;
""", 1),
]


def main():
    check_only = "--check" in sys.argv
    txt = open(SRC, encoding="utf-8", newline="").read()
    assert "\r" not in txt, "源文件含 CR"
    for a, b, n in SUBS:
        c = txt.count(a)
        assert c == n, "锚点命中 %d 次（期望 %d）：%r" % (c, n, a[:70])
        txt = txt.replace(a, b)
    for dead in ("r_vld2", "r_tlast2", "r_tuser2"):
        assert dead not in txt, "%s 没删干净" % dead
    for need in ("r_vld1", "r_tlast", "r_tuser"):
        assert txt.count(need) >= 3, "%s 出现次数过少" % need
    print("锚点全部命中；%d 行 → %d 行" % (open(SRC, encoding="utf-8").read().count("\n"),
                                          txt.count("\n")))
    if check_only:
        print("[check] 未写文件")
        return
    ts = time.strftime("%Y%m%d-%H%M%S")
    bak = SRC + ".bak-v12-%s" % ts
    shutil.copy(SRC, bak)
    for p in [SRC] + COPIES:
        if not os.path.exists(os.path.dirname(p)):
            print("跳过（目录不存在）：%s" % p)
            continue
        if p != SRC and os.path.exists(p):
            shutil.copy(p, p + ".bak-v12-%s" % ts)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(txt)
        print("写入 : %s" % p)
    print("备份 : %s" % bak)


if __name__ == "__main__":
    main()
