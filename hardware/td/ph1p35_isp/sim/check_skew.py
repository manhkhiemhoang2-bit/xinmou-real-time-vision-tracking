#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_skew.py —— 判定「O_tdata 的拍号」与「O_tuser/O_tlast/O_tvalid 的拍号」是否同拍

只读 dump_skew.txt（TB 逐拍 dump），期望值全部来自**输入激励**（像素值图严格单射，
每个像素自带拍号），不读 DUT/REF 的任何内部信号。

核心两问：
  Q1  O_tuser 拉高的那一拍，O_tdata 解出来的拍号是 0 还是 1？
      （beat0 就是带 I_tuser=1 的那一拍 ⇒ 同拍应当解出 0）
  Q2  O_tlast 拉高的那一拍，O_tdata 解出来的拍号是不是带 I_tlast 的那一拍？

用法：
    python check_skew.py [--dump _skew_work\\dump_skew.txt]
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))

GAP_TAG = 0x0BAD          # 气泡期总线上的醒目标记


def pix(beat, ch):
    return (beat << 7) | ((beat % 32) << 2) | ch


def dec(v, ch):
    """v 若正好是 pix(beat,ch) 则返回 beat，否则 None"""
    if (v & 3) != ch:
        return None
    b = v >> 7
    if b < 0 or b >= 4096:
        return None
    return b if pix(b, ch) == v else None


def beats_of(tdata):
    v = int(tdata, 16)
    out = set()
    for ch in range(4):
        b = dec((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
        if b is not None:
            out.add(b)
    return out


def is_gap(tdata):
    v = int(tdata, 16)
    for ch in range(4):
        px = (v >> (72 - 24 * ch)) & 0xFFFFFF
        if (px >> 8) == GAP_TAG:
            return True
    return False


def parse(path):
    rows = []
    hdr = None
    for ln in open(path, encoding="ascii", errors="replace"):
        f = ln.split()
        if not f:
            continue
        if f[0] == "H":
            hdr = [int(x) for x in f[1:]]
            continue
        if len(f) < 14:
            continue
        rows.append({
            "cyc": int(f[0]),
            "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]), "Id": f[4], "bidx": int(f[5]),
            "Rv": int(f[6]), "Rl": int(f[7]), "Ru": int(f[8]), "Rd": f[9],
            "Dv": int(f[10]), "Dl": int(f[11]), "Du": int(f[12]), "Dd": f[13],
        })
    assert hdr is not None, "dump 没有 H 头"
    return hdr, rows


def analyse(rows, tag, vk, lk, uk, dk):
    """vk/lk/uk = 该 RTL 的 tvalid/tlast/tuser 列名；dk = 数据列名"""
    print("---- %s ----" % tag)
    # 输入侧基准
    in_u = [r for r in rows if r["Iu"] == 1 and r["Iv"] == 1]
    in_l = [r for r in rows if r["Il"] == 1 and r["Iv"] == 1]
    in_v = [r for r in rows if r["Iv"] == 1]
    bu = sorted(beats_of(in_u[0]["Id"]))[0] if in_u else None
    bl = [sorted(beats_of(r["Id"]))[0] for r in in_l]
    print("  输入：I_tuser=1 于 cyc=%s，该拍总线拍号=%s ；I_tlast=1 于 cyc=%s，拍号=%s"
          % ([r["cyc"] for r in in_u], bu, [r["cyc"] for r in in_l], bl))
    print("  输入：有效拍数（I_tvalid=1）=%d" % len(in_v))

    # 输出侧
    out_v = [r for r in rows if r[vk] == 1]
    out_u = [r for r in rows if r[uk] == 1]
    out_l = [r for r in rows if r[lk] == 1]
    print("  输出：O_tvalid=1 拍数=%d ；O_tuser=1 于 cyc=%s ；O_tlast=1 于 cyc=%s"
          % (len(out_v), [r["cyc"] for r in out_u], [r["cyc"] for r in out_l]))

    # Q1：O_tuser 那一拍携带的拍号
    q1 = None
    if out_u:
        for r in out_u:
            bs = sorted(beats_of(r[dk]))
            print("  ** Q1  O_tuser=1 那一拍 cyc=%d 的 O_tdata 拍号 = %s  (同一拍的总线拍号 %s)"
                  % (r["cyc"], bs if bs else "解不出(非透传值)", r["bidx"]))
            q1 = bs[0] if len(bs) == 1 else None
    else:
        print("  ** Q1  没有 O_tuser 拍")

    # Q2：O_tlast 那一拍携带的拍号
    q2 = []
    for r in out_l:
        bs = sorted(beats_of(r[dk]))
        q2.append((r["cyc"], bs[0] if len(bs) == 1 else None))
    print("  ** Q2  O_tlast=1 的各拍 (cyc, O_tdata 拍号) = %s ；带 I_tlast 的输入拍号 = %s"
          % (q2, bl))

    # 气泡：O_tvalid=0 时数据必须为 0；O_tvalid=1 时不许出现气泡标记
    bad_zero = [r["cyc"] for r in rows if r[vk] == 0 and int(r[dk], 16) != 0]
    gap_leak = [r["cyc"] for r in rows if r[vk] == 1 and is_gap(r[dk])]
    print("  O_tvalid=0 但 O_tdata!=0 的拍：%s" % (bad_zero if bad_zero else "无"))
    print("  ** O_tvalid=1 却携带【气泡期标记 0x0BAD】的拍：%s"
          % (gap_leak if gap_leak else "无"))

    # 每个输出有效拍携带的拍号序列（前 6 / 后 6）
    seq = [(r["cyc"], sorted(beats_of(r[dk]))[:1], r[lk], r[uk]) for r in out_v]
    print("  输出有效拍序列（cyc, 拍号, tlast, tuser）前 6：")
    for s in seq[:6]:
        print("      %s" % (s,))
    print("  输出有效拍序列 后 6：")
    for s in seq[-6:]:
        print("      %s" % (s,))
    return q1, q2, gap_leak


def main():
    argv = sys.argv[1:]
    dump = os.path.join(HERE, "_skew_work", "dump_skew.txt")
    if "--dump" in argv:
        dump = argv[argv.index("--dump") + 1]
    hdr, rows = parse(dump)
    print("check_skew.py  dump=%s  H=%s  (%d 拍)" % (dump, hdr, len(rows)))
    q1r, q2r, gapr = analyse(rows, "REF = osd_mixer_ref（改造前 v1.1）", "Rv", "Rl", "Ru", "Rd")
    print("")
    q1d, q2d, gapd = analyse(rows, "DUT = osd_mixer（改造后 v1.2）", "Dv", "Dl", "Du", "Dd")

    print("\n================ 判定 ================")
    for tag, q1 in (("v1.1", q1r), ("v1.2", q1d)):
        if q1 == 0:
            print("%s : O_tuser 那一拍的数据拍号 = 0 ⇒ 控制与数据**同拍**，不是 bug" % tag)
        elif q1 is None:
            print("%s : 无法判定（数据拍号解不出）" % tag)
        else:
            print("%s : O_tuser 那一拍的数据拍号 = %d ⇒ **数据与控制错开 1 拍（真 bug）**"
                  % (tag, q1))
    sys.exit(0)


if __name__ == "__main__":
    main()
