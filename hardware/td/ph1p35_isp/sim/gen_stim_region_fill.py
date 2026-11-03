#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_region_fill.py —— 生成 alg_region_fill_96 的仿真激励与参考数据

产出（都写在 sim\\ 下）：
  stim_rf.hex / stim_rf_hd.hex   逐拍 96bit 掩膜激励（$readmemh 用，
                                 每拍 1 行 24 个十六进制字符，= 4 个像素 × 24bit，
                                 pix0（行内最左）在最高位）
  meta_rf.json / meta_rf_hd.json 尺寸、帧数、每帧图案说明
  ref_rf.npz   / ref_rf_hd.npz   参考实现的输出（键：out_beats / in_beats / frames）

图案设计（**每一条都对应规格里的一条要求**，小图 = 32×10）：
  F0 **2 像素宽**闭合矩形轮廓 —— 上升沿判据的**承重用例**
     （旧规则"每个白像素都翻一次"在偶数宽轮廓上填不上，见 §填充规则）
  F1 **4 像素宽**闭合矩形轮廓（旁证，同样偶数宽）
  F2 2 像素宽方框 + 2 像素缺口 —— 膨胀把缺口接上后内部才填得上
  F3 孤立白点 —— 未闭合，从该点一路填到行尾（经典行为，规格允许）
  F4 全黑
  F5 全白 —— **实心图**：inside 一路保持到行尾（本模块只能吃轮廓图，见报告）
  F6 两个互不相连的 2 像素宽环（第二个环内部再放一个孤立点）—— 多目标互不串扰
  F7 顶部贴边的 2 像素宽矩形 —— 跨帧连续性（上一帧全白，inside/prev 都可能为 1）

填充规则（**RTL 与 ref_region_fill.py 写死同一个口径**）：
  只在"由黑变白"那一下翻转 inside（上升沿判据），不是"每个白像素都翻一次"。
  理由：后者翻转次数 = 边缘带宽度，2/4 像素（偶数）宽的轮廓会填不上，
  而上游 Sobel 边缘本来就是 2~3 像素宽且不稳定 ⇒ 变成赌奇偶。

用法：python gen_stim_region_fill.py
"""
from __future__ import annotations

import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ref_region_fill as R  # noqa: E402

# ---- 小图（TB: tb_region_fill.v）----
SW, SH = 32, 10
# ---- 大图（TB: tb_region_fill_hd.v，真实分辨率）----
HW, HH = 1280, 720


# ===========================================================================
# 小图图案
# ===========================================================================
def small_frames():
    W, H = SW, SH
    F = []

    # F0 **2 像素宽**闭合矩形轮廓 —— 上升沿判据的承重用例
    m = np.zeros((H, W), dtype=bool)
    m[2:9, 6:8] = True
    m[2:9, 24:26] = True
    m[2:4, 6:26] = True
    m[7:9, 6:26] = True
    F.append(("F0 2px-wide closed rectangle outline [LOAD-BEARING]", m))

    # F1 **4 像素宽**闭合矩形轮廓（旁证：也是偶数宽）
    m = np.zeros((H, W), dtype=bool)
    m[2:9, 4:8] = True
    m[2:9, 22:26] = True
    m[2:6, 4:26] = True
    m[5:9, 4:26] = True
    F.append(("F1 4px-wide closed rectangle outline", m))

    # F2 2 像素宽方框 + 2 像素缺口（膨胀应把缺口接上 ⇒ 内部仍被填）
    m = np.zeros((H, W), dtype=bool)
    m[2:9, 6:8] = True
    m[2:9, 24:26] = True
    m[2:4, 6:26] = True
    m[7:9, 6:26] = True
    m[8, 14:16] = False                 # 2 像素缺口
    F.append(("F2 2px outline with 2px gap (dilate must close it)", m))

    # F3 孤立白点（未闭合 ⇒ 从该点一路填到行尾，经典行为，规格允许）
    m = np.zeros((H, W), dtype=bool)
    m[4, 16] = True
    F.append(("F3 isolated dot", m))

    # F4 全黑
    F.append(("F4 all black", np.zeros((H, W), dtype=bool)))

    # F5 全白（实心图：一路填到行尾；本模块只能吃轮廓图）
    F.append(("F5 all white (solid frame - fills to EOL)", np.ones((H, W), dtype=bool)))

    # F6 两个互不相连的 2 像素宽环（第二个环内部再放一个孤立点）
    m = np.zeros((H, W), dtype=bool)
    m[2:8, 4:6] = True
    m[2:8, 12:14] = True
    m[2:4, 4:14] = True
    m[6:8, 4:14] = True
    m[2:8, 18:20] = True
    m[2:8, 26:28] = True
    m[2:4, 18:28] = True
    m[6:8, 18:28] = True
    m[4, 22] = True                     # 第二个环内部的孤立点
    F.append(("F6 two 2px rings, 2nd has a dot inside", m))

    # F7 顶部贴边的 2 像素宽矩形（跨帧连续性：上一帧全白，inside/prev 都可能为 1）
    m = np.zeros((H, W), dtype=bool)
    m[2:5, 4:8] = True
    m[2:5, 24:28] = True
    m[2:4, 4:28] = True
    m[3:5, 4:28] = True
    F.append(("F7 top-touching 2px rectangle (frame continuity)", m))

    return F


# ===========================================================================
# 大图图案（1280×720，真实分辨率）
# ===========================================================================
def hd_frames():
    W, H = HW, HH
    F = []

    # H0 **2 像素宽**大矩形轮廓 + 2 个孤立点（承重用例的真实分辨率版本）
    m = np.zeros((H, W), dtype=bool)
    m[50:600, 100:102] = True           # 左边框（2 像素宽）
    m[50:600, 499:501] = True           # 右边框
    m[50:52, 100:501] = True            # 上边框
    m[598:600, 100:501] = True          # 下边框
    m[300, 900] = True                  # 孤立白点（列 900 = 拍 225 的第 0 个像素）
    m[650, 1100] = True                 # 孤立白点（列 1100 = 拍 275 第 0 个像素）
    F.append(("H0 2px-wide big rectangle outline + isolated dots", m))

    # H1 2 像素宽方框 + 2 像素缺口 + 4 个内部 2 像素宽小环
    m = np.zeros((H, W), dtype=bool)
    m[100:500, 200:202] = True
    m[100:500, 699:701] = True
    m[100:102, 200:701] = True
    m[498:500, 200:701] = True
    m[498, 400:402] = False             # 2 像素缺口（膨胀后应被接上）
    for (y0, x0) in ((200, 300), (200, 400), (350, 300), (350, 400)):
        m[y0:y0 + 40, x0:x0 + 2] = True
        m[y0:y0 + 40, x0 + 40:x0 + 42] = True
        m[y0:y0 + 2, x0:x0 + 42] = True
        m[y0 + 38:y0 + 40, x0:x0 + 42] = True
    F.append(("H1 2px ring with 2px gap + four inner 2px rings", m))

    # H2 斜线 + 孤立点（斜线被膨胀加宽后整行填满 = 经典行为）
    m = np.zeros((H, W), dtype=bool)
    yy = np.arange(20, 60)
    m[yy, yy + 620] = True              # 列 640..679，远离图的左右边界
    m[400, 4] = True                    # 恰好落在被掩蔽的第 0 拍
    m[500, 1024] = True                 # 列 1024 = 拍 256 的第 0 个像素
    F.append(("H2 diagonal line + isolated dots", m))

    return F


# ===========================================================================
# 输出
# ===========================================================================
def dump(frames, W, H, stim_name, meta_name, ref_name):
    named = [n for n, _ in frames]
    # ⚠ 必须先把 bool 掩膜映射成 0xFFFFFF / 0x000000 再打包：
    #   直接 astype(uint32) 会把 True 变成 1，那不是合法的掩膜取值。
    arr = np.stack([R.bool_to_mask(m) for _, m in frames])          # (F,H,W) uint32
    beats = R.frames_to_beats(arr, W, H)
    beats = np.where(beats != 0, np.uint32(R.WHITE), np.uint32(R.BLACK))
    lines = []
    for b in beats:
        lines.append("%06X%06X%06X%06X" % (int(b[0]), int(b[1]), int(b[2]), int(b[3])))
    with open(os.path.join(HERE, stim_name), "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    ref = R.ref_region_fill(arr, W, H)          # (F,H,W) uint32，与 RTL 同口径
    np.savez_compressed(os.path.join(HERE, ref_name),
                        out_beats=R.frames_to_beats(ref, W, H),
                        in_beats=beats,
                        frames=ref)
    meta = {
        "W": W, "H": H, "BPL": W // 4, "frames": len(named),
        "beats": int(beats.shape[0]),
        "names": named,
        "white_pixels_per_frame": [int((ref[i] == R.WHITE).sum()) for i in range(len(named))],
        "white_criterion": "pixel == 0xFFFFFF",
        "fill_rule": "rising-edge only (inside ^= edge & ~edge_prev)",
    }
    with open(os.path.join(HERE, meta_name), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print("wrote %-18s %6d beats  (%d frames, %dx%d)"
          % (stim_name, beats.shape[0], len(named), W, H))
    for n, c in zip(named, meta["white_pixels_per_frame"]):
        print("    %-56s white=%d" % (n, c))
    return meta


def main():
    print("== small round (tb_region_fill.v) ==")
    dump(small_frames(), SW, SH, "stim_rf.hex", "meta_rf.json", "ref_rf.npz")
    print("== full-HD round (tb_region_fill_hd.v) ==")
    dump(hd_frames(), HW, HH, "stim_rf_hd.hex", "meta_rf_hd.json", "ref_rf_hd.npz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
