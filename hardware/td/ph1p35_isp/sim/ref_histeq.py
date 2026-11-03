#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
ref_histeq.py —— 直方图均衡的**纯 Python/numpy 参考实现**（按规格写，不照抄 Verilog 结构）

供 check_histeq.py / 其它 checker import：`from ref_histeq import ref_histeq`

===============================================================================
一、规格（= 契约，逐条对应 src\\alg_histeq_96.v 文件头 §一）
===============================================================================
  1) 逐通道 256 bin 直方图 → 累积分布 CDF → 映射表 → 对**全部像素**查表。
  2) 统计抽样口径：每 4 个有效拍取 1 拍、且只取该拍的 pix0（行内最左像素）。
     对 IMG_WIDTH 是 16 的倍数的情况，抽到的就是每行第 0,16,32,... 列：
         SAMPLES_PER_FRAME = (W // 16) * H
     1280×720 → 80 * 720 = 57,600。
  3) 归一化常数（编译期常数，无运行期除法）：
         K = (255 * 65536) // SAMPLES_PER_FRAME        # 1280×720 → 290
         map[bin] = min(255, (cdf[bin] * K) >> 16)     # cdf 含当前 bin
     ⚠ floor 归一化的固有后果（**这是口径不是 bug**）：满直方图时
       cdf = 57600 ⇒ map = (57600*290)>>16 = 254 —— 最大映射值是 254 而不是 255。
  4) 帧边界滞后 1 帧（ping-pong）：第 f 帧用**第 f-1 帧**统计出来的表；
     第 0 帧没有可用表 ⇒ 输出 = 输入（恒等表 = 旁路）。
  5) 全同值帧的口径：帧内所有像素都是同一个值 v ⇒ 直方图只有 bin v 非零
     ⇒ cdf[b] = 0 (b < v)、= N (b >= v)
     ⇒ map[b] = 0 (b < v)、= 254 (b >= v)
     ⇒ **帧内所有像素（含等于 v 的那些）都映射成 254**，即"全变近白"，不是"全黑"、
       也不是"保持不变"。第 0 帧因为是恒等表，仍然是 v。绝不会出现 X/未定义值。
  6) 使能 I_en：只控制输出选择器，**不影响统计与制表**（关着也在统计）。
     en=0 的帧输出 = 输入（恒等），但该帧的直方图照样会用于**下一帧**的表。

===============================================================================
二、与 RTL 的关系
===============================================================================
  · 本文件只描述"应该是什么"，不描述"怎么算"：没有 RMW 流水、没有 ERAM/LUTRAM、
    没有相位计数器 —— 那些是实现细节，出现分歧时以本文件的规格为准。
  · 逐比特一致的保证：`>> 16` 与 RTL 的 `w_map_prod[23:16]` 等价，前提是
    cdf*K < 2^24（cdf <= N 且 K = floor(255*65536/N) ⇒ cdf*K <= 255*65536 < 2^24 ✓）。
    同值帧/满直方图这两种边界在 check_histeq.py 里都有专门断言。
"""
from __future__ import annotations

import numpy as np

# 抽样步长：每 4 拍取 1 拍（每拍 4 像素）、每拍取 pix0 ⇒ 每 16 列取 1 列
SAMPLE_STRIDE = 16
OFFICIAL_W, OFFICIAL_H = 1280, 720


def samples_per_frame(W: int, H: int) -> int:
    """一帧被统计的样本数。要求 W % 16 == 0（否则行内采样相位逐行漂移）。"""
    if W % SAMPLE_STRIDE != 0:
        raise ValueError("IMG_WIDTH 必须是 16 的倍数（BEATS_PER_LINE %% 4 == 0），收到 W=%d" % W)
    return (W // SAMPLE_STRIDE) * H


def k_const(W: int, H: int) -> int:
    """归一化常数 K = floor(255*65536 / 样本数)。1280×720 → 290。"""
    return (255 * 65536) // samples_per_frame(W, H)


def sample_index_blocks(W: int, H: int) -> np.ndarray:
    """每个像素所属样本的编号 j（int64, 形状 (H, W)）。

    抽样列是 x % 16 == 0；本函数把**同一 16 列块**都标成该块样本的编号，
    这样块内所有像素共用一个 j —— 造测试图时可以直接按 j 生成"块常数"图案，
    被抽到的那一列自然与块内其它列同值（规格只规定抽样列，块内同值是我们选图方便）。
    """
    bx = (np.arange(W, dtype=np.int64) // SAMPLE_STRIDE)[None, :]
    yy = np.arange(H, dtype=np.int64)[:, None]
    return yy * (W // SAMPLE_STRIDE) + bx


def build_hist(frame: np.ndarray) -> np.ndarray:
    """一帧的逐通道直方图，形状 (3, 256)，int64。frame: (H, W, 3) uint8。"""
    smp = frame[:, ::SAMPLE_STRIDE, :].reshape(-1, 3)
    hist = np.zeros((3, 256), dtype=np.int64)
    for c in range(3):
        hist[c] = np.bincount(smp[:, c], minlength=256)[:256]
    return hist


def build_cdf(hist: np.ndarray) -> np.ndarray:
    """累积分布（含当前 bin），形状 (3, 256)。"""
    return np.cumsum(hist.astype(np.int64), axis=1)


def build_map(hist: np.ndarray, W: int, H: int) -> np.ndarray:
    """由直方图造映射表，形状 (3, 256)，uint8。"""
    cdf = build_cdf(hist)
    m = (cdf * k_const(W, H)) >> 16
    return np.clip(m, 0, 255).astype(np.uint8)


def apply_map(frame: np.ndarray, m: np.ndarray) -> np.ndarray:
    """逐通道查表。frame: (H, W, 3) uint8；m: (3, 256)。"""
    out = np.empty_like(frame)
    for c in range(3):
        out[:, :, c] = m[c][frame[:, :, c]]
    return out


def ref_histeq(frames, W: int, H: int, en=None, lag: int = 1):
    """直方图均衡参考实现。

    参数
      frames : 序列，每帧 (H, W, 3) uint8（按显示顺序）
      W, H   : 图像尺寸（模块参数）
      en     : None（= 每帧都开）或长度等于帧数的 0/1 序列；en=0 的帧输出 = 输入
      lag    : 表滞后帧数，规格 = 1（第 f 帧用第 f-1 帧的直方图）
    返回
      (outs, info)
        outs : list[np.ndarray]，每帧输出 (H, W, 3) uint8
        info : dict，含 'hist'（每帧直方图）、'map'（每帧的**当前生效**表，None 表示恒等）、
               'K'、'samples_per_frame'
    """
    frames = [np.asarray(f, dtype=np.uint8) for f in frames]
    n = len(frames)
    for f in frames:
        if f.shape != (H, W, 3):
            raise ValueError("帧形状应为 (%d,%d,3)，收到 %s" % (H, W, f.shape))
    if en is None:
        en = [1] * n
    if len(en) != n:
        raise ValueError("en 长度必须等于帧数")
    if lag != 1:
        raise ValueError("本规格只定义 lag=1（第 f 帧用第 f-1 帧的表）")

    K = k_const(W, H)
    hists = [build_hist(f) for f in frames]
    maps = [build_map(h, W, H) for h in hists]

    outs = []
    used = []
    for f in range(n):
        if f - lag >= 0:
            m = maps[f - lag]
        else:
            m = None                       # 还没有表 ⇒ 恒等
        used.append(m)
        if en[f]:
            outs.append(apply_map(frames[f], m) if m is not None else frames[f].copy())
        else:
            outs.append(frames[f].copy())  # 关使能：逐比特等于输入
    info = {
        "K": K,
        "samples_per_frame": samples_per_frame(W, H),
        "hist": hists,
        "map": maps,
        "map_used": used,
    }
    return outs, info


def beats_of_frames(frames, W: int, H: int):
    """把帧序列打成 96 bit 拍序列（与 RTL/TB 的总线口径逐位一致）。

    一拍 = 行内相邻 4 像素；pix0（行内最左）在 [95:72]；每像素 {R,G,B}。
    返回 list[int]（每帧 BPL*H 拍，帧间无空拍）。行数必须是 4 的倍数行宽
    （W % 4 == 0；本模块还要求 W % 16 == 0）。
    """
    words = []
    for fr in frames:
        fr = np.asarray(fr, dtype=np.uint8)
        for y in range(H):
            row = fr[y].reshape(-1, 3)
            for x0 in range(0, W, 4):
                w = 0
                for k in range(4):
                    p = row[x0 + k]
                    w = (w << 24) | (int(p[0]) << 16) | (int(p[1]) << 8) | int(p[2])
                words.append(w)
    return words


def words_of_beats(beats):
    """把 96 bit 拍序列还原成 (N, 12) 的字节数组：列序 = [lane0R,lane0G,lane0B, lane1R,...]。"""
    b = np.asarray(beats, dtype=object)
    out = np.zeros((len(beats), 12), dtype=np.uint8)
    for i, w in enumerate(beats):
        w = int(w)
        for j in range(12):
            out[i, j] = (w >> (88 - 8 * j)) & 0xFF
    return out


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    W, H = OFFICIAL_W, OFFICIAL_H
    print("规格自检（1280x720）：")
    print("  SAMPLES_PER_FRAME = %d" % samples_per_frame(W, H))
    print("  K                 = %d" % k_const(W, H))
    # 满直方图：cdf = N ⇒ map 最大 254
    hist = np.zeros((3, 256), dtype=np.int64)
    hist[:, 0] = samples_per_frame(W, H)
    m = build_map(hist, W, H)
    print("  满直方图 map[0]   = %d（期望 254，floor 归一化的量化后果）" % m[0, 0])
    # 全同值 128
    hist = np.zeros((3, 256), dtype=np.int64)
    hist[:, 128] = samples_per_frame(W, H)
    m = build_map(hist, W, H)
    print("  全同值 128：map[127]=%d map[128]=%d map[255]=%d（期望 0/254/254）"
          % (m[0, 127], m[0, 128], m[0, 255]))
    # 均匀：每 bin 恰好 N/256 个样本 ⇒ 近恒等
    hist = np.zeros((3, 256), dtype=np.int64)
    hist[:, :] = samples_per_frame(W, H) // 256
    m = build_map(hist, W, H)
    d = int(np.max(np.abs(m[0].astype(int) - np.arange(256))))
    print("  均匀直方图 |map-b| 最大偏差 = %d（期望 <= 1）" % d)
