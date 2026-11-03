#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_thresh_probe.py -- M7 输入阈值选值的**实测依据**（不是推导）。

问题：alg_sobel_96 的输出不是黑白边缘，而是
      out = edge ? sat8(src + EDGE_K) : src        (src = 原图第 y-1 行彩色)
      所以 M7 必须自带一级"硬阈值"把它变成纯二值。

本脚本用**真实激励图**（160x64 与 1280x720 同一套 build_image，只是平铺倍率不同）
算出 M3 输出，然后：
  · 统计 edge / non-edge 两类像素的 min(R,G,B) 分布；
  · 对候选阈值 T 计算 "binarize(M3输出) 与 Sobel 的 edge 掩码" 的逐像素差异；
  · 顺便算 M2（二值化）输出的前景占比，说明"为什么不能接二值化那条支路"。

用法：ALG_W=160 ALG_H=64 python _m7_thresh_probe.py
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

for _d in (os.environ.get("ALG_REF_DIR", ""),
           r"C:\Users\29072\PycharmProjects\PythonProject8",
           os.path.dirname(os.path.abspath(__file__))):
    if _d and os.path.isfile(os.path.join(_d, "alg_ref.py")):
        if _d not in sys.path:
            sys.path.insert(0, _d)
        break
else:
    raise SystemExit("找不到 alg_ref.py")

import numpy as np       # noqa: E402
import alg_ref as A      # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_stim_top_full as G   # noqa: E402

EDGE_K = G.EDGE_K


def m3_and_edge(img):
    """返回 (M3 输出帧, edge 掩码, 是否逐位等于 alg_ref 的 MODE_EDGE 结果)。"""
    gray = A.gray_bt601(img)
    win = A.build_windows(gray, 3, 3)
    mag = A.sobel_mag(win)
    th = A.local_mean(A.neighbor_sum_S(win), G.C_OFF, 0, 255)
    edge = mag >= th * A.EDGE_TH_SCALE
    src = img.astype(np.int32)
    out = np.where(edge[:, :, None], A.sat8(src + np.int32(EDGE_K)), src).astype(np.uint8)
    return out, edge


def binarize(out, T, mode="all"):
    """纯二值化：三通道都 >= T 记白，否则黑。返回 bool 前景图。"""
    if mode == "all":
        return (out[:, :, 0] >= T) & (out[:, :, 1] >= T) & (out[:, :, 2] >= T)
    raise ValueError(mode)


def main():
    print("=" * 78)
    print("M7 输入阈值实测：几何 W=%d H=%d（图 = gen_stim_top_full.build_image 平铺）" % (G.W, G.H))
    print("=" * 78)
    tot_bad = {}
    for f in range(3):
        img = G.build_image(f)
        out, edge = m3_and_edge(img)
        mn = np.minimum(np.minimum(out[:, :, 0], out[:, :, 1]), out[:, :, 2]).astype(np.int64)
        mx = np.maximum(np.maximum(out[:, :, 0], out[:, :, 1]), out[:, :, 2]).astype(np.int64)
        ne = ~edge
        print("-" * 78)
        print("帧 %d：像素 %d，edge 命中 %d（%.2f%%）" % (f, edge.size, int(edge.sum()),
                                                        100.0 * edge.sum() / edge.size))
        print("  非边缘像素 min(R,G,B)：最大 %d，分位 [50%%=%d 90%%=%d 99%%=%d 100%%=%d]"
              % (mn[ne].max(), np.percentile(mn[ne], 50), np.percentile(mn[ne], 90),
                 np.percentile(mn[ne], 99), mn[ne].max()))
        print("  边缘像素   min(R,G,B)：最小 %d，最大 %d" % (mn[edge].min(), mn[edge].max()))
        print("  边缘像素   max(R,G,B)：等于 255 的占比 %.2f%%"
              % (100.0 * (mx[edge] == 255).mean()))
        for T in (0, 8, 64, 96, 120, 127, 128, 129, 160, 200, 255):
            b = binarize(out, T)
            bad = int((b != edge).sum())
            tot_bad.setdefault(T, []).append(bad)
            print("     T=%-4d 前景 %7d 像素（%.2f%%）  与 edge 掩码不符 %d  %s"
                  % (T, int(b.sum()), 100.0 * b.sum() / b.size, bad,
                     "== edge 掩码" if bad == 0 else ""))
        # 「三字节全 0xFF」口径（任务书里填充模块的判白口径）
        b255 = (out[:, :, 0] == 255) & (out[:, :, 1] == 255) & (out[:, :, 2] == 255)
        print("     口径'三字节全 0xFF'：前景 %d 像素（%.2f%%）  与 edge 不符 %d"
              % (int(b255.sum()), 100.0 * b255.sum() / b255.size, int((b255 != edge).sum())))
        # M2（二值化）前景占比 —— 说明为什么不能接那条支路
        thm = A.local_mean(A.neighbor_sum_S(win := A.build_windows(A.gray_bt601(img), 3, 3)),
                           G.C_OFF, 0, 255)
        b2 = win[:, :, 1, 1] > thm
        print("     对照 M2（二值化）通路前景占比 = %.2f%%（整片实心区，填充会整幅花掉）"
              % (100.0 * b2.mean()))
    print("=" * 78)
    print("汇总（3 帧合计 %d 像素）：" % (G.W * G.H * 3))
    for T in sorted(tot_bad):
        print("   T=%-4d 累计不符 %d" % (T, sum(tot_bad[T])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
