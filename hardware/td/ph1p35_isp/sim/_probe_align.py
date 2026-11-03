#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_align.py —— 逐拍模型搜索行缓存的正确读地址/对齐配置（不跑 ModelSim）

把 RTL 的每一级按拍建模（line1/line2 + 读数据链 + 窗口 + ripple + 输出级），
用 (rd_off, sh_cur) 扫一遍：
    rd_off  = 组合读地址相对"本拍拍号"的偏移（写地址恒为 x_grp）
    sh_cur  = 当前组（第 X 组）在读出链上的位置（0 = 读口当拍输出）
   左邻居 = 链上第 sh_cur+1 级（第 X−1 组）的位 3
   右邻居 = 链上第 sh_cur−1 级（第 X+1 组）的位 3；sh_cur=0 时就是**读口当拍的那个新值**
   底行   = 输入链第 bot_d1+1 级
对 7 帧小图求"与参考实现逐像素零失配"的组合，并把**每个组合实际用到的行号**打出来，
便于排除"模型自己对不上"的可能。
"""
from __future__ import annotations

import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, ".")
import ref_region_fill as R  # noqa: E402


def build_stim():
    import gen_stim_region_fill as G
    F = G.small_frames()
    W, H = G.SW, G.SH
    arr = np.stack([R.bool_to_mask(m) for _, m in F])
    return R.frames_to_beats(arr, W, H), arr, W, H


def b(word, i):
    return (word >> i) & 1


def simulate(beats, W, H, rd_off, use_bot_d, lat, trace=False):
    """逐拍模型。

    记号：cycle c 的**组合**逻辑用的是"c−1 拍末装载"的寄存器值。
      x_grp = X(c)   —— 本拍要写的拍号 + 1
      r_x   = X(c)−1 —— 装配用的拍号
    行缓存读地址（cycle c−1 发出、此刻在链上）= X(c−1) + rd_off = r_x + rd_off
      chX[k] = 第 r_x + rd_off − k 组
    于是：
      当前组 X  = r_x      → k = rd_off
      左邻居    X−1        → k = rd_off + 1
      右邻居    X+1        → k = rd_off − 1（rd_off=0 时用"本拍新读值" new_rd）
    keep 只用于给链留够长度（模型不截断）。
    """
    BPL = W // 4
    BPF = BPL * H
    N = beats.shape[0]
    DEPTH = 8
    line1, line2 = {}, {}
    ch1 = [0] * DEPTH              # 第 c−1 拍末装载后的链（cycle c 用它）
    ch2 = [0] * DEPTH
    r_x = 0
    r_y = 0
    tuser1 = 0
    CH = 12
    vld = [0] * CH
    x_grp, y_pos = 0, 0
    inside = 0
    r_prev3 = 0
    r_prev_beat = [0, 0, 0, 0]
    out = []
    trows = []

    for c in range(N + 16):
        iv = c < N
        p = [int(v == R.WHITE) for v in beats[c]] if iv else [0, 0, 0, 0]
        win_valid = (r_y >= 2) and (r_x != 0) and (tuser1 == 0)

        kc = rd_off
        cur1 = ch1[kc] if 0 <= kc < DEPTH else 0
        left1 = ch1[kc + 1] if 0 <= kc + 1 < DEPTH else 0
        right1 = ch1[kc - 1] if kc - 1 >= 0 else None
        cur2 = ch2[kc] if 0 <= kc < DEPTH else 0
        left2 = ch2[kc + 1] if 0 <= kc + 1 < DEPTH else 0
        right2 = ch2[kc - 1] if kc - 1 >= 0 else None
        bot = list(p)                          # 本拍总线
        bot_use = list(r_prev_beat) if use_bot_d else bot

        cols_top = [b(left2, 3), b(cur2, 3), b(cur2, 2), b(cur2, 1), b(cur2, 0),
                    b(right2, 3) if right2 is not None else 0]
        cols_mid = [b(left1, 3), b(cur1, 3), b(cur1, 2), b(cur1, 1), b(cur1, 0),
                    b(right1, 3) if right1 is not None else 0]
        cols_bot = [ch1[0] if False else r_prev3, bot[0], bot[1], bot[2], bot[3], p[0]]
        cols_bot[0] = r_prev3
        if r_x == 0:
            cols_top[0] = cols_mid[0] = cols_bot[0] = 0
        if r_x == BPL - 1:
            cols_top[5] = cols_mid[5] = cols_bot[5] = 0

        e = [0] * 4
        if win_valid:
            for k in range(4):
                e[k] = 1 if any((cols_top[k], cols_top[k + 1], cols_top[k + 2],
                                 cols_mid[k], cols_mid[k + 1], cols_mid[k + 2],
                                 cols_bot[k], cols_bot[k + 1], cols_bot[k + 2])) else 0
        ins = [inside]
        for k in range(4):
            ins.append(ins[-1] ^ e[k])
        fill = [e[k] | ins[k] for k in range(4)]
        if vld[lat]:
            out.append([R.WHITE if f else R.BLACK for f in fill])
            trows.append((r_y - 2, r_y - 1, r_y))

        # ---- 本拍末装载 ----
        rd_addr = (x_grp + rd_off) % BPL
        new1 = line1.get(rd_addr, 0)
        new2 = line2.get(rd_addr, 0)
        if iv:
            line2[x_grp] = ch1[0]
            line1[x_grp] = (p[0] << 3) | (p[1] << 2) | (p[2] << 1) | p[3]
        ch1 = [new1] + ch1[:-1]
        ch2 = [new2] + ch2[:-1]
        vld = [iv] + vld[:-1]
        tl_now = 1 if (iv and (c % BPL == BPL - 1)) else 0
        tu_now = 1 if (iv and (c % BPF == 0)) else 0
        inside = 0 if (tl_now or tu_now) else (ins[4] if iv else inside)
        r_prev3 = p[3] if iv else r_prev3
        r_x, r_y = x_grp, y_pos
        tuser1 = tu_now
        if iv:
            if c % BPF == 0:
                x_grp, y_pos = (1 % BPL), 0
            elif x_grp == BPL - 1:
                x_grp, y_pos = 0, (0 if y_pos == H - 1 else y_pos + 1)
            else:
                x_grp += 1
    return np.array(out, dtype=np.uint32), trows


def main():
    beats, arr, W, H = build_stim()
    exp = R.frames_to_beats(R.ref_region_fill(arr, W, H), W, H)
    print("参考输出拍数 %d" % exp.shape[0])
    res = []
    for rd_off in (-1, 0, 1, 2):
        for lat in (2, 3, 4, 5, 6):
            out, _ = simulate(beats, W, H, rd_off, 0, lat)
            n = min(out.shape[0], exp.shape[0])
            bad = int(np.sum((out[:n] != exp[:n]).any(axis=1)))
            bad += abs(out.shape[0] - exp.shape[0])
            res.append((bad, rd_off, lat))
    res.sort()
    for r in res[:10]:
        print("  失配拍 %4d  rd_off=%+d lat=%d" % r)
    zero = [r for r in res if r[0] == 0]
    print("零失配配置数: %d" % len(zero))
    for z in zero[:8]:
        print("   OK rd_off=%+d lat=%d" % (z[1], z[2]))
    if zero:
        z = zero[0]
        out, trows = simulate(beats, W, H, z[1], 0, z[2], trace=True)
        print("最佳配置用到的行号（前 6 拍）:", trows[:6])


if __name__ == "__main__":
    main()
