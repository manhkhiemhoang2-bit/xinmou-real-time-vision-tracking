# -*- coding: utf-8 -*-
"""check_ext_ctrl.py —— ext_ctrl 的 checker（逐拍金标准回放 + 规格级断言）

输入：dump_ext.txt（tb_ext_ctrl.v 写出的**变化点**轨迹）
输出：每条断言的"检查次数 / 失配数"，以及最终 PASS / FAIL

设计要点（防假绿）：
  · 期望值**硬编码在 checker 里**（分界 640/360、节流 20 帧、beep 400000 拍、
    MIN_PIX=1），**不读 RTL**。所以把 RTL 里的常数改错（变异）必然失配。
  · TB 用 RTL 默认参数例化 DUT，参数变异才会真正打进来。
  · 每条断言都统计检查次数；检查次数为 0 一律判失败（防止"空跑通过"）。
  · 另加覆盖度计数器（四个象限各至少亮一次、beep 至少起 3 次）同样要求 > 0。

时序口径（与 RTL 的两个寄存器级严格对应）：
  帧同步拍 = C  ⇒  C 末锁存 bbox/valid；C+1 末 O_led 用新值译码；
                  C+2 拍起 O_led 反映新象限。O_buzzer 比 beep 包络晚 1 拍生效。

用法： python check_ext_ctrl.py [dump文件]
"""
import bisect
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

import gen_stim_ext_ctrl as G

# ------------------------------------------------------------------
# 期望常数（按规格硬编码；与 RTL 默认参数一致，但**不从 RTL 读取**）
# ------------------------------------------------------------------
X_MID = 640
Y_MID = 360
GAP_FRAMES = 20
GAP_TOP = GAP_FRAMES - 1
BEEP_ON = 400000
BEEP_TOP = BEEP_ON - 1
MIN_PIX = 1

NF = G.NF
P = G.P
SETUP = G.SETUP
END_CYC = NF * P + 40

EXPECT_BUZZ_RISE_FRAMES = [0, 12, 14, 34, 54, 56, 76]   # O_buzzer 上升沿帧序列（规格推导）
#   其中"包络起始"帧 = [0, 34, 54, 56, 76]；帧 12/14 是包络 #0 还没走完时
#   r_val 重新变 1 导致 O_buzzer 再次拉高（O_buzzer = 包络 & r_val 的必然结果，
#   也是"抖动场景能听见"的来源）。整条序列都当作断言对象，任何语义漂移都会错位。
LED_BIT2Q = {1: 0, 2: 1, 4: 2, 8: 3}
# 帧同步拍 = f*P + (P-SETUP)。两个"收尾事件"的拍号（由 TB 的复位/激励口径推出）：
MID_RST_CYC  = G.MID_RST_FRAME * P + G.MID_RST_P0        # 中途复位拉低的第一拍
VAL_DROP_CYC = 78 * P + (P - SETUP) + 1                   # 帧 78 strobe 之后 1 拍


def parse_dump(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as f:
        for line in f:
            t = line.split()
            if len(t) != 11:
                continue
            rows.append((
                int(t[0]),                   # cyc
                1 if t[1] == "1" else 0,     # rst_n
                1 if t[2] == "1" else 0,     # I_frame
                1 if t[3] == "1" else 0,     # I_bbox_valid
                int(t[4]),                   # I_pix_count
                int(t[5]), int(t[6]),        # x0, x1
                int(t[7]), int(t[8]),        # y0, y1
                int(t[9], 2),                # O_led
                1 if t[10] == "1" else 0,    # O_buzzer
            ))
    return rows


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "dump_ext.txt"
    if not os.path.exists(path):
        print("FAIL: 找不到 %s" % path)
        return 1
    rows = parse_dump(path)
    if len(rows) < 100:
        print("FAIL: %s 只有 %d 行（dump 不完整/未产生变化）" % (path, len(rows)))
        return 1
    last_cyc = rows[-1][0]
    if last_cyc < END_CYC - 2:
        print("FAIL: dump 只到第 %d 拍，未跑到 %d 拍（仿真被截断）" % (last_cyc, END_CYC))
        return 1

    seg_start = [r[0] for r in rows]
    seg_led = [r[9] for r in rows]
    seg_bz = [r[10] for r in rows]

    def obs_led(c):
        return seg_led[bisect.bisect_right(seg_start, c) - 1]

    def obs_bz(c):
        return seg_bz[bisect.bisect_right(seg_start, c) - 1]

    names = ["A1  LED_MATCH   逐拍 O_led == 金标准",
             "A2  BUZZ_MATCH  逐拍 O_buzzer == 金标准",
             "A3  Q_SPEC      每帧 strobe+3 拍 LED == 规格象限",
             "A4  NO_TGT      无目标帧 strobe+3 拍 LED == 0000",
             "A5  BEEP_START  每次 beep 的起始帧号序列 == 规格",
             "A6  BEEP_MAXRUN 最长连续鸣叫 == %d 拍（真·不可重触发）" % BEEP_ON,
             "A6b TRUNC_RST   中途复位把正在鸣叫的 beep 立即打断",
             "A6c TRUNC_VALID bbox_valid 掉 0 把 beep 立即打断",
             "A6d FULL_RUNS   完整 400000 拍包络的段数 == 2",
             "A7  SILENT      无目标期间 O_buzzer 恒为 0",
             "A8  RST_CLEAR   复位期间 LED / BUZZER 都为 0",
             "A9  LED_ONEHOT  亮灯时必为 1-of-4",
             "A10 FRAME_PULSE 帧同步脉冲数 == %d" % NF,
             "A11 COVERAGE    四象限各亮>=1 且 beep>=3 次"]
    stat = [[n, 0, 0] for n in names]
    (I_LED, I_BZ, I_Q, I_NT, I_ST, I_WD, I_WR, I_WV, I_WF,
     I_SL, I_RS, I_OH, I_PL, I_CV) = range(14)

    cov_led = {0: 0, 1: 0, 2: 0, 3: 0}
    beep_rises = []
    cur_bz = 0
    bz_bad = []
    led_bad = []

    # ------------------------------------------------------------------
    # 逐拍回放：金标准状态机
    # ------------------------------------------------------------------
    frame_d = 0; x0 = 0; x1 = 0; y0 = 0; y1 = 0
    val = 0; led = 0; pres_d = 0; gap = 0; req = 0; cnt = 0; on = 0

    nseg = len(rows)
    for si in range(nseg):
        c = rows[si][0]
        nxt = rows[si + 1][0] if si + 1 < nseg else END_CYC
        (_, irsn, iframe, ivalid, ipc, ix0, ix1, iy0, iy1, dled, dbz) = rows[si]
        for k in range(c, nxt):
            # ---- 异步复位在本拍已生效 ----
            if irsn == 0:
                frame_d = 0; x0 = 0; x1 = 0; y0 = 0; y1 = 0
                val = 0; led = 0; pres_d = 0; gap = 0; req = 0; cnt = 0; on = 0
            # ---- 本拍可见的输出（金标准）----
            exp_led = led
            exp_bz = 1 if (on == 1 and val == 1) else 0
            oled = dled
            obz = dbz
            stat[I_LED][1] += 1
            if oled != exp_led:
                stat[I_LED][2] += 1
                if len(led_bad) < 8:
                    led_bad.append((k, exp_led, oled, irsn, iframe, val, x0, x1, y0, y1))
            stat[I_BZ][1] += 1
            if obz != exp_bz:
                stat[I_BZ][2] += 1
                if len(bz_bad) < 8:
                    bz_bad.append((k, exp_bz, obz, irsn, iframe, val, on, cnt, req))
            if val == 0:                        # A7
                stat[I_SL][1] += 1
                if obz != 0:
                    stat[I_SL][2] += 1
            if irsn == 0:                       # A8
                stat[I_RS][1] += 1
                if oled != 0 or obz != 0:
                    stat[I_RS][2] += 1
            if oled != 0:                       # A9
                stat[I_OH][1] += 1
                if (oled & (oled - 1)) != 0:
                    stat[I_OH][2] += 1
            if obz == 1 and cur_bz == 0:        # beep 上升沿（用观测值）
                beep_rises.append(k)
            cur_bz = obz
            # ---- 状态推进（复位拍不推进）----
            if irsn == 1:
                w_frame = 1 if (iframe == 1 and frame_d == 0) else 0
                present = 1 if (ivalid == 1 and ipc >= MIN_PIX
                                and ix0 <= ix1 and iy0 <= iy1) else 0
                # (a) O_led 的下一拍值：用**本拍**的 r_val / r_bb（锁存前的值）
                if val == 0:
                    led_n = 0
                else:
                    cx = (x0 + x1) >> 1
                    cy = (y0 + y1) >> 1
                    led_n = 1 << ((1 if cx >= X_MID else 0) | (2 if cy >= Y_MID else 0))
                # (b) 帧级锁存
                if w_frame == 1:
                    x0 = ix0; x1 = ix1; y0 = iy0; y1 = iy1
                    val = present
                # (c) 蜂鸣节流：上升沿立刻响 + 持续存在每 N 帧一次
                req_now = req            # beep 包络读的是"本拍"的 req（锁存前的值）
                if w_frame == 1:
                    rising = 1 if (present == 1 and pres_d == 0) else 0
                    pres_d = present
                    if present == 0:
                        gap = 0; req = 0
                    elif rising == 1:
                        gap = 0; req = 1
                    elif gap == GAP_TOP:
                        gap = 0; req = 1
                    else:
                        gap = gap + 1; req = 0
                else:
                    req = 0
                # (d) beep 包络：真·不可重触发（进行中的请求直接丢）
                if req_now == 1 and on == 0:
                    cnt = BEEP_TOP; on = 1
                elif on == 1:
                    if cnt == 0:
                        on = 0
                    else:
                        cnt = cnt - 1
                frame_d = iframe
                led = led_n

    # ------------------------------------------------------------------
    # A3 / A4：规格级逐帧检查（只看 stim 表 + 分界规则，不依赖金标准）
    # ------------------------------------------------------------------
    frames = G.build_frames()
    for fi, fr in enumerate(frames):
        probe = fi * P + (P - SETUP) + 3
        if probe >= END_CYC:
            continue
        q = G.quad_of(fr)
        oled = obs_led(probe)
        if q is None:
            stat[I_NT][1] += 1
            if oled != 0:
                stat[I_NT][2] += 1
        else:
            stat[I_Q][1] += 1
            if oled != (1 << q):
                stat[I_Q][2] += 1
        if oled in LED_BIT2Q:
            cov_led[LED_BIT2Q[oled]] += 1

    # ------------------------------------------------------------------
    # A5：O_buzzer 上升沿帧序列（必须与规格推导的序列**逐个相同、顺序一致**）
    # ------------------------------------------------------------------
    got_frames = [r // P for r in beep_rises]
    for i, want in enumerate(EXPECT_BUZZ_RISE_FRAMES):
        stat[I_ST][1] += 1
        if i >= len(got_frames) or got_frames[i] != want:
            stat[I_ST][2] += 1
    if len(got_frames) > len(EXPECT_BUZZ_RISE_FRAMES):
        stat[I_ST][1] += 1
        stat[I_ST][2] += len(got_frames) - len(EXPECT_BUZZ_RISE_FRAMES)

    # ------------------------------------------------------------------
    # A6 家族：beep 宽度（三种收尾方式各验一次）+ 不可重触发
    #   规格（新语义）：
    #     · 帧 34 触发：全程有目标、无复位 ⇒ 完整包络 400000 拍
    #     · 帧 54 触发：被"帧 56 的中途复位"立即打断
    #     · 帧 76 触发：被"帧 78 的 valid 掉 0"立即打断
    #     · 任何一段连续鸣叫都不得超过 400000 拍（包络进行中的请求被丢弃）
    # ------------------------------------------------------------------
    def run_at(cyc, limit_cyc):
        """返回包含 cyc 的那一段连续鸣叫 (start, len)"""
        st = cyc
        while st > 0 and obs_bz(st - 1) == 1:
            st -= 1
        en = cyc
        while en < limit_cyc and obs_bz(en) == 1:
            en += 1
        return st, en - st

    def buzz_width(idx, limit_cyc):
        if idx >= len(beep_rises):
            return None
        st = beep_rises[idx]
        end = st + 1
        while end < limit_cyc and obs_bz(end) == 1:
            end += 1
        return st, end - st

    # 所有连续鸣叫段
    all_runs = []
    c = 0
    while c < END_CYC:
        if obs_bz(c) == 1:
            s, ln = run_at(c, END_CYC)
            all_runs.append((s, ln))
            c = s + ln
        else:
            c += 1
    max_run = max([l for _, l in all_runs]) if all_runs else 0
    n_full = len([1 for _, l in all_runs if l == BEEP_ON])
    stat[I_WD][1] += 1
    if max_run != BEEP_ON:
        stat[I_WD][2] += 1

    # A6b：帧 54 那次 beep 的收尾拍号必须正好落在中途复位拍
    s_rst, l_rst = run_at(MID_RST_CYC - 1, END_CYC)
    stat[I_WR][1] += 1
    if (s_rst + l_rst) != MID_RST_CYC:
        stat[I_WR][2] += 1

    # A6c：帧 76 那次 beep 的收尾拍号必须正好落在 valid 掉 0 那一拍
    s_vd, l_vd = run_at(VAL_DROP_CYC - 1, END_CYC)
    stat[I_WV][1] += 1
    if (s_vd + l_vd) != VAL_DROP_CYC:
        stat[I_WV][2] += 1

    # A6d：完整 400000 拍包络的段数必须是 2（帧 34 与帧 56 各一次）
    stat[I_WF][1] += 1
    if n_full != 2:
        stat[I_WF][2] += 1

    # ------------------------------------------------------------------
    # A10：帧同步脉冲数
    # ------------------------------------------------------------------
    n_pulse = 0
    prev = 0
    for r in rows:
        if r[2] == 1 and prev == 0:
            n_pulse += 1
        prev = r[2]
    stat[I_PL][1] += 1
    if n_pulse != NF:
        stat[I_PL][2] += 1

    # ------------------------------------------------------------------
    # A11：覆盖度
    # ------------------------------------------------------------------
    stat[I_CV][1] += 1
    if not (all(v > 0 for v in cov_led.values()) and len(beep_rises) >= 3):
        stat[I_CV][2] += 1

    # ------------------------------------------------------------------
    # 输出
    # ------------------------------------------------------------------
    print("=" * 78)
    print("check_ext_ctrl —— %s" % path)
    print("  帧数=%d 每帧周期=%d  仿真结束拍=%d  dump 变化点=%d" % (NF, P, last_cyc, nseg))
    print("  观测 beep 上升沿拍号: %s" % beep_rises)
    print("  观测 beep 上升沿帧号: %s   (规格期望 %s)" % (got_frames, EXPECT_BUZZ_RISE_FRAMES))
    print("  象限点亮帧数 LED0/1/2/3 = %d/%d/%d/%d"
          % (cov_led[0], cov_led[1], cov_led[2], cov_led[3]))
    print("  连续鸣叫段 (起始拍, 长度): %s" % (all_runs,))
    print("  最长段=%d(期望 %d)  完整包络段数=%d(期望 2)" % (max_run, BEEP_ON, n_full))
    print("  被复位截断段: 起始=%d 长度=%d → 收尾拍=%d (期望 %d)"
          % (s_rst, l_rst, s_rst + l_rst, MID_RST_CYC))
    print("  被 valid 截断段: 起始=%d 长度=%d → 收尾拍=%d (期望 %d)"
          % (s_vd, l_vd, s_vd + l_vd, VAL_DROP_CYC))
    if bz_bad:
        print("  A2 前几个失配 (拍, 期望, 实测, rst_n, frame, val, on, cnt, req):")
        for t in bz_bad:
            print("     %s" % (t,))
    if led_bad:
        print("  A1 前几个失配 (拍, 期望LED, 实测LED, rst_n, frame, val, x0,x1,y0,y1):")
        for t in led_bad:
            print("     %s" % (t,))
    print("-" * 78)
    print("%-52s %12s %10s" % ("断言", "检查次数", "失配数"))
    print("-" * 78)
    bad = 0
    for name, checks, fails in stat:
        flag = ""
        if fails:
            flag += "  <== 失配"
            bad += 1
        if checks == 0:
            flag += "  <== 0 次检查(空跑)"
            bad += 1
        print("%-52s %12d %10d%s" % (name, checks, fails, flag))
        print("RESULT|%s|%d|%d" % (name.split()[0], checks, fails))
    print("-" * 78)
    if bad:
        print("结论: FAIL（%d 条断言未通过）" % bad)
        return 1
    print("结论: PASS（全部 %d 条断言通过，且无 0 次检查）" % len(stat))
    return 0


if __name__ == "__main__":
    sys.exit(main())
