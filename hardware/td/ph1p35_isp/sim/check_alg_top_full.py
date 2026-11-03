#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_alg_top_full.py —— 校验 ModelSim 真仿真出来的 dump_top_full.txt
                         （`alg_top` 集成层，**全尺寸 1280x720**）

被测：src/alg_top.v（7 档切换 + 掩蔽 + 延迟对齐）。8 个子模块已各自验过，本次不改。

期望值的**唯一来源**（绝不读 DUT 内部量；dump 里也一个内部探针都没有）：
  · 激励序列本身 —— gen_stim_top_full.py 直接 import（位序/几何/档位表同源）；
  · 独立金标准 alg_ref.py 的 AlgPipeline（帧级参考模型，M0..M5）；
  · M6（帧差运动检测）alg_ref 里**没有实现**（MODE_MOTION 只占编号），黄金模型在
    本文件 0b 节独立实现（8x8 降采样 / 帧差阈值 / 上一帧 bbox 画框）。
    ⚠ 它逐位依赖 A.gray_bt601，那是**同一个**已经被 M1 判据钉死的灰度来源，
      不是从 DUT 读出来的值（见 0b 节注释）。

与小图 check_alg_top.py 的关系：判据口径逐条沿用（A 延迟 / B 对金标准 /
C 掩蔽=原图 / D 档位锁存 / E M3 的 src 行 / F X-Z / G bbox / H 激励自检 /
I 行消隐工况），但**实现完全不同**：全尺寸 12 帧 = 276 万拍 x 6 个逐像素探针
≈ 1658 万个采样点，逐点 Python 循环跑不动，所以解析与判定全部 **numpy 向量化**。
新增判据：
  · I 里加了**帧消隐**门禁（全尺寸新增的激励特征）；
  · J **每行/每帧拍数**门禁（每行恰好 320 拍、每帧恰好 720 行、tlast/tuser 逐拍）；
  · G 由"M5 bbox"扩成"**按档选族**"：M5 帧报颜色 bbox、M6 帧报运动 bbox；
  · L **M6 专属**：M6 帧的控制延迟/输出拍数/O_tlast 位置，加"运动格子数 > 0 且
    红框非空"的防空跑门禁（0 次检查 = 失败）。

用法：
    python check_alg_top_full.py                 # 正常校验（需先跑 tb_alg_top_full）
    python check_alg_top_full.py --frames 2      # 只校验前 2 帧（冒烟）
    python check_alg_top_full.py --selftest      # 改期望值的变异自证
"""
from __future__ import annotations

import os
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

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

from gen_stim_top_full import (   # noqa: E402
    W, H, BPL, BPF, FRAMES_ALL, BLANK_LEN, EOF_BLANK, HEX_NAME,
    MODE_SCHED, EDGE_K, C_OFF, RLO, RHI, GLO, GHI, BLO, BHI,
    DS, CX, CY, M6_DIFF_TH, RF_TH,
    build_images, nbeat,
)

# M7 的填充参考实现：**与 alg_region_fill_96 自己验收时用的是同一份**
# （sim\ref_region_fill.py，check_region_fill.py 也 import 它）。
# 不在这里重写第三份填充算法 —— 那样只会多一个"两处各写一遍然后祈祷相等"的口径源。
import ref_region_fill as RF     # noqa: E402

LAT = 5                        # 全链延迟（S1第二批_接口冻结.md §2.5，冻结值；M0..M6）
# M7 支路比别的档位多 3 拍：填充模块自己的契约就是"延迟 3 拍"，而它必须吃边缘轮廓，
# 边缘只有 M3 那条支路有（已在延迟 4）⇒ M7 最早只能落在 4+3=7 拍，本级输出寄存器 → 8。
M7_EXTRA = 3
LAT_M7 = LAT + M7_EXTRA        # = 8
MODE_NAMES = {0: "M0 RAW", 1: "M1 GRAY", 2: "M2 BIN", 3: "M3 EDGE",
              4: "M4 SMOOTH", 5: "M5 TARGET", 6: "M6 MOTION", 7: "M7 FILL"}
MODE_M6 = 6
MODE_M7 = 7
DUMP = "dump_top_full.txt"
HEXF = HEX_NAME                # 随尺寸变化（1280x720 -> stim_top_full.hex）
NCOL = 17                      # dump 每行的字段数（见 tb_alg_top_full.v）
# ⚠ parse() 会用 dump 首行的实际字段数**覆盖**它（老 dump 是 16 列）。
# E1「反解」判据的歧义率上限。歧义本身不是错（猜不出来≠猜错了），但必须受控：
# 一旦歧义率超过这个上限，说明激励图或反解方法退化，E1 已接近失效 —— 判 FAIL。
# 实测基线：34,306 / 916,168 = 3.74%（2026-09-16，1280x720 x 6 帧）。
E1_AMB_CEIL = 0.10

_IMGS = []                     # 图像缓存


def images(frames):
    global _IMGS
    if len(_IMGS) < frames:
        _IMGS = build_images(frames)
    return _IMGS[:frames]


# ===========================================================================
# 0. 参考期望（唯一的金标准入口；变异时也只改这里）
# ===========================================================================
def _pipe(mode, mut):
    kw = dict(c_off=C_OFF, th_min=0, th_max=255, edge_k=EDGE_K,
              rlo=RLO, rhi=RHI, glo=GLO, ghi=GHI, blo=BLO, bhi=BHI)
    if mut:
        if "ppb" in mut:
            kw["pixels_per_beat"] = mut["ppb"]
        if "mask_rows" in mut:
            kw["mask_top_rows"] = mut["mask_rows"]
        if mut.get("bbox_current"):
            kw["bbox_source"] = "current"
    return A.AlgPipeline(mode=mode, **kw)


def _shift1(x):
    return np.concatenate([x[:1], x[:-1]], axis=0)


def variant_out(img, mode, mut, bbox_prev=None, img_prev=None, mot_bb_prev=None,
                mot=None, mot_bb_cur=None, trail=None):
    """变异路径：按 alg_ref 的向量化原语重算一帧（默认参数下必须与 AlgPipeline 逐位相同）。

    只用于造"错误期望"（判据 E 的候选对照 + 变异自证）；正常校验走 AlgPipeline 本体。
    M6（alg_ref 里没有实现）走 0b 节的独立黄金模型，额外需要：
        img_prev    上一帧原图（首帧 None）
        mot         本帧运动格子图；mot_bb_prev / mot_bb_cur 上一帧 / 本帧运动 bbox
    """
    mut = mut or {}
    valid = A.window_valid_mask(H, W, mut.get("ppb", 4), mut.get("mask_rows", 2))
    gray = A.gray_bt601(img)
    gray3 = np.repeat(gray[:, :, None], 3, axis=2).astype(np.uint8)
    win = A.build_windows(gray, 3, 3)

    if mode == A.MODE_RAW:
        out = img.copy()
    elif mode == A.MODE_GRAY:
        out = gray3.copy()
    elif mode == A.MODE_MOTION:
        out = m6_frame(img, mot, mot_bb_prev, mot_bb_cur, mut)
    elif mode == A.MODE_BIN:
        th = A.local_mean(A.neighbor_sum_S(win), C_OFF, 0, 255)
        out = np.repeat(np.where(win[:, :, 1, 1] > th, 255, 0).astype(np.uint8)[:, :, None],
                        3, axis=2)
        if not mut.get("no_row_shift"):
            out = _shift1(out)
    elif mode == A.MODE_EDGE:
        mag = A.sobel_mag(win)
        th = A.local_mean(A.neighbor_sum_S(win), C_OFF, 0, 255)
        edge = mag >= th * A.EDGE_TH_SCALE
        kv = mut.get("edge_k", EDGE_K)
        if mut.get("src_gray"):
            src = gray3.astype(np.int32)
        else:
            dy = mut.get("src_dy", -1)
            if dy == 0:
                src = np.roll(img, -1, axis=0).astype(np.int32)
            elif dy == -2:
                src = np.roll(img, 1, axis=0).astype(np.int32)
            else:
                src = img.astype(np.int32)
        out = np.where(edge[:, :, None], A.sat8(src + np.int32(kv)), src).astype(np.uint8)
        if not mut.get("no_row_shift"):
            out = _shift1(out)
    elif mode == A.MODE_SMOOTH:
        g = A.gauss_121(win)
        out = np.repeat(g[:, :, None].astype(np.uint8), 3, axis=2)
        if not mut.get("no_row_shift"):
            out = _shift1(out)
    else:
        # 2026-09-20（2.5(2) 动态跟踪）：先轨迹、后当前框（同 RTL §5c 的优先级）
        out = A.draw_trail(img, trail or []).astype(np.uint8)
        out = A.draw_bbox(out, bbox_prev).astype(np.uint8)

    if mut.get("mask_black"):
        out = np.where(valid[:, :, None], out, np.uint8(0))
    elif mut.get("skip_mask_modes") and mode in mut["skip_mask_modes"]:
        pass
    else:
        out = np.where(valid[:, :, None], out, img)
    return np.ascontiguousarray(out.astype(np.uint8))


def bboxes(frames):
    """逐帧 M5 bbox（金标准口径：hit_vote 后再套 window_valid 掩蔽）。"""
    out = []
    for f in range(frames):
        hit = A.target_hit(images(frames)[f], RLO, RHI, GLO, GHI, BLO, BHI)
        hit = A.hit_vote(hit) & A.window_valid_mask(H, W)
        out.append(A.bbox_stats(hit)["bbox"])
    return out


TRAIL_N = 8          # 与 alg_color_detect_96 的 localparam TRAIL_N 逐字一致


def trail_states(frames, bb):
    """逐帧的**轨迹寄存器状态**（2026-09-20，进阶 2.5(2) 动态目标跟踪）。

    RTL（alg_color_detect_96 §10c）：帧边界把**上一帧**的框中心压进 8 级移位寄存器，
    且**只在那一帧有目标时才压**。所以第 f 帧画面上画的是
        第 f-1, f-2, ... 帧的中心（跳过没目标的那几帧），最多 8 个。

    ⚠ 这就是判据侧的"金标准状态机"，它必须逐条复刻 RTL 的推入时机；
      推错一拍在全尺寸回归里会立刻报红（轨迹点整体错一格）。
      下面 out[f] 是"画第 f 帧时寄存器里的内容"，顺序 = 新→旧。
    """
    hist, out = [], []
    for f in range(frames):
        out.append(list(hist))
        b = bb[f]
        if b is not None:
            min_x, min_y, max_x, max_y = (int(v) for v in b)
            hist = [((min_x + max_x) >> 1, (min_y + max_y) >> 1)] + hist[:TRAIL_N - 1]
    return out


# ===========================================================================
# 0b. M6（帧差运动检测）黄金模型 —— **独立于 RTL**，口径与 alg_framediff_96.v
#     的文件头逐条对应；不读任何 DUT 内部信号。
#
#   · 灰度：A.gray_bt601（= gray_bt601_96 的输出。M1 判据已把那条通路逐位钉死在
#     同一个函数上，所以这里复用它是"同一来源"，不是循环论证）。
#   · 采样点：pix0 && 拍号为偶 && 行号 %8==0  ⇔  绝对坐标 (x, y) = (8*cx, 8*cy)。
#     （pix0 的 x = 4*x_grp；x_grp 为偶 ⇒ x = 8*(x_grp/2)。）
#   · 差分：diff = |gray_f - gray_{f-1}|，motion = (diff > DIFF_TH)（**严格大于**）。
#   · 第 0 帧：**整帧无运动** —— RTL 里 r_mem_full=0 期间 motion 恒 0（阵列没被完整
#     写过一遍 ⇒ 没有可比对象）。⚠ 任务书 2.1 写的"首帧存储器为复位值 0，自然不产生
#     运动"在数学上不成立：prev=0 时 diff=|gray-0|=gray，灰度 > 阈值就报运动
#     （实测 160x64 第 0 帧 160/160 个格子全部报运动）。判据按 RTL 的实际口径走，
#     并在报告里列出这条差异。
#   · 白点：运动格子的采样点**那一个像素**涂白（= 该拍 pix0，24'hFFFFFF）。
#   · 红框：用**上一帧**的运动 bbox（像素坐标，x1/y1 = cx*8+7），只画边框。
#   · 优先级：**红框 > 白点**；最后统一套 window_valid 掩蔽（掩蔽期输出原图）。
# ===========================================================================
def m6_gray_grid(img):
    """(H,W,3) -> (CY,CX) int32：8x8 降采样后的灰度格子。"""
    g = A.gray_bt601(img).astype(np.int32)
    assert g.shape == (H, W), g.shape
    sub = g[0::DS, 0::DS]
    assert sub.shape == (CY, CX), "降采样网格 %s != (CY,CX)=(%d,%d)" % (sub.shape, CY, CX)
    return sub


def m6_motion_maps(frames, mut=None):
    """逐帧运动格子图 (CY,CX) bool 列表（第 0 帧全 0）。"""
    mut = mut or {}
    imgs = images(frames)
    out = []
    for f in range(frames):
        if f == 0:
            out.append(np.zeros((CY, CX), dtype=bool))
            continue
        d = m6_gray_grid(imgs[f]) - m6_gray_grid(imgs[f - 1])
        if mut.get("m6_signed"):
            out.append(d > M6_DIFF_TH)              # 变异：不取绝对值（单向）
        elif mut.get("m6_inv_th"):
            out.append(np.abs(d) < M6_DIFF_TH)      # 变异：阈值比较取反
        else:
            out.append(np.abs(d) > M6_DIFF_TH)
    return out


def m6_bbox(mot, grid_units=False):
    """运动 bbox -> (x0, x1, y0, y1) 像素坐标闭区间；空则 None。"""
    ys, xs = np.nonzero(mot)
    if ys.size == 0:
        return None
    if grid_units:                                  # 变异：格子坐标当像素坐标
        return (int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max()))
    return (int(xs.min()) * DS, int(xs.max()) * DS + (DS - 1),
            int(ys.min()) * DS, int(ys.max()) * DS + (DS - 1))


def m6_stats(frames, mut=None):
    """(运动图列表, bbox 列表, 计数列表)；bbox 用 None 表示空。"""
    mut = mut or {}
    mots = m6_motion_maps(frames, mut)
    bbs = [m6_bbox(m, mut.get("m6_grid_bbox", False)) for m in mots]
    return mots, bbs, [int(m.sum()) for m in mots]


def m6_draw_box(out, bb):
    """在 out 上画红色 1 像素边框（= alg_color_detect_96 §5 的 draw_bbox 换色）。"""
    x0, x1, y0, y1 = bb
    if x1 < x0 or y1 < y0:
        return
    x0 = max(0, min(W - 1, x0)); x1 = max(0, min(W - 1, x1))
    y0 = max(0, min(H - 1, y0)); y1 = max(0, min(H - 1, y1))
    out[y0, x0:x1 + 1] = (255, 0, 0)
    out[y1, x0:x1 + 1] = (255, 0, 0)
    out[y0:y1 + 1, x0] = (255, 0, 0)
    out[y0:y1 + 1, x1] = (255, 0, 0)


def m6_frame(img, mot, bb_prev, bb_cur=None, mut=None):
    """M6 一帧的期望像素 (H,W,3) uint8（**不含**掩蔽，掩蔽由调用方统一套）。"""
    mut = mut or {}
    out = np.array(img, copy=True)
    # ① 运动点：格子采样点 (8cx, 8cy) 的 pix0 涂白
    ys, xs = np.nonzero(mot)
    if ys.size:
        out[ys * DS, xs * DS] = 255
    # ② 红框：上一帧 bbox（变异：本帧 / 格子坐标）
    bb = bb_cur if mut.get("m6_cur_bbox") else bb_prev
    if bb is not None and not mut.get("m6_no_box"):
        m6_draw_box(out, bb)
    return np.ascontiguousarray(out.astype(np.uint8))


def m6_beats_out(imgs, mots, bbs, f, mut=None):
    """M6 期望的**逐拍**构造（与 m6_frame 不同的写法：按 (行,拍号) 逐拍算）。

    只用于自洽性交叉检查（两种独立写法必须逐位相同），也是"掩蔽按拍生效"的直接依据：
      · 掩蔽拍 = (y < 2) | (x_grp == 0)  → 输出原图；
      · 运动点只落在 pix0（列 4*x_grp，且仅当拍号为偶、y%8==0）；
      · 红框按像素坐标逐像素判。
    返回 (H*BPL, 4, 3) uint8。
    """
    mut = mut or {}
    img = imgs[f]
    mot = mots[f]
    bb = bbs[f - 1] if f >= 1 else None
    if mut.get("m6_cur_bbox"):
        bb = bbs[f]
    bb_ok = (bb is not None) and (bb[0] <= bb[1]) and (bb[2] <= bb[3])
    out = np.array(img, copy=True).reshape(H, BPL, 4, 3)
    red = np.zeros((H, BPL, 4), dtype=bool)
    if bb_ok:
        x0, x1, y0, y1 = bb
        yy = np.arange(H)[:, None, None]
        xx = (4 * np.arange(BPL)[None, :, None]) + np.arange(4)[None, None, :]
        on_row = ((yy == y0) | (yy == y1)) & (xx >= x0) & (xx <= x1)
        on_col = ((xx == x0) | (xx == x1)) & (yy >= y0) & (yy <= y1)
        red = on_row | on_col
    white = np.zeros((H, BPL, 4), dtype=bool)
    cys, cxs = np.nonzero(mot)
    if cys.size:
        white[cys * DS, 2 * cxs, 0] = True           # 采样点 = 该拍 pix0（x_grp = 2*cx）
    out[red] = (255, 0, 0)                           # 红框优先
    out[white & ~red] = (255, 255, 255)              # 其次白点
    valid = A.window_valid_mask(H, W).reshape(H, BPL, 4)
    out = np.where(valid[:, :, :, None], out, img.reshape(H, BPL, 4, 3))
    return np.ascontiguousarray(out.reshape(H * BPL, 4, 3))


# ===========================================================================
# 0c. M7（区域填充）黄金模型 —— **独立于 RTL**，口径与 alg_top.v §四·补2 逐条对应
#
#   链（三处写死同一份口径，RTL alg_top.v / 这里 / 报告）：
#     ① 输入源：alg_sobel_96 的**原始输出**（out = edge ? sat8(src+K) : src）。
#        ⚠ 这里**不能**用 variant_out(..., MODE_EDGE, {}) 的默认结果 —— 那个在最后
#          统一套了 window_valid 掩蔽（掩蔽期换成原图），而 u_rf 吃的是**掩蔽前**的
#          w_s_dat（顶层掩蔽在 alg_top 最末一级才做）。用带掩蔽的那份当填充输入，
#          等于把前 2 行喂成原图彩色 —— 那不是 M7 的输入。
#     ② 硬阈值：白 ⟺ **三个字节都 >= RF_TH**（默认 128），其余黑。
#        ⇒ 与 alg_top.v 的 `w_rf_wht` 逐位同口径（参数也同源：gen_stim_top_full.RF_TH）。
#     ③ 填充：ref_region_fill(masked=True)（= 膨胀 + 上升沿行内填充 + 模块自带的
#        2 行 / 每行第 0 拍掩蔽），再**整体下移一行**（模块契约：输出第 y 行承载
#        输入第 y-1 行的结果，与 win3x3_96 同口径；模块自己的 A5 判据也是 shift1）。
#     M3 本身已经有一行位移 ⇒ M7 帧相对原图一共下移 2 行，这是两个契约叠加的结果，
#     判据不做任何补偿（alg_top.v §四·补2 明令"不要对齐掉"）。
# ===========================================================================
def m3_raw(img):
    """M3 的**原始**输出帧（未叠顶层掩蔽）—— 这正是 u_rf 吃进去的那条流。"""
    return variant_out(img, A.MODE_EDGE, {"skip_mask_modes": (A.MODE_EDGE,)})


def m3_edge(img):
    """Sobel 的 edge 判据（未下移），= m3_raw 的"提亮前"布尔图。"""
    gray = A.gray_bt601(img)
    win = A.build_windows(gray, 3, 3)
    mag = A.sobel_mag(win)
    th = A.local_mean(A.neighbor_sum_S(win), C_OFF, 0, 255)
    return mag >= th * A.EDGE_TH_SCALE


def m7_binarize(m3, thr=None):
    """硬阈值二值化：三字节都 >= thr 记白（255/255/255），否则黑。返回 (H,W,3) uint8。"""
    t = int(RF_TH if thr is None else thr)
    m = (m3[:, :, 0] >= t) & (m3[:, :, 1] >= t) & (m3[:, :, 2] >= t)
    return np.ascontiguousarray(np.repeat((m[:, :, None] * np.uint8(255)), 3, axis=2))


def m7_input_mask():
    """M7 支路输入的**可信范围**（像素级）：前 2 行 + 每行第 0 拍（列 0..3）。

    ⚠ 这不是"保险"而是必需：alg_sobel_96 在窗口不可信拍上输出的是**未定义值**
      （窗口横跨行/帧边界），实测第 0 拍 4 个像素在 RTL 里全是"边缘"。M3 档位上
      看不见（顶层掩蔽把那几拍换成原图），但填充模块的 3×3 膨胀会往左多吃一个像素
      （第 1 拍的窗口含第 0 拍的列 3）⇒ 每行第 4 列冒假边缘 ⇒ 1051 拍错位。
      alg_top.v §5d 的做法 = 这些拍**明确声明为黑**（与 r_mask_d 相与），参考模型同口径。
    """
    return A.window_valid_mask(H, W)


def m7_frame(img, mut=None):
    """M7 一帧的期望像素 (H,W,3) uint8。mut 用于变异自证（改阈值 / 去掉位移 / 裸填充）。

    ⚠ ref_region_fill 收的是 (F,H,W) **掩膜**（不是 (F,H,W,3) 彩色），所以这里显式转
      bool 前景图再喂进去 —— 判白口径仍是"三字节全 0xFF"，与填充模块的输入契约同一份。
    """
    mut = mut or {}
    bin3 = m7_binarize(m3_raw(img), mut.get("m7_th", RF_TH))
    mask = (bin3[:, :, 0] == 255)
    if not mut.get("m7_novm"):
        mask = mask & m7_input_mask()
    filled = RF.ref_region_fill([mask], W, H, masked=not mut.get("m7_nomask"))[0]
    out = np.where((filled == 0xFFFFFF)[:, :, None], np.uint8(255), np.uint8(0))
    for _ in range(int(mut.get("m7_shift", 1))):
        out = _shift1(out)
    return np.ascontiguousarray(out.astype(np.uint8))


def m7_frame_lowlevel(img, mut=None):
    """M7 期望的**第二套写法**（只走 ref_region_fill 的底层原语，与 m7_frame 互为独立实现）。

    用于自洽性交叉检查：两条路径必须逐位相同，否则"期望值怎么算的"本身就有歧义。
    """
    mut = mut or {}
    bin3 = m7_binarize(m3_raw(img), mut.get("m7_th", RF_TH))
    mask = (bin3[:, :, 0] == 255)
    if not mut.get("m7_novm"):
        mask = mask & m7_input_mask()
    edge = RF.dilate3x3(mask)
    if mut.get("m7_nomask"):
        filled, _inside = RF.scanline_fill(edge)
    else:
        filled, _inside = RF.scanline_fill_masked(edge, W, H)
    for _ in range(int(mut.get("m7_shift", 1))):
        filled = _shift1(filled)
    return np.ascontiguousarray(np.where(filled[:, :, None],
                                         np.uint8(255), np.uint8(0)).astype(np.uint8))


def pin_beats(imgs):
    """(...,H,W,3) uint8 -> **((...,H*BPL) hi32, (...,H*BPL) lo64)** 的 96bit 期望拍。

    返回两个 uint64 数组（不是一个有损打包值，见 pack96 的说明）。
    接受 list / (frames,H,W,3) / (H,W,3) 三种形状。
    """
    a = np.ascontiguousarray(np.asarray(imgs, dtype=np.uint8))
    lead = a.shape[:-3]
    hi, lo = _pair_of(A.pack_beats(a.reshape(-1, H, BPL, 4, 3)))
    if lead:
        return hi.reshape(-1, H * BPL), lo.reshape(-1, H * BPL)
    return hi.reshape(H * BPL), lo.reshape(H * BPL)


def beats_at(pair, f, flat):
    """从 pin_beats 的返回值里取 (帧 f, 拍序 flat) 的 (hi, lo)。pair 可以是 1D 或 2D。"""
    hi, lo = pair
    if hi.ndim == 2:
        return hi[f, flat], lo[f, flat]
    return hi[flat], lo[flat]


def mode_sched_arr():
    """档位表（长度 FRAMES_ALL；小尺寸表在 gen_stim_top_full 里定义）。"""
    return np.array(MODE_SCHED)


def expected_frames(frames, mut=None):
    """逐帧期望：(frames,H,W,3) uint8 图 + (frames,H*BPL) uint64 打包拍 + M5 bbox 列表。

    M6 帧走 0b 节的独立黄金模型（alg_ref 里 MODE_MOTION 只保留编号、没实现）；
    M7 帧走 0c 节（M3 原始输出 → 硬阈值 → 填充参考 → 整体下移一行）。
    """
    mut = mut or {}
    imgs = np.stack(images(frames))
    bb = bboxes(frames)
    tr = trail_states(frames, bb)          # 2026-09-20：逐帧轨迹寄存器状态（M5 用）
    mots, mbbs, _mcnt = m6_stats(frames, mut)
    frames_txt = np.array(MODE_SCHED[:frames])
    exp = np.empty((frames, H, W, 3), dtype=np.uint8)
    for f in range(frames):
        mode = int(frames_txt[f])
        if mut.get("mode_off"):
            mode = (mode + mut["mode_off"]) % 8
        bp = bb[f - 1] if f >= 1 else None
        if mut.get("bbox_current"):
            bp = bb[f]
        tp = tr[f]
        if mut.get("trail_off"):
            # 变异：把轨迹状态整体**往前**取若干帧（判据会报红才算自证）。
            # ⚠ 方向不能反：写成 `f+k` 时，M5 是档位表最后一帧，会被 min(...,frames-1)
            #   钳回 f 本身 ⇒ 变异变成**空操作**，"抓不住"是假的（2026-09-20 踩过）。
            tp = tr[max(f - int(mut["trail_off"]), 0)]
        if mode == MODE_M7:
            exp[f] = m7_frame(imgs[f], mut)
        elif mode == MODE_M6:
            exp[f] = variant_out(imgs[f], mode, mut, bbox_prev=bp,
                                 img_prev=(imgs[f - 1] if f >= 1 else None),
                                 mot_bb_prev=(mbbs[f - 1] if f >= 1 else None),
                                 mot=mots[f], mot_bb_cur=mbbs[f])
        elif mut:
            exp[f] = variant_out(imgs[f], mode, mut, bbox_prev=bp, trail=tp)
        else:
            exp[f] = _pipe(mode, mut).process(imgs[f], bbox_prev=bp,
                                              trail=tp).image
    return exp, pin_beats(exp), bb


# ===========================================================================
# 1. dump 解析（numpy 向量化；不逐点 Python 循环）
# ===========================================================================
#  行格式（tb_alg_top_full.v 的 $fwrite 顺序）：
#     cyc Iv Il Iu <24 hex> Ov Ol Ou <24 hex> Omode bbv cnt x0 x1 y0 y1
#  ⚠ 字段**不是定宽**（cyc 是 %0d，不补零；%h 也不补零），所以不能按字节偏移切列。
#    这里用两条正则路径：
#      · hex 字段：全局匹配 `[0-9a-fA-F]{24}`（每行恰好 2 个：I_tdata / O_tdata）。
#        行内其余数字串最长 4 位（11 位端口值最大 2047）⇒ 不可能被误当成 24 位 hex。
#        `[-]?[0-9]{24}` 也不存在（没有任何字段有 24 位十进制数）。
#      · 其余字段：把两个 hex 字段**替换成 '0'** 后整块 fromstring 成 float64，
#        再 reshape(-1, 16)。用 float64 是因为端口值最大 2047、拍号最大 3e6，
#        全都在 2^53 内可精确表示。
#      · X/Z：hex 字符以外没有 x/z 字符，所以 $readmemh 风格 x/z 只会出现在
#        O_tdata 字段里，用「含 x/X/z/Z 的 24 字符串」单独抓。
_HEXL = 24
# 一个 tdata 字段 = 24 个"hex 或 x/z"字符，且后面必须紧跟空白或行尾（词边界），
# 否则会把更长的串截成 24 位。`(?=[\s]|$)` 是前瞻断言，不消费字符。
_REXX_END = re.compile(rb"(?<![0-9a-fA-FxXzZ])[0-9a-fA-FxXzZ]{%d}(?=[\s]|$)" % _HEXL)
# ⚠ 2026-09-17 修（**既有脆性**，被 M6 的 X 传播变异暴露出来）：
#   旧版假设"X/Z 只可能出现在 O_tdata 的 24 位 hex 字段里"。一旦**数字字段**
#   （O_bbox_x0/x1/y0/y1 用 %d、cnt 用 %d）拿到 X，ModelSim 会打成 `x`/`X`，
#   于是 np.fromstring 直接抛 ValueError —— 表面看像"解析器坏了"，其实是
#   "RTL 把 X 泄进了状态输出"。现在把这些 token 记成 flag（当 0 参与解析），
#   交给判据 F 报红，而不是让整个 checker 崩掉。
_REXX_NUMX = re.compile(rb"(?<![0-9a-zA-Z_])[xXzZ]+(?![0-9a-zA-Z_])")


def _parse_chunk(lines):
    """把一批"完整行"解析成 (n, 2, 24) 的 tdata 字节块 + (n, NCOL) 的 float64 数值块
    + (n,) 的"数字字段带 x/z"标志（见 _REXX_NUMX）。

    只做"行内"工作，所以可以按块调用（全尺寸 12 帧 dump ≈ 300 MB，整块读会到 GB 级内存）。
    """
    blob = b"\n".join(lines)
    hx = _REXX_END.findall(blob)
    if len(hx) != 2 * len(lines):
        raise SystemExit("本块 hex 字段数 %d != 2 x %d 行 —— dump 格式变了"
                         % (len(hx), len(lines)))
    idt = np.frombuffer(b"".join(hx), dtype=np.uint8).reshape(-1, 2, _HEXL)
    num = _REXX_END.sub(b"0", blob)
    # 数字字段里的 x/X/z/Z：记下所在行，替换成 0 再解析（不让 checker 崩掉）
    line_x = np.zeros(len(lines), dtype=bool)
    hits = [m.start() for m in _REXX_NUMX.finditer(num)]
    if hits:
        nl_pos = np.flatnonzero(np.frombuffer(num, dtype=np.uint8) == 10)
        li = np.searchsorted(nl_pos, hits, side="left")
        line_x[li[li < len(lines)]] = True
        num = _REXX_NUMX.sub(b"0", num)
    vals = np.fromstring(num, dtype=np.float64, sep=" ")
    if vals.size != NCOL * len(lines):
        raise SystemExit("本块字段数 %d != %d x %d 行" % (vals.size, NCOL, len(lines)))
    return idt, vals.reshape(-1, NCOL), line_x


def parse(path, quiet=False, chunk_lines=200000):
    """按行分块解析 dump（内存只与本块大小相关，与文件总长无关）。"""
    global NCOL
    t0 = time.time()
    if not os.path.isfile(path):
        raise SystemExit("找不到 %s —— 先跑 tb_alg_top_full.v" % path)
    # 2026-09-20：列数从 dump 首行**自己读**，不再写死。
    #   第 16 列（O_color_class）是追加在末尾的，所以老 dump 是 16 列、新 dump 是 17 列。
    #   写死成 17 会让所有历史 dump 直接崩（"字段数不符"），写死成 16 又会让新列读不到。
    with open(path, "rb") as fh0:
        for ln in fh0:
            ln = ln.strip()
            if ln:
                nf = len(ln.split())
                if nf not in (16, 17, 18):
                    raise SystemExit("dump 每行 %d 个字段，既不是 16（2026-09-20 之前）、"
                                     "17（含 O_color_class）也不是 18（含 O_track_id）" % nf)
                NCOL = nf
                break
        else:
            raise SystemExit("dump 是空文件：%s" % path)
    idt_parts, v_parts, x_parts = [], [], []
    n = 0
    buf = []
    with open(path, "rb") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            buf.append(ln)
            if len(buf) >= chunk_lines:
                idt, v, lx = _parse_chunk(buf)
                idt_parts.append(idt)
                v_parts.append(v)
                x_parts.append(lx)
                n += len(buf)
                buf = []
    if buf:
        idt, v, lx = _parse_chunk(buf)
        idt_parts.append(idt)
        v_parts.append(v)
        x_parts.append(lx)
        n += len(buf)
    if n < 10:
        raise SystemExit("dump 只有 %d 行，格式不对" % n)
    idtxt = np.concatenate(idt_parts, axis=0)
    v = np.concatenate(v_parts, axis=0)
    numx = np.concatenate(x_parts, axis=0)          # 数字字段带 x/z 的行（见 _REXX_NUMX）
    if not np.isfinite(v).all():
        raise SystemExit("有 %d 个字段解析失败（NaN）—— dump 有异常字符"
                         % int((~np.isfinite(v)).sum()))
    xzb = _HZ[idtxt[:, 1]].any(axis=1) | _HZ[idtxt[:, 0]].any(axis=1) | numx

    def col(i, dt=np.int64):
        return v[:, i].astype(dt)

    d = {
        "cyc": col(0, np.int64),
        "Iv": col(1, np.int8).astype(bool),
        "Il": col(2, np.int8).astype(bool),
        "Iu": col(3, np.int8).astype(bool),
        "id_hi": _hex48_to_pair(idtxt[:, 0])[0],
        "id_lo": _hex48_to_pair(idtxt[:, 0])[1],
        "Oxz": xzb,
        "numx": numx,                    # 数字字段（O_bbox_* / cnt 等）带 x/z 的行
        "Ov": col(5, np.int8).astype(bool),
        "Ol": col(6, np.int8).astype(bool),
        "Ou": col(7, np.int8).astype(bool),
        "od_hi": _hex48_to_pair(idtxt[:, 1])[0],
        "od_lo": _hex48_to_pair(idtxt[:, 1])[1],
        "omode": col(9, np.int8),
        "bbv": col(10, np.int8).astype(bool),
        "cnt": col(11, np.int64),
        "bx0": col(12, np.int64), "bx1": col(13, np.int64),
        "by0": col(14, np.int64), "by1": col(15, np.int64),
        # 2026-09-20：第 16 列 = O_color_class。老 dump（16 列）没有 ⇒ None，
        #   判据 N 打印"跳过 + 原因"而不是假装通过。
        "ocls": (col(16, np.int8) if NCOL >= 17 else None),
        "otid": (col(17, np.int16) if NCOL >= 18 else None),
        "_ncol": NCOL,
    }
    del v, idtxt, idt_parts, v_parts
    # ⚠ 不裁剪收尾拍：TB 的收尾长度是它自己按 TAIL_CYC 决定的（= LAT + BLANK_LEN + 2），
    #   而判据 I 要用"最后一个有效拍之后还有多少拍 tvalid=0"当门禁。曾经在这里裁到
    #   `last + LAT + 3`，等于把收尾消隐自己砍掉，判据 I 就永远报"收尾消隐不足"——
    #   那是 checker 造出来的假 FAIL。收尾拍在判据 A 里是**真**断言（O_tvalid 必须为 0）。
    last = int(np.nonzero(d["Iv"])[0][-1])
    cut = n
    for k in list(d):
        # ⚠ 只切**数组**：老 dump（16 列）没有 ocls 这一列，占位是 None；_ncol 是标量。
        #   第一版无条件 `d[k][:cut]`，直接崩在 None 上；第二版只跳 None，又崩在标量上。
        #   教训：加一列/加一个键的时候，**后面每一处"遍历整个 d"的地方都要跟着过一遍**。
        if not isinstance(d[k], np.ndarray):
            continue
        d[k] = d[k][:cut]
    d["ncycles"] = cut
    d["_path"] = path          # 供 check_stim 找同目录的 stim hex
    if d["cyc"][-1] - d["cyc"][last] < LAT:
        raise SystemExit("dump 在最后 1 个有效拍之后只有 %d 拍，连流水线都没冲干净"
                         % int(d["cyc"][-1] - d["cyc"][last]))
    idx = np.nonzero(d["Iv"])[0]
    oc = np.nonzero(d["Ov"])[0]
    k = np.arange(idx.size, dtype=np.int64)
    d["nbeats_in"] = int(idx.size)
    d["nbeats_out"] = int(oc.size)
    # ⚠ 不在这里 raise：有效拍数不等本身就是**被测对象的一种失败形态**（变异测试会造出来，
    #   例如输出多吐一拍）。raise 会以 SystemExit 终止整个 checker，看起来像"工具崩了"，
    #   实际是"抓到了"。改为截到公共长度继续判，并把差值交给判据 A 记成不符。
    nb = min(int(idx.size), int(oc.size))
    d["nbeats"] = nb
    idx, oc = idx[:nb], oc[:nb]
    k = k[:nb]
    d["vidx"] = idx          # 第 i 个输入有效拍的周期号
    d["ocidx"] = oc          # 第 i 个输出有效拍的周期号
    # 坐标按**输入有效拍序**索引（长度 = nbeats，激励侧，判据 I/J 用）
    #
    # ⚠⚠ 2026-09-16 实测钉死的坑（曾导致一份"每行末尾 5 拍输出恒 0"的**假** bug 报告）：
    #   判据 A 已证 O_tvalid[t] == I_tvalid[t-LAT]；_m0_delay_probe 进一步实测
    #   O_tdata[t] == I_tdata[t-LAT] 在全部 230400 个有效周期上**逐周期全等**。
    #   ⇒ **第 i 个输出有效拍 = 第 i 个输入有效拍**（拍序一一对应，**不需要**在拍轴上
    #     再补偿 LAT；LAT 只体现在周期轴上）。所以输出侧各列必须按【输出】有效拍的
    #     周期取样：按输入有效拍取样会拿到 5 拍之前的值，而行首 5 拍的 t-LAT 落在
    #     行消隐（I_tdata=0）⇒ 行首 5 拍读出一片 0，形状酷似"行缓存丢行末 5 拍"。
    d["frm"] = k // BPF
    d["y"] = (k // BPL) % H
    d["xg"] = k % BPL
    d["idv_hi"], d["idv_lo"] = d["id_hi"][idx], d["id_lo"][idx]   # 第 i 个输入有效拍
    d["odv_hi"], d["odv_lo"] = d["od_hi"][oc], d["od_lo"][oc]    # 第 i 个输出有效拍
    d["omodev"] = d["omode"][oc]
    d["bbvv"] = d["bbv"][oc]
    d["cntv"] = d["cnt"][oc]
    # 2026-09-20：颜色类别也按**输出有效拍序**索引（判据 N 与 G 用同一套轴）。
    #   ⚠ oc 是"输出有效拍的周期号"，ocls 是逐周期数组：漏了这一步就会拿 1382400 长的
    #     布尔掩码去索引 1469314 长的数组 → IndexError。判据 G 早就踩过同一个坑，
    #     所以这里是照抄它的写法，不是自己发明。
    if d.get("ocls") is not None:
        d["oclsv"] = d["ocls"][oc]
    if d.get("otid") is not None:
        d["otidv"] = d["otid"][oc]
    d["bx0v"], d["bx1v"] = d["bx0"][oc], d["bx1"][oc]
    d["by0v"], d["by1v"] = d["by0"][oc], d["by1"][oc]
    if not quiet:
        print("  解析 %s：%d 拍（%d 个输入有效拍），%.1f s"
              % (path, cut, d["nbeats"], time.time() - t0))
    return d


_HLUT = np.full(256, 255, dtype=np.uint64)
for _i, _c in enumerate(b"0123456789"):
    _HLUT[_c] = _i
for _i, _c in enumerate(b"abcdef"):
    _HLUT[_c] = 10 + _i
for _i, _c in enumerate(b"ABCDEF"):
    _HLUT[_c] = 10 + _i
_HZ = np.zeros(256, dtype=bool)
for _c in b"xXzZ":
    _HZ[_c] = True


def pack96(hi32, lo64):
    """占位：历史实现。**不要再用**（保留名字只为让旧引用立刻报错，见下）。

    ⚠⚠ 2026-09-16 实测定位到的**正确性缺陷**：旧实现是
        P = (hi32 << 32) | lo64
    而 hi32 << 32 占据 bit[63:32]、lo64 占据 bit[63:0] —— **两者按位或会重叠**：
        P 的 [63:32] = hi32 | lo64[63:32]
    于是 ① P 是**有损**的：hi32 与 lo64 的高 32 位被 OR 到一起，
            (hi=0, lo=X) 与 (hi=1, lo=X^(1<<32)) 会得到同一个 P
            ⇒ 用它做等值比较**可能把不同的 96bit 拍判成相等**（假 PASS 风险）；
         ② 从 P 里**无法**解出 pix0/pix1（它们的位跨越了 hi32 与 lo64 的边界）
            ⇒ 判据 E 的逐像素反解从这个表示上做，结果全是错的。
    这就是"E2 拍级 0 不符、E1 像素级却大面积多解/无解"的真因。
    正确做法：全程携带 **(hi32, lo64) 两个 uint64**，比较用两个都相等，解码按位拼接。
    """
    raise AssertionError("pack96 是有损表示，已废弃：请用 (hi32, lo64) 成对比较")


def _hex48_to_pair(txt):
    """(n,24) 的 hex ASCII -> (hi32, lo64) 两个 uint64（96 bit **精确**，x/z 记 255）。

    按冻结位序：tdata[95:64] = hi32、tdata[63:0] = lo64，两者拼接即完整 96 bit。
    """
    dg = _HLUT[txt]
    hi = np.zeros(txt.shape[0], dtype=np.uint64)
    for k in range(8):
        hi = (hi << np.uint64(4)) | dg[:, k]
    lo = np.zeros(txt.shape[0], dtype=np.uint64)
    for k in range(8, 24):
        lo = (lo << np.uint64(4)) | dg[:, k]
    return hi, lo


def _pair_of(img_beats):
    """A.pack_beats 的 (...,2) 输出 -> ((...,) hi32, (...,) lo64)。"""
    b = np.ascontiguousarray(img_beats).view(np.uint64).reshape(-1, 2)
    return (b[:, 0].astype(np.uint64) & np.uint64(0xFFFFFFFF)), b[:, 1].astype(np.uint64)


def _pix_of_pair(hi, lo, k):
    """从 (hi32, lo64) 精确解出第 k 个像素的 24bit 值（pix0 在 [95:72]）。

    位映射（冻结位序，见 alg_ref.pack_beats 的位图）：
        pix0 = tdata[95:72] = hi32[31: 8]
        pix1 = tdata[71:48] = {hi32[7:0], lo64[63:48]}
        pix2 = tdata[47:24] = lo64[47:24]
        pix3 = tdata[23: 0] = lo64[23: 0]
    """
    if k == 0:
        w = (hi >> np.uint64(8)) & np.uint64(0xFFFFFF)
    elif k == 1:
        w = ((hi & np.uint64(0xFF)) << np.uint64(16)) | ((lo >> np.uint64(48)) & np.uint64(0xFFFF))
    elif k == 2:
        w = (lo >> np.uint64(24)) & np.uint64(0xFFFFFF)
    else:
        w = lo & np.uint64(0xFFFFFF)
    return ((w >> np.uint64(16)) & np.uint64(0xFF)).astype(np.int64) << 16 \
        | ((w >> np.uint64(8)) & np.uint64(0xFF)).astype(np.int64) << 8 \
        | (w & np.uint64(0xFF)).astype(np.int64)


# ===========================================================================
# 2. 判据
# ===========================================================================
def lat_of_beat(d, mut=None):
    """逐**输出有效拍**的期望延迟：M7 帧 LAT_M7=8，其余帧 LAT=5。

    ⚠ 为什么必须逐档：M7 支路数据在延迟 7 拍、控制取 u_rf 自己的（见 alg_top.v §一·补），
      所以 M7 帧在**周期轴**上整体晚 3 拍；而在**拍轴**上第 i 个输出有效拍仍然等于
      第 i 个输入有效拍（u_rf 的 tvalid/tlast/tuser 与它的输入严格同拍、延迟恒定）。
      mut["lat"] 给了就整体覆盖（变异自证："按 4 拍比 / 按 6 拍比 / M7 也按 5 拍比"）。
    """
    mut = mut or {}
    if "lat" in mut:
        return np.full(d["nbeats"], int(mut["lat"]), dtype=np.int64)
    mp = mode_sched_arr()
    f = np.minimum(d["frm"], mp.size - 1)
    return np.where(mp[f] == MODE_M7, LAT_M7, LAT).astype(np.int64)


def exp_out_ctl(d, mut=None):
    """按"逐档延迟"算出的期望输出控制（周期轴）：(ev, el, eu)。"""
    n = d["ncycles"]
    ic = np.nonzero(d["Iv"])[0]
    lat = lat_of_beat(d, mut)
    dst = ic + lat
    ok = dst < n
    ev = np.zeros(n, dtype=bool)
    el = np.zeros(n, dtype=bool)
    eu = np.zeros(n, dtype=bool)
    ev[dst[ok]] = True
    el[dst[ok]] = d["Il"][ic[ok]]
    eu[dst[ok]] = d["Iu"][ic[ok]]
    return ev, el, eu


def check_a(d, mut=None, verbose=True):
    """A：控制信号逐拍 = 输入延迟 LAT 拍（**M7 帧 = LAT_M7 = 8 拍**，其余 5 拍）。

    ⚠ 2026-09-18 M7 起本判据**逐档**：M7 是唯一延迟不是 5 的档位（理由见 alg_top.v §一·补）。
      这不放宽任何一条期望 —— 每个输出有效拍仍然必须逐周期等于对应输入有效拍延迟
      **它自己那一档**的拍数。
    """
    mut = mut or {}
    n = d["ncycles"]
    ic = np.nonzero(d["Iv"])[0]
    ev, el, eu = exp_out_ctl(d, mut)
    bad_v = int((d["Ov"] != ev).sum())
    bad_l = int((d["Ol"] != el).sum())
    bad_u = int((d["Ou"] != eu).sum())
    nass = 3 * n
    lat = lat_of_beat(d, mut)
    dst = ic + lat
    oc = np.nonzero(d["Ov"])[0]
    nass += max(int(ic.size), int(oc.size))
    m = min(int(ic.size), int(oc.size))
    bad_beat = abs(int(ic.size) - int(oc.size))
    if bad_beat == 0:
        bad_beat = int((oc[:m] != dst[:m]).sum())
    if verbose:
        first = None
        badm = (d["Ov"] != ev) | (d["Ol"] != el) | (d["Ou"] != eu)
        if badm.any():
            i = int(np.nonzero(badm)[0][0])
            first = (int(d["cyc"][i]), int(d["Ov"][i]), int(d["Ol"][i]), int(d["Ou"][i]))
        print("  O_tvalid 不符 %-6d  O_tlast 不符 %-6d  O_tuser 不符 %-6d  首错拍=%s"
              % (bad_v, bad_l, bad_u, first))
        print("  逐档延迟：M0..M6 = %d 拍，M7 = %d 拍（本跑的档位表里 M7 帧 %s）"
              % (LAT, LAT_M7,
                 [int(x) for x in np.nonzero(mode_sched_arr()[:min(FRAMES_ALL, d["nbeats"]
                                                                  // BPF + 1)] == MODE_M7)[0]]))
        print("  有效拍数：输入 %d / 输出 %d；第 i 个输出有效拍 = 第 i 个输入有效拍 + 该档延迟，"
              "不符 %d  %s" % (ic.size, oc.size, bad_beat,
                               "PASS" if (bad_v + bad_l + bad_u + bad_beat) == 0 else "FAIL"))
    return nass, bad_v + bad_l + bad_u + bad_beat


def beat_axes(d, frames):
    """拍轴：**第 i 个输出有效拍 = 第 i 个输入有效拍**（一一对应，不做 LAT 补偿）。

    依据（两条，都是实测而不是推导）：
      · 判据 A：O_tvalid[t] == I_tvalid[t-LAT]（244793 个周期上不符 0）；
      · _m0_delay_probe：M0 档 O_tdata[t] == I_tdata[t-LAT]（230400 个有效周期全等）。
    ⇒ 输出有效拍序与输入有效拍序是同一套序号，LAT 只体现在**周期轴**上。

    ⚠ 曾经的错误实现：在这里减 LAT（把输出拍 i 当作输入拍 i-LAT），等于在"输出列已按
      输出拍序取样"之外又叠加了一次补偿；若再配上"按输入拍序取 O_* 列"，两个错会互相
      伪装成"行末 5 拍为 0"的行缓存 bug。不要再往这里加位移。

    返回 (f, y, xg, valid)：第 i 个输出有效拍对应的输入拍坐标；valid 全 1。
    """
    f = np.minimum(d["frm"], frames - 1)
    return f, d["y"], d["xg"], np.ones(d["nbeats"], dtype=bool)


def check_b(d, exp_pack, frames, mut=None, verbose=True):
    """B：6 档逐拍对金标准（一次向量化比对 276 万拍）。"""
    mut = mut or {}
    f, y, xg, valid = beat_axes(d, frames)
    got_hi, got_lo = d["odv_hi"], d["odv_lo"]
    off = mut.get("beat_off", 0)
    off_modes = set(mut.get("beat_off_modes", ()))
    if off:
        modes = np.array(MODE_SCHED[:frames])[f]
        m = np.isin(modes, list(off_modes))
        xg = np.where(m, np.clip(xg + off, 0, BPL - 1), xg)
    w_hi, w_lo = beats_at(exp_pack, f, y * BPL + xg)
    eq = ((got_hi == w_hi) & (got_lo == w_lo)) | (~valid)
    nass = int(eq.size)
    nbad = int((~eq).sum())
    if verbose:
        modes = np.array(MODE_SCHED[:frames])[f]
        for mm in range(7):
            sel = (modes == mm) & valid
            n = int(sel.sum())
            if n:
                print("  %-9s 比较 %8d 拍，不符 %-6d  %s"
                      % (MODE_NAMES[mm], n, int((~eq & sel).sum()),
                         "PASS" if not (~eq & sel).any() else "FAIL"))
        if nbad:
            i = int(np.nonzero(~eq)[0][0])
            print("    首错：输出有效拍 %d 帧 %d 行 %d 拍号 %d  got %08X_%016X want %08X_%016X"
                  % (i, f[i], y[i], xg[i], int(got_hi[i]), int(got_lo[i]),
                     int(w_hi[i]), int(w_lo[i])))
    return nass, nbad


def check_c(d, exp_img, frames, mut=None, verbose=True):
    """C：掩蔽区（前 2 行 + 每行第 0 拍 = 列 0..3）必须输出**原图**（不是黑屏/算法结果）。

    ⚠ 2026-09-18 M7：**M7 帧不适用本条**，被显式排除。顶层掩蔽是对齐在延迟 4 拍的，
      而 M7 支路在延迟 7 拍，叠上去会把掩蔽区整体挪 3 拍（= 每行 12 像素）——
      所以 alg_top 对 M7 档**不叠**顶层掩蔽，改用 u_rf 自带的掩蔽（前 3 行 + 每行第 0 拍
      ⇒ 掩蔽区输出**黑**）。M7 的掩蔽语义由判据 M（check_m7）单独钉死，一条都没少。
    """
    mut = mut or {}
    f, y, xg, valid = beat_axes(d, frames)
    got_hi, got_lo = d["odv_hi"], d["odv_lo"]
    mp = mode_sched_arr()
    is7 = mp[np.minimum(f, mp.size - 1)] == MODE_M7
    if mut.get("c_mask_extra_beat"):
        msel = (y < 2) | (xg < 2)
    elif mut.get("c_mask_row0_only"):
        msel = (y < 1) | (xg == 0)
    else:
        msel = (y < 2) | (xg == 0)
    msel = msel & valid & ~is7
    idx = np.nonzero(msel)[0]
    ff, yy, gg = f[idx], y[idx], xg[idx]
    # 期望 = 该帧**原图**的整拍；一次算好整帧再按 (帧,行,拍号) 取
    pb = pin_beats(exp_img)
    ov_hi, ov_lo = beats_at(pb, ff, yy * BPL + gg)
    if mut.get("mask_black"):
        ov_hi = np.zeros_like(ov_hi)
        ov_lo = np.zeros_like(ov_lo)
    eq = (got_hi[idx] == ov_hi) & (got_lo[idx] == ov_lo)
    nass = int(eq.size) * 4
    nbad = int((~eq).sum()) * 4
    # ---- 掩蔽**集合**本身也要卡死（2026-09-17 修）------------------------------
    # 判据 C 的"期望"是金标准帧，而金标准帧在**非掩蔽**拍上装的是算法结果 ——
    # 于是"多盖一拍"（msel 变大）与"少盖一拍"（msel 变小）这两条改期望值的变异会
    # **互相抵消**：多盖的那些拍上，DUT 输出算法结果、金标准帧在那些拍上也是算法结果
    # ⇒ 逐位相等 ⇒ 变异逃逸。实测证据：sim/_full6_selftest3.log（本次改动之前的日志）
    # 里这两条就是 "!! 漏掉 !!"。这不是 RTL 的问题，是**判据自己的期望集没被钉住**。
    # 修法：把"被判的拍集合"直接钉死成冻结规格的掩蔽集（S0-02 §6：前 2 行 + 每行第 0 拍），
    # 多盖/少盖都当场报红 —— 判据仍然逐像素比原图，一条期望都没放宽。
    truth = ((y < 2) | (xg == 0)) & valid & ~is7
    nass += 1
    if not np.array_equal(msel, truth):
        nbad += 1
        if verbose:
            print("    !! 掩蔽集与冻结规格（前 2 行 + 每行第 0 拍）不符：多 %d 拍 / 少 %d 拍"
                  % (int((msel & ~truth).sum()), int((truth & ~msel).sum())))
    if verbose:
        modes = mp[ff]
        for mm in range(8):
            sel = (modes == mm)
            if sel.any():
                print("  %-9s 掩蔽 %8d 拍（%d 像素），不符 %-6d  %s"
                      % (MODE_NAMES[mm], int(sel.sum()), int(sel.sum()) * 4,
                         int((~eq & sel).sum()) * 4,
                         "PASS" if not (~eq & sel).any() else "FAIL"))
        print("  掩蔽拍合计 %d（%d 像素）；M7 帧 %d 拍不在本条内（见判据 M）"
              % (nass // 4, nass, int(is7.sum())))
    return nass, nbad


def check_d(d, frames, mut=None, verbose=True):
    """D：整帧之内 O_mode 恒定 + 等于该帧期望档位。"""
    mut = mut or {}
    f, y, xg, valid = beat_axes(d, frames)
    got = d["omodev"]
    if mut.get("d_early"):
        k = np.arange(d["nbeats"], dtype=np.int64)
        f = np.minimum(frames - 1, (np.clip(k - LAT, 0, None) + 4) // BPF)
    want = (np.array(MODE_SCHED[:frames])[f] + mut.get("mode_off", 0)) % 8
    eq = (got == want) | (~valid)
    nass = int(eq.size)
    nbad = int((~eq).sum())
    nonconst = 0
    for fr in range(frames):
        sel = valid & (f == fr)
        if sel.any() and np.unique(got[sel]).size != 1:
            nonconst += 1
    nass += frames
    nbad += nonconst
    if verbose:
        print("  逐拍 O_mode 与期望档位不符 %-6d / %d 拍  整帧内换过档的帧 %d  %s"
              % (int((~eq).sum()), eq.size, nonconst,
                 "PASS" if nbad == 0 else "FAIL"))
        # ⚠ .tolist()：不转的话 numpy 数组会被 %s 打印成上万个整数的一整屏
        print("  各帧 O_mode 取值：%s"
              % "  ".join("f%d=%s" % (fr, np.unique(got[valid & (f == fr)]).tolist())
                          for fr in range(frames)))
    return nass, nbad


def check_e(d, frames, mut=None, verbose=True):
    """E：M3 的 src 到底来自哪一行 —— 反解 + 4 候选对照（判据只在 M3 帧上跑）。"""
    mut = mut or {}
    F = MODE_SCHED.index(A.MODE_EDGE)
    if F >= frames:
        if verbose:
            print("  ⚠ 本次只跑 %d 帧，没有 M3 帧（M3 在第 %d 帧）—— 本条判据本跑不可用"
                  % (frames, F + 1))
        return 0, 0
    img = images(frames)[F]
    f, yall, xgall, valid = beat_axes(d, frames)
    # ⚠ 只反解**未被掩蔽**的拍：掩蔽拍输出的原图（不是窗口结果），拿它反解 src 行没有意义。
    #   掩蔽集 = (y<2) | (xg==0)（与判据 C 实测的集合一致），这里补上这个过滤。
    sel = (f == F) & valid & (yall >= 2) & (xgall != 0)
    y = yall[sel]
    xg = xgall[sel]
    gv_hi = d["odv_hi"][sel]
    gv_lo = d["odv_lo"][sel]
    nass = nbad = 0

    # ---- E1 反解：把每个待解像素的 24bit 值，与**它自己那一列**的全部 H 行的
    #      "原值 / 提亮值" 比对，取命中行数 == 1 的那些作为解。 ----
    #   ⚠⚠ 2026-09-16 修掉的三个坑（本条判据此前**从未真正跑过** —— 1 帧时没有 M3 帧，
    #     check_e 直接返回 (0,0)，所以缺陷一直藏着）：
    #       (1) 旧代码用 `P = W // W_SMALL` 当"列图案周期"（1280/32=40）去建 40 个代表列，
    #           再用 `cid = xs // P` 索引 —— 可图像的真实列周期是 **W_SMALL = 32 像素**，
    #           而且红块覆盖会打破周期性。⇒ 改为**逐列建精确 key 表**。
    #       (2) 引用了没导入的 W_SMALL（NameError）。
    #       (3) 最关键的：像素是从**有损**的 pack96 表示里解的（见 pack96 注释），
    #           解出来全是垃圾 ⇒ 现在改成从 (hi32, lo64) 精确解码。
    r_ch = img[:, :, 0].astype(np.int32)
    g_ch = img[:, :, 1].astype(np.int32)
    b_ch = img[:, :, 2].astype(np.int32)
    key_lo = ((r_ch << 16) | (g_ch << 8) | b_ch)                              # (H,W)
    key_hi = ((np.minimum(r_ch + EDGE_K, 255) << 16)
              | (np.minimum(g_ch + EDGE_K, 255) << 8)
              | np.minimum(b_ch + EDGE_K, 255)).astype(np.int32)               # (H,W)
    col0 = xg * 4
    xs = np.stack([col0 + p for p in range(4)], axis=1)           # (N,4) 列号
    dec = np.full(xs.shape, -1, dtype=np.int32)
    amb = np.zeros(xs.shape, dtype=bool)
    CH = 2000
    for s in range(0, xs.shape[0], CH):
        e = min(xs.shape[0], s + CH)
        blk = xs[s:e]                                              # (m,4) 实际列号
        kv = np.stack([_pix_of_pair(gv_hi[s:e], gv_lo[s:e], p) for p in range(4)],
                      axis=1)                                      # (m,4) 24bit 精确解码
        # (H, m, 4) -> (m, H, 4)：每列 H 行是否命中
        kl = key_lo[:, blk].transpose(1, 0, 2)
        kh = key_hi[:, blk].transpose(1, 0, 2)
        hit = (kl == kv[:, None, :]) | (kh == kv[:, None, :])   # (m, H, 4)
        cnt = hit.sum(axis=1)                                   # (m, 4) 命中行数
        amb[s:e] = (cnt != 1)
        dec[s:e] = np.argmax(hit, axis=1).astype(np.int32)       # (m, 4) 解出的源行
        del kl, kh, hit
    want = y[:, None] + int(mut.get("e_dy", -1))
    nass += int(xs.size)
    namb = int(amb.sum())
    nres = int(xs.size) - namb
    nbadrow = int(((~amb) & (dec != want)).sum())
    # ---- 2026-09-16 判据修正 ----------------------------------------------
    # 旧写法：nbad += amb.sum() + nbadrow  —— 把「多解/无解」直接算成失败。
    # 「猜不出来」≠「猜错了」：合成测试图同一列常有跨行重复的像素值（平坦背景等），
    #   E1 的反解法对这类像素本质上无法唯一定位。实测歧义 34,306 / 916,168 = 3.74%，
    #   而「解出的行 != 期望行」= 0 —— 凡是能唯一解出的像素，行号一个都没错。
    # 但**不能只把歧义从失败里删掉就完事**（那等于把判据改松），所以补三条硬约束：
    #   (1) 已唯一解出的像素，行号必须 0 错（真正的失败形态，保留）；
    #   (2) 唯一解出数必须 > 0，否则判 FAIL（防空跑）；
    #   (3) 歧义率必须 < E1_AMB_CEIL，否则判 FAIL —— 防止歧义悄悄涨到 100% 把这条判据掏空。
    # 定位：E1 是**弱判据**（受激励图内容限制）。**硬判据是下面的 E2 四候选对照**：
    #   正确假设必须 0 失配、三个错误假设必须大面积失配，且自带"无鉴别力"自检。
    nbad += nbadrow
    if nres == 0:
        nbad += 1
    elif namb > int(E1_AMB_CEIL * xs.size):
        nbad += 1
    if verbose:
        i = None
        badm = ~amb & (dec != want)
        if badm.any():
            w = np.nonzero(badm)
            i = (int(w[0][0]), int(xs[w][0]), int(dec[w][0]), int(want[w[0][0], 0]))
        print("  反解 %d 个像素：唯一定位 %d（行号错 %d），多解/无解 %d（%.2f%%，上限 %.0f%%）"
              "  首错=%s  %s"
              % (xs.size, nres, nbadrow, namb, 100.0 * namb / xs.size,
                 100.0 * E1_AMB_CEIL, i, "PASS" if nbad == 0 else "FAIL"))

    # ---- E2：4 候选逐像素对照（正确候选必须 0 不符；错候选必须大面积不符） ----
    cands = {
        "彩色第 y-1 行（正确）": {"src_dy": -1},
        "彩色第 y 行（少延迟一行）": {"src_dy": 0},
        "彩色第 y-2 行（多延迟一行）": {"src_dy": -2},
        "灰度中心行（规格记的坑）": {"src_gray": True},
    }
    for name, mm in cands.items():
        ex = variant_out(img, A.MODE_EDGE, mm)
        w_hi, w_lo = beats_at(pin_beats(ex), None, yall[sel] * BPL + xgall[sel])
        bad = int(((gv_hi != w_hi) | (gv_lo != w_lo)).sum())
        is_ref = (not mm.get("src_gray")) and mm.get("src_dy", -1) == -1
        nass += int(gv_hi.size)
        if is_ref:
            nbad += bad
        elif bad == 0:
            nbad += 1
        if verbose:
            print("  候选 [%s]：不符 %8d / %d 拍  %s"
                  % (name, bad, gv_hi.size, "匹配（正确候选）" if is_ref else
                     ("不匹配（应当如此）" if bad else "!! 无鉴别力 !!")))
    return nass, nbad


def check_xz(d, frames, verbose=True):
    """F：输入有效拍上输出不允许 X/Z。

    在**输出拍轴**上判：输入有效拍 i 的 O_tdata 出现在输出有效拍 i+LAT 上。
    """
    nbeats = d["nbeats"]
    oc = np.nonzero(d["Ov"])[0]
    # ⚠ 不 raise：输出有效拍数与输入不等本身是一种失败形态（变异会造出来），
    #   parse() 已把拍级数组截到公共长度；这里只把差值计进不符，别让 checker 崩掉。
    nmis = abs(int(oc.size) - int(d["nbeats_in"]))
    oxz = d["Oxz"][d["vidx"]]
    nass = int(oxz.size) + 1
    nbad = int(oxz.sum()) + (1 if nmis else 0)
    if verbose:
        print("  有效拍输出出现 X/Z 的次数 = %d / %d  %s"
              % (nbad, nass, "PASS" if nbad == 0 else "FAIL"))
        if int(d["numx"].sum()):
            print("    其中**数字字段**（O_bbox_* / O_pix_count）带 x/z 的拍数 = %d"
                  "（状态输出被 X 污染，不是 hex 字段的问题）" % int(d["numx"].sum()))
        if nbad:
            i = int(np.nonzero(oxz)[0][0])
            print("    首错：输出有效拍 %d（输入有效拍 %d，帧 %d 行 %d 拍号 %d）"
                  % (i, i - LAT, i // BPF, (i // BPL) % H, i % BPL))
    return nass, nbad


def check_bbox(d, bb, frames, mb=None, mc=None, verbose=True):
    """G：bbox / pix_count / bbox_valid == 金标准（上一帧锁存），帧内可见。

    采样点选在"输出有效拍"上（拍轴口径见 beat_axes）：
      第 i 个输出有效拍 -> 第 i-LAT 个输入拍的 (帧, 行, 拍号)。

    **按帧的档位选族**（2026-09-17 M6）：
      · 帧 f 是 M5 ⇒ 期望 = 第 f-1 帧的 **颜色** bbox（既有行为，一字不改）；
      · 帧 f 是 M6 ⇒ 期望 = 第 f-1 帧的 **运动** bbox（= 帧 f-1 与 f-2 的帧差统计）。
    两族统计在 RTL 里都是逐帧连续累加的（u_det / u_mot 都在跑），alg_top 只在帧边界
    按"本帧生效的档位"选源，所以"进入 M6 的第一帧"也必须立刻报运动 bbox。
    """
    f, y, xg, valid = beat_axes(d, frames)
    mp = np.array(MODE_SCHED[:frames])
    pick = valid & (xg == 1) & (y == 1)         # 帧内固定采样点（每帧一次）
    nass = nbad = 0
    for fr in range(1, frames):
        i = np.nonzero(pick & (f == fr))[0]
        if i.size == 0:
            continue
        i = int(i[0])
        is_m6 = int(mp[fr]) == MODE_M6
        if is_m6:
            b = None if (mb is None or mb[fr - 1] is None) else mb[fr - 1]
            exp = (2047, 0, 2047, 0) if b is None else b       # (x0, x1, y0, y1)
            cnt_exp = 0 if (mc is None or fr < 1) else int(mc[fr - 1])
        else:
            b = bb[fr - 1]
            exp = (2047, 0, 2047, 0) if b is None else (b[0], b[2], b[1], b[3])
            cnt_exp = None
        got = (int(d["bx0v"][i]), int(d["bx1v"][i]),
               int(d["by0v"][i]), int(d["by1v"][i]))
        nass += 3
        if got != exp:
            nbad += 1
            if verbose:
                print("    帧 %d（%s）：O_bbox=%s（期望 %s）  <- FAIL"
                      % (fr, MODE_NAMES[int(mp[fr])], got, exp))
        if cnt_exp is None:
            if int(d["cntv"][i]) <= 0:                         # M5 帧必须 >0（既有门禁）
                nbad += 1
                if verbose:
                    print("    帧 %d：O_pix_count=%d（M5 帧必须 >0）  <- FAIL"
                          % (fr, int(d["cntv"][i])))
        else:
            if int(d["cntv"][i]) != cnt_exp:                   # M6 帧逐值比对
                nbad += 1
                if verbose:
                    print("    帧 %d：O_pix_count=%d（期望运动格子数 %d）  <- FAIL"
                          % (fr, int(d["cntv"][i]), cnt_exp))
        want_v = (cnt_exp is None) or (cnt_exp > 0)
        if bool(d["bbvv"][i]) != want_v:
            nbad += 1
            if verbose:
                print("    帧 %d：O_bbox_valid=%d（期望 %d）  <- FAIL"
                      % (fr, int(d["bbvv"][i]), int(want_v)))
    if verbose:
        print("  O_bbox_* / O_pix_count / O_bbox_valid 与金标准比对 %d 帧，不符 %d  %s"
              % (frames - 1, nbad, "PASS" if nbad == 0 else "FAIL"))
        print("  逐帧金标准 M5 bbox = %s" % (bb,))
        if mb is not None:
            print("  逐帧金标准 M6 运动 bbox（像素坐标 x0,x1,y0,y1）= %s" % (mb,))
            print("  逐帧金标准 M6 运动格子数 = %s" % (mc,))
    return nass, nbad


def check_m6(d, frames, mb, mc, mots, verbose=True):
    """L：M6 专属判据（2026-09-17 新增）—— 控制对齐 / 拍数 / 激励非空三门禁。

    为什么单独一条：M6 是本项目**唯一**带帧间状态的档位（帧差要上一帧），
    它的正确性除了"像素逐位对金标准"（判据 B）之外还有三件必须钉死的事：

      ① **控制与拍数**：M6 帧里 O_tvalid/O_tlast/O_tuser 相对输入仍是延迟 LAT 拍、
         输出有效拍数 == 输入有效拍数、O_tlast 仍每 BPL 拍一次、帧内不多不少
         （对齐错拍在本项目已经真实发生过一次：osd_mixer 数据链 2 拍 / 控制链 3 拍
         ⇒ 整帧偏移 4 像素。所以 M6 帧上单独再钉一遍，不靠"别的档位对了"外推。）
      ② **激励非空**：M6 帧的**本帧运动格子数 > 0** 且**显示的红框非空**。
         否则整条 M6 判据退化成"输出 == 原图"，白点和红框两条通路都成了空跑
         （0 次检查 = 失败，不是通过）。
      ③ **单帧一致性**：M6 帧的输出有效拍必须落在本帧的拍序区间内（不多吐拍）。
    """
    mp = np.array(MODE_SCHED[:frames])
    m6_frames = [fr for fr in range(frames) if int(mp[fr]) == MODE_M6]
    if not m6_frames:
        if verbose:
            print("  ⚠ 本跑的档位时序里**没有 M6 帧**（MODE_SCHED=%s）—— 本条不可用；"
                  "M6 的覆盖请用 160x64 / 7 帧（帧 i = 档位 i）" % (list(mp),))
        return 0, 0
    ic = np.nonzero(d["Iv"])[0]
    oc = np.nonzero(d["Ov"])[0]
    kk = np.arange(ic.size, dtype=np.int64)
    frm_in = kk // BPF
    ko = np.arange(oc.size, dtype=np.int64)
    frm_out = ko // BPF
    nass = nbad = 0
    nwht = nbox = 0
    for fr in m6_frames:
        # ① 控制延迟（周期轴）+ 输出拍序（拍轴）
        src = ic[frm_in == fr]
        dst = src + LAT
        ok = dst < d["ncycles"]
        nass += int(ok.sum())
        bad = ok & ((~d["Ov"][dst]) | (~d["Ol"][dst] & (d["Il"][src]))
                    | (~d["Ou"][dst] & (d["Iu"][src])))
        nbad += int(bad.sum())
        # 输出有效拍：**本帧的**输出有效拍必须 = **本帧的**输入有效拍 + LAT
        # ⚠ 2026-09-18 M7 起必须按帧取（M7 帧是 +8）：写成全局 `oc != ic + LAT`
        #   会把 M7 帧的 3 拍差值算到 M6 头上（实测：M7 接进来后 L 判据假报 1 处）。
        frm_o = np.arange(oc.size, dtype=np.int64) // BPF
        so = oc[frm_o == fr]
        si = ic[frm_in == fr]
        m = min(so.size, si.size)
        nass += 1
        if (so.size != si.size) or (so[:m] != si[:m] + LAT).any():
            nbad += 1
            if verbose:
                print("    帧 %d：输出有效拍数/位置与输入不符（%d vs %d）  <- FAIL"
                      % (fr, so.size, si.size))
        # 该帧的输出拍数 & O_tlast 计数
        ol = d["Ol"][so]
        nass += 1 + int(ol.size)
        if ol.size != BPL * H:
            nbad += 1
            if verbose:
                print("    帧 %d：输出有效拍 %d != %d（每行 %d x %d 行）  <- FAIL"
                      % (fr, ol.size, BPL * H, BPL, H))
        nbad += int((ol != ((np.arange(ol.size) % BPL) == BPL - 1)).sum())
        # ② 激励非空（本帧运动格子 / 显示的红框）
        cnt = int(mc[fr])
        box_nonempty = (mb[fr - 1] is not None) if fr >= 1 else False
        nass += 2
        if cnt <= 0:
            nbad += 1
            if verbose:
                print("    帧 %d：本帧运动格子数 = 0 —— M6 判据空跑（激励问题）  <- FAIL" % fr)
        if not box_nonempty:
            nbad += 1
            if verbose:
                print("    帧 %d：显示的红框为空 —— 画框通路空跑（激励问题）  <- FAIL" % fr)
        nwht += cnt
        nbox += 1 if box_nonempty else 0
    if verbose:
        print("  M6 帧 %s：控制/拍数断言 %d 条；本帧运动格子合计 %d（白点像素）；"
              "非空红框 %d/%d 帧  %s"
              % (m6_frames, nass, nwht, nbox, len(m6_frames),
                 "PASS" if nbad == 0 else "FAIL"))
        print("    （M6 像素本身逐位比对在判据 B 的 M6 行；本帧运动格子图 = %s）"
              % ([int(m.sum()) for m in mots],))
    return nass, nbad


def check_m7(d, frames, exp_img, mut=None, verbose=True):
    """M：M7 专属判据（2026-09-18 新增）—— 对齐 / 拍数 / 掩蔽语义 / 阈值口径 / 防空跑。

    为什么单独一条：M7 是本项目**唯一延迟不是 5** 的档位，也是唯一"输入要再过一级阈值、
    输出带模块自带掩蔽"的档位。除了"逐像素对金标准"（判据 B）之外还有五件必须钉死的事：

      ① **逐档延迟**：M7 帧里 O_tvalid/O_tlast/O_tuser 相对输入仍是延迟 LAT_M7=8 拍，
         输出有效拍数 == 输入有效拍数，O_tlast 每 BPL 拍一次（对齐错拍在本项目真发生过）；
      ② **拍序**：第 i 个输出有效拍（M7 帧内）必须落在第 i 个输入有效拍 + 8 拍的周期上；
      ③ **掩蔽语义**：M7 帧的掩蔽区（前 3 行 + 每行第 0 拍的 4 个像素）必须输出**黑**
         （= u_rf 自带掩蔽），**不能**是顶层那套"掩蔽期输出原图" —— 顶层掩蔽对齐在
         延迟 4 拍，对 M7 会整体挪 3 拍，所以 alg_top 对 M7 档不叠它（见 alg_top.v §9）。
         这一条同时验证了"没叠错掩蔽"和"掩蔽确实生效"；
      ④ **阈值口径**：binarize(M3 原始输出) 必须逐像素等于 Sobel 的 edge 掩码
         （RF_TH=128 的选值依据；不等就说明阈值/激励已经不匹配，必须重选，不是放宽）；
      ⑤ **防空跑**：M7 帧的期望输出既不能全黑（填不出东西）也不能几乎全白（吃实心图），
         且"裸填充 vs 带掩蔽填充"必须有差异（否则掩蔽根本没被测到）。
    """
    mut = mut or {}
    mp = mode_sched_arr()
    m7_frames = [fr for fr in range(frames) if int(mp[fr]) == MODE_M7]
    if not m7_frames:
        if verbose:
            print("  ⚠ 本跑的档位时序里**没有 M7 帧**（MODE_SCHED=%s）—— 本条不可用；"
                  "M7 的覆盖请用 160x64 / 8 帧（帧 i = 档位 i，第 8 帧走按键路径）"
                  % (list(mp[:frames]),))
        return 0, 0
    ic = np.nonzero(d["Iv"])[0]
    oc = np.nonzero(d["Ov"])[0]
    kk = np.arange(ic.size, dtype=np.int64)
    frm_in = kk // BPF
    nass = nbad = 0
    first = None
    for fr in m7_frames:
        # ① 控制延迟（周期轴）
        src = ic[frm_in == fr]
        dst = src + LAT_M7
        ok = dst < d["ncycles"]
        nass += int(ok.sum())
        bad = ok & ((~d["Ov"][dst]) | (~d["Ol"][dst] & (d["Il"][src]))
                    | (~d["Ou"][dst] & (d["Iu"][src])))
        nbad += int(bad.sum())
        # ② 拍序：**本帧的**输出有效拍必须落在**本帧的**输入有效拍 + 8 拍的周期上
        #    ⚠ 不能写成全局 `oc == ic + LAT`：其它档位是 5 拍，混在一起比会假报
        #      （实测踩到过：20480 vs 20480 计数相同、位置判据却整片报红）。
        frm_o = np.arange(oc.size, dtype=np.int64) // BPF
        so = oc[frm_o == fr]
        si = ic[frm_in == fr]
        m = min(so.size, si.size)
        nass += 1
        if (so.size != si.size) or (so[:m] != si[:m] + LAT_M7).any():
            nbad += 1
            if verbose:
                print("    帧 %d：M7 输出有效拍数/位置与输入不符（%d vs %d，延迟应为 %d）  <- FAIL"
                      % (fr, so.size, si.size, LAT_M7))
        # 该帧输出拍数 & O_tlast 计数
        ol = d["Ol"][so]
        nass += 1 + int(ol.size)
        if ol.size != BPL * H:
            nbad += 1
            if verbose:
                print("    帧 %d：M7 输出有效拍 %d != %d（每行 %d x %d 行）  <- FAIL"
                      % (fr, ol.size, BPL * H, BPL, H))
        nbad += int((ol != ((np.arange(ol.size) % BPL) == BPL - 1)).sum())

    # ③ 掩蔽语义 + ④ 阈值口径 + ⑤ 防空跑（全部在帧级图像上做，逐像素不重复判据 B）
    imgs = images(frames)
    for fr in m7_frames:
        img = imgs[fr]
        bin3 = m7_binarize(m3_raw(img), mut.get("m7_th", RF_TH))
        raw_mask = (bin3[:, :, 0] == 255)
        vm = m7_input_mask()
        out = exp_img[fr]
        white = (out[:, :, 0] == 255) & (out[:, :, 1] == 255) & (out[:, :, 2] == 255)
        # ③ 掩蔽区必须是黑：前 3 行 + 每行前 4 列（模块 r_y>=3 与 r_x!=0 的像素级等效）
        bmask = np.zeros((H, W), dtype=bool)
        bmask[:min(3, H), :] = True
        bmask[:, :min(4, W)] = True
        nass += 1
        if bool(white[bmask].any()):
            nbad += 1
            if verbose:
                print("    帧 %d：M7 掩蔽区里有 %d 个白像素（应为全黑）  <- FAIL"
                      % (fr, int(white[bmask].sum())))
        # 掩蔽**不是**顶层那套"输出原图"：掩蔽区里原图有非零像素，输出却必须全黑
        nass += 1
        if not bool((img[bmask] != 0).any()):
            nbad += 1
            if verbose:
                print("    帧 %d：掩蔽区原图本来就是全 0 —— 本条无鉴别力（激励问题）  <- FAIL"
                      % fr)
        # ④ 阈值口径：**未下移**的二值化结果 == Sobel edge 掩码（下移由 m3_raw 负责）
        #    ⚠ 2026-09-18 修：旧写法拿 m3_raw（已下移）去比未下移的 edge，差一行 ⇒
        #      假报 632 像素。这条判据是**阈值选值的依据**，必须逐像素精确。
        src = img.astype(np.int32)
        boost = np.where(m3_edge(img)[:, :, None],
                         A.sat8(src + np.int32(EDGE_K)), src).astype(np.uint8)
        bchk = (boost[:, :, 0] >= int(mut.get("m7_th", RF_TH))) \
            & (boost[:, :, 1] >= int(mut.get("m7_th", RF_TH))) \
            & (boost[:, :, 2] >= int(mut.get("m7_th", RF_TH)))
        ndiff = int((bchk != m3_edge(img)).sum())
        nass += 1
        if ndiff:
            nbad += 1
            if verbose:
                print("    帧 %d：RF_TH=%d 的二值化与 Sobel edge 掩码不符 %d 像素 "
                      "——阈值口径已不成立，必须重选阈值（不是放宽）  <- FAIL"
                      % (fr, int(mut.get("m7_th", RF_TH)), ndiff))
        # ④b 可信范围（前 2 行 + 每行第 0 拍）确实被声明为黑，且这段里 RTL 的 M3 值
        #     本来就与金标准不同 ⇒ 不掩蔽就会漏进填充（这条是本次实测定位的根因，留作回归）
        nass += 1
        nm_ = int((raw_mask & ~vm).sum())
        if nm_ == 0:
            nbad += 1
            if verbose:
                print("    帧 %d：可信范围外的二值化前景为 0 —— 掩蔽没有起点（激励问题）  <- FAIL"
                      % fr)
        # ⑤ 防空跑：前景占比不能是 0（填不出东西）也不能是实心（吃了实心图）
        nw = int(white.sum())
        nall = white.size
        nass += 2
        if nw == 0:
            nbad += 1
            if verbose:
                print("    帧 %d：M7 期望输出全黑 —— 判据空跑（阈值/输入源问题）  <- FAIL" % fr)
        if nw > int(0.95 * nall):
            nbad += 1
            if verbose:
                print("    帧 %d：M7 期望输出 %d/%d 全白 —— 吃了实心图  <- FAIL" % (fr, nw, nall))
        # 掩蔽确实改变了结果（裸填充 vs 带掩蔽填充）
        ideal = m7_frame_lowlevel(img, dict(mut, m7_nomask=True))
        nass += 1
        nd = int(((ideal == 255).any(axis=2) & ~white).sum())
        if nd == 0:
            nbad += 1
            if verbose:
                print("    帧 %d：裸填充与带掩蔽填充完全相同 —— 掩蔽没被测到  <- FAIL" % fr)
        if verbose:
            exc = int(white[~bmask].sum())
            print("    帧 %d：M7 前景 %d 像素（占整帧 %.1f%%，掩蔽区外 %d）；"
                  "掩蔽区白 %d（应 0）；二值化 vs edge 掩码不符 %d；裸/掩蔽差异 %d"
                  % (fr, nw, 100.0 * nw / nall, exc, int(white[bmask].sum()), ndiff, nd))
    if verbose:
        print("  M7 帧 %s：控制/拍数/掩蔽/阈值/非空断言 %d 条  %s"
              % (m7_frames, nass, "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


def check_stim(d, frames, verbose=True):
    """H：激励自检 —— dump 里的输入必须与 stim_top_*.hex 逐拍一致。"""
    here = os.path.dirname(os.path.abspath(__file__))
    # 小尺寸变异跑时，hex 会被拷到 work 目录（与 dump 同目录）；优先取那里
    cand = os.path.join(os.path.dirname(os.path.abspath(d.get("_path", ""))), HEXF) \
        if d.get("_path") else None
    hexp = cand if (cand and os.path.isfile(cand)) else os.path.join(here, HEXF)
    nb = nbeat(frames)
    raw = np.fromfile(hexp, dtype=np.uint8)
    raw = raw[raw != 0x0A]
    if raw.size % _HEXL:
        raise SystemExit("%s 长度 %d 不是 24 的倍数" % (HEXF, raw.size))
    raw = raw.reshape(-1, _HEXL)[:nb]
    ns = raw.shape[0]
    hex_hi, hex_lo = _hex48_to_pair(raw)
    # 拍级数组可能因"输出有效拍数与输入不等"被截短（变异会造出来），取两者的公共长度
    ns = min(ns, int(d["idv_hi"].size))
    nass = ns
    # ⚠ d["id*"] 是**逐周期**列，必须用 d["idv_*"]（逐有效拍）来比；用 id[:ns] 比等于
    #   把"周期序列"和"拍序列"对齐，除了前几拍之外全错（实测不符 231799/691202）。
    nbad = int(((hex_hi[:ns] != d["idv_hi"][:ns])
                | (hex_lo[:ns] != d["idv_lo"][:ns])).sum())
    k = np.arange(ns, dtype=np.int64)
    nass += 2 * ns
    nbad += int((d["Il"][d["vidx"][:ns]] != ((k % BPL) == BPL - 1)).sum())
    nbad += int((d["Iu"][d["vidx"][:ns]] != ((k % BPF) == 0)).sum())
    nass += 2
    # ⚠ 报"输入侧"的拍数要用 d["nbeats_in"]，**不要**用 d["nbeats"]：后者是输入/输出
    #   两者的公共长度，被变异改短时会误导成"激励少了 1 拍"（实测踩到过：
    #   "M5 补拍 2 拍 -> 1 拍" 的变异让 DUT 少吐 1 个有效拍，日志却像激励出问题）。
    if d["nbeats_in"] != nb:
        nbad += 1
        print("  !! dump 输入有效拍 %d != 期望 %d（激励/加载问题）" % (d["nbeats_in"], nb))
    if d["nbeats_out"] != d["nbeats_in"]:
        nbad += 1
        print("  !! 输出有效拍 %d != 输入有效拍 %d（DUT 少吐/多吐，判据 A 也报）"
              % (d["nbeats_out"], d["nbeats_in"]))
    if verbose:
        print("  dump 输入 %d 拍 vs %s（%d 拍）：data/tlast/tuser 比对 %d 条，不符 %d  %s"
              % (min(ns, d["nbeats"]), HEXF, nb, nass, nbad,
                 "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


def check_blanking(d, frames, verbose=True):
    """I：激励工况 —— 每行行末有行消隐、每帧末有帧消隐（真实链路工况门禁）。

    只读 dump 的 I_* 列，不读 RTL：
      · 行内相邻有效拍必须背靠背（间隔 1 拍）；
      · 普通行末 -> 下一行首：恰好 BLANK_LEN 个 tvalid=0 拍（间隔 1+BLANK_LEN）；
      · 帧末行末 -> 下一帧首：恰好 BLANK_LEN+EOF_BLANK 个 tvalid=0 拍；
      · 最后一个有效拍之后还要有 >= BLANK_LEN 拍 tvalid=0。
    为什么：真实链路（zhenghe.v:137-146 的 rd_valid / x_cnt）每行都有一段 valid=0，
    经 data128_96 / awb 纯寄存器延迟原样到达 alg_top 输入。没有行消隐的激励在真实
    系统里**不存在** —— 金标准在那种激励上通过不算验过。
    """
    ic = np.nonzero(d["Iv"])[0]
    gap = np.diff(ic)
    kk = np.arange(ic.size, dtype=np.int64)
    line_end = (kk[:-1] % BPL) == (BPL - 1)
    frame_end = (kk[:-1] % BPF) == (BPF - 1)
    nass = nbad = 0
    first = None
    for name, m, want in (("行消隐", line_end & ~frame_end, 1 + BLANK_LEN),
                          ("帧消隐", line_end & frame_end, 1 + BLANK_LEN + EOF_BLANK),
                          ("行内背靠背", ~line_end, 1)):
        nass += int(m.sum())
        bad = m & (gap != want)
        if bad.any():
            nbad += int(bad.sum())
            if first is None:
                j = int(np.nonzero(bad)[0][0])
                first = (name, j, int(ic[j]), int(gap[j]), want)
    nass += 1
    # 收尾：dump 必须覆盖到最后 1 个输出有效拍（= 最后 1 个输入有效拍 + LAT），
    # 且最后 1 个输入有效拍之后要有 >= BLANK_LEN 个 tvalid=0 拍。
    # ⚠ TB 的 TAIL_CYC 与这里的 BLANK_LEN 是两回事：TAIL 只保证"把流水线冲干净"。
    tail = int(d["cyc"][-1] - d["cyc"][ic[-1]])
    # ⚠ 2026-09-18 M7：最后一个有效拍若落在 M7 帧，它的输出要等到 +LAT_M7（8 拍）才出现。
    last_lat = LAT_M7 if int(mode_sched_arr()[
        min(ic.size - 1, FRAMES_ALL * BPF - 1) // BPF]) == MODE_M7 else LAT
    last_out = int(d["vidx"][-1]) + last_lat
    nass += 1
    if d["ncycles"] <= last_out:
        nbad += 1
        if first is None:
            first = ("收尾不够长", int(ic[-1]), int(d["cyc"][ic[-1]]), tail, last_out)
        if verbose:
            print("    ⚠ dump 在输出有效拍 %d 就截断了（该拍周期 %d，dump 末周期 %d）"
                  % (last_out, last_out, int(d["cyc"][-1])))
    elif tail < BLANK_LEN:
        nbad += 1
        first = first or ("收尾消隐", int(ic[-1]), int(d["cyc"][ic[-1]]), tail, BLANK_LEN)
    if verbose:
        print("  有效拍 %d；行末拍 %d（期望 %d = %d 帧 x %d 行）；行消隐 %d 拍/行；"
              "帧消隐 %d 拍/帧；末拍之后还有 %d 拍"
              % (ic.size, int(line_end.sum()), frames * H, frames, H,
                 BLANK_LEN, EOF_BLANK, tail))
        print("  行/帧消隐自检 %d 条，不符 %d  首错=%s  %s"
              % (nass, nbad, first, "PASS" if nbad == 0 else "FAIL"))
        if nbad:
            print("    ⚠ 激励里没有消隐 = 你验的是真实系统里不存在的工况")
    return nass, nbad


def check_m0_passthrough(d, frames, verbose=True):
    """K：M0 直通 = 输入延迟 LAT 拍（**逐周期**判据，不依赖任何帧级参考模型）。

    这条是"钉死 M0 数据通路"的干净判据（2026-09-16 由用户指定，用来区分
    "RTL 真吐 0" 与 "checker 期望算错"）：

        M0 档上，掩蔽**不改变结果**（掩蔽期输出原图 = w_a0_dat，非掩蔽期 M0 的 mux
        输出也是 w_a0_dat），所以 RTL 的 O_tdata 必须**逐周期**等于 I_tdata 延迟 LAT：

            O_tdata[t] == I_tdata[t-LAT]   对所有"t-LAT 是输入有效拍"的 t

    为什么只用 M0：其它档位要么过 3x3 窗口（结果与单拍输入无关），要么掩蔽期换成原图，
    都不满足"逐周期纯延迟"这个可判定的性质。

    实测（本 TB / 本 RTL）：k=5 时 230400 个有效周期**全等**，k=0..4、6..12 各错
    20 万拍量级 ⇒ 该判据对"数据通路错位"有满鉴别力（见变异脚本 MUT-LAT5）。
    """
    ic = np.nonzero(d["Iv"])[0]
    kk = np.arange(ic.size, dtype=np.int64)
    fr = kk // BPF
    nass = nbad = 0
    first = None
    for m0 in [i for i, md in enumerate(MODE_SCHED[:frames]) if md == A.MODE_RAW]:
        sel = (fr == m0)
        src = ic[sel]                       # 该帧的输入有效拍周期
        dst = src + LAT                     # 同一批拍在输出侧应出现的周期
        ok = dst < d["ncycles"]
        nass += int(ok.sum())
        bad = ok & ((d["od_hi"][dst] != d["id_hi"][src])
                    | (d["od_lo"][dst] != d["id_lo"][src]))
        if bad.any():
            nbad += int(bad.sum())
            if first is None:
                j = int(np.nonzero(bad)[0][0])
                first = (m0, int(src[j]), int(dst[j]),
                         "%08X_%016X" % (int(d["id_hi"][src[j]]), int(d["id_lo"][src[j]])),
                         "%08X_%016X" % (int(d["od_hi"][dst[j]]), int(d["od_lo"][dst[j]])))
    if verbose:
        print("  M0 帧逐周期 O_tdata[t] == I_tdata[t-%d]：比较 %d 拍，不符 %d  %s"
              % (LAT, nass, nbad, "PASS" if nbad == 0 else "FAIL"))
        if nbad:
            print("    首错（帧 %d）：I[%d]=%s  O[%d]=%s" % first)
    return nass, nbad


def check_shape(d, frames, verbose=True):
    """J：每行恰好 320 拍、每帧恰好 720 行、tlast/tuser 逐拍与拍序一致。"""
    ic = np.nonzero(d["Iv"])[0]
    kk = np.arange(ic.size, dtype=np.int64)
    nass = nbad = 0
    nl = int(((kk % BPL) == BPL - 1).sum())
    nu = int((kk % BPF == 0).sum())
    nass += 4
    if ic.size != frames * BPF:
        nbad += 1
        print("  !! 有效拍 %d != %d" % (ic.size, frames * BPF))
    if nl != frames * H:
        nbad += 1
        print("  !! 行末拍 %d != %d" % (nl, frames * H))
    if nu != frames:
        nbad += 1
        print("  !! 帧首拍 %d != %d" % (nu, frames))
    tl = d["Il"][ic]
    tu = d["Iu"][ic]
    nass += int(tl.size) + int(tu.size)
    nbad += int((tl != ((kk % BPL) == BPL - 1)).sum())
    nbad += int((tu != (kk % BPF == 0)).sum())
    # 输出侧同一件事：O_tlast 必须每 320 个输出有效拍出现一次
    oc = np.nonzero(d["Ov"])[0]
    ko = np.arange(oc.size, dtype=np.int64)
    ol = d["Ol"][oc]
    nass += int(ol.size)
    nbad += int((ol != ((ko % BPL) == BPL - 1)).sum())
    if verbose:
        print("  输入：每行 %d 拍 x %d 行 x %d 帧；行末拍 %d 次；tlast/tuser 比对 %d 条"
              % (BPL, H, frames, nl, 2 * int(tl.size)))
        print("  输出：%d 个输出有效拍；O_tlast 每 %d 拍一次，比对 %d 条，不符 %d  %s"
              % (oc.size, BPL, ol.size, nbad, "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


# ===========================================================================
# 3. 改期望值的变异清单（自证用）
# ===========================================================================
MUTATIONS = [
    ("A 延迟按 4 拍比（真实 5 拍）",          {"lat": 4}, "A"),
    ("A 延迟按 6 拍比",                      {"lat": 6}, "A"),
    # ⚠ `_need` = 本条变异**需要哪些档位出现在本跑档位表里**，否则它改的是空操作
    #   （见 active_mutations 的说明）。漏标本标签的后果 = 该跑假报"漏掉"。
    ("B M1 期望帧整体错一拍",                 {"beat_off": 1, "beat_off_modes": (1,), "_need": (1,)}, "B"),
    ("B M5 期望帧整体错一拍",                 {"beat_off": 1, "beat_off_modes": (5,), "_need": (5,)}, "B"),
    ("B M2/M3/M4 期望帧整体错一拍",           {"beat_off": 1, "beat_off_modes": (2, 3, 4), "_need": (2, 3, 4)}, "B"),
    ("B M3 的 src 期望取第 y 行",             {"src_dy": 0, "_need": (3,)}, "B"),
    ("B M3 的 src 期望取窗口中心灰度",         {"src_gray": True, "_need": (3,)}, "B"),
    ("B M5 期望画本帧 bbox（而不是上一帧）",    {"bbox_current": True, "_need": (5,)}, "B"),
    ("B 期望去掉窗口档位的一行输出位移",        {"no_row_shift": True, "_need": (2, 3, 4)}, "B"),
    ("B 期望掩蔽按逐像素 x%4==0（不是每拍）",   {"ppb": 1}, "B"),
    ("C 期望掩蔽期输出黑屏（例程口径）",        {"mask_black": True}, "C"),
    ("C 期望掩蔽区多盖一拍（拍号<2 也算）",      {"c_mask_extra_beat": True}, "C"),
    ("C 期望掩蔽只盖 1 行（前 1 行 + 第 0 拍）", {"c_mask_row0_only": True}, "C"),
    ("D 期望档位表整体错一档",                 {"mode_off": 1}, "D"),
    ("D 期望档位按输入 tuser 锁存（早 4 拍换）", {"d_early": True}, "D"),
    ("E 期望 src 来自第 y 行",                {"e_dy": 0, "_need": (3,)}, "E"),
    ("E 期望 src 来自第 y-2 行",              {"e_dy": -2, "_need": (3,)}, "E"),
    # ---- M6 帧差（2026-09-17 新增）：改的是 0b 节黄金模型的口径 ----
    # ⚠ 这一组**之前漏标 `_need`**：M0..M5 六帧基线跑的档位表里没有 M6，
    #   它们在那里全是空操作。2026-09-20 补上（之前那轮没跑 --selftest 所以没暴露）。
    ("M6 期望差分不取绝对值（单向漏检）",       {"m6_signed": True, "_need": (6,)}, "B"),
    ("M6 期望阈值比较取反（< 算运动）",         {"m6_inv_th": True, "_need": (6,)}, "B"),
    ("M6 期望 bbox 用格子坐标（不乘 8）",       {"m6_grid_bbox": True, "_need": (6,)}, "B"),
    ("M6 期望画本帧 bbox（而不是上一帧）",      {"m6_cur_bbox": True, "_need": (6,)}, "B"),
    ("M6 期望不画红框（只剩白点）",             {"m6_no_box": True, "_need": (6,)}, "B"),
    # ---- M7 区域填充（2026-09-18 新增）：改的是 0c 节黄金模型的口径 ----
    # ⚠ 带 "_m7": True 的条目**只在档位表里真有 M7 帧时才参与**（见 active_mutations）：
    #   1280x720 那套冻结时序里没有 M7 帧，这些条目在那里是**空操作**，
    #   不筛掉的话全尺寸 --selftest 会假报"漏掉"。
    ("M7 期望用 shift0 比（丢掉'晚一行'契约）",  {"m7_shift": 0, "_m7": True}, "B"),
    ("M7 期望用 shift2 比（多下移一行）",        {"m7_shift": 2, "_m7": True}, "B"),
    ("M7 期望去掉填充模块自带掩蔽（裸填充）",     {"m7_nomask": True, "_m7": True}, "B"),
    ("M7 期望阈值 128 -> 129（漏掉真边缘）",     {"m7_th": 129, "_m7": True}, "B"),
    ("M7 期望阈值 128 -> 8（大片误判成白）",     {"m7_th": 8, "_m7": True}, "B"),
    ("M7 期望也按 LAT=5 比（真实 8）",           {"lat": LAT, "_m7": True}, "A"),
    # ---- 判据 N 颜色类别（2026-09-20）------------------------------------------
    # ⚠ 只此一条，而且它**只证明"判据会报红"，不证明分类器对**：
    #   本跑六帧的原始命中像素全是红色主导（每帧 115200 个命中，R/G/B = 115200/0/0），
    #   金标准**恒为 0**，所以"期望取本帧 / 上一帧"这类对齐变异在这里是**空操作**。
    #   于是改用"把期望强行换成 GRN"——它至少能证明比对与报错这条路是通的。
    #   分类器本身的鉴别力在小图专项：gen_stim_cd_cls.py + tb_cd_cls.v + check_cd_cls.py
    #   （七帧期望 [1,2,0,0,1,0,0]，生成器里已自证能照出"错 1 拍窗口/平局判错/写死 RED"）。
    ("N 类别期望强行换成 GRN（只证判据会报红）", {"_class_set": 1}, "N"),
    # ---- 判据 B / M5 轨迹（2026-09-20，进阶 2.5(2) 动态目标跟踪）------------------
    # ⚠ 这两条**有真鉴别力**：全尺寸激励里红块逐帧右移 40 列，8 个轨迹点逐帧都在变，
    #   "错一帧"会整片点位移，"点错格"会多/少一整片 8x8 橙块 —— 都会实打实报红。
    ("B M5 轨迹取前一帧的状态",               {"trail_off": 1, "_need": (5,)}, "B"),
    ("B M5 轨迹取前两帧的状态",               {"trail_off": 2, "_need": (5,)}, "B"),
    # ---- 判据 P 跟踪编号（2026-09-20）------------------------------------------
    # ⚠ 只此一条，且它**只证判据会报红**：本跑目标每帧都在 ⇒ 期望恒为 1，
    #   任何"恒输出 1"的实现都能过。编号递增的真验证在小图专项 check_cd_cls.py。
    ("P 跟踪编号期望换成 2（只证判据会报红）",  {"_tid_set": 2}, "P"),
]


def active_mutations(frames):
    """把"本跑档位表里没有所需档位"的期望值变异筛掉（否则是空操作 = 假"漏掉"）。

    2026-09-20 由原来的 `_m7` 特例**推广**而来。起因：M6/M7 全尺寸专项跑的档位表是
    [M0, M1, M6, M7]，里面没有 M2/M3/M4/M5，于是 8 条依赖这些档位的变异被假报
    "漏掉"（实测 20/28）。它们**不是"判据没鉴别力"**，而是本跑根本没激励到那一档：
      · B M5 错一拍 / M5 画本帧 bbox             -> 需要 M5
      · B M2/M3/M4 错一拍 / 去掉窗口档位行位移    -> 需要 M2/M3/M4
      · B M3 的 src 取第 y 行 / 取窗口中心灰度    -> 需要 M3
      · E 的两条                                -> 判据 E 只在 M3 帧上跑（本跑 E 断言 = 0）
    这些档位的覆盖在"M0..M5 六帧基线跑"与"160x64 小图（八档齐全）"里，不在本跑的责任内。
    筛掉它们，分母才等于"本跑真正能考的量"；**留下的条目一条都没放宽**。

    判据：mut 里 `_need` 列出的档位**至少出现一个**在本跑档位表里（any-of，取最保守的筛法：
          只要它想改的那一档真在，就保留）；
          旧的 `"_m7": True` 等价于 `_need = (7,)`，保留兼容。
    """
    have = set(int(x) for x in MODE_SCHED[:frames])
    out = []
    for m in MUTATIONS:
        need = set(int(x) for x in m[1].get("_need", ()))
        if m[1].get("_m7"):
            need.add(MODE_M7)
        if not need or (need & have):
            out.append(m)
    return out


# ===========================================================================
# 4. 主流程
# ===========================================================================
def check_track_id(d, frames, verbose=True, mut=None):
    """P：跟踪编号（O_track_id）—— 2026-09-20，进阶要求 2.5(2)「动态目标跟踪」。

    金标准：全尺寸激励里红块**每一帧都在**，所以一次也没跟丢 ⇒ 编号从第 1 帧起
    恒为 **1**，且帧内恒定。

    ⚠ 本条**鉴别力很弱，必须说清楚**：期望值是常数 1，把实现换成"恒输出 1"照样 PASS。
      编号真正会被激励到的是**目标丢失/重现**那条路，全尺寸激励里一次都没发生
      （每一帧都有 115200 个命中像素）。
      ⇒ 编号**递增逻辑**的验证在 `check_cd_cls.py`（小图专项，专门造了丢帧再重现）。
      本条在这里只负责：① 这个信号真的从算法模块走到了 alg_top 的输出（线路通）；
      ② 帧内不抖（不会出现一帧里编号乱跳）。
    """
    if d.get("otidv") is None:
        if verbose:
            print("  判据 P 跳过：dump 只有 %d 列（无 O_track_id 列）—— 老 dump 或 TB 未更新"
                  % d.get("_ncol", 0))
        return 0, 0
    mut = mut or {}
    f, y, xg, valid = beat_axes(d, frames)
    nass = nbad = 0
    for fr in range(frames):
        sel = valid & (f == fr)
        idx = np.nonzero(sel)[0]
        if idx.size == 0:
            continue
        # ⚠ 第 0 帧看到的是**复位值 0**：编号是在帧边界由"上一帧有没有目标"推出来的，
        #   第 0 帧没有"上一帧"，第一次捕获发生在第 1 帧的帧首。
        exp = 0 if fr == 0 else 1
        if mut.get("_tid_set") is not None:
            exp = int(mut["_tid_set"])
        got = int(d["otidv"][idx[0]])
        nass += 1
        if got != exp:
            nbad += 1
            if verbose:
                print("    帧 %d：O_track_id=%d（期望 %d）  <- FAIL" % (fr, got, exp))
        vals = d["otidv"][sel]
        nass += 1
        if int(vals.min()) != int(vals.max()):
            nbad += 1
            if verbose:
                print("    帧 %d：O_track_id 帧内抖了（min=%d max=%d）  <- FAIL"
                      % (fr, int(vals.min()), int(vals.max())))
    if verbose:
        print("  O_track_id 逐帧比对 %d 帧 + 帧内稳定性，不符 %d  %s"
              % (frames, nbad, "PASS" if nbad == 0 else "FAIL"))
        print("  实测逐帧跟踪编号 = %s"
              % ([int(d["otidv"][np.nonzero(valid & (f == fr))[0][0]])
                  for fr in range(frames)
                  if np.nonzero(valid & (f == fr))[0].size],))
        print("  ⚠ 本跑目标每帧都在 ⇒ 期望恒为 1，本条**只证线路通**；"
              "编号递增逻辑见小图专项 check_cd_cls.py")
    return nass, nbad


def check_class(d, frames, verbose=True, mut=None):
    """N：颜色类别（O_color_class）—— 2026-09-20，扩展要求 2.4(2)「识别」。

    期望值 = **上一帧**原始命中像素的主导通道（与 bbox/count 同一套"帧边界锁存"约定，
    因为 alg_top 是在同一拍 w_sof_a0 把它们一起采下来的）。金标准走 alg_ref.color_class，
    与 alg_color_detect_96 §2b/§10b 的口径逐条对应。

    ⚠ 本跑的**鉴别力有限，必须说清楚**：1280x720 这套激励的命中像素全是红色主导
      （目标色 R=235±20、G/B 只有 0..40）⇒ 期望类别**恒为 0（RED）**。
      把实现换成"永远输出 0"这里照样 PASS。
      真正有鉴别力的是**小图专项**：sim/gen_stim_cd_cls.py + tb_cd_cls.v + check_cd_cls.py
      （七帧期望 [1,2,0,0,1,0,0]，生成器里已自证能照出"错 1 拍窗口 / 平局判错 / 写死 RED"）。
      本条判据在这里的职责只有两件：① 端到端**通不通**（alg_top 的锁存/端口有没有接对）；
      ② 帧内稳不稳（同一帧里不许抖）。**不要**把它当成分类器正确性的证据。
    """
    if d.get("oclsv") is None:
        if verbose:
            print("  判据 N 跳过：dump 只有 %d 列（无 O_color_class 列）—— 老 dump 或 TB 未更新"
                  % d.get("_ncol", 0))
        return 0, 0
    mut = mut or {}
    f, y, xg, valid = beat_axes(d, frames)
    mp = np.array(MODE_SCHED[:frames])

    # 逐帧金标准：第 f 帧的原始命中主导通道
    imgs = images(frames)
    gold = []
    for fr in range(frames):
        cls, _cnts, _nh = A.color_class(imgs[fr], None, RLO, RHI, GLO, GHI, BLO, BHI)
        gold.append(cls)
    if mut.get("_class_set") is not None:
        gold = [int(mut["_class_set"])] * frames

    nass = nbad = 0
    for fr in range(1, frames):
        # 采样点与判据 G 完全相同：帧内固定点（第一行的第 1 个输出有效拍）
        sel = valid & (f == fr) & (y == 1) & (xg == 1)
        i = np.nonzero(sel)[0]
        if i.size == 0:
            continue
        i = int(i[0])
        exp = gold[fr - 1]
        got = int(d["oclsv"][i])
        nass += 1
        if got != exp:
            nbad += 1
            if verbose:
                print("    帧 %d：O_color_class=%d（期望 %d，上一帧金标准）  <- FAIL"
                      % (fr, got, exp))
        # 帧内稳定性：该帧所有输出有效拍上的类别必须一致
        allb = valid & (f == fr)
        vals = d["oclsv"][allb]
        nass += 1
        if vals.size and int(vals.min()) != int(vals.max()):
            nbad += 1
            if verbose:
                print("    帧 %d：O_color_class 帧内抖了（min=%d max=%d，%d 拍）  <- FAIL"
                      % (fr, int(vals.min()), int(vals.max()), int(vals.size)))
    if verbose:
        print("  O_color_class 逐帧比对 %d 帧 + 帧内稳定性，不符 %d  %s"
              % (frames - 1, nbad, "PASS" if nbad == 0 else "FAIL"))
        print("  逐帧金标准类别（原始命中主导通道）= %s" % (gold,))
        print("  实测逐帧类别 = %s"
              % ([int(d["oclsv"][np.nonzero(valid & (f == fr) & (y == 1) & (xg == 1))[0][0]])
                  for fr in range(1, frames)
                  if np.nonzero(valid & (f == fr) & (y == 1) & (xg == 1))[0].size],))
        if len(set(gold)) == 1:
            print("  ⚠ 本跑金标准类别只有 1 种取值 ⇒ 本条判据**无鉴别力**，"
                  "分类器正确性见小图专项 check_cd_cls.py")
    return nass, nbad


def run_all(d, frames, exp_img, exp_pack, bb, mut=None, verbose=True):
    mut = mut or {}
    counts, fails = {}, []

    n, b = check_a(d, mut, verbose)
    counts["A 延迟5拍"] = (n, b)
    if b:
        fails.append("A：控制信号/有效拍不是输入延迟 5 拍（%d 处）" % b)
    n, b = check_b(d, exp_pack, frames, mut, verbose)
    counts["B 七档对金标准"] = (n, b)
    if b:
        fails.append("B：%d 拍不符金标准" % b)
    n, b = check_c(d, exp_img, frames, mut, verbose)
    counts["C 掩蔽区=原图"] = (n, b)
    if b:
        fails.append("C：掩蔽区 %d 像素不是原图" % b)
    n, b = check_d(d, frames, mut, verbose)
    counts["D 档位锁存"] = (n, b)
    if b:
        fails.append("D：%d 拍档位不符/帧内换档" % b)
    n, b = check_e(d, frames, mut, verbose)
    counts["E M3的src行"] = (n, b)
    if b:
        fails.append("E：M3 的 src 行反解/候选对照 %d 处不符" % b)
    n, b = check_blanking(d, frames, verbose)
    counts["I 行/帧消隐工况"] = (n, b)
    if b:
        fails.append("I：激励不是真实链路工况（消隐自检不符 %d 处）" % b)
    n, b = check_class(d, frames, verbose, mut)
    counts["N 颜色类别"] = (n, b)
    if b:
        fails.append("N：颜色类别 %d 处不符（或帧内抖动）" % b)
    n, b = check_track_id(d, frames, verbose, mut)
    counts["P 跟踪编号"] = (n, b)
    if b:
        fails.append("P：跟踪编号 %d 处不符（或帧内抖动）" % b)

    if not mut:
        for fn, nm, msg in ((check_xz, "F X/Z泄漏", "F：输出 X/Z 泄漏 %d 次"),
                            (check_shape, "J 每行/每帧拍数", "J：行/帧拍数不符 %d 处")):
            n, b = fn(d, frames, verbose) if fn is check_xz else fn(d, frames, verbose)
            counts[nm] = (n, b)
            if b:
                fails.append(msg % b)
        n, b = check_m0_passthrough(d, frames, verbose)
        counts["K M0直通=LAT拍"] = (n, b)
        if b:
            fails.append("K：M0 直通不是输入延迟 %d 拍（%d 处）" % (LAT, b))
        mots, mbbs, mcnt = m6_stats(frames)
        n, b = check_bbox(d, bb, frames, mbbs, mcnt, verbose)
        counts["G bbox(按档选族)"] = (n, b)
        if b:
            fails.append("G：bbox 统计 %d 处不符" % b)
        n, b = check_m6(d, frames, mbbs, mcnt, mots, verbose)
        counts["L M6对齐/拍数/非空"] = (n, b)
        if b:
            fails.append("L：M6 帧控制对齐/拍数/激励非空 %d 处不符" % b)
        n, b = check_m7(d, frames, exp_img, None, verbose)
        counts["M M7对齐/掩蔽/阈值"] = (n, b)
        if b:
            fails.append("M：M7 帧对齐/掩蔽/阈值口径/非空 %d 处不符" % b)
        n, b = check_stim(d, frames, verbose)
        counts["H 激励自检"] = (n, b)
        if b:
            fails.append("H：dump 输入与激励文件不符 %d 处" % b)
    return counts, fails


def self_consistency(frames):
    """自洽性：variant_out 在默认参数下必须与金标准 AlgPipeline 逐位相同。

    M6 在 alg_ref 里没有实现（MODE_MOTION 只保留编号），所以 M6 帧改用
    **两种独立写法互检**：逐像素的 m6_frame（帧级掩码/画法）必须与逐拍的
    m6_beats_out（按 (行,拍号) 逐拍构造、掩蔽按拍生效）逐位相同。
    """
    bad = 0
    bb = bboxes(frames)
    tr = trail_states(frames, bb)          # 两条写法必须用**同一份**轨迹状态
    mots, mbbs, _c = m6_stats(frames)
    imgs = images(frames)
    for f in range(frames):
        img = imgs[f]
        if int(MODE_SCHED[f]) == MODE_M7:
            # M7：两条独立写法（ref_region_fill 主接口 vs 底层原语）必须逐位相同
            ref = m7_frame(img, None)
            var = m7_frame_lowlevel(img, None)
            bad += int((ref != var).any(axis=2).sum())
            continue
        if int(MODE_SCHED[f]) == MODE_M6:
            bp = mbbs[f - 1] if f >= 1 else None
            ref = m6_frame(img, mots[f], bp, mbbs[f], None)
            var = m6_beats_out(imgs, mots, mbbs, f, None).reshape(H, W, 3)
            bad += int((ref != var).any(axis=2).sum())
            continue
        bp = bb[f - 1] if f >= 1 else None
        ref = _pipe(MODE_SCHED[f], None).process(img, bbox_prev=bp, trail=tr[f]).image
        var = variant_out(img, MODE_SCHED[f], {}, bbox_prev=bp, trail=tr[f])
        bad += int((ref != var).any(axis=2).sum())
    return bad


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    frames = FRAMES_ALL
    if "--frames" in sys.argv:
        frames = int(sys.argv[sys.argv.index("--frames") + 1])
    dump = os.path.join(here, DUMP)
    if "--dump" in sys.argv:                 # 变异脚本用小尺寸时会指到自己的 work 目录
        dump = sys.argv[sys.argv.index("--dump") + 1]
    selftest = "--selftest" in sys.argv
    t0 = time.time()

    print("=" * 78)
    print("集成校验：W=%d H=%d 每行 %d 拍 帧数 %d 总拍 %d" % (W, H, BPL, frames, nbeat(frames)))
    print("档位时序 MODE_SCHED=%s%s%s"
          % (MODE_SCHED[:frames],
             "" if MODE_M6 in MODE_SCHED[:frames] else "   ⚠ 本跑无 M6 帧（L 判据不可用）",
             "" if MODE_M7 in MODE_SCHED[:frames] else "   ⚠ 本跑无 M7 帧（M 判据不可用）"))
    print("延迟：M0..M6 = %d 拍；M7 = %d 拍（= %d + 填充模块自身的 3 拍）"
          % (LAT, LAT_M7, LAT))
    print("M7 输入阈值 RF_TH=%d（白 ⟺ 三字节都 >= RF_TH；依据 sim/_m7_thresh_probe.py）"
          % RF_TH)
    print("M6 几何：8x8 降采样 CX=%d CY=%d 深度=%d  DIFF_TH=%d"
          % (CX, CY, CX * CY, M6_DIFF_TH))
    print("=" * 78)
    d = parse(dump)
    print("  逐像素采样点 = %d 拍 x 6 个探针 = %d（约 %.1f 万）"
          % (d["nbeats"], d["nbeats"] * 6, d["nbeats"] * 6 / 1e4))

    t1 = time.time()
    exp_img, exp_pack, bb = expected_frames(frames, None)
    print("  金标准期望帧 %d 帧算完（%.1f s）；逐帧 bbox=%s" % (frames, time.time() - t1, bb))

    sc = self_consistency(frames)
    print("  自洽性：variant_out(默认参数) vs 金标准 AlgPipeline —— 不符像素 %d  %s"
          % (sc, "PASS" if sc == 0 else "FAIL"))
    if sc:
        print("  ⚠ 变异路径自己就不等于金标准，先修这个再看别的")
        return 2

    if not selftest:
        for t in ("\n=== A. 全链延迟 = 5 拍（逐拍控制 + 有效拍落点）===",
                  "\n=== B. 7 档逐拍对金标准（M6 = 帧差黄金模型）===",
                  "\n=== C. 掩蔽：前 2 行 + 每行第 0 拍 = 原图 ===",
                  "\n=== D. 档位锁存：整帧不换档 / 换档在帧边界 ===",
                  "\n=== E. M3 的 src 行反解 ===",
                  "\n=== I. 激励工况（行消隐 + 帧消隐）===",
                  "\n=== F/G/H/J/K/L. X-Z、bbox、激励自检、行/帧拍数、M6 对齐 ==="):
            print(t)
        counts, fails = run_all(d, frames, exp_img, exp_pack, bb, None, verbose=True)
        tot = sum(a for a, _b in counts.values())
        print("\n" + "=" * 78)
        for k, (n, b) in counts.items():
            print("  %-18s 断言 %9d  不符 %-6d  %s" % (k, n, b, "PASS" if b == 0 else "FAIL"))
        print("  合计断言 %d   （解析+判定总耗时 %.1f s）" % (tot, time.time() - t0))
        print("=" * 78)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails:
                print("   " + s)
            return 1
        print("结论：PASS —— %dx%d 集成判据 A~L 全过，合计 %d 条断言" % (W, H, tot))
        return 0

    # ---------------- 改期望值变异自证 ----------------
    print("\n" + "=" * 78)
    print("变异自证（改期望值）：故意用错误期望重跑，每条都必须被对应判据抓住")
    print("=" * 78)
    _c, base_fails = run_all(d, frames, exp_img, exp_pack, bb, None, verbose=False)
    _tot = sum(a for a, _b in _c.values())
    print("  基线（未变异）  断言 %d 条，报错 %d 条  -> %s"
          % (_tot, len(base_fails), "PASS" if not base_fails else "FAIL"))
    if base_fails:
        print("  !! 基线就是红的：变异自证在这种情况下没有意义（假绿来源）")
        for s in base_fails[:5]:
            print("     " + s)
        return 1
    caught = 0
    muts = active_mutations(frames)
    if len(muts) != len(MUTATIONS):
        # ⚠ 逐条打印筛掉了什么 —— 筛掉必须是**可审计**的，不能是"让数字变绿"的暗箱。
        #   判据：每条被筛掉的变异，它想改的那一档都不在本跑档位表里（空操作）。
        skipped = [m[0] for m in MUTATIONS if m not in muts]
        print("  （本跑档位表 MODE_SCHED=%s 覆盖不到全部档位：%d/%d 条期望值变异已筛掉，"
              "它们只在**有那一档的跑**里适用；留下的一条都没放宽）"
              % (list(MODE_SCHED[:frames]), len(skipped), len(MUTATIONS)))
        for s in skipped:
            print("     筛掉：%s" % s)
    for name, mut, who in muts:
        red = []
        # ⚠⚠ 这张派发表是**手工维护**的：加了新判据却忘了加进来，后果是
        #   "期望抓=N 实际报错:无 !! 漏掉 !!" —— 看起来像变异没抓住，实际是这个
        #   变异**压根没被执行**。2026-09-20 加判据 N 时就踩了这条（本次已补 N）。
        #   凡是要进 --selftest 的判据，**必须同时**改这里，否则自证是空的。
        for key in ("A", "B", "C", "D", "E", "N", "P"):
            fn = globals()[{"A": "check_a", "B": "check_b", "C": "check_c",
                            "D": "check_d", "E": "check_e", "N": "check_class",
                            "P": "check_track_id"}[key]]
            if key == "B":
                epk = expected_frames(frames, mut)[1] if mut else exp_pack
                _n, nb = fn(d, epk, frames, mut, verbose=False)
            elif key == "A":
                # ⚠ check_a 的签名是 (d, mut, verbose)，**不收 frames**。
                #   2026-09-16 修：原先 A/D/E 走同一行 fn(d, frames, mut, ...)，
                #   对 check_a 会把 frames 塞进 mut、mut 塞进 verbose，再撞上前面的
                #   verbose 关键字 ⇒ TypeError: got multiple values for argument 'verbose'。
                #   也就是说本 --selftest 在全尺寸 checker 上**从来没跑通过**。
                _n, nb = fn(d, mut, verbose=False)
            elif key in ("D", "E"):
                _n, nb = fn(d, frames, mut, verbose=False)
            elif key in ("N", "P"):
                # check_class / check_track_id 的签名是 (d, frames, verbose, mut)：
                # mut 在**最后**，不能跟 D/E 那样当第 3 个位置参数传（会塞进 verbose）。
                _n, nb = fn(d, frames, verbose=False, mut=mut)
            else:
                _n, nb = fn(d, exp_img, frames, mut, verbose=False)
            if nb:
                red.append("%s(%d)" % (key, nb))
        ok = len(red) > 0
        caught += 1 if ok else 0
        print("  %-40s 期望抓=%s  实际报错: %-32s %s"
              % (name, who, ",".join(red) if red else "无", "抓住" if ok else "!! 漏掉 !!"))
    print("-" * 78)
    print("  改期望值鉴别力：%d/%d  -> %s"
          % (caught, len(muts), "PASS" if caught == len(muts) else "FAIL"))
    print("=" * 78)
    return 0 if caught == len(muts) else 1


if __name__ == "__main__":
    sys.exit(main())
