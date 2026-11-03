#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_color_detect.py —— 为 alg_color_detect_96 生成 ModelSim 激励

图像 32×8（每行 8 拍）× 5 帧，每帧刻意安排若干"该抓得住 / 不该命中"的像素：

  背景：R=(y<<5)|x 唯一、G=255-R、B=255（B=255 永远出不了容差框 ⇒ 背景必然不命中；
        且 (R,G) 逐像素唯一 ⇒ 任何"画错位置"都能靠值比对看出来）
  目标色 (200,40,60)，容差 40 ⇒ 命中判据 R∈[160,240] & G∈[0,80] & B∈[20,100]

  F0  实心块 A（行 2..5，列 8..15，精确目标色）
  F1  块 B（行 3..6，列 4..11）+ 五处边界/陷阱：
        · 行 2 列 0..3   精确色   —— 掩蔽列（x<4），不该进统计
        · 行 1 列 6..9   精确色   —— 掩蔽行（y<2），不该进统计
        · 行 2 列 20..23 (160,40,60) —— R 差刚好 = 40，判据是 <= ⇒ 必须命中
        · 行 2 列 24..27 (159,40,60) —— R 差 = 41 ⇒ 必须不命中
        · 行 5 列 31     精确色   —— 行末孤立点，右邻居在图外 ⇒ 表决必须削掉它
        · 行 6 列 0      精确色   —— 掩蔽 + 下一行首像素：给"行末右邻居串行"下套
        · 行 6 列 30..31 精确色   —— 行末成对，右邻居补 0 后仍应双双存活
  F2  全背景（无命中）—— 统计必须为"无效 bbox"，本帧输出 = 原图（不画框）
  F3  G/B 边界 + 跨拍邻居：
        · 行 2..3 列 6..13  (200,80,60)  —— G 差 = 40 ⇒ 命中
        · 行 5..6 列 18..25 (200,40,100) —— B 差 = 40 ⇒ 命中
        · 行 4..5 列 6..9   (200,81,60)  —— G 差 = 41 ⇒ 不命中
        · 行 4..5 列 26..29 (200,40,101) —— B 差 = 41 ⇒ 不命中
        · 行 7 列 27..28    精确色        —— 跨拍对（27 是上一拍 pix3、28 是下一拍 pix0）
  F4  小块 D（行 2..3，列 4..7）—— 用来观测 F3 的统计与本帧画 F3 的框

打包用 alg_ref.frame_to_beats / beats_to_hex（金标准自己的位序实现），
避免"激励位序"和"校验位序"两边各写一遍、一起错。

输出：stim_cd.hex
"""
from __future__ import annotations
import sys, os

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, r"C:\Users\29072\PycharmProjects\PythonProject8")
import alg_ref                                            # noqa: E402

W, H = 32, 8
BPL = W // 4                                              # 8 拍/行
FRAMES = 5
NBEAT = BPL * H * FRAMES                                  # 320

TGT = (200, 40, 60)                                       # tb 里的 I_tgt_color
TOL = 40                                                  # tb 里的 I_tgt_tol

EXACT = (200, 40, 60)


def bkg(y, x):
    v = (y << 5) | x
    return (v, 255 - v, 255)


def fill(img, r0, r1, c0, c1, rgb):
    img[r0:r1 + 1, c0:c1 + 1] = rgb


def build_frames():
    """返回 FRAMES 个 (H, W, 3) uint8 帧。"""
    fr = []

    # ---- F0：实心块 A ----
    a = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        for x in range(W):
            a[y, x] = bkg(y, x)
    fill(a, 2, 5, 8, 15, EXACT)
    fr.append(a)

    # ---- F1：块 B + 边界/陷阱 ----
    b = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        for x in range(W):
            b[y, x] = bkg(y, x)
    fill(b, 3, 6, 4, 11, EXACT)                # 块 B
    fill(b, 2, 2, 0, 3, EXACT)                 # 掩蔽列
    fill(b, 1, 1, 6, 9, EXACT)                 # 掩蔽行
    fill(b, 2, 2, 20, 23, (160, 40, 60))       # R 边界 = 40 → 命中
    fill(b, 2, 2, 24, 27, (159, 40, 60))       # R 越界 = 41 → 不命中
    b[5, 31] = EXACT                           # 行末孤立点（右邻居在图外）
    b[6, 0] = EXACT                            # 下一行首像素（行末串行陷阱）
    fill(b, 6, 6, 30, 31, EXACT)               # 行末成对
    fr.append(b)

    # ---- F2：全背景 ----
    c = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        for x in range(W):
            c[y, x] = bkg(y, x)
    fr.append(c)

    # ---- F3：G/B 边界 + 跨拍对 ----
    d = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        for x in range(W):
            d[y, x] = bkg(y, x)
    fill(d, 2, 3, 6, 13, (200, 80, 60))        # G 差 = 40 → 命中
    fill(d, 5, 6, 18, 25, (200, 40, 100))      # B 差 = 40 → 命中
    fill(d, 4, 5, 6, 9, (200, 81, 60))         # G 差 = 41 → 不命中
    fill(d, 4, 5, 26, 29, (200, 40, 101))      # B 差 = 41 → 不命中
    fill(d, 7, 7, 27, 28, EXACT)               # 跨拍对
    fr.append(d)

    # ---- F4：小块 D ----
    e = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        for x in range(W):
            e[y, x] = bkg(y, x)
    fill(e, 2, 3, 4, 7, EXACT)
    fr.append(e)

    return fr


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    frames = build_frames()
    assert len(frames) == FRAMES
    beats = []
    for img in frames:
        beats.append(alg_ref.frame_to_beats(img))          # (H, BPL, 2)
    flat = np.concatenate(beats, axis=0).reshape(-1, 2)
    assert flat.shape[0] == NBEAT, flat.shape
    hexs = alg_ref.beats_to_hex(flat)
    out = os.path.join(here, "stim_cd.hex")
    with open(out, "w", encoding="ascii") as fh:
        for hstr in hexs:
            fh.write("%s\n" % hstr)

    print("已生成 %s" % out)
    print("  %dx%d，每行 %d 拍，%d 帧，共 %d 拍" % (W, H, BPL, FRAMES, NBEAT))
    print("  目标色 %s 容差 %d（tb 的 I_tgt_color=24'h%02X%02X%02X, I_tgt_tol=%d）"
          % (TGT, TOL, TGT[0], TGT[1], TGT[2], TOL))
    print("  第 0 帧命中像素数（金标准）：%d" % _count(frames[0]))
    for i, img in enumerate(frames):
        print("    F%d 命中像素（未掩蔽）：%d" % (i, _count(img)))


def _count(img):
    rlo, rhi = max(0, TGT[0] - TOL), min(255, TGT[0] + TOL)
    glo, ghi = max(0, TGT[1] - TOL), min(255, TGT[1] + TOL)
    blo, bhi = max(0, TGT[2] - TOL), min(255, TGT[2] + TOL)
    hit = alg_ref.target_hit(img, rlo, rhi, glo, ghi, blo, bhi)
    hit = alg_ref.hit_vote(hit) & alg_ref.window_valid_mask(H, W, 4, 2)
    return int(hit.sum())


if __name__ == "__main__":
    main()
