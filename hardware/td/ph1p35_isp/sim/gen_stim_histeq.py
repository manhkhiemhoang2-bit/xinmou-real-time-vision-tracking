#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_histeq.py —— 为 tb_histeq.v 生成激励 + 场景清单（histeq_scen.json）

设计原则（照本项目惯例）：
  · 每帧的**像素内容**由 Python 唯一确定地造出来（图案函数），TB 只负责"什么时候送"，
    所以气泡/消隐/使能这些都是 TB 的事，与数据无关 ⇒ 判据不需要建模时序。
  · 场景清单 JSON 同时被 run_histeq.py（生成 vsim 命令行）和 check_histeq.py（判据）读取，
    避免"TB 参数"与"判据口径"两处各写一遍。
  · "uniq" 图案的每个像素值全局唯一 ⇒ 96bit 逐位比对时任何错拍/错字节序/错 lane 都会暴露，
    不存在"凑巧相等"。

输出：
    stim_he_<场景>.hex        每行一个 96bit 拍（24 个十六进制位）
    histeq_scen.json          场景清单
用法：
    python gen_stim_histeq.py            # 生成全部场景
    python gen_stim_histeq.py --list     # 只打印清单
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from ref_histeq import sample_index_blocks, samples_per_frame, k_const  # noqa: E402

# =============================================================================
# 一、图案库： pattern(frame_idx, W, H) -> (H, W, 3) uint8
#     j  = 每个像素所属"16 列块"的样本编号（同块同值，被抽样那一列与块同值）
#     X,Y = 像素坐标网格
# =============================================================================
def _grids(W, H):
    j = sample_index_blocks(W, H)
    X = np.arange(W, dtype=np.int64)[None, :].repeat(H, axis=0)
    Y = np.arange(H, dtype=np.int64)[:, None].repeat(W, axis=1)
    return j, X, Y


def _mk(r, g, b):
    out = np.zeros(r.shape + (3,), dtype=np.uint8)
    out[:, :, 0] = np.clip(r, 0, 255).astype(np.uint8)
    out[:, :, 1] = np.clip(g, 0, 255).astype(np.uint8)
    out[:, :, 2] = np.clip(b, 0, 255).astype(np.uint8)
    return out


def pat_lowc(f, W, H):
    """低对比度：三通道都只在 60..100，但相位互不相同（抓通道串位）。"""
    j, _, _ = _grids(W, H)
    return _mk(60 + (j % 41), 60 + ((j * 7) % 41), 60 + ((j * 13) % 41))


def pat_highkey(f, W, H):
    """高调：亮部为主，三个通道分布形状不同。"""
    j, _, _ = _grids(W, H)
    return _mk(180 + (j % 60), 200 - (j % 50), 150 + ((j * 3) % 70))


def pat_const(f, W, H):
    """整帧常数（三通道互不相同）：CDF 只有最后一级跳变。"""
    j, _, _ = _grids(W, H)
    return _mk(0 * j + 200, 0 * j + 30, 0 * j + 120)


def pat_const128(f, W, H):
    """整帧全 128（题目点名的场景）。"""
    j, _, _ = _grids(W, H)
    return _mk(0 * j + 128, 0 * j + 128, 0 * j + 128)


def pat_dark(f, W, H):
    """暗部窄分布 + 三通道不同。"""
    j, _, _ = _grids(W, H)
    return _mk(j % 64, (j * 5) % 32, 255 - (j % 48))


def pat_uniform(f, W, H):
    """抽样直方图**近似均匀**：R/G/B 分别用 j、3j、5j（对 256 互素 ⇒ 均匀）。"""
    j, _, _ = _grids(W, H)
    return _mk(j % 256, (j * 3) % 256, (j * 5) % 256)


def pat_uniq(f, W, H):
    """每像素值全局唯一（帧号也编进去）⇒ 逐位比对最灵敏。"""
    j, X, Y = _grids(W, H)
    p = (f * W * H + Y * W + X) & 0xFFFFFF
    return _mk((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF)


def pat_grad(f, W, H):
    """真实尺寸用：有结构的低中对比度渐变（块状 + 行向渐变）。"""
    j, X, Y = _grids(W, H)
    bb = (X * 32) // W
    cc = (Y * 16) // H
    return _mk(64 + bb * 4 + (cc % 4), 128 - cc * 4 + (bb % 8), 32 + cc * 8 + (bb % 16))


def pat_grad2(f, W, H):
    """第二帧：轴向对调 + 反向斜坡，与第 1 帧分布明显不同（ping-pong 才能显形）。"""
    j, X, Y = _grids(W, H)
    bb = (Y * 32) // H
    cc = (X * 16) // W
    return _mk(200 - bb * 4 - (cc % 3), 40 + cc * 10 + (bb % 6), 160 - cc * 6 + (bb % 9))


PATTERNS = {
    "lowc": pat_lowc,
    "highkey": pat_highkey,
    "const": pat_const,
    "const128": pat_const128,
    "dark": pat_dark,
    "uniform": pat_uniform,
    "uniq": pat_uniq,
    "grad": pat_grad,
    "grad2": pat_grad2,
}


# =============================================================================
# 二、场景清单
#     en_mask：bit k = 第 k 帧的 I_en（<=8 帧）
#     contract：1 = 满足"帧末有效拍 → 下一帧 tuser ≥ 1700 拍"的接口合同（判据做逐像素比对）
#               0 = 故意违约（只做结构性判据，见 check_histeq.py）
# =============================================================================
SCENARIOS = [
    dict(name="lowc",     W=64,   H=8,   frames=4,
         patterns=["lowc"] * 4, gap=3200, lgap=0,  bub_period=0, bub_len=0,
         en_mask=0xF, dump_all=1, head=0, tail=0, contract=1,
         why="低对比度输入 → 均衡后铺开到 0..254"),

    dict(name="uniform",  W=256,  H=32,  frames=3,
         patterns=["uniform"] * 3, gap=3200, lgap=0, bub_period=0, bub_len=0,
         en_mask=0x7, dump_all=1, head=0, tail=0, contract=1,
         why="已经是均匀分布 → 映射应当接近恒等（|map-b|<=1）"),

    dict(name="const",    W=64,   H=8,   frames=3,
         patterns=["const128"] * 3, gap=3200, lgap=0, bub_period=0, bub_len=0,
         en_mask=0x7, dump_all=1, head=0, tail=0, contract=1,
         why="全同值帧 128 → 第 0 帧 128、其后 254（口径见 ref_histeq.py 头部 §一.5）"),

    dict(name="bypass",   W=64,   H=8,   frames=3,
         patterns=["uniq"] * 3, gap=3200, lgap=0, bub_period=0, bub_len=0,
         en_mask=0x0, dump_all=1, head=0, tail=0, contract=1,
         why="I_en=0 全程 → O_tdata 逐比特 = I_tdata 延迟 2 拍（每个时钟沿都比）"),

    dict(name="pingpong", W=128,  H=16,  frames=4,
         patterns=["lowc", "highkey", "const", "dark"], gap=3200, lgap=0,
         bub_period=0, bub_len=0, en_mask=0xB, dump_all=1, head=0, tail=0, contract=1,
         why="4 帧图案互不相同 + 第 2 帧 I_en=0：验证「第 f 帧用第 f-1 帧的表」、"
             "帧边界原子切换、以及 en=0 时统计照跑"),

    dict(name="bubble",   W=128,  H=16,  frames=3,
         patterns=["highkey"] * 3, gap=3200, lgap=12, bub_period=5, bub_len=3,
         en_mask=0x7, dump_all=1, head=0, tail=0, contract=1,
         why="行内气泡（每 5 拍停 3 拍）+ 行末消隐 → 输出拍数不增不减、采样相位不被气泡带偏"),

    dict(name="full",     W=1280, H=720, frames=2,
         patterns=["grad", "grad2"], gap=4000, lgap=0, bub_period=0, bub_len=0,
         en_mask=0x3, dump_all=0, head=1280, tail=640, contract=1,
         why="1280×720 真实尺寸：每行 320 拍 / 每帧 230400 拍；dump 只取每帧头 4 行 + 末 2 行"),

    dict(name="shortgap", W=64,   H=8,   frames=4,
         patterns=["lowc"] * 4, gap=200, lgap=0, bub_period=0, bub_len=0,
         en_mask=0xF, dump_all=1, head=0, tail=0, contract=0,
         why="故意违反消隐合同（帧间只有 200 拍 < 扫描所需 1540 拍）→ 只查结构（无 X、拍数、相位、延迟）"),
]


def scen_params(s):
    """派生量（生成端与判据端共用同一份定义）。"""
    W, H = s["W"], s["H"]
    bpl = W // 4
    bpf = bpl * H
    return dict(bpl=bpl, bpf=bpf, nbeat=bpf * s["frames"],
                samples=samples_per_frame(W, H), K=k_const(W, H))


def build_frames(s):
    """按 patterns 造出该场景的全部帧，返回 (frames, H, W, 3) uint8。"""
    W, H = s["W"], s["H"]
    pats = s["patterns"]
    assert len(pats) == s["frames"], (s["name"], len(pats), s["frames"])
    return np.stack([PATTERNS[p](f, W, H) for f, p in enumerate(pats)], axis=0)


def frames_to_exp_bytes(frames, W, H):
    """帧序列 → "拍字节序"数组 (NBEAT, 12)：列序 = [pix0R,pix0G,pix0B, pix1R,...]。

    与 TB dump 里 96bit 输出的字节序**逐位对应**（byte j = 位 [88-8j -: 8]）。
    ⚠ 96 bit 装不进 numpy 的 uint64（曾经踩过：`a << 88` 直接截成 0），
      所以这里**只用字节矩阵**表示拍，hex 行由字节矩阵 tobytes().hex() 生成。
    """
    out = []
    for fr in frames:
        out.append(fr.reshape(H, W // 4, 12))
    return np.concatenate(out, axis=0).reshape(-1, 12)


def frames_to_beats(frames, W, H):
    """帧序列 → 96bit 拍（Python 大整数列表）。给交叉自检用（慢，大场景别用）。"""
    eb = frames_to_exp_bytes(frames, W, H)
    return [int.from_bytes(bytes(r), "big") for r in eb]


def write_stim(s, frames):
    fn = os.path.join(HERE, "stim_he_%s.hex" % s["name"])
    eb = frames_to_exp_bytes(frames, s["W"], s["H"])
    p = scen_params(s)
    assert eb.shape[0] == p["nbeat"], (eb.shape, p["nbeat"])
    with open(fn, "w", encoding="ascii") as fh:
        fh.write("".join(r.tobytes().hex() + "\n" for r in eb))
    return fn, eb.shape[0]


def main():
    if "--list" in sys.argv:
        for s in SCENARIOS:
            p = scen_params(s)
            print("%-10s %4dx%-4d frames=%d  BPL=%-4d BPF=%-8d NBEAT=%-8d samples/帧=%-7d K=%-7d %s"
                  % (s["name"], s["W"], s["H"], s["frames"], p["bpl"], p["bpf"],
                     p["nbeat"], p["samples"], p["K"], s["why"]))
        return 0

    man = {"scenarios": []}
    for s in SCENARIOS:
        frames = build_frames(s)
        fn, n = write_stim(s, frames)
        p = scen_params(s)
        rec = dict(s)
        rec.update(bpl=p["bpl"], bpf=p["bpf"], nbeat=p["nbeat"],
                   samples=p["samples"], K=p["K"],
                   stim=os.path.basename(fn),
                   dump="dump_he_%s.txt" % s["name"],
                   log="run_he_%s.log" % s["name"])
        man["scenarios"].append(rec)
        print("  %-10s %4dx%-4d %d 帧  NBEAT=%-8d %s  → %s"
              % (s["name"], s["W"], s["H"], s["frames"], n, s["why"],
                 os.path.basename(fn)))
    with open(os.path.join(HERE, "histeq_scen.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    print("已写出 histeq_scen.json（%d 个场景）" % len(SCENARIOS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
