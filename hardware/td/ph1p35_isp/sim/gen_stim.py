#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim.py —— 为 win3x3_96 生成 ModelSim 激励

唯一值图设计（这是本次验证的关键，不能再用有混叠的编码）：
    gray[y][x] = (y << 5) | x        W=32, H=8
    x 占低 5 位、y 占高 3 位，取值范围 0..255（正好 8 bit）
    => 全图 256 个像素，灰度样本两两互不相同，**严格单射，零混叠**

所以从任意一个观察到的字节值都能唯一反解出源像素的 (y, x)。
若反解失败或对不上期望坐标，就是几何真错了 —— 没有第二种解释。

输出：
    stim.hex   每行一个 96bit 拍数据（24 个十六进制位）
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

W, H = 32, 8
BPL = W // 4                 # 每行拍数 = 8
FRAMES = 2
NBEAT = BPL * H * FRAMES     # 8 * 8 * 2 = 128

assert W == 32 and H == 8, "唯一值编码要求 W=32,H=8（y 3 位 + x 5 位 = 8 位）"
assert (H - 1) * W + (W - 1) <= 255, "编码溢出 8 bit"


def gray_at(y: int, x: int) -> int:
    """唯一值图的灰度样本；图外返回 None（由 testbench/校验器按 0 补边处理）。"""
    if 0 <= y < H and 0 <= x < W:
        return (y << 5) | x
    return None


def build_beats():
    beats = []
    for f in range(FRAMES):
        for y in range(H):
            for xg in range(BPL):
                pix = []
                for k in range(4):
                    g = gray_at(y, 4 * xg + k)
                    assert g is not None
                    pix.append(g)
                # 96bit：pix0 在最高位（S0-02 §2.1，最左）
                word = 0
                for k, g in enumerate(pix):
                    # 每个像素 RGB888 都填同一个灰度值 ⇒ 高字节 = 灰度样本
                    px = (g << 16) | (g << 8) | g
                    word = (word << 24) | px
                beats.append(word)
    return beats


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    beats = build_beats()
    assert len(beats) == NBEAT, (len(beats), NBEAT)
    out = os.path.join(here, "stim.hex")
    with open(out, "w", encoding="ascii") as fh:
        for w in beats:
            fh.write("%024x\n" % w)

    print("已生成 %s" % out)
    print("  W=%d H=%d 每行 %d 拍 帧数 %d 总拍数 %d" % (W, H, BPL, FRAMES, NBEAT))
    print("  唯一值编码 gray=(y<<5)|x，取值 %d..%d，两两互不相同"
          % (min((y << 5) | x for y in range(H) for x in range(W)),
             max((y << 5) | x for y in range(H) for x in range(W))))
    print("  前 3 拍：")
    for i in range(3):
        print("    beat %d = %024x" % (i, beats[i]))


if __name__ == "__main__":
    main()
