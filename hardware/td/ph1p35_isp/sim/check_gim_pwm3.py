#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gim_pwm3.py -- gim_pwm3（三路舵机 PWM）的判据

输入：sim\\_gim_pwm3\\dump_gim_pwm3.txt（tb_gim_pwm3.v 写出的**变化沿**表）
用法：
    python check_gim_pwm3.py --dump sim\\_gim_pwm3\\dump_gim_pwm3.txt
    python check_gim_pwm3.py --dump ... --selftest        # 变异自证

判据（对应 doc_describe\\三轴云台_设计与实施规划_20260922.md §8.2）：
    J1  周期 = PWM_PER 拍（20ms @50MHz），逐条脉冲对
    J2  脉宽 = 限幅后的命令值（±1 拍）
    J3  命令超上限 / 超下限时被限到 PULSE_MAX / PULSE_MIN（限幅真的起作用）
    J4  O_boot_done 在 T_RST_END + BOOT_MUTE 附近拉高，且**它拉高之前三路恒 0**
    J5  en=0 那一段时间三路恒 0（舵机松开）

拍数约定（很重要，差一拍会全红）：
    DUT 的输出寄存器在第 N 个上升沿更新；TB 的 now_v 在第 N+1 个沿才看到它。
    所以"上升沿记在第 A 拍、下降沿记在第 B 拍"时，实测脉宽 = B - A（偏移抵消）。
    周期 = 下一次上升的拍号 - 本次上升的拍号。

反循环：本脚本只读 dump，不读 DUT 内部信号，也不 import RTL。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

# dump 的列序
C_CYC, C_STEP, C_BOOT, C_PAN, C_TILT, C_ROLL, C_CPAN, C_CTILT, C_CROLL = range(9)
CHANNELS = (("pan", C_PAN, C_CPAN), ("tilt", C_TILT, C_CTILT), ("roll", C_ROLL, C_CROLL))


# ---------------------------------------------------------------------------
def parse(path):
    """读 dump：返回 (参数头, 事件列表)。"""
    hdr, ev = {}, []
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            if ln.startswith("#"):
                for k, v in re.findall(r"([A-Za-z_]\w*)=(\d+)", ln):
                    hdr[k] = int(v)
                continue
            parts = ln.split()
            if len(parts) != 9:
                raise ValueError("dump 行字段数不是 9（%d）：%r" % (len(parts), ln))
            ev.append(tuple(int(x) for x in parts))
    if not ev:
        raise ValueError("dump 里一条事件都没有")
    return hdr, ev


def edges_of(ev, col):
    """把一个通道的 (上升拍号列表, 下降拍号列表) 抽出来。

    dump 里只有变化沿，所以两条相邻行之间状态恒定：
      上一行该位 = 0、本行 = 1  -> 本行拍号就是**上升沿**
    """
    rises, falls = [], []
    prev = ev[0][col]
    for row in ev[1:]:
        cur = row[col]
        if prev == 0 and cur == 1:
            rises.append(row[C_CYC])
        elif prev == 1 and cur == 0:
            falls.append(row[C_CYC])
        prev = cur
    return rises, falls


def pulses(rises, falls):
    """把上升/下降配成脉冲。返回 [(rise_cyc, fall_cyc, width)]。"""
    out = []
    for r in rises:
        nxt = [f for f in falls if f > r]
        if not nxt:
            break
        f = nxt[0]
        out.append((r, f, f - r))
    return out


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


# ---------------------------------------------------------------------------
# 判据
# ---------------------------------------------------------------------------
def judge(hdr, ev, mut=None, verbose=True):
    """返回 (断言数, 不符数)。mut 是变异字典（--selftest 用）。"""
    mut = mut or {}
    per   = hdr["PWM_PER"]
    pmin  = hdr["PULSE_MIN"]
    pmax  = hdr["PULSE_MAX"]
    mid   = hdr["PULSE_MID"]
    bmute = hdr["BOOT_MUTE"]
    t_rst = hdr["T_RST_END"]

    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    # ---- 先算全部边沿 ----
    info = {}
    for name, col, cpc in CHANNELS:
        rises, falls = edges_of(ev, col)
        info[name] = {"rises": rises, "falls": falls, "pulses": pulses(rises, falls)}

    # ---- J1 周期 ----
    #   ⚠ 2026-09-23 踩过的坑：第一版直接对全部相邻上升沿求差，结果在 en=0 那一段报红。
    #     原因不是 RTL 错 —— en=0 窗口 [T_OFF, T_ON) 会**故意**压掉一个脉冲，
    #     跨过它的那个间隔本来就是 2 个周期。
    #     凡是跨过这个窗口的间隔一律跳过，并把跳过条数打印出来
    #     （按项目纪律：被排除的判据必须打印原因，不能静默放过）。
    off_lo, off_hi = hdr["T_OFF"], hdr["T_ON"]
    n_p = n_p_skip = 0
    for name, _, _ in CHANNELS:
        rs = info[name]["rises"]
        for a, b in zip(rs, rs[1:]):
            if a < off_hi and b > off_lo:
                n_p_skip += 1
                continue
            n_p += 1
            want = per + mut.get("period_off", 0)
            chk(b - a == want, "J1[%s] 周期" % name,
                "实测 %d 拍，期望 %d" % (b - a, want))
    # 0 次检查不算验证（项目纪律）
    chk(n_p > 0, "J1 至少检查到一条周期", "一条都没检查到")
    if verbose:
        print("  J1 周期（PWM_PER=%d）：检查 %d 条；跨 en=0 窗口跳过 %d 条（那段故意少一个脉冲）"
              % (per, n_p, n_p_skip))

    # ---- J2 脉宽 = 限幅后的命令值 ----
    #   命令值取**上升沿那一拍记录的 cp_***（TB 只在脉冲之外改命令值，
    #   所以一条脉冲从头到尾对应同一个命令值）。
    cp_at = {}                       # cyc -> (cpan, ctilt, croll)
    for row in ev:
        cp_at[row[C_CYC]] = (row[C_CPAN], row[C_CTILT], row[C_CROLL])
    cyc_list = sorted(cp_at)

    def cp_before(cyc, idx):
        lo, hi = 0, len(cyc_list) - 1
        best = cyc_list[0]
        while lo <= hi:
            m = (lo + hi) // 2
            if cyc_list[m] <= cyc:
                best = cyc_list[m]; lo = m + 1
            else:
                hi = m - 1
        return cp_at[best][idx]

    n_w = 0
    for ci, (name, _, _) in enumerate(CHANNELS):
        for (r, f, w) in info[name]["pulses"]:
            n_w += 1
            raw = cp_before(r, ci)
            want = raw if mut.get("no_clamp") else clamp(raw, pmin, pmax)
            want += mut.get("width_off", 0)
            chk(w == want, "J2[%s] 脉宽" % name,
                "上升@%d 命令=%d 实测 %d 拍，期望 %d" % (r, raw, w, want))
    if verbose:
        print("  J2 脉宽（命令值 vs 限幅后）：检查 %d 条" % n_w)

    # ---- J3 限幅真的生效（命令超界时必须被夹住，而不是照原值输出）----
    n_c = 0
    for ci, (name, _, _) in enumerate(CHANNELS):
        for (r, f, w) in info[name]["pulses"]:
            raw = cp_before(r, ci)
            if raw > pmax:
                n_c += 1
                chk(w == pmax, "J3[%s] 超上限被限幅" % name,
                    "命令 %d > MAX %d，实测 %d" % (raw, pmax, w))
            elif raw < pmin:
                n_c += 1
                chk(w == pmin, "J3[%s] 超下限被限幅" % name,
                    "命令 %d < MIN %d，实测 %d" % (raw, pmin, w))
    if verbose:
        print("  J3 限幅：检查 %d 条（若为 0，说明本跑没有超界脉冲）" % n_c)

    # ---- J4 boot_done 与静默期 ----
    boot_rise = [row[C_CYC] for row in ev if row[C_BOOT] == 1]
    boot_rise = boot_rise[0] if boot_rise else None
    want_boot = t_rst + bmute + mut.get("boot_off", 0)
    chk(boot_rise is not None, "J4 O_boot_done 拉高", "整跑没看到它拉高")
    if boot_rise is not None:
        chk(abs(boot_rise - want_boot) <= 3, "J4 O_boot_done 时刻",
            "实测 @%d，期望 @%d(±3)" % (boot_rise, want_boot))
    n_sil = 0
    for name, _, _ in CHANNELS:
        for r in info[name]["rises"]:
            if boot_rise is None or r < (boot_rise if not mut.get("ignore_mute") else 0):
                n_sil += 1
                chk(False, "J4[%s] 静默期内出现脉冲" % name,
                    "上升沿 @%d，boot_done @%s" % (r, boot_rise))
    # 恒 0 是一个"否定命题"，必须至少证明我们看过那段时间：
    chk(n_sil == 0, "J4 静默期内三路无脉冲",
        "静默期内出现 %d 次上升沿" % n_sil)
    if verbose:
        print("  J4 静默期：boot_done 实测 @%s，期望 @%d(±3)；期内违例 %d 次"
              % (boot_rise, want_boot, n_sil))

    # ---- J5 en=0 期间三路恒 0 ----
    off_lo = hdr["T_OFF"]
    off_hi = hdr["T_ON"]
    n_off = 0
    for name, _, _ in CHANNELS:
        for r in info[name]["rises"]:
            if off_lo <= r < off_hi:
                n_off += 1
                chk(False, "J5[%s] en=0 期间出现脉冲" % name, "上升沿 @%d" % r)
        for f in info[name]["falls"]:
            if off_lo <= f < off_hi:
                n_off += 1
                chk(False, "J5[%s] en=0 期间有下降沿" % name, "下降沿 @%d" % f)
    chk(n_off == 0, "J5 en=0 期间三路恒 0", "期间活动 %d 次" % n_off)
    # 还要证明确实有脉冲在 en 恢复之后又出来了（否则"全程无脉冲"也能过 J5）
    n_after = sum(1 for name, _, _ in CHANNELS for r in info[name]["rises"] if r >= off_hi)
    chk(n_after >= 3, "J5 en 恢复后三路重新出脉冲",
        "恢复后只有 %d 个上升沿" % n_after)
    if verbose:
        print("  J5 en=0 期间（[%d,%d)）：违例 %d 次；恢复后上升沿 %d 个"
              % (off_lo, off_hi, n_off, n_after))

    return nass, nbad


# ---------------------------------------------------------------------------
MUTATIONS = [
    ("周期偏 1 拍",        {"period_off": 1}),
    ("脉宽偏 1 拍",        {"width_off": 1}),
    ("去掉限幅（照原值输出）", {"no_clamp": True}),
    ("忽略静默期",          {"boot_off": 5}),
]


def selftest(hdr, ev):
    base_ass, base_bad = judge(hdr, ev, None, verbose=False)
    print("  基线：断言 %d / 不符 %d" % (base_ass, base_bad))
    if base_bad != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b = judge(hdr, ev, mut, verbose=False)
        caught = b > 0
        print("  [mut] %-24s -> %s（断言 %d / 不符 %d）"
              % (label, "抓住" if caught else "**漏掉**", a, b))
        ok += 1 if caught else 0
    print("------------------------------------------------------------------------")
    print("变异自证：%d/%d 被抓住" % (ok, len(MUTATIONS)))
    return 0 if ok == len(MUTATIONS) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    hdr, ev = parse(args.dump)
    print("=" * 78)
    print("check_gim_pwm3.py  dump=%s" % args.dump)
    print("  事件 %d 条；PWM_PER=%d PULSE_MIN=%d PULSE_MAX=%d PULSE_MID=%d BOOT_MUTE=%d"
          % (len(ev), hdr["PWM_PER"], hdr["PULSE_MIN"], hdr["PULSE_MAX"],
             hdr["PULSE_MID"], hdr["BOOT_MUTE"]))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, ev)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad = judge(hdr, ev, None, verbose=True)
    print("=" * 78)
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
