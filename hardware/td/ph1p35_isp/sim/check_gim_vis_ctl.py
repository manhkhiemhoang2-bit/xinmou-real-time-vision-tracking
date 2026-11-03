#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gim_vis_ctl.py -- gim_vis_ctl（pan/tilt 视觉伺服控制律）的判据

输入：sim\\_gim_vis\\dump_gim_vis.txt（tb_gim_vis_ctl.v 写出的逐帧表）
用法：
    python check_gim_vis_ctl.py --dump sim\\_gim_vis\\dump_gim_vis.txt
    python check_gim_vis_ctl.py --dump ... --selftest        # 变异自证

判据（对应 doc_describe\\三轴云台_设计与实施规划_20260922.md §8.2）：
    N0  逐帧对**独立的 Python 参考模型**（参考模型照规格写，不照抄 RTL）
    N1  死区内脉宽不变
    N2  每帧脉宽变化量 <= SLEW_MAX（限斜率真的起作用）
    N3  脉宽始终落在 [PULSE_MIN, PULSE_MAX]
    N4  valid=0 时脉宽**保持不变**（不是回中）
    N5  锁定：连续 LOCK_N 帧在死区内 -> O_locked=1，且**之后的帧保持 1**；
        一帧出死区 -> 立刻 0

反循环：本脚本只读 dump，不读 DUT 内部信号，也不 import RTL。
"""
from __future__ import annotations

import argparse
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")


# ---------------------------------------------------------------------------
def parse(path):
    hdr, rows = {}, []
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
            if len(p) != 9:
                raise ValueError("dump 行字段数不是 9（%d）：%r" % (len(p), ln))
            rows.append(tuple(int(x) for x in p))
    if not rows:
        raise ValueError("dump 里一帧都没有")
    return hdr, rows


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def step_of(e, dz, kn, ksh, slew, sign, no_dead=False, no_slew=False):
    """按规格算一帧的脉宽步进（独立于 RTL 的实现）。"""
    if (not no_dead) and abs(e) <= dz:
        return 0
    mag = (abs(e) * kn) >> ksh
    if (not no_slew) and mag > slew:
        mag = slew
    if e < 0:
        mag = -mag
    return mag if sign >= 0 else -mag


def ref_run(hdr, rows, mut=None):
    """参考模型：按**规格**重算每帧应有的 (pan, tilt, locked, tgt)。"""
    mut = mut or {}
    W, H    = hdr["IMG_W"], hdr["IMG_H"]
    dz      = 0 if mut.get("dz_off") else hdr["DEADZONE"]
    kn, ksh = hdr["KP_NUM"], hdr["KP_SH"]
    slew    = 10 ** 9 if mut.get("no_slew") else hdr["SLEW_MAX"]
    pmin, pmid, pmax = hdr["PULSE_MIN"], hdr["PULSE_MID"], hdr["PULSE_MAX"]
    sp      = -hdr["SIGN_PAN"] if mut.get("sign_flip") else hdr["SIGN_PAN"]
    st      = -hdr["SIGN_TILT"] if mut.get("sign_flip") else hdr["SIGN_TILT"]
    lockn   = hdr["LOCK_N"] - 1 if mut.get("lock_off") else hdr["LOCK_N"]

    cx0, cy0 = W // 2, H // 2
    pan = tilt = pmid
    lock_cnt = locked = tgt = 0
    out = []
    for (f, cx, cy, valid, en, _pp, _pt, _lk, _tp) in rows:
        if en == 0:
            pan, tilt = pmid, pmid
            lock_cnt = locked = tgt = 0
        elif valid == 0:
            if mut.get("lost_recenter"):        # 变异：丢失时回中（规格要求"保持"）
                pan, tilt = pmid, pmid
            lock_cnt = locked = tgt = 0
        else:
            ex, ey = cx - cx0, cy - cy0
            dx = step_of(ex, dz, kn, ksh, slew, sp, bool(mut.get("dz_off")), bool(mut.get("no_slew")))
            dy = step_of(ey, dz, kn, ksh, slew, st, bool(mut.get("dz_off")), bool(mut.get("no_slew")))
            pan  = clamp(pan  + dx, pmin, pmax)
            tilt = clamp(tilt + dy, pmin, pmax)
            tgt  = 1
            if abs(ex) <= dz and abs(ey) <= dz:
                lock_cnt = min(lock_cnt + 1, lockn)
                locked = 1 if lock_cnt >= lockn else 0
            else:
                lock_cnt = locked = 0
        out.append((f, pan, tilt, locked, tgt))
    return out


# ---------------------------------------------------------------------------
def judge(hdr, rows, mut=None, verbose=True):
    mut = mut or {}
    pmin, pmid, pmax = hdr["PULSE_MIN"], hdr["PULSE_MID"], hdr["PULSE_MAX"]
    dz, slew, lockn = hdr["DEADZONE"], hdr["SLEW_MAX"], hdr["LOCK_N"]
    cx0, cy0 = hdr["IMG_W"] // 2, hdr["IMG_H"] // 2

    exp = {e[0]: e for e in ref_run(hdr, rows, mut)}
    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    # ---- N0 逐帧对参考模型 ----
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        e = exp[f]
        chk(pp == e[1], "N0[f%d] pulse_pan" % f, "实测 %d，期望 %d" % (pp, e[1]))
        chk(pt == e[2], "N0[f%d] pulse_tilt" % f, "实测 %d，期望 %d" % (pt, e[2]))
        chk(lk == e[3], "N0[f%d] locked" % f, "实测 %d，期望 %d" % (lk, e[3]))
        chk(tp == e[4], "N0[f%d] tgt_present" % f, "实测 %d，期望 %d" % (tp, e[4]))
    if verbose:
        print("  N0 逐帧对参考模型：%d 帧 × 4 项" % len(rows))

    # ---- N1 死区内脉宽不变 ----
    n1 = 0
    prev = None
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        if prev is not None and en and valid and prev[4] and \
           abs(cx - cx0) <= dz and abs(cy - cy0) <= dz and \
           abs(prev[1] - cx0) <= dz and abs(prev[2] - cy0) <= dz:
            n1 += 1
            chk((pp, pt) == (prev[5], prev[6]), "N1[f%d] 死区内脉宽不变" % f,
                "上一帧 (%d,%d) -> 本帧 (%d,%d)" % (prev[5], prev[6], pp, pt))
        prev = r
    chk(n1 > 0, "N1 至少检查到一对连续死区帧", "一对都没检查到（激励没覆盖）")
    if verbose:
        print("  N1 死区内脉宽不变：检查 %d 对" % n1)

    # ---- N2 限斜率 ----
    n2 = 0
    prev = None
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        if prev is not None and en and valid and prev[4]:
            n2 += 1
            d1, d2 = abs(pp - prev[5]), abs(pt - prev[6])
            chk(d1 <= slew, "N2[f%d] pan 步进未超限" % f, "实测 %d > SLEW_MAX %d" % (d1, slew))
            chk(d2 <= slew, "N2[f%d] tilt 步进未超限" % f, "实测 %d > SLEW_MAX %d" % (d2, slew))
        prev = r
    chk(n2 > 0, "N2 至少检查到一次帧间变化", "一次都没检查到")
    if verbose:
        print("  N2 限斜率（SLEW_MAX=%d）：检查 %d 对" % (slew, n2))

    # ---- N3 脉宽范围 ----
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        chk(pmin <= pp <= pmax, "N3[f%d] pan 在范围内" % f, "实测 %d" % pp)
        chk(pmin <= pt <= pmax, "N3[f%d] tilt 在范围内" % f, "实测 %d" % pt)
    if verbose:
        print("  N3 脉宽范围 [%d,%d]：%d 帧 × 2 轴" % (pmin, pmax, len(rows)))

    # ---- N4 丢失时保持 ----
    n4 = 0
    prev = None
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        if prev is not None and en and (not valid) and prev[4]:
            n4 += 1
            chk((pp, pt) == (prev[5], prev[6]), "N4[f%d] 丢失时脉宽保持" % f,
                "上一帧 (%d,%d) -> 丢帧后 (%d,%d)" % (prev[5], prev[6], pp, pt))
        prev = r
    chk(n4 > 0, "N4 至少检查到一次目标丢失", "激励里没有丢失帧")
    if verbose:
        print("  N4 丢失时保持：检查 %d 次" % n4)

    # ---- N5 锁定行为 ----
    #   看每个"连续在死区"的游程：第 LOCK_N 帧应为 1，之后的帧**必须保持 1**
    runs, cur = [], []
    for r in rows:
        f, cx, cy, valid, en, pp, pt, lk, tp = r
        indz = (en == 1) and (valid == 1) and abs(cx - cx0) <= dz and abs(cy - cy0) <= dz
        if indz:
            cur.append(r)
        else:
            if cur:
                runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    n5 = 0
    for run in runs:
        for i, r in enumerate(run):
            n5 += 1
            want = 1 if (i + 1) >= lockn else 0
            chk(r[7] == want, "N5[f%d] 死区游程第 %d 帧 locked" % (r[0], i + 1),
                "实测 %d，期望 %d" % (r[7], want))
    # 出死区必须立刻为 0
    for i in range(1, len(rows)):
        f, cx, cy, valid, en, pp, pt, lk, tp = rows[i]
        pf = rows[i - 1]
        indz = (en == 1) and (valid == 1) and abs(cx - cx0) <= dz and abs(cy - cy0) <= dz
        if (not indz) and en == 1 and valid == 1 and pf[7] == 1 or \
           ((not indz) and en == 1 and pf[7] == 1):
            n5 += 1
            chk(lk == 0, "N5[f%d] 出死区立刻解锁" % f, "实测 locked=%d，应为 0" % lk)
    chk(n5 > 0, "N5 至少检查到一帧锁定状态", "一帧都没检查到")
    if verbose:
        print("  N5 锁定（LOCK_N=%d）：检查 %d 帧；死区游程 %d 段（长度 %s）"
              % (lockn, n5, len(runs), [len(x) for x in runs]))

    return nass, nbad


# ---------------------------------------------------------------------------
MUTATIONS = [
    ("死区失效（DZ 当 0）",      {"dz_off": True}),
    ("去掉限斜率",              {"no_slew": True}),
    ("丢失时回中",              {"lost_recenter": True}),
    ("方向符号取反",            {"sign_flip": True}),
    ("锁定少一帧",              {"lock_off": True}),
]


def selftest(hdr, rows):
    a0, b0 = judge(hdr, rows, None, verbose=False)
    print("  基线：断言 %d / 不符 %d" % (a0, b0))
    if b0 != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b = judge(hdr, rows, mut, verbose=False)
        caught = b > 0
        print("  [mut] %-22s -> %s（断言 %d / 不符 %d）"
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

    hdr, rows = parse(args.dump)
    print("=" * 78)
    print("check_gim_vis_ctl.py  dump=%s" % args.dump)
    print("  帧数 %d；DZ=%d KP=%d>>%d SLEW=%d PULSE=[%d,%d] SIGN=(%d,%d) LOCK_N=%d"
          % (len(rows), hdr["DEADZONE"], hdr["KP_NUM"], hdr["KP_SH"], hdr["SLEW_MAX"],
             hdr["PULSE_MIN"], hdr["PULSE_MAX"], hdr["SIGN_PAN"], hdr["SIGN_TILT"],
             hdr["LOCK_N"]))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, rows)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad = judge(hdr, rows, None, verbose=True)
    print("=" * 78)
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
