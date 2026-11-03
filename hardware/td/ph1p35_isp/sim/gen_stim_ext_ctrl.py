# -*- coding: utf-8 -*-
"""gen_stim_ext_ctrl.py —— 生成 tb_ext_ctrl 的帧激励 stim_ext.hex

记录宽度 96bit（每行 24 个 hex 字符，一个帧一条）：
    [95:64] pix_count
    [63:53] bbox_x0
    [52:42] bbox_x1
    [41:31] bbox_y0
    [30:20] bbox_y1
    [19]    bbox_valid
    [18:0]  保留（0）

坐标口径：与 alg_top / alg_color_detect_96 一致 —— **像素列 0..1279 / 像素行 0..719**
（该模块内部 w_x_base = {r_x_d1, 2'b00}，已经乘过 4）。

本文件同时被 check_ext_ctrl.py import，用作"规格期望象限"的唯一来源：
checker 不读 RTL，只按 build_frames() 的表 + 分界规则算期望。
"""
import sys

sys.stdout.reconfigure(encoding="utf-8")

IMG_W = 1280
IMG_H = 720
X_MID = IMG_W // 2          # 640
Y_MID = IMG_H // 2          # 360

NF = 80                     # 帧数（必须与 tb_ext_ctrl.v 的 NF 一致）
P = 24000                   # 每帧周期数（必须与 tb 一致）
SETUP = 8                   # 帧同步脉冲前，真实 bbox 提前建立的拍数
MID_RST_FRAME = 56          # 中途复位所在帧
MID_RST_P0 = 100            # 中途复位在帧内的起始拍
MID_RST_LEN = 4

# 非建立窗口期间挂在输入总线上的"干扰值"：合法、有目标、属于左上象限。
# 若实现漏掉帧锁存（直接吃实时 bbox），LED 会在帧中间显示成 0001 → 被抓。
DIST = dict(x0=100, x1=300, y0=50, y1=150, valid=1, pc=5000)
D_X0, D_X1, D_Y0, D_Y1, D_PC = DIST["x0"], DIST["x1"], DIST["y0"], DIST["y1"], DIST["pc"]

# alg_top 复位/无目标时的空 bbox 哨兵（min > max）
SENT = dict(x0=0x7FF, x1=0, y0=0x7FF, y1=0, valid=0, pc=0)


def F(x0, x1, y0, y1, valid=1, pc=5000):
    return dict(x0=x0, x1=x1, y0=y0, y1=y1, valid=valid, pc=pc)


def quad_of(fr):
    """规格期望象限：返回 0..3，或 None 表示"无目标"。"""
    if not fr["valid"] or fr["pc"] < 1:      # MIN_PIX 默认 1
        return None
    cx = (fr["x0"] + fr["x1"]) >> 1          # 中心列，向下取整
    cy = (fr["y0"] + fr["y1"]) >> 1          # 中心行，向下取整
    return (1 if cx >= X_MID else 0) | (2 if cy >= Y_MID else 0)


def build_frames():
    fr = []
    # ---- A 段 0..13：四象限 / 分界线 / 无目标 ----
    fr.append(F(100, 300, 50, 150, 1, 5000))      # 0  左上 Q0
    fr.append(F(900, 1100, 50, 150, 1, 5000))     # 1  右上 Q1
    fr.append(F(100, 300, 500, 600, 1, 5000))     # 2  左下 Q2
    fr.append(F(900, 1100, 500, 600, 1, 5000))    # 3  右下 Q3
    fr.append(F(600, 680, 320, 400, 1, 9))        # 4  中心正好 (640,360) → 右下 Q3
    fr.append(F(600, 680, 100, 200, 1, 9))        # 5  中心正好 (640,150) → 右上 Q1
    fr.append(F(100, 200, 320, 400, 1, 9))        # 6  中心正好 (150,360) → 左下 Q2
    fr.append(F(599, 679, 319, 399, 1, 9))        # 7  中心 (639,359)   → 左上 Q0
    fr.append(F(600, 681, 320, 401, 1, 9))        # 8  求和 1281/721 → 中心仍 (640,360) → Q3
    fr.append(dict(SENT))                          # 9  无目标：哨兵
    fr.append(F(100, 300, 50, 150, 1, 0))         # 10 无目标：valid=1 但 pc=0（MIN_PIX 门限）
    fr.append(F(100, 300, 50, 150, 0, 12345))     # 11 无目标：pc 很大但 valid=0
    fr.append(F(1000, 1200, 600, 700, 1, 1))      # 12 有目标且 pc 刚好 = MIN_PIX → Q3
    fr.append(F(2047, 2047, 2047, 2047, 0, 0))    # 13 无目标：哨兵变体，中心 (2047,2047)
                                                  #    若漏掉 r_val 门控 → LED3 亮 → 被抓
    # ---- B 段 14..55：连续 42 帧有目标（Q3）—— 蜂鸣节流间隔的观测窗口 ----
    for _ in range(14, 56):
        fr.append(F(900, 1100, 500, 600, 1, 5000))
    # ---- C 段 56..79 ----
    fr.append(F(900, 1100, 50, 150, 1, 5000))     # 56 中途复位发生在这一帧 pos=100（复位后有目标）
    fr.append(F(100, 300, 500, 600, 1, 5000))     # 57 复位后象限恢复 Q2
    fr.append(F(900, 1100, 500, 600, 1, 5000))    # 58 Q3
    fr.append(F(100, 300, 50, 150, 1, 5000))      # 59 Q0
    for _ in range(60, 78):                        # 60..77 连续有目标 Q3
        fr.append(F(900, 1100, 500, 600, 1, 5000))
    fr.append(dict(SENT))                          # 78 无目标 → beep3 途中立刻静音
    fr.append(dict(SENT))                          # 79 无目标
    assert len(fr) == NF, "帧数 %d != NF %d" % (len(fr), NF)
    return fr


def pack(fr):
    return ((fr["pc"] & 0xFFFFFFFF) << 64) | \
           ((fr["x0"] & 0x7FF) << 53) | \
           ((fr["x1"] & 0x7FF) << 42) | \
           ((fr["y0"] & 0x7FF) << 31) | \
           ((fr["y1"] & 0x7FF) << 20) | \
           ((fr["valid"] & 1) << 19)


def write_hex(path):
    fr = build_frames()
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for r in fr:
            f.write("%024x\n" % pack(r))
    return fr


if __name__ == "__main__":
    import os
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stim_ext.hex")
    frames = write_hex(out)
    print("已写 %s（%d 帧）" % (out, len(frames)))
    names = ["左上", "右上", "左下", "右下"]
    for i, r in enumerate(frames):
        q = quad_of(r)
        print("帧 %2d  valid=%d pc=%6d bbox=(%4d,%4d)-(%4d,%4d)  期望=%s"
              % (i, r["valid"], r["pc"], r["x0"], r["y0"], r["x1"], r["y1"],
                 (names[q] + " LED%d" % q) if q is not None else "无目标 全灭"))
