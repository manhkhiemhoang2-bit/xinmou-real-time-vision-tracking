#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gim_imu_roll.py -- gim_imu_roll（零偏标定 + 互补滤波）的判据

核心手段：**独立的 Python 浮点金标准**
    同一个差分方程，用 Python 的任意精度整数 + 浮点数重算一遍，再和定点 RTL 逐样本比。
    这样既能验"方程实现对了没有"，又能量出"定点化丢了多少精度"。

    为什么金标准要**按规格重写**而不是照抄 RTL：
      照抄 RTL 就只能验"我抄对了没有"，验不出"我一开始想对了没有"。
      这里按文件头的公式独立写：
        陀螺每拍增量 = gyro_sub × 500 / 256        （浮点算，不做 >>8 截断）
        加速度倾角   = −ay × 229.18 / 256          （浮点算，229.18 = (180/π)×65536/16384）
        roll = roll + 陀螺增量 − (roll − 倾角)/256

判据：
    R1  零偏标定：标定结束后，静止段的 roll **基本不动**
        （这条专门验"零偏真的被减掉了"；如果没减，roll 会以 300×500/256 ≈ 586/样本飞走）
    R2  roll 逐样本对金标准：|定点 − 浮点| ≤ 容差
    R3  短时跟随陀螺 / 长时收敛到加速度倾角（互补滤波的两个半边都要起作用）
    R4  角度限幅在工作范围 ±25° 内
    R5  角度 → 脉宽：脉宽 = MID − roll_deg×PULSE_PER_DEG，且限在 [MIN,MAX]
    R6  en=0 时输出回中位
    R7  标定期间 roll 保持 0（没标定完不许动）

用法：
    python check_gim_imu_roll.py --dump sim\\_gim_roll\\dump_gim_roll.txt
    python check_gim_imu_roll.py --dump ... --selftest
"""
from __future__ import annotations

import argparse
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

# 金标准用的**精确常数**（注意：和 RTL 里的整数近似不同，这正是要量的差）
K_GYRO   = 500.0 / 256.0            # 每 raw 每样本的 Q16 角度增量（精确值，不截断）
# 加速度倾角：**从物理量纲重推，不照抄 RTL 注释**
#   ay 单位 LSB，16384 LSB = 1g；小角度 sin(φ)≈φ
#   ⇒ φ_rad = ay/16384
#   ⇒ φ_q16 = (ay/16384) × (180/π) × 65536 = ay × 229.1831
#   ⚠ 229.18 里**已经含了 /16384**，所以不要再除 256。
#     第一版金标准和 RTL 都多除了 256 ⇒ 两边"互相吻合"、R2 全绿，
#     只有"±2g 必须撞限幅"这一条露馅。这就是模型和被测件一起错的典型。
K_ACC    = (180.0 / 3.14159265358979) * 65536.0 / 16384.0   # ≈ 229.1831，已含 /16384
CAL_N    = 256


def parse(path):
    hdr, S, O = {}, {}, {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            if ln.startswith("#"):
                for k, v in re.findall(r"([A-Za-z_]\w*)=(-?\d+)", ln):
                    hdr[k] = int(v)
                continue
            p = ln.split()
            if p[0] == "S" and len(p) == 4:
                S[int(p[1])] = (int(p[2]), int(p[3]))
            elif p[0] == "O" and len(p) == 6:
                O[int(p[1])] = (int(p[2]), int(p[3]), int(p[4]), int(p[5]))
            else:
                raise ValueError("不认识的 dump 行：%r" % ln)
    return hdr, S, O


def stim_at(S, k, last):
    """第 k 个样本的 (ay, gy)：S 只在变化时记，所以要往前找最近的一条。"""
    if k in S:
        last = S[k]
    return last


def golden(hdr, S, mut=None):
    """独立的浮点金标准：返回 {k: (roll_q16, pulse, calib_done)}。"""
    mut = mut or {}
    comp_sh   = hdr["COMP_SH"]
    cal_sh    = hdr["CAL_SH"]
    cal_n     = hdr["CAL_N"] - (1 if mut.get("cal_off") else 0)
    acc_k     = hdr["ACC_K"]
    pmin, pmid, pmax = hdr["PULSE_MIN"], hdr["PULSE_MID"], hdr["PULSE_MAX"]
    ppd       = hdr["PULSE_PER_DEG"]
    lim       = hdr["ROLL_LIMIT_Q16"]
    nsamp     = max(S.keys(), default=0)
    nsamp     = hdr.get("NSAMP", nsamp + 1)

    # 金标准的常数
    k_gyro = K_GYRO
    # 变异：用整数 229 代替精确值 229.18 —— ⚠ 这个变异**太弱**，和真值只差 0.006°，
    #   在容差之下，本来就测不出来（第一版把它列进变异表是设计错误）。
    #   换成 +10% 的强扰动，才真的能验出"判据对加速度系数敏感"。
    if mut.get("acc_int"):
        k_acc = acc_k
    elif mut.get("acc_110"):
        k_acc = K_ACC * 1.10
    else:
        k_acc = K_ACC

    # 标定：取前 cal_n 个样本的陀螺均值
    #
    # ⚠⚠ 2026-09-23 踩的两个对齐坑，都让金标准"看起来 RTL 错了"：
    #   坑一：把**标定段最后一个输出**当成了 k=255。TB 只在 data_rdy 那一拍更新输出
    #         ⇒ 第 256 个样本（k=256）产生的是**第 257 个输出**。
    #         正确对齐：样本 k 产生输出 k+1（k=0..255 标定 ⇒ 输出 1..256，
    #         calib_done 在输出 256）。
    #   坑二：标定期间的输出虽然都是 0，但**必须每个 k 都写一条 out[k+1]**；
    #         只在取均值那一拍写，会导致 out 里缺一大批 key，比对时静默跳过、
    #         看起来"恰好对上"，其实是没比。
    #   ⚠ 还有一个纯属我自己的低级错：`stim_at` 返回的是**元组 (ay, gy)**，
    #     我写过 `ay, gy = stim_at(...)` 之外的写法把 gy 取成了整个元组，
    #     于是 bias 算成 (0,300)/256 这种荒谬的值。这类错只能靠"把中间量打出来"发现。
    ay = gy = 0
    last = (0, 0)
    acc_sum = 0
    first_gy = 0
    bias = None
    roll = 0.0
    out = {}
    for k in range(nsamp):
        ay, gy = stim_at(S, k, last)      # ← 必须是 (ay, gy) 两元组解包
        last = (ay, gy)
        if bias is None:
            if k == 0:
                first_gy = gy
            acc_sum += gy
            if k == cal_n - 1:
                # 变异：直接拿第一个样本当零偏（不平均）—— 验"真的做了平均"
                bias = float(first_gy) if mut.get("cal_first") else acc_sum / float(cal_n)
                if mut.get("bias_zero"):
                    bias = 0.0
            # 标定期间每个 k 都要写一条（都在输出 k+1 这一拍）
            out[k + 1] = (0, pmid, 1 if k == cal_n - 1 else 0)
            continue
        # 互补滤波（浮点）
        gsub  = gy - bias
        step  = gsub * k_gyro
        ang   = (ay if mut.get("acc_sign_flip") else -ay) * k_acc   # 不再 /256（见上面的推导注释）
        roll  = roll + step - (roll - ang) / (2.0 ** comp_sh)
        # 限幅
        if roll < -lim:
            roll = float(-lim)
        if roll > lim:
            roll = float(lim)
        rq = int(roll)
        deg = rq >> 16                     # 算术右移，等价于 floor 除法
        if deg < 0:
            deg = -((-rq) >> 16)
        pulse = pmid - deg * ppd
        pulse = max(pmin, min(pmax, pulse))
        out[k + 1] = (rq, pulse, 1)
    return out


def judge(hdr, S, O, mut=None, verbose=True, wa_O=None):
    mut = mut or {}
    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    G = golden(hdr, S, mut)
    ks = sorted(O.keys())
    # 定点 vs 浮点允许的偏差：定标常数 229 vs 229.18 会带来系统性偏差，
    #   容差取"角度的 2%"比较合理（角度小的时候按绝对值兜底）
    lim  = hdr["ROLL_LIMIT_Q16"]
    tol  = max(1024, int(lim * 0.02))

    # ---- R2 roll 逐样本对金标准 ----
    #   ⚠ en=0 之后 DUT 会主动回零（设计如此：没有可信姿态源就回中位），
    #     而金标准只算滤波方程、不管使能 ⇒ 那一段不能按"对金标准"判。
    #     TB 里 en 在最后 20 个样本拉低；这里把 NSAMP-20 之后的排除掉，
    #     并**打印排除了多少**（项目纪律：排除必须留痕）。
    nsamp  = hdr.get("NSAMP", 0)
    en_off = max(0, nsamp - 20)
    n_excl = 0
    worst = 0
    worst_k = -1
    for k in ks:
        if k not in G:
            continue
        if k >= en_off:
            n_excl += 1
            continue
        d = abs(O[k][0] - G[k][0])
        if d > worst:
            worst, worst_k = d, k
        chk(d <= tol, "R2[样本%d] roll 对金标准" % k,
            "定点 %d，浮点 %d，差 %d > 容差 %d" % (O[k][0], G[k][0], d, tol))
    if verbose:
        print("  R2 roll vs 浮点金标准：比对 %d 个样本（en=0 的 %d 个排除，"
              "那段 DUT 主动回零）；最大偏差 %d (= %.5f°，容差 %d)"
              % (len(ks) - n_excl, n_excl, worst, worst / 65536.0, tol))
    chk(len(ks) - n_excl > 100, "R2 比对的样本数够多", "只有 %d 个" % (len(ks) - n_excl))

    # ---- R1 零偏标定：标定后静止段 roll 基本不动 ----
    cal_n = hdr["CAL_N"]
    seg = [k for k in ks if cal_n <= k < cal_n + 100]
    if seg:
        r0, r1 = O[seg[0]][0], O[seg[-1]][0]
        # 静止 100 个样本，零偏若没减，roll 会跑 300×500/256×100 ≈ 58600
        chk(abs(r1 - r0) < 3000, "R1 标定后静止段 roll 基本不动",
            "100 个样本里 roll 从 %d 变到 %d（差 %d）" % (r0, r1, r1 - r0))
        if verbose:
            print("  R1 零偏标定：标定后静止 100 样本，roll %d -> %d（差 %d，"
                  "零偏若未减会跑约 58600）" % (r0, r1, r1 - r0))
    # 标定期间 roll 必须保持 0（R7）
    for k in ks:
        if k < cal_n:
            nass += 1
            if O[k][0] != 0:
                nbad += 1
                if verbose:
                    print("    FAIL R7[样本%d] 标定期间 roll 应为 0，实测 %d" % (k, O[k][0]))
    if verbose:
        print("  R7 标定期间（%d 个样本）roll 恒为 0" % cal_n)

    # ---- R3 互补滤波两个半边都起作用 ----
    #   半边一：短时跟随陀螺 —— 陀螺转的那段（真实角速度 −5000），
    #           roll 必须**单调朝负方向**走（这条证明陀螺那半真的在起作用）
    seg1 = [k for k in ks if 456 <= k <= 575]
    if seg1:
        mono = all(O[seg1[i + 1]][0] <= O[seg1[i]][0] for i in range(len(seg1) - 1))
        moved = O[seg1[0]][0] - O[seg1[-1]][0]
        chk(mono, "R3a 陀螺段 roll 单调下降（跟随陀螺）", "不是单调下降")
        chk(moved > 100000, "R3a 陀螺段 roll 确实动了", "120 个样本只动了 %d" % moved)
        if verbose:
            print("  R3a 短时跟随陀螺：120 样本 roll 变化 %d (= %.3f°)"
                  % (moved, moved / 65536.0))
    else:
        chk(False, "R3a 激励段存在", "找不到 456..575 的样本")

    #   半边二：长时间信加速度计 —— 两段，都要求**真的收敛到目标**，不是"变化变慢"
    #     · F 段（ay=2000，755 拍 ≈ 2.95τ）：应收敛到倾角 −2000×229.18 = −458366
    #     · H 段（ay=0，1500 拍 ≈ 5.9τ）：应回到 0 附近
    #   ⚠ 判据的时间尺度必须和 τ 匹配。第一版只给 100 拍（0.4τ）就要求"收敛"，
    #     那是在要求它 0.4 个时间常数内到位 —— 判据定错了，不是 RTL 的问题。
    segF = [k for k in ks if 896 <= k <= 1650]
    if segF:
        r_end  = O[segF[-1]][0]
        r_sta  = O[895][0] if 895 in O else O[segF[0]][0]
        target = -2000 * K_ACC                    # ≈ −458366
        # ⚠ 不能用固定容差。进入 F 段时 roll 离目标很远（陀螺段把它甩到 +669237），
        #   755 拍 = 2.95τ 之后**必然**还剩 e^-2.95 = 5.24% 的残余。
        #   第一版容差给 40000，被这 59000 的残余判成失败 —— 那是**判据没考虑
        #   起点距离**，不是 RTL 错。
        #   改成按指数**解析算出应该到哪**：
        #       roll(N) = target + (start − target)·e^(−N/τ)
        #   这样这条判据同时验了「目标值对不对」和「时间常数对不对」，
        #   比单纯放宽容差强得多（放宽容差等于把真 bug 也一起放过去）。
        tau    = float(2 ** hdr["COMP_SH"])       # τ = 2^COMP_SH / 256 秒 = 2^COMP_SH 拍
        N      = float(len(segF))
        expect = target + (r_sta - target) * (2.718281828459045 ** (-N / tau))
        chk(abs(r_end - expect) < 20000, "R3b[F段末] roll 按指数收敛到倾角",
            "实测 %d (= %.3f°)，按 τ=%d、N=%d 算应为 %.0f (= %.3f°)，差 %d"
            % (r_end, r_end / 65536.0, int(tau), int(N),
               expect, expect / 65536.0, abs(r_end - expect)))
        if verbose:
            print("  R3b-F 收敛：起点 %d → 实测 %d，解析应为 %.0f（目标 %.0f，τ=%d，N=%d）"
                  % (r_sta, r_end, expect, target, int(tau), int(N)))
    else:
        chk(False, "R3b-F 激励段存在", "找不到 896..1650 的样本")

    segH = [k for k in ks if k >= 2151]
    if segH:
        r_end = O[segH[-1]][0]
        chk(abs(r_end) < 20000, "R3b[H段末] roll 回到 0 附近",
            "末样本 roll = %d (= %.5f°)" % (r_end, r_end / 65536.0))
        if verbose:
            print("  R3b-H 回零收敛：%d 拍后 roll = %d (= %.5f°)"
                  % (len(segH), r_end, r_end / 65536.0))
    else:
        chk(False, "R3b-H 激励段存在", "找不到 >=2151 的样本")

    # ---- R8 轴选择参数**真的接到了逻辑上** ----
    #   为什么需要这条：`GYRO_AXIS` 这种参数最容易"声明了但没接进逻辑"，
    #   而逐样本对金标准**测不出来** —— 金标准是从 dump 读激励的，两边一致。
    #   做法：跑第二遍，把陀螺激励故意放到**没被选中的轴**上。
    #   如果参数真的起作用，模块读的那根轴恒为 0 => 陀螺段应当**没有 excursion**。
    if wa_O is not None:
        segC = [k for k in sorted(wa_O) if 456 <= k <= 575]
        if segC:
            d_wa = abs(wa_O[segC[-1]][0] - wa_O[segC[0]][0])
            d_no = abs(O[575][0] - O[456][0]) if (456 in O and 575 in O) else 0
            chk(d_wa < d_no / 4, "R8 轴选择参数起作用（信号放错轴 => 陀螺段没反应）",
                "放错轴时陀螺段只变化 %d，正常跑是 %d" % (d_wa, d_no))
            if verbose:
                print("  R8 轴选择：信号放错轴时陀螺段变化 %d，正常跑 %d（前者应远小于后者）"
                      % (d_wa, d_no))
        else:
            chk(False, "R8 轴选择跑有陀螺段样本", "找不到 456..575 的样本")
    else:
        chk(False, "R8 提供了轴选择跑的 dump", "没给 --wrongaxis-dump，这条判据没跑")

    # ---- R4 限幅 ----
    for k in ks:
        chk(abs(O[k][0]) <= lim, "R4[样本%d] roll 在 ±25° 内" % k,
            "实测 %d > %d" % (O[k][0], lim))
    nlim = sum(1 for k in ks if abs(O[k][0]) == lim)
    chk(nlim > 0, "R4 限幅真的被触发过", "整跑没碰到限幅，这条没验到")
    if verbose:
        print("  R4 角度限幅：%d 个样本处于限幅值（说明限幅路径被走到了）" % nlim)

    # ---- R5 角度 → 脉宽 ----
    #   ⚠ 不要死抠"脉宽 == MID − deg×PPD"的量化边界：deg 是整数除法（向零取整），
    #     角度 −7.99° 和 −7.00° 落在同一个 deg=−8 上，脉宽会在边界附近滞后一拍。
    #     逐样本抠这个只会制造假失败。改成验**真正重要的性质**：
    #       ① 脉宽随角度单调（角度越正 ⇒ 脉宽越小，因为 脉宽 = MID − deg×PPD）
    #       ② 脉宽落在 [PULSE_MIN, PULSE_MAX]
    #       ③ 角度 = 0 时脉宽 = PULSE_MID
    ppd, pmin, pmid, pmax = hdr["PULSE_PER_DEG"], hdr["PULSE_MIN"], hdr["PULSE_MID"], hdr["PULSE_MAX"]
    prev_rq, prev_pulse = None, None
    n_mono = 0
    n_form = 0
    for k in ks:
        rq, pulse = O[k][0], O[k][1]

        # ---- ① 按公式算期望脉宽并比对 ----
        #   ⚠ 度数的取整方向必须和 RTL 一致：RTL 用 `>>> 16`（算术右移）= **向下取整**，
        #     Python 里对应的就是 `rq >> 16`。
        #     早先这里写成 `-((-rq) >> 16)`（向零取整），对负数正好差 1 度，
        #     于是"公式比对"整片报假失败 —— 那是判据的错，不是 RTL 的。
        deg  = rq >> 16                       # 向下取整，与 RTL 的 >>> 一致
        want = pmid - deg * ppd
        if not mut.get("pulse_no_clamp"):
            want = max(pmin, min(pmax, want))  # 变异：去掉限幅
        n_form += 1
        chk(pulse == want, "R5[样本%d] 脉宽 = MID − deg×PPD" % k,
            "实测 %d，期望 %d（roll=%d → deg=%d）" % (pulse, want, rq, deg))

        chk(pmin <= pulse <= pmax, "R5[样本%d] 脉宽在范围内" % k,
            "实测 %d 不在 [%d,%d]" % (pulse, pmin, pmax))
        if rq == 0:
            chk(pulse == pmid, "R5[样本%d] 角度为 0 时脉宽 = 中位" % k,
                "实测 %d，期望 %d" % (pulse, pmid))
        if prev_rq is not None:
            if rq > prev_rq:
                n_mono += 1
                chk(pulse <= prev_pulse, "R5[样本%d] 脉宽随角度单调（角度正⇒脉宽小）" % k,
                    "角度 %d→%d，脉宽 %d→%d" % (prev_rq, rq, prev_pulse, pulse))
            elif rq < prev_rq:
                n_mono += 1
                chk(pulse >= prev_pulse, "R5[样本%d] 脉宽随角度单调（角度负⇒脉宽大）" % k,
                    "角度 %d→%d，脉宽 %d→%d" % (prev_rq, rq, prev_pulse, pulse))
        prev_rq, prev_pulse = rq, pulse
    chk(n_mono > 500, "R5 单调性检查的对数够多", "只有 %d 对" % n_mono)
    n_clip = sum(1 for k in ks if O[k][1] in (pmin, pmax))
    chk(n_clip > 0, "R5 脉宽限幅真的被触发过",
        "整跑没有一条脉宽落在 [%d,%d] 的边界上 ⇒ 限幅没被验到" % (pmin, pmax))
    if verbose:
        print("  R5 角度→脉宽：公式比对 %d 条、单调性 %d 对、触到限幅 %d 条（PULSE_PER_DEG=%d）"
              % (n_form, n_mono, n_clip, ppd))

    # ---- R6 en=0 回中位 ----
    tail = [k for k in ks if k >= hdr.get("NSAMP", 0) - 20]
    for k in tail:
        chk(O[k][1] == pmid, "R6[样本%d] en=0 输出回中位" % k,
            "实测 %d，期望 %d" % (O[k][1], pmid))
    chk(len(tail) > 0, "R6 有 en=0 的样本", "没有")
    if verbose:
        print("  R6 en=0 回中位：检查末段 %d 个样本" % len(tail))

    return nass, nbad, worst


MUTATIONS = [
    ("减零偏去掉",         {"bias_zero": True}),
    ("标定取第一个样本",    {"cal_first": True}),
    ("加速度系数 +10%",    {"acc_110": True}),
    ("脉宽不限幅",         {"pulse_no_clamp": True}),
]


def selftest(hdr, S, O, wa_O=None):
    a0, b0, _ = judge(hdr, S, O, None, verbose=False, wa_O=wa_O)
    print("  基线：断言 %d / 不符 %d" % (a0, b0))
    if b0 != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b, _ = judge(hdr, S, O, mut, verbose=False, wa_O=wa_O)
        caught = b > 0
        print("  [mut] %-18s -> %s（断言 %d / 不符 %d）"
              % (label, "抓住" if caught else "**漏掉**", a, b))
        ok += 1 if caught else 0
    print("------------------------------------------------------------------------")
    print("变异自证：%d/%d 被抓住" % (ok, len(MUTATIONS)))
    return 0 if ok == len(MUTATIONS) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--wrongaxis-dump", default=None)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    hdr, S, O = parse(args.dump)
    try:
        _wh, _wS, wa_O = parse(args.wrongaxis_dump) if args.wrongaxis_dump else (None, None, None)
    except Exception as e:
        print("  (轴选择跑 dump 读不了：%s)" % e); wa_O = None
    print("=" * 78)
    print("check_gim_imu_roll.py  dump=%s" % args.dump)
    print("  COMP_SH=%s CAL_N=%s ACC_K=%s PULSE_PER_DEG=%s；样本 %d 个"
          % (hdr.get("COMP_SH"), hdr.get("CAL_N"), hdr.get("ACC_K"),
             hdr.get("PULSE_PER_DEG"), len(O)))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, S, O, wa_O)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad, worst = judge(hdr, S, O, None, verbose=True, wa_O=wa_O)
    print("=" * 78)
    print("定点 vs 浮点金标准最大偏差：%d LSB = %.5f 度" % (worst, worst / 65536.0))
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
