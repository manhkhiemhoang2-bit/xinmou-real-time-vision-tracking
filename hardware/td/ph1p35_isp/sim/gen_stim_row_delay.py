#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_row_delay.py —— 为 rgb_row_delay_96 生成 ModelSim 激励

编码原则：**每个像素值全局唯一**（pixel = 3 字节大整数，从 0 递增），
这样 O_tdata 与 I_tdata(迟 320 拍) 的比对是"值级别"的，任何错拍、错总线位域、
错字节序都会立刻暴露，不存在"凑巧相等"。

尺寸取真实值：IMG_WIDTH=1280 → 每行 320 拍（这才是 320 拍延迟的出处）。
每帧 3 行（本模块没有 IMG_HEIGHT 参数，行内拍号只按 320 循环），2 帧。

输出：
    stim_rd.hex   每行一个 96bit 拍数据（24 个十六进制位）
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

IMG_WIDTH = 1280
BPL = IMG_WIDTH // 4          # 320 拍/行
ROWS = 3                      # 每帧行数（本模块不关心帧长）
FRAMES = 2
NBEAT = BPL * ROWS * FRAMES   # 1920

START_CYC = 4                 # 必须与 tb_rgb_row_delay.v 一致
TAIL_CYC = 360


def build_beats():
    """第 i 个像素的值 = i（24 bit 大整数）⇒ 每拍 4 个唯一值，全部互不相同。"""
    beats = []
    p = 0
    for _ in range(NBEAT):
        word = 0
        for _k in range(4):
            word = (word << 24) | (p & 0xFFFFFF)
            p += 1
        beats.append(word)
    assert len(set(beats)) == NBEAT, "拍值必须两两不同"
    return beats


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    beats = build_beats()
    assert len(beats) == NBEAT, (len(beats), NBEAT)
    out = os.path.join(here, "stim_rd.hex")
    with open(out, "w", encoding="ascii") as fh:
        for w in beats:
            fh.write("%024x\n" % w)

    print("已生成 %s" % out)
    print("  每行 %d 拍 × %d 行 × %d 帧 = %d 拍" % (BPL, ROWS, FRAMES, NBEAT))
    print("  延迟 320 拍；比对从第 %d 拍起（= START_CYC %d + 320）"
          % (START_CYC + 320, START_CYC))
    print("  仿真总拍数约 %d" % (START_CYC + NBEAT + TAIL_CYC))
    print("  前 3 拍：")
    for i in range(3):
        print("    beat %d = %024x" % (i, beats[i]))


if __name__ == "__main__":
    main()
