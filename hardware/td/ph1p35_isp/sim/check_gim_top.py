#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gim_top.py -- gim_top（三轴云台子系统）**集成级**判据

和模块级判据的分工：
    模块级已经把每个模块的内部行为验透了。这一层只验"接起来之后还对"。

输入：
    sim\\_gim_top\\dump_gim_top.txt          正常跑（IMU 在）
    sim\\_gim_top\\dump_gim_top_imufail.txt  失效注入跑（IMU 不回应）

判据：
    G1  视觉链路仍然通：pan/tilt 脉宽 == **独立重算的控制律结果**
        （保证 Stage 1 的功能没被 Stage 2 的集成破坏）
    G2  roll 现在真的由 IMU 驱动：roll 角度离开 0、roll 脉宽离开中位
    G3  **IMU 失效回退**：IMU 不回应时 roll 回中位、imu_err 置位，
        而 **pan/tilt 脉宽与正常跑逐位相同** —— 这条最重要，
        它保证"拆掉 IMU 也照样能演示视觉伺服"

⚠ 为什么要拿两次跑对比：单看一次"pan 脉宽 = 某值"只能证明"它是个数"；
   两次对比才能证明"IMU 的状态没有渗进视觉通路"。

用法：
    python check_gim_top.py --dump ... --imufail-dump ...
    python check_gim_top.py --dump ... --selftest
"""
from __future__ import annotations

import argparse
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

# 和 TB 里同一组 bbox 激励：{valid, x0, x1, y0, y1}
STIM = [
    (1,  560,  720, 300, 420),
    (1,  100,  300, 300, 420),
    (1, 1000, 1200, 300, 420),
    (1,  560,  720, 100, 200),
    (1,  560,  720, 500, 640),
    (0,    0,    0,   0,   0),
    (0,    1,    2,   3,   4),
    (1,    0,    0,   0,   0),
    (1, 1279, 1279, 719, 719),
    (1,    0,    1,   0,   1),
    (1,    1,    2,   1,   2),
    (1, 1000, 1200, 300, 420),
]


def parse(path):
    hdr, R, W = {}, [], None
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
            if p[0] == "R" and len(p) == 5:
                R.append(tuple(int(x) for x in p[1:]))
            elif p[0] == "W" and len(p) == 4:
                W = tuple(int(x) for x in p[1:])
            else:
                raise ValueError("不认识的 dump 行：%r" % ln)
    return hdr, R, W


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def step_of(e, dz, kn, ksh, slew, sign):
    if abs(e) <= dz:
        return 0
    mag = (abs(e) * kn) >> ksh
    if mag > slew:
        mag = slew
    if e < 0:
        mag = -mag
    return mag if sign >= 0 else -mag


def ref_pan_tilt(hdr):
    """独立重算视觉控制律：跑完 TB 那 12 帧后 pan/tilt 应该停在哪个脉宽。"""
    dz   = hdr.get("DEADZONE", 40)
    kn   = hdr.get("KP_NUM", 13)
    ksh  = hdr.get("KP_SH", 2)
    slew = hdr.get("SLEW_MAX", 60)
    pmin, pmid, pmax = hdr["PULSE_MIN"], hdr["PULSE_MID"], hdr["PULSE_MAX"]
    sp, st = hdr.get("SIGN_PAN", 1), hdr.get("SIGN_TILT", 1)
    cx0, cy0 = 1280 // 2, 720 // 2
    pan = tilt = pmid
    for (vld, x0, x1, y0, y1) in STIM:
        if not vld:
            continue
        cx = (x0 + x1) >> 1
        cy = (y0 + y1) >> 1
        pan  = clamp(pan  + step_of(cx - cx0, dz, kn, ksh, slew, sp), pmin, pmax)
        tilt = clamp(tilt + step_of(cy - cy0, dz, kn, ksh, slew, st), pmin, pmax)
    return pan, tilt


def judge(hdr, R, W, if_hdr, if_R, if_W, mut=None, verbose=True):
    mut = mut or {}
    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    pmid = hdr["PULSE_MID"]
    wp, wt, wr = W if W else (0, 0, 0)

    # ---- G1 视觉链路 ----
    e_pan, e_tilt = ref_pan_tilt(hdr)
    if mut.get("pan_off"):
        e_pan += 120
    chk(wp == e_pan,  "G1 pan  脉宽 == 独立重算的控制律", "实测 %d，期望 %d" % (wp, e_pan))
    chk(wt == e_tilt, "G1 tilt 脉宽 == 独立重算的控制律", "实测 %d，期望 %d" % (wt, e_tilt))
    chk(wp != wt, "G1 pan/tilt 没接反", "两路都是 %d" % wp)
    if verbose:
        print("  G1 视觉链路：pan 实测 %d（期望 %d），tilt 实测 %d（期望 %d）"
              % (wp, e_pan, wt, e_tilt))

    # ---- G2 roll 由 IMU 驱动 ----
    rolls = [r[1] for r in R]
    if mut.get("roll_stuck"):
        rolls = [0]
    chk(len(rolls) > 3, "G2 roll 有变化（不是一直不动）", "只记录了 %d 条" % len(rolls))
    if rolls:
        chk(rolls[-1] != 0, "G2 roll 角度离开 0", "末值 = %d" % rolls[-1])
        chk(min(rolls) < 0, "G2 roll 朝加速度倾角的方向走（负）",
            "最小值 = %d，前几条 %r" % (min(rolls), rolls[:6]))
    chk(wr != pmid, "G2 roll 脉宽离开中位", "实测 %d，中位 %d" % (wr, pmid))
    if verbose:
        print("  G2 roll 由 IMU 驱动：角度 %d → %d（%d 条变化记录），脉宽 %d（中位 %d）"
              % (rolls[0] if rolls else 0, rolls[-1] if rolls else 0, len(rolls), wr, pmid))

    # ---- G3 IMU 失效回退 ----
    if if_hdr is not None:
        iwp, iwt, iwr = if_W if if_W else (0, 0, 0)
        chk(if_hdr.get("IMUFAIL", 0) == 1, "G3 失效注入确实打开了",
            "IMUFAIL=%s" % if_hdr.get("IMUFAIL"))
        chk(iwr == pmid, "G3 IMU 失效时 roll 脉宽回中位",
            "实测 %d，期望 %d" % (iwr, pmid))
        chk(all(r[1] == 0 for r in if_R), "G3 IMU 失效时 roll 角度恒为 0",
            "出现过非零：%r" % [r[1] for r in if_R if r[1] != 0][:5])
        # ⚠ 这条要读**末行汇总**里的 imu_err，不能只扫 R 行：
        #   失效跑里 roll 恒为 0，R 行本来就只有很少几条（TB 已改成状态位变化也记，
        #   但判据不该依赖"dump 恰好记到了那一拍"这种巧合）。
        chk(if_hdr.get("imu_err", 0) == 1, "G3 IMU 失效时 imu_err 置位",
            "末行汇总 imu_err=%s" % if_hdr.get("imu_err"))
        chk(if_hdr.get("imu_ok", 0) == 0, "G3 IMU 失效时 imu_ok 不置位",
            "末行汇总 imu_ok=%s" % if_hdr.get("imu_ok"))
        # ★ 最关键的一条：视觉通路必须**逐位不受影响**
        chk((iwp, iwt) == (wp, wt),
            "G3 IMU 失效不影响 pan/tilt（两次跑逐位相同）",
            "正常跑 (%d,%d)，失效跑 (%d,%d)" % (wp, wt, iwp, iwt))
        if verbose:
            print("  G3 失效回退：roll 脉宽 %d（中位 %d）、角度恒 0、"
                  "pan/tilt (%d,%d) == 正常跑 (%d,%d)" % (iwr, pmid, iwp, iwt, wp, wt))
    else:
        chk(False, "G3 提供了失效注入的 dump", "没给 --imufail-dump，这条判据没跑")

    return nass, nbad


MUTATIONS = [
    ("pan 期望偏移 120", {"pan_off": True}),
    ("roll 当作没动",    {"roll_stuck": True}),
]


def selftest(hdr, R, W, if_hdr, if_R, if_W):
    a0, b0 = judge(hdr, R, W, if_hdr, if_R, if_W, None, verbose=False)
    print("  基线：断言 %d / 不符 %d" % (a0, b0))
    if b0 != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b = judge(hdr, R, W, if_hdr, if_R, if_W, mut, verbose=False)
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
    ap.add_argument("--imufail-dump", default=None)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    hdr, R, W = parse(args.dump)
    if_hdr = if_R = if_W = None
    if args.imufail_dump:
        if_hdr, if_R, if_W = parse(args.imufail_dump)

    print("=" * 78)
    print("check_gim_top.py  dump=%s" % args.dump)
    print("  roll 变化记录 %d 条；实测脉宽 %r；失效跑 %s"
          % (len(R), W, "有" if if_hdr else "无"))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, R, W, if_hdr, if_R, if_W)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad = judge(hdr, R, W, if_hdr, if_R, if_W, None, verbose=True)
    print("=" * 78)
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
