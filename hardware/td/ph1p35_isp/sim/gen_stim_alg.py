#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_alg.py —— 为 M2/M3/M4 三个窗口算子生成 ModelSim 激励

与 win3x3 的 gen_stim.py（唯一值图）不同，这里的目的**不是**几何反解，
而是**把三个算子的每一个判决边界都踩到**，因为后面要做变异自证：
改错一条系数/一个比较符，必须至少有一个像素能把它暴露出来。

图像是**彩色的**（32x8），刻意让 RGB != 灰度：
  · 窗口灰度走 win3x3_96 的"每像素取高字节"约定（S1_RTL_README §4.1）→
    所以喂给 win3x3 的是 gray_bt601 结果的 {Y,Y,Y}；
  · M3 的提亮源 src 走**原始彩色通路**（第 y-1 行的 RGB888）→ 所以另出一份
    原始 RGB 的拍流给 TB，TB 自己延迟一行当 I_rgb_center 的中心行。
  两条通路数值不同 ⇒ "src 取错成灰度" 这类错误会被抓住。

图像内容（每行一个目的）：
  y=0  R=G=B 阶梯 8   横向强梯度 → Sobel gx
  y=1  R=G=B 反阶梯   → Sobel 反号（验 |gx| 的取绝对）
  y=2  R=80 G=110 B=140 恒定（灰度 = 104 恒定）→ 3x3 邻域灰度全同，
       均值恰等于中心值 ⇒ M2 的 `>` / `>=` 分水岭；同时 RGB != 灰度
  y=3  同上（中段 x=4..27），两侧 R=G=B 阶梯
  y=4  同上（中段 x=4..27），两侧 R=G=B 阶梯
       ⇒ y=2/3/4 中段三行同色 ⇒ 输出行 3/4 出现**整块平坦的 3x3 邻域**，
         而且这几行的 RGB 与灰度不同 ⇒ "M3 的 src 取错成灰度" 会被抓住
  y=5  左半 (150,200,40) / 右半 (0,0,0) 硬边
       → Sobel 满量程 + M3 彩色 src 提亮（三通道两个饱和一个不饱和）
  y=6  R=G=B 0/255 棋盘 → 高频，M4 平滑的动态范围
  y=7  彩色渐变 R≠G≠B   → 窗口底行也是彩色的
  y=5/6/7 的 x=24..31 一起挖成**全黑块**：
       ⇒ 输出行 7 的 x_grp=7 出现"整块 3x3 全 0"的窗口（S=0 → TH=0，mag=0），
         把 M3 的 `mag >= TH*4` 在 **mag == TH == 0** 这个真实像素上踩到
         （`>=` 出提亮、`>` 出原值），同时也是 M2 全黑窗口的一例

输出（都写在脚本同目录）：
  stim_alg.hex   每行 24 个十六进制位 = 96bit 灰度拍（每像素 {Y,Y,Y}）→ 喂 win3x3_96
  rgb_alg.hex    每行 24 个十六进制位 = 96bit RGB 拍（原始彩色图）  → 喂 TB 的行延迟
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# ---- 金标准 alg_ref.py 的位置（可用环境变量 ALG_REF_DIR 覆盖）----
_GOLD_DIRS = [
    os.environ.get("ALG_REF_DIR", ""),
    r"C:\Users\29072\PycharmProjects\PythonProject8",
]
for _d in _GOLD_DIRS:
    if _d and os.path.isfile(os.path.join(_d, "alg_ref.py")):
        if _d not in sys.path:
            sys.path.insert(0, _d)
        break
else:  # pragma: no cover
    raise SystemExit("找不到 alg_ref.py，请设 ALG_REF_DIR 指向金标准所在目录")

import numpy as np
import alg_ref as A

# ---------------------------------------------------------------------------
# 图像与拍流几何（与 tb_alg_ops.v 的 localparam 必须一致）
# ---------------------------------------------------------------------------
W, H = 32, 8
BPL = W // 4                 # 8 拍/行
FRAMES = 3                   # 跑 3 帧，只比第 3 帧（行缓存稳态纪律）
NBEAT = BPL * H * FRAMES     # 192 拍


def build_image():
    """合成彩色测试图 (H, W, 3) uint8。设计依据见文件头注释。"""
    img = np.zeros((H, W, 3), dtype=np.uint8)
    x = np.arange(W)
    g = np.zeros((H, W), dtype=np.int32)

    g[0] = (x * 8) & 0xFF                       # 阶梯升
    g[1] = 255 - ((x * 8) & 0xFF)               # 阶梯降
    g[2] = 104                                  # 恒定（RGB=(80,110,140) → 灰度 104）
    mid = (x >= 4) & (x <= 27)
    g[3] = np.where(mid, 104, (x * 16) & 0xFF)
    g[4] = np.where(mid, 104, (x * 24) & 0xFF)
    g[5] = np.where(x < 16, 166, 0)             # 硬边（左半 RGB=(150,200,40) → 灰度 166）
    g[6] = np.where((x & 1) == 1, 255, 0)       # 棋盘
    g[6, 24:] = 0                               #   末 8 列挖黑（与 y=5/7 一起造全黑 3x3 块）
    g[7] = np.zeros(W, dtype=np.int32)          # 下面单独填彩色

    img[:, :, 0] = g
    img[:, :, 1] = g
    img[:, :, 2] = g

    # y=2：整行恒定彩色（灰度 = 104 恒定，但 RGB 互不相同）
    img[2, :, 0], img[2, :, 1], img[2, :, 2] = 80, 110, 140
    # y=3 / y=4：中段与 y=2 同色（造出平坦 3x3 邻域），两侧回到 R=G=B
    for yy in (3, 4):
        img[yy, mid, 0], img[yy, mid, 1], img[yy, mid, 2] = 80, 110, 140
    # y=5：左半彩色 + 右半黑（硬边，且提亮源是彩色）
    img[5, :16, 0], img[5, :16, 1], img[5, :16, 2] = 150, 200, 40
    # y=7：彩色渐变（R/G/B 互不相同），末 8 列留黑（配合 y=5/6 造全黑 3x3 块）
    img[7, :24, 0] = (x[:24] * 7 + 20) & 0xFF
    img[7, :24, 1] = (200 - x[:24] * 5) & 0xFF
    img[7, :24, 2] = 60 + ((x[:24] * 3) & 0x3F)
    return img


def gray_beats(img):
    """(H,W,3) → NBEAT 个 96bit 灰度拍：每像素 {Y,Y,Y}（win3x3 取高字节 = Y）。"""
    y = A.gray_bt601(img)                      # (H,W) uint8
    gray_img = np.repeat(y[:, :, None], 3, axis=2).astype(np.uint8)
    beats = A.frame_to_beats(gray_img).reshape(H * BPL, 2)
    return np.tile(beats, (FRAMES, 1))         # 同一张图连喂 FRAMES 帧


def rgb_beats(img):
    """(H,W,3) → NBEAT 个 96bit RGB 拍（原始彩色图，给 TB 做行延迟）。"""
    beats = A.frame_to_beats(img).reshape(H * BPL, 2)
    return np.tile(beats, (FRAMES, 1))


def gray_frame(img):
    """帧级灰度图 (H,W)，供校验器用（与喂进 RTL 的灰度完全同源）。"""
    return A.gray_bt601(img).astype(np.int32)


def _write_hex(path, beats):
    with open(path, "w", encoding="ascii") as fh:
        for w in A.beats_to_hex(beats):
            fh.write(w + "\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    img = build_image()
    gb, rb = gray_beats(img), rgb_beats(img)
    assert gb.shape[0] == NBEAT and rb.shape[0] == NBEAT, (gb.shape, rb.shape)
    _write_hex(os.path.join(here, "stim_alg.hex"), gb)
    _write_hex(os.path.join(here, "rgb_alg.hex"), rb)

    gy = gray_frame(img)
    print("已生成 stim_alg.hex / rgb_alg.hex")
    print("  W=%d H=%d 每行 %d 拍 帧数 %d 总拍数 %d" % (W, H, BPL, FRAMES, NBEAT))
    print("  灰度取值 %d..%d；RGB 与灰度不同的像素数 = %d"
          % (gy.min(), gy.max(),
             int((img[:, :, 0].astype(int) != gy).sum()
                 + (img[:, :, 1].astype(int) != gy).sum()
                 + (img[:, :, 2].astype(int) != gy).sum())))
    print("  灰度图：")
    for r in range(H):
        print("    y=%d  %s" % (r, " ".join("%3d" % v for v in gy[r])))
    print("  y=7 的 R 通道：%s" % " ".join("%3d" % v for v in img[7, :, 0]))


if __name__ == "__main__":
    main()
