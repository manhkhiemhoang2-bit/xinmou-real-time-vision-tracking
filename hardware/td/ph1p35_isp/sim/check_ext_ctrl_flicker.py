# -*- coding: utf-8 -*-
"""check_ext_ctrl_flicker.py —— tb_ext_ctrl_flicker.v 的 checker

两种模式（同一份实现，断言集不同；两种都必须跑，都必须 PASS）：
  --mode flicker  （抖动 run：-gP=600 -gNCYC=72100）
      F3  首个 O_buzzer 上升沿必须正好在"无→有"那一帧 +2 拍
      F4  1:1 抖动段必须响（上升沿数 >= 10）
      F5  1:3 抖动段必须响（高电平拍数 >= 1）
      F7  倒置框帧：LED == 0000，且激励本身确实倒置 + valid=1（防空跑）
      F8  倒置框帧区间内 O_buzzer 恒为 0
  --mode retrig   （重触发 run：-gP=100 -gNCYC=2500000）
      F6a 最长连续鸣叫 == 400000 拍（真·不可重触发）
      F6b 完整 400000 拍包络的段数 >= 2
两种模式都跑：
  F1 逐拍 O_led == 金标准     F2 逐拍 O_buzzer == 金标准
  F9 覆盖度（至少 3 段鸣叫 / 至少 1 段高电平）

期望常数全部按规格硬编码，**不读 RTL**。
"""
import bisect
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

BEEP_ON = 400000
GAP_FRAMES = 20
MIN_PIX = 1

MODE = "flicker"
DUMP = "dump_flk.txt"
PP = 600
for i, a in enumerate(sys.argv):
    if a == "--mode":
        MODE = sys.argv[i + 1]
    elif a == "--p":
        PP = int(sys.argv[i + 1])
    elif not a.startswith("--") and a.endswith(".txt"):
        DUMP = a


def parse_dump(path):
    rows = []
    for line in open(path, "r", encoding="ascii", errors="replace"):
        t = line.split()
        if len(t) != 11:
            continue
        rows.append((int(t[0]), 1 if t[1] == "1" else 0, 1 if t[2] == "1" else 0,
                     1 if t[3] == "1" else 0, int(t[4]),
                     int(t[5]), int(t[6]), int(t[7]), int(t[8]),
                     int(t[9], 2), 1 if t[10] == "1" else 0))
    return rows


def main():
    if not os.path.exists(DUMP):
        print("FAIL: 找不到 %s" % DUMP)
        return 1
    rows = parse_dump(DUMP)
    if len(rows) < 50:
        print("FAIL: %s 只有 %d 行（dump 不完整）" % (DUMP, len(rows)))
        return 1
    last_cyc = rows[-1][0]
    NCYC = last_cyc
    seg_start = [r[0] for r in rows]

    def obs_led(c):
        return rows[bisect.bisect_right(seg_start, c) - 1][9]

    def obs_bz(c):
        return rows[bisect.bisect_right(seg_start, c) - 1][10]

    names = ["F1  LED_MATCH   逐拍 O_led == 金标准",
             "F2  BUZZ_MATCH  逐拍 O_buzzer == 金标准",
             "F3  FIRST_RISE  首个上升沿 == (无→有)帧 +2 拍",
             "F4  FLICK_1TO1  1:1 抖动段必须响",
             "F5  FLICK_1TO3  1:3 抖动段必须响",
             "F6a NONRETRIG   最长连续鸣叫 == %d 拍" % BEEP_ON,
             "F6b NONRETRIG   完整 %d 拍包络段数 >= 2" % BEEP_ON,
             "F7  INV_LED     倒置框帧 LED == 0000（含激励自查）",
             "F8  INV_SILENT  倒置框帧区间 O_buzzer 恒为 0",
             "F9  COVERAGE    鸣叫段 >= 3 且高电平拍数 > 0"]
    stat = [[n, 0, 0] for n in names]
    F1, F2, F3, F4, F5, F6a, F6b, F7, F8, F9 = range(10)

    # ---------------- 逐拍金标准回放 ----------------
    frame_d = 0; x0 = 0; x1 = 0; y0 = 0; y1 = 0
    val = 0; led = 0; pres_d = 0; gap = 0; req = 0; cnt = 0; on = 0
    beep_rises = []
    cur_bz = 0
    bad = []
    nseg = len(rows)
    for si in range(nseg):
        c = rows[si][0]
        nxt = rows[si + 1][0] if si + 1 < nseg else NCYC + 1
        (_, irsn, iframe, ivalid, ipc, ix0, ix1, iy0, iy1, dled, dbz) = rows[si]
        for k in range(c, nxt):
            if irsn == 0:
                frame_d = 0; x0 = 0; x1 = 0; y0 = 0; y1 = 0
                val = 0; led = 0; pres_d = 0; gap = 0; req = 0; cnt = 0; on = 0
            exp_led = led
            exp_bz = 1 if (on == 1 and val == 1) else 0
            stat[F1][1] += 1
            if dled != exp_led:
                stat[F1][2] += 1
                if len(bad) < 6:
                    bad.append(("LED", k, exp_led, dled))
            stat[F2][1] += 1
            if dbz != exp_bz:
                stat[F2][2] += 1
                if len(bad) < 6:
                    bad.append(("BZ", k, exp_bz, dbz))
            if dbz == 1 and cur_bz == 0:
                beep_rises.append(k)
            cur_bz = dbz
            if irsn == 1:
                w_frame = 1 if (iframe == 1 and frame_d == 0) else 0
                present = 1 if (ivalid == 1 and ipc >= MIN_PIX
                                and ix0 <= ix1 and iy0 <= iy1) else 0
                if val == 0:
                    led_n = 0
                else:
                    cx = (x0 + x1) >> 1
                    cy = (y0 + y1) >> 1
                    led_n = 1 << ((1 if cx >= 640 else 0) | (2 if cy >= 360 else 0))
                if w_frame == 1:
                    x0 = ix0; x1 = ix1; y0 = iy0; y1 = iy1
                    val = present
                req_now = req
                if w_frame == 1:
                    rising = 1 if (present == 1 and pres_d == 0) else 0
                    pres_d = present
                    if present == 0:
                        gap = 0; req = 0
                    elif rising == 1:
                        gap = 0; req = 1
                    elif gap == (GAP_FRAMES - 1):
                        gap = 0; req = 1
                    else:
                        gap = gap + 1; req = 0
                else:
                    req = 0
                if req_now == 1 and on == 0:
                    cnt = BEEP_ON - 1; on = 1
                elif on == 1:
                    if cnt == 0:
                        on = 0
                    else:
                        cnt = cnt - 1
                frame_d = iframe
                led = led_n

    # ---------------- 鸣叫段统计（按变化点分段扫，避免逐拍循环）----------------
    runs = []
    cur = None
    for si in range(nseg):
        c = rows[si][0]
        nxt = rows[si + 1][0] if si + 1 < nseg else NCYC + 1
        if rows[si][10] == 1:
            if cur is None:
                cur = [c, 0]
            cur[1] += (nxt - c)
        else:
            if cur is not None:
                runs.append((cur[0], cur[1]))
                cur = None
    if cur is not None:
        runs.append((cur[0], cur[1]))
    max_run = max([l for _, l in runs]) if runs else 0
    n_full = len([1 for _, l in runs if l == BEEP_ON])
    on_total = sum(l for _, l in runs)

    # ---------------- F3/F4/F5：抖动语义（两种模式都适用）----------------
    want_first = 4 * PP + 2                  # 帧 4 是"无→有"那一帧；strobe 后 2 拍起响
    stat[F3][1] += 1
    if not beep_rises or beep_rises[0] != want_first:
        stat[F3][2] += 1

    # F4：1:1 抖动段（帧 4..43）内的上升沿数
    rA = [r for r in beep_rises if 4 * PP <= r < 44 * PP]
    stat[F4][1] += 1
    if len(rA) < 10:
        stat[F4][2] += 1

    # F5：1:3 抖动段（帧 44..63）内的高电平拍数
    hi = 0
    for k in range(44 * PP, min(64 * PP, NCYC + 1)):
        if obs_bz(k) == 1:
            hi += 1
    stat[F5][1] += 1
    if hi < 1:
        stat[F5][2] += 1

    # ---------------- F6：不可重触发（只有长 run 才判得动）----------------
    #   ★ 2026-09-28：新增 "real" 模式（真实帧周期 P≈1,237,500）也判 F6。
    #     为什么必须加：原来只跑了 P=600 与 P=100 两个**很小**的帧周期，
    #     而真实帧周期比 beep 包络（400000 拍）还长约 3 倍 —— 量级完全不同。
    #     "帧周期 >> 包络"这种情形正是"包络可被重装"类缺陷最容易藏身的地方
    #     （旧 v1 的退化条件是"帧周期×GAP < 包络"，判据必须两头都覆盖）。
    if MODE in ("retrig", "real"):
        stat[F6a][1] += 1
        if max_run != BEEP_ON:
            stat[F6a][2] += 1
        stat[F6b][1] += 1
        if n_full < 2:
            stat[F6b][2] += 1
    else:
        stat[F6a][1] = -1                    # -1 = 本模式不适用（不算空跑）
        stat[F6b][1] = -1

    # ---------------- F7 / F8：倒置框 ----------------
    for f in (70, 71, 72, 73):
        probe = f * PP + 3
        if probe > NCYC:
            continue
        if obs_led(probe) != 0:
            stat[F7][2] += 1
        stat[F7][1] += 1
        # 激励自查：这一段确实"倒置 + valid=1"，否则上面的断言是空跑
        st = rows[bisect.bisect_right(seg_start, probe) - 1]
        stat[F7][1] += 1
        if not (st[3] == 1 and st[5] > st[6] and st[7] > st[8]):
            stat[F7][2] += 1
    # 窗口口径：帧同步拍 S=70*P 那一拍锁存新值，S+1 拍起 r_val 才是 0
    #（O_buzzer = 包络 & r_val），所以从 S+1 拍到帧 74 的同步拍为止必须恒 0。
    lo = 70 * PP + 1
    hi_end = min(74 * PP, NCYC)
    for k in range(lo, hi_end):
        stat[F8][1] += 1
        if obs_bz(k) != 0:
            stat[F8][2] += 1

    # ---------------- F9：覆盖度 ----------------
    stat[F9][1] += 1
    if not (len(runs) >= 3 and on_total > 0):
        stat[F9][2] += 1

    # ---------------- 输出 ----------------
    print("=" * 84)
    print("check_ext_ctrl_flicker —— mode=%s  P=%d  dump=%s  结束拍=%d  变化点=%d"
          % (MODE, PP, DUMP, NCYC, nseg))
    print("  上升沿拍号(前 12): %s" % beep_rises[:12])
    print("  鸣叫段数=%d  最长=%d  完整 400000 段数=%d  高电平总拍数=%d"
          % (len(runs), max_run, n_full, on_total))
    if bad:
        print("  前几个失配: %s" % (bad,))
    print("-" * 84)
    print("%-52s %12s %10s" % ("断言", "检查次数", "失配数"))
    print("-" * 84)
    nbad = 0
    for name, checks, fails in stat:
        if checks < 0:
            print("%-52s %12s %10s   (本模式不适用)" % (name, "N/A", "-"))
            continue
        flag = ""
        if fails:
            flag += "  <== 失配"
            nbad += 1
        if checks == 0:
            flag += "  <== 0 次检查(空跑)"
            nbad += 1
        print("%-52s %12d %10d%s" % (name, checks, fails, flag))
        print("RESULT|%s|%d|%d" % (name.split()[0], checks, fails))
    print("-" * 84)
    print("结论: %s" % ("FAIL（%d 条未过）" % nbad if nbad else "PASS"))
    return 1 if nbad else 0


if __name__ == "__main__":
    sys.exit(main())
