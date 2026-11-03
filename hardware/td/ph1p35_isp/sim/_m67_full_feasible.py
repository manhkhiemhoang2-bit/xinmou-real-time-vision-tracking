# -*- coding: utf-8 -*-
"""
_m67_full_feasible.py —— 全尺寸 M6/M7 专项跑的**先决可行性判据**（不跑 ModelSim，纯 CPU 几秒）

为什么要有这一份：
  全尺寸（1280x720）那套档位表里**没有 M6/M7 帧**，M6/M7 至今只在小图 160x64 上验过。
  在花一条 ModelSim 全尺寸跑之前，必须先确认"全尺寸激励能不能把这两档激励起来"，
  否则判据 L / M 会按"空跑"报红，整轮白跑。

两条要判死的空跑风险：
  ① M6：8x8 降采样帧差，红块每帧右移 W//W_SMALL = 8 列 = 正好一格。
     但帧差比的是**灰度**，而红块灰度 ≈ 0.299*255+0.114*12 ≈ 78，
     它与"红块原本盖住的背景"的灰度差可能 < DIFF_TH=24 ⇒ 一个运动格子都没有。
  ② M7：期望输出既不能全黑（填不出东西）也不能几乎全白（吃了实心图）。

判据口径全部复用 check_alg_top_full 的黄金模型（不另写一套，避免判据漂移）。
"""
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_alg_top_full as C  # noqa: E402

# 本次专项跑的档位表。
#   ⚠ 2026-09-20 第一版排成 [M0, M6, M7]（M6 在第 1 帧）—— 实测判据 L 报红：
#     判据 L 原文 check_alg_top_full.py:1187 `box_nonempty = (mb[fr-1] is not None)`，
#     即"M6 帧显示的红框 = **上一帧**的运动框"。M6 排在第 1 帧时上一帧是第 0 帧，
#     而第 0 帧的运动图恒为全 0 ⇒ 框必然为空。那是**正常行为**，不是 RTL bug。
#   ⇒ M6 必须排在第 2 帧（前一帧要有运动），第 0/1 帧用 M0/M1 垫：
#        f0 = M0（提供参考帧 + 判据 K 的 M0 直通）
#        f1 = M1（提供"上一帧运动框"给 f2 的 M6 画框用）
#        f2 = M6
#        f3 = M7
SCHED = [0, 1, 6, 7]

print("=" * 78)
print("几何 W=%d H=%d  降采样 DS=%d  网格 CX=%d CY=%d  M6 DIFF_TH=%d  M7 RF_TH=%d"
      % (C.W, C.H, C.DS, C.CX, C.CY, C.M6_DIFF_TH, C.RF_TH))
print("档位表 = %s（f0=M0 参考帧、f1=M1 给 M6 供上一帧运动框、f2=M6、f3=M7）" % SCHED)
print("=" * 78)

imgs = C.images(len(SCHED))
print("图像已构造：%d 帧，每帧 %s" % (len(imgs), imgs[0].shape))

# ---------------------------------------------------------------- ① M6 空跑判据
print("\n--- ① M6 帧差：格子级灰度差有没有超过阈值 ---")
grids = [C.m6_gray_grid(im) for im in imgs]
for f in (1, 2):
    d = np.abs(grids[f] - grids[f - 1])
    flat = np.sort(d.ravel())
    over = int((flat > C.M6_DIFF_TH).sum())
    print("  帧 %d vs %d：|Δ灰度| max=%d  次大=%d  第3大=%d  超阈值个数=%d / %d"
          % (f, f - 1, flat[-1], flat[-2], flat[-3], over, flat.size))
    print("     超阈值格子的灰度差取值（前 8 个）= %s" % np.sort(flat[flat > C.M6_DIFF_TH])[::-1][:8])

mots, bbs, cnt = C.m6_stats(len(SCHED))
for f in range(len(SCHED)):
    print("  帧 %d（%s）：运动格子 %d  bbox=%s" % (f, "M%d" % SCHED[f], cnt[f], bbs[f]))

m6_frames = [f for f, m in enumerate(SCHED) if m == 6]
# ⚠ 口径与判据 L 逐条对齐（check_alg_top_full.py:1185-1196）：
#   "本帧运动格子数 > 0"  AND  "显示的红框非空 = 上一帧的运动框非空"
m6_ok = all(cnt[f] > 0 and (f >= 1 and bbs[f - 1] is not None) for f in m6_frames)
for f in m6_frames:
    print("  M6 帧 %d：本帧运动格子 = %d（需 > 0）；上一帧运动框 mb[%d] = %s（需非空）"
          % (f, cnt[f], f - 1, bbs[f - 1] if f >= 1 else None))
print("  ⇒ M6 非空判据（本帧格子 > 0 且 上一帧运动框非空）：%s" % ("PASS" if m6_ok else "FAIL"))

# ---------------------------------------------------------------- ② M7 空跑判据
print("\n--- ② M7 区域填充：期望输出既不能全黑也不能几乎全白 ---")
RF_TH = C.RF_TH
for f, m in enumerate(SCHED):
    if m != 7:
        continue
    exp = C.m7_frame(imgs[f])
    # ⚠ m7_frame 的文档写 (H,W,3)，实际返回 (H,W,1)：np.where 的条件是 [:, :, None]，
    #   三通道靠"赋值给 (H,W,3) 切片"时广播补齐。这里按真实形状取。
    assert exp.ndim == 3 and exp.shape[2] == 1, exp.shape
    white = exp[:, :, 0] != 0
    black = ~white
    n, nw, nb = exp.shape[0] * exp.shape[1], int(white.sum()), int(black.sum())
    print("  帧 %d（M7）：期望白像素 %d / %d（%.2f%%）  黑像素 %d（%.2f%%）"
          % (f, nw, n, 100.0 * nw / n, nb, 100.0 * nb / n))
    # 掩蔽区（前 3 行 + 每行第 0 拍 = 列 0..3）必须是黑
    mask = np.zeros((C.H, C.W), dtype=bool)
    mask[:3, :] = True
    mask[:, :4] = True
    print("     掩蔽区（前 3 行 + 每行前 4 列）像素 %d，其中非黑 %d"
          % (int(mask.sum()), int((~black)[mask].sum())))
    allblack = nw == 0
    allwhite = nw > 0.9 * n
    print("     ⇒ 非空判据：%s（全黑=%s 几乎全白=%s）"
          % ("PASS" if not (allblack or allwhite) else "FAIL", allblack, allwhite))

print("\n" + "=" * 78)
print("结论：M6 非空 %s；M7 非空见上" % ("PASS" if m6_ok else "FAIL"))
print("=" * 78)
