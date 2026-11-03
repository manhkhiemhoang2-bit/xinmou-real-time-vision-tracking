#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_inside.py —— 先在**逐拍模型**里把"行首/行尾 inside 边界"改到与参考逐拍一致，
再落到 Verilog（不做猜测式改 RTL）。

模型复刻 v3.1 的各级，只把"清零条件"参数化：
    clr_mode = 'tlast'   : r_clr <= r_tlast | r_tuser            （v3.1 现状）
    clr_mode = 'tlast_d' : r_clr <= 上一拍的 (r_tlast|r_tuser)   （v3.1 实际接法）
    clr_mode = 'rowstart': 用**几何计数器**判断"本拍是不是行首拍"（父代理的建议）
                            r_x == LAST_BEAT  ⇔ 本拍是行首拍（因为 r_x 比 x_grp 晚一拍）
对每种条件分别算"与参考逐像素失配数"，取 0 的那个落 RTL。
"""
from __future__ import annotations

import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, ".")
import ref_region_fill as R  # noqa: E402


def model(beats, W, H, clr_mode):
    BPL, BPF = W // 4, (W // 4) * H
    N = beats.shape[0]
    line1, line2 = {}, {}
    r_rd1 = r_rd1_s1 = r_rd1_s2 = 0
    r_rd2 = r_rd2_s1 = r_rd2_s2 = 0
    r_x = r_y = 0
    r_word = [0, 0, 0, 0]
    r_bl1 = r_bl2 = r_bl3 = 0
    r_inside = 0
    r_edge_prev = 0
    r_tlast = r_tuser = 0
    r_last_prev = r_user_prev = 0
    r_vld1 = 0
    x_grp = y_pos = 0
    # 输出（stage2）寄存器：r_fill2 -> O 各一级
    vld = [0] * 8
    out = {}
    trace = []
    for c in range(N + 8):
        iv = c < N
        p = [int(v == R.WHITE) for v in beats[c]] if iv else [0, 0, 0, 0]
        # ---------------- 组合（用 stage1 的寄存器）----------------
        win_valid = (r_y >= 2) and (r_x != 0) and (r_tuser == 0)

        def bit(w, i):
            return (w >> i) & 1
        top = [0 if r_x == 0 else r_bl3, bit(r_rd2_s2, 3), bit(r_rd2_s2, 2),
               bit(r_rd2_s2, 1), bit(r_rd2_s2, 0),
               0 if r_x == BPL - 1 else bit(r_rd2_s1, 3)]
        mid = [0 if r_x == 0 else r_bl2, bit(r_rd1_s2, 3), bit(r_rd1_s2, 2),
               bit(r_rd1_s2, 1), bit(r_rd1_s2, 0),
               0 if r_x == BPL - 1 else bit(r_rd1_s1, 3)]
        bot = [0 if r_x == 0 else r_bl1, r_word[3], r_word[2], r_word[1], r_word[0],
               0 if r_x == BPL - 1 else p[0]]
        e = [0] * 4
        if win_valid:
            for k in range(4):
                e[k] = 1 if any((top[k], top[k + 1], top[k + 2],
                                 mid[k], mid[k + 1], mid[k + 2],
                                 bot[k], bot[k + 1], bot[k + 2])) else 0
        rise = [e[0] & (1 - r_edge_prev), e[1] & (1 - e[0]),
                e[2] & (1 - e[1]), e[3] & (1 - e[2])]
        ins = [r_inside]
        for k in range(4):
            ins.append(ins[-1] ^ rise[k])
        fill = [e[k] | ins[k] for k in range(4)]
        if vld[2]:
            out[c] = [R.WHITE if f else R.BLACK for f in fill]
        trace.append((c, r_x, r_y, e, rise, r_inside, r_tlast, r_tuser, fill))
        # ---------------- 本拍末装载 ----------------
        rd_addr = (x_grp + 1) % BPL
        n1 = line1.get(rd_addr, 0)
        n2 = line2.get(rd_addr, 0)
        if iv:
            line2[x_grp] = r_rd1
            line1[x_grp] = (p[0] << 3) | (p[1] << 2) | (p[2] << 1) | p[3]
        r_rd1_s2, r_rd1_s1, r_rd1 = r_rd1_s1, r_rd1, n1
        r_rd2_s2, r_rd2_s1, r_rd2 = r_rd2_s1, r_rd2, n2
        r_word = list(p) if iv else r_word
        r_bl1 = r_word[0] if iv else r_bl1
        r_bl2 = r_bl1 if iv else r_bl2
        r_bl3 = r_bl2 if iv else r_bl3
        vld = [iv] + vld[:-1]
        # 清零条件
        if clr_mode == "tlast":
            clr = (r_tlast == 1) or (r_tuser == 1)
        elif clr_mode == "tlast_d":
            clr = (r_last_prev == 1) or (r_user_prev == 1)
        else:                                    # rowstart
            clr = (r_x == LAST_BEAT_X) or (r_tuser == 1)
        r_vld1 = iv
        if clr:
            r_inside, r_edge_prev = 0, 0
        elif r_vld1:
            r_inside, r_edge_prev = ins[4], e[3]
        r_last_prev, r_user_prev = r_tlast, r_tuser
        r_tlast = 1 if (iv and (c % BPL == BPL - 1)) else 0
        r_tuser = 1 if (iv and (c % BPF == 0)) else 0
        r_x, r_y = x_grp, y_pos
        if iv:
            if c % BPF == 0:
                x_grp, y_pos = (1 % BPL), 0
            elif x_grp == BPL - 1:
                x_grp, y_pos = 0, (0 if y_pos == H - 1 else y_pos + 1)
            else:
                x_grp += 1
    return out, trace


LAST_BEAT_X = 0        # 占位，main 里按 BPL 设置


def main():
    global LAST_BEAT_X
    import check_region_fill as C
    import json
    d = C.load_dump("dump_rf.txt")
    inb = C.beats_of(d["id"], d["iv"])
    outb = C.beats_of(d["od"], d["ov"])
    m = json.load(open("meta_rf.json", encoding="utf-8"))
    W, H = m["W"], m["H"]
    BPL = W // 4
    LAST_BEAT_X = BPL - 1
    vc = list(np.nonzero(d["ov"])[0])
    got = {int(cc): [int(v) for v in outb[i]] for i, cc in enumerate(vc)}
    for mode in ("tlast", "tlast_d", "rowstart"):
        out, tr = model(inb, W, H, mode)
        bad = sum(1 for cc in out if got.get(cc) is not None and got[cc] != out[cc])
        print("clr_mode=%-9s -> 与 RTL dump 失配 %d 拍" % (mode, bad))
    # 再把 rowstart 模式与**参考实现**逐像素比
    out, tr = model(inb, W, H, "rowstart")
    exp = R.ref_region_fill(
        R.ref_frames_from_beats(inb, W, H), W, H).reshape(-1, 4)
    keys = sorted(out)
    n = min(len(keys), exp.shape[0])
    bad = sum(1 for i in range(n) if list(exp[i]) != out[keys[i]])
    print("rowstart 模式 vs Python 参考：%d/%d 拍失配" % (bad, n))
    if bad:
        for i in range(n):
            if list(exp[i]) != out[keys[i]]:
                cc = keys[i]
                t = [t for t in tr if t[0] == cc][0]
                print("   首错 cyc=%d r_x=%d r_y=%d e=%s rise=%s inside_in=%d tl=%d tu=%d"
                      % (t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7]))
                print("        got=%s" % ''.join('#' if v == R.WHITE else '.' for v in out[cc]))
                print("        ref=%s" % ''.join('#' if v == R.WHITE else '.' for v in exp[i]))
                break
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
