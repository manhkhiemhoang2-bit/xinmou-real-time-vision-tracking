#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_top.py —— `alg_top` 集成验证的**图像 / 档位时序 / 激励**唯一定义源

被 tb_alg_top.v（通过 stim_top.hex）与 check_alg_top.py（直接 import）共用，
避免"激励"和"期望值"两边各写一遍。

图像 32x8（8 拍/行），共 10 帧，每帧内容基本相同，只有 M5 的红色目标块
**逐帧右移 2 列**：
    红块 = 行 3..6，列 4+2f .. 11+2f
这样 M5 档位画的是**上一帧**的 bbox（RTL 语义），与"本帧 bbox"位置不同
⇒ "画上一帧还是本帧"这条口径在测试里有鉴别力（否则两者永远重合、测不出来）。

R 通道 = 行号唯一编码 8+8y（红块内改成 G = 5y+2）：
    · 行号唯一 ⇒ 可以从 M3 的输出**反解出 src 到底来自哪一行**（判据 E）
    · 8+8y 最大 64，+EDGE_K(128) = 192 < 256 ⇒ 提亮后**不饱和**，反解不受影响
    · 红块里 R=230（+128 会饱和到 255），但 G=5y+2 仍然逐行唯一，反解照常可用
    · R 逐行差 8 ⇒ 灰度逐行差约 2.4，窗口有垂直梯度（Sobel 的 Gy 不为 0）

列图案（非红块区）见 COL_G / COL_B：平坦段、硬边、棋盘、强梯度都有，
保证 M2/M3/M4 的判决两头都能踩到。

输出：stim_top.hex（每行 24 个十六进制字符 = 1 个 96bit 原始彩色拍，共 NBEAT 行）
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# ---- 金标准 alg_ref.py 的位置（可用环境变量 ALG_REF_DIR 覆盖）----
for _d in (os.environ.get("ALG_REF_DIR", ""),
           r"C:\Users\29072\PycharmProjects\PythonProject8",
           os.path.dirname(os.path.abspath(__file__))):
    if _d and os.path.isfile(os.path.join(_d, "alg_ref.py")):
        if _d not in sys.path:
            sys.path.insert(0, _d)
        break
else:  # pragma: no cover
    raise SystemExit("找不到 alg_ref.py，请设 ALG_REF_DIR 指向金标准所在目录")

import numpy as np       # noqa: E402
import alg_ref as A      # noqa: E402

# ---------------------------------------------------------------------------
# 几何（必须与 tb_alg_top.v 的 localparam 一致）
# ---------------------------------------------------------------------------
W, H = 32, 8
BPL = W // 4                 # 8 拍/行
FRAMES = 10
BPF = BPL * H                # 64 拍/帧
NBEAT = BPF * FRAMES         # 640 拍

# ---------------------------------------------------------------------------
# DUT 参数（与 tb_alg_top.v 的 alg_top 例化一致）
# ---------------------------------------------------------------------------
TGT_COLOR = 0xFF0000
TGT_TOL = 40
# 颜色阈值框 = [tgt-tol, tgt+tol]，给 alg_ref.AlgPipeline 用
RLO, RHI = ((TGT_COLOR >> 16) & 0xFF) - TGT_TOL, ((TGT_COLOR >> 16) & 0xFF) + TGT_TOL
GLO, GHI = ((TGT_COLOR >> 8) & 0xFF) - TGT_TOL, ((TGT_COLOR >> 8) & 0xFF) + TGT_TOL
BLO, BHI = (TGT_COLOR & 0xFF) - TGT_TOL, (TGT_COLOR & 0xFF) + TGT_TOL
EDGE_K = 128
C_OFF = 0

# ---------------------------------------------------------------------------
# 档位时序（与 tb_alg_top.v 的 always @(*) 逐条对应）
#   frame 0..5 : 六档各一帧（M0..M5），每个帧边界换档
#   frame 6    : 帧内 bif=24 处把 I_mode_sel 从 3 改成 5 —— 本帧必须仍是 M3
#   frame 7    : M5（承接上一条：换档只发生在帧边界）
#   frame 8/9  : I_mode_set=0，靠按键脉冲走 r_mode_hold（7 帧内按一下 -> 1；8 帧内再按 -> 2）
# ---------------------------------------------------------------------------
MODE_SCHED = [0, 1, 2, 3, 4, 5, 3, 5, 1, 2]
MODE_SET_SCHED = [1] * 8 + [0, 0]
MODE_SEL_MIDF = 24           # frame 6 帧内改 I_mode_sel 的拍号
MODE_SEL_MIDV = 5
KEY_FRAMES = (7, 8)          # 这两帧内按键（每帧一次脉冲）
KEY_BIF, KEY_LEN = 20, 48    # 起始拍号 / 按住长度（> KEY_DIV=32 才产生 1 个脉冲）

# 行消隐长度（真实链路值）：每行行末 tvalid=0 的拍数。
# 必须与 tb_alg_top.v 的 `pause_len <= 5'd20` 一致；判定侧由 check_alg_top.py 的判据 I 用。
# 依据：官方 zhenghe.v:137-146 —— rd_valid 是 x_cnt 的函数、x_cnt 在非有效期清零，
# 所以每行都有一段 valid=0；这一段经 data128_96 / awb（纯寄存器延迟、无门控）到达 alg_top。
BLANK_LEN = 20

# 非红块区的列图案（G, B）；R = 8+8y 恒为行号编码
COL_G = np.array([90, 90, 90, 90,
                  30, 30, 30, 30,
                  200, 200, 200, 200,
                  60, 60, 60, 60,
                  255, 0, 255, 0,
                  128, 128, 128, 128,
                  240, 240, 240, 240,
                  20, 20, 20, 20], dtype=np.uint8)
COL_B = np.array([30, 30, 30, 30,
                  30, 30, 30, 30,
                  60, 60, 60, 60,
                  200, 200, 200, 200,
                  0, 255, 0, 255,
                  128, 128, 128, 128,
                  20, 20, 20, 20,
                  240, 240, 240, 240], dtype=np.uint8)


def red_block(f):
    """第 f 帧的红块范围（行 0..1、列 0..1 闭区间）。"""
    c0 = 4 + 2 * f
    return (3, 6, c0, c0 + 7)


def build_image(f):
    """第 f 帧的彩色测试图 (H, W, 3) uint8。"""
    img = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        img[y, :, 0] = 8 + 8 * y                 # R = 行号唯一编码
        img[y, :, 1] = COL_G
        img[y, :, 2] = COL_B
    r0, r1, c0, c1 = red_block(f)
    for y in range(r0, r1 + 1):
        img[y, c0:c1 + 1, 0] = 230               # 红块：|230-255|=25 <= 40 -> 命中
        img[y, c0:c1 + 1, 1] = 5 * y + 2         # G = 5y+2 <= 37 -> 命中，且逐行唯一
        img[y, c0:c1 + 1, 2] = 12
    return img


def build_images():
    return [build_image(f) for f in range(FRAMES)]


def frame_beats(img):
    """(H,W,3) -> (BPF, 2) uint64 的 96bit 拍流（行优先）。"""
    return A.frame_to_beats(img).reshape(BPF, 2)


def stim_beats():
    """10 帧连成一串。**帧间不留气泡**是对的：气泡由 tb_alg_top.v 按"每行行末"插
    （BLANK_LEN 拍），拍序本身不变 —— 这才是真实链路的形状（行消隐，不是帧间空洞）。
    注意 rgb_row_delay_96 现在与 win3x3_96 一样按 **I_tvalid 有效拍** 计数，所以
    行消隐对它是"停顿不可见"；改造前那条"rgb_row_delay 不按 tvalid 计数、
    插气泡会让 M3 的 src 与窗口错位"的注释已经作废（那正是气泡 bug 本身）。"""
    imgs = build_images()
    return np.concatenate([frame_beats(im) for im in imgs], axis=0)


def _write_hex(path, beats):
    with open(path, "w", encoding="ascii") as fh:
        for w in A.beats_to_hex(beats):
            fh.write(w + "\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    beats = stim_beats()
    assert beats.shape[0] == NBEAT, beats.shape
    _write_hex(os.path.join(here, "stim_top.hex"), beats)
    print("已生成 stim_top.hex")
    print("  W=%d H=%d 行 %d 拍 帧 %d 总拍 %d" % (W, H, BPL, FRAMES, NBEAT))
    print("  档位时序 MODE_SCHED=%s  I_mode_set=%s" % (MODE_SCHED, MODE_SET_SCHED))
    print("  颜色框 R[%d,%d] G[%d,%d] B[%d,%d]  EDGE_K=%d" %
          (RLO, RHI, GLO, GHI, BLO, BHI, EDGE_K))
    imgs = build_images()
    img0 = imgs[0]
    gy = A.gray_bt601(img0)
    print("  帧 0 灰度：")
    for r in range(H):
        print("    y=%d  %s" % (r, " ".join("%3d" % v for v in gy[r])))
    print("  帧 0 的 R 通道：%s" % " ".join("%3d" % v for v in img0[0, :, 0]))
    nz = 0
    for f in range(FRAMES):
        im = imgs[f]
        g = A.gray_bt601(im)
        nz += int((im[:, :, 0].astype(int) != g).sum() +
                  (im[:, :, 1].astype(int) != g).sum() +
                  (im[:, :, 2].astype(int) != g).sum())
    print("  RGB != 灰度 的通道数合计 = %d（>0 才能区分 src=彩色 / src=灰度）" % nz)
    # 行号唯一性自检（判据 E 的前提）
    for x in range(W):
        cols = [tuple(int(v) for v in imgs[0][y, x]) for y in range(H)]
        assert len(set(cols)) == H, "列 x=%d 的行值不唯一：%s" % (x, cols)
    print("  逐列行值唯一性（行号可反解）：PASS")


if __name__ == "__main__":
    main()
