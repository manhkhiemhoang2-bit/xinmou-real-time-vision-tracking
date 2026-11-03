#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_gray.py —— 为 gray_bt601_96 生成 ModelSim 激励

点算子没有"邻居"问题，所以不用唯一值图，改为**四个扫描面全覆盖**：
    每拍 4 个像素，正好一趟扫完四种情形：
        pix0 = (i, 0, 0)   只扫 R 通道
        pix1 = (0, i, 0)   只扫 G 通道
        pix2 = (0, 0, i)   只扫 B 通道
        pix3 = (i, i, i)   灰阶（R=G=B）
    i 从 0 到 255，256 拍扫完全部 256 个取值 × 4 种情形 = 1024 个测试向量。

第二帧用混合值，专门打"通道间进位/舍入"的边界：
    (255,255,255) (255,0,255) (0,255,255) (1,1,1) 这类极端组合。

输出：stim_gray.hex，每行一个 96bit 拍数据（24 个十六进制位）
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

BPL = 8              # 每行 8 拍（小图，只为让 tlast/tuser 有机会出现）
H = 36
FRAMES = 1
NBEAT = BPL * H * FRAMES     # 288 = 256 拍扫描 + 32 拍极端值


def pack(pixels):
    """pixels = [(R,G,B)] * 4 ；pix0 在最高位（S0-02 §2.2，最左）"""
    w = 0
    for (r, g, b) in pixels:
        w = (w << 24) | (r << 16) | (g << 8) | b
    return w


def build():
    beats = []
    # ---- 帧 0：四个扫描面 ----
    for v in range(256):                      # 256 拍，v 取遍 0..255
        beats.append(pack([(v, 0, 0), (0, v, 0), (0, 0, v), (v, v, v)]))
    # 补足剩下的拍：极端值
    extremes = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0),
                (0, 0, 255), (1, 0, 0), (0, 1, 0), (0, 0, 1),
                (255, 255, 0), (0, 255, 255), (255, 0, 255), (128, 128, 128),
                (254, 255, 255), (255, 254, 255), (255, 255, 254), (1, 1, 1),
                (127, 128, 129), (63, 64, 65), (191, 192, 193), (7, 8, 9),
                (250, 5, 128), (128, 5, 250), (5, 128, 250), (200, 100, 50),
                (50, 100, 200), (17, 34, 51), (85, 170, 255), (240, 15, 90),
                (90, 15, 240), (15, 240, 90), (123, 45, 67), (222, 111, 33)]
    for e in extremes:
        beats.append(pack([e, e, e, e]))
    while len(beats) < NBEAT:
        beats.append(0)
    return beats[:NBEAT]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    beats = build()
    out = os.path.join(here, "stim_gray.hex")
    with open(out, "w", encoding="ascii") as fh:
        for w in beats:
            fh.write("%024x\n" % w)
    print("已生成 %s" % out)
    print("  %d 拍，每行 %d 拍，%d 行" % (len(beats), BPL, H))
    print("  第 0 拍 = %024x  → 像素 (0,0,0) (0,0,0) (0,0,0) (0,0,0)" % beats[0])
    print("  第 1 拍 = %024x  → 像素 (1,0,0) (0,1,0) (0,0,1) (1,1,1)" % beats[1])
    print("  第 255 拍 = %024x  → v=255 的一组" % beats[255])


if __name__ == "__main__":
    main()
