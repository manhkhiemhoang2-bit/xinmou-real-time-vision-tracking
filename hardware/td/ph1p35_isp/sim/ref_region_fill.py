#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
ref_region_fill.py —— 区域填充的**纯 Python 参考实现**（numpy）

对应比赛扩展要求 2.4(1)「风格化或视觉增强 —— 边缘提取与区域填充」里的**区域填充**，
与 RTL `src\\alg_region_fill_96.v` 同源（同一份规格）但**独立实现**：
  · 本文件按【规格文字】写成**帧级、窗口中心式**的实现（每个输出像素独立地看
    自己的 3×3 邻域 + 一次整行前缀奇偶运算）；
  · RTL 是【逐拍、行缓存式】实现（2 条行缓存 + 每拍 4 像素串行 ripple）。
两者结构完全不同，只有"结果逐像素相同"这一条被判据钉住（sim\\check_region_fill.py）。

判据口径（与 RTL 文件头 §一/§四**写死同一个**）
------------------------------------------------
1. 颜色：输入是二值掩膜，合法取值只有 24'hFFFFFF（白 = 前景/边缘）与
   24'h000000（黑）。白的判据取 **三字节全 0xFF**（`pixel == 0xFFFFFF`），
   不取"亮度 >= 128"：上游 alg_binarize_96 / alg_sobel_96 的输出只有这两个取值，
   两种口径在合法输入上等价，而"全 0xFF"不需要算亮度、也不会把中间灰误判成白。
   （见 mask_to_bool 的 docstring。）
2. 3×3 膨胀：`edge(y,x) = OR over (dy,dx) in [-1,0,1]^2 of white(y+dy, x+dx)`，
   图外一律补 0（黑）。膨胀的目的是把断开的轮廓接上、把细缝堵住。
3. 行内奇偶扫描填充：每一行从左到右，
       inside ^= edge_pixel ;  out_pixel = edge_pixel | inside
   行首 inside = 0（每行独立复位）。**轮廓不闭合时 inside 会一直保持到行尾**，
   于是从最后一条边一路填到该行最右像素 —— 这是经典行为，规格允许。
   等价写法：inside(y,x) = XOR_{x' < x} edge(y,x')（边缘计数的前缀奇偶）。
4. 输出格式与输入相同：前景 = 24'hFFFFFF，背景 = 24'h000000。

RTL 侧另有一处**掩蔽纪律**（照抄 win3x3_96）：前 2 行、每行第 0 拍、帧首拍的
窗口不可信，掩膜按全黑算。参考模型**必须采取同一口径**（`apply_row_barrier`）：
masked 与"裸膨胀+填充"的结果在合法数据上就会不同（白点落在 (0,0) 时裸膨胀会把
(0,0)/(0,1) 点亮，而 RTL 因窗口不可信输出全黑）。check_region_fill.py 的 A7 会
独立复算"掩蔽的影响只落在被掩蔽的像素上"这条不变量，并要求差异**真的存在**
（否则说明掩蔽根本没被测到）。

接口（供其它 checker 直接 import）
----------------------------------
    ref_region_fill(frames, W, H, white_thresh=None) -> filled_frames
    ref_frames_from_beats(beats, W, H) -> frames          96bit 拍 → 帧
    frames_to_beats(frames, W, H)     -> beats            帧 → 96bit 拍
    dilate3x3(mask)                   -> mask             单步：3×3 膨胀
    scanline_fill(edge)               -> (out, inside)    单步：奇偶填充 + inside 电平
    barrier_mask(W, H)                -> mask             RTL 掩蔽纪律的像素级屏蔽图
    apply_row_barrier(filled, W, H)   -> mask             施加掩蔽（与 RTL 同口径）
    compare_stream(beats, out_beats, W, H, want_parity)   大图友好的**帧内流式**比对
    self_test()                       -> (checked, errors, msgs)  纯 Python 自证

命令行（可选，用来生成整帧期望图）：
    python ref_region_fill.py --selftest
"""
from __future__ import annotations

import numpy as np

__all__ = [
    "WHITE", "BLACK", "bpl_of", "mask_to_bool", "bool_to_mask",
    "ref_frames_from_beats", "frames_to_beats",
    "dilate3x3", "scanline_fill", "barrier_mask", "apply_row_barrier",
    "ref_region_fill", "compare_stream", "self_test",
]

WHITE = 0xFFFFFF
BLACK = 0x000000


def bpl_of(W):
    """每行拍数（一拍 4 个像素）。"""
    if W % 4 != 0:
        raise ValueError("W 必须是 4 的倍数（一拍 4 像素），收到 %d" % W)
    return W // 4


# ===========================================================================
# 1. 位序 / 打包原语（口径来自 S0-02 §2.1：pix0 = [95:72] 是行内最左像素）
# ===========================================================================
def mask_to_bool(arr, white_thresh=None):
    """把"掩膜"转成 bool 前景图。

    支持三种输入形态：
      (a) (H, W) 整数数组：0xFFFFFF / 0x000000（或 255 / 0）
      (b) (H, W) 浮点数组：0.0 / 1.0（或 0.0 / 255.0）
      (c) (H, W, 3) RGB888

    白判据：
      white_thresh is None → 整数形态按 `== 0xFFFFFF`；浮点形态按 `> 0.5`
                             （即"全白"）；RGB 形态按三字节全 0xFF。
                             —— 这是 RTL 采用的口径。
      white_thresh = t     → 按 BT.601 整数亮度 `(77R + 150G + 29B) >> 8 >= t` 判白
                             （与 gray_bt601_96.v 同一系数）。仅作备选口径，
                             RTL 与 TB 都不用它。
    """
    a = np.asarray(arr)
    if a.ndim == 3 and a.shape[2] == 3:
        r = a[..., 0].astype(np.int64)
        g = a[..., 1].astype(np.int64)
        b = a[..., 2].astype(np.int64)
        if white_thresh is None:
            return (r == 255) & (g == 255) & (b == 255)
        return ((77 * r + 150 * g + 29 * b) >> 8) >= int(white_thresh)
    if a.ndim != 2:
        raise ValueError("mask_to_bool: 只接受 (H,W) 或 (H,W,3)，收到 %r" % (a.shape,))
    if white_thresh is not None:
        if a.dtype.kind == "f":
            lum = np.clip(np.rint(a * 255.0), 0, 255).astype(np.int64)
        else:
            lum = a.astype(np.int64)
        return lum >= int(white_thresh)
    if a.dtype == np.bool_:
        return a.copy()
    if a.dtype.kind == "f":
        return a > 0.5
    return a.astype(np.int64) == WHITE


def bool_to_mask(mask):
    """bool (H,W) → uint32 (H,W)，前景 = 0xFFFFFF、背景 = 0x000000。"""
    m = np.asarray(mask, dtype=bool)
    return np.where(m, np.uint32(WHITE), np.uint32(BLACK))


def ref_frames_from_beats(beats, W, H):
    """96bit 拍序列 → (F, H, W) uint32 帧数组。

    beats : (N, 4) 数组，每行 4 个像素，**pix0 在最左**（对应 I_tdata[95:72]）。
    """
    b = np.asarray(beats, dtype=np.uint32).reshape(-1, 4)
    bpl = bpl_of(W)
    if b.shape[0] % (bpl * H) != 0:
        raise ValueError("beat 总数 %d 不是整帧 %d 的整数倍" % (b.shape[0], bpl * H))
    f = b.shape[0] // (bpl * H)
    # (F,H,bpl,4) → 每行内 (bpl,4) 拉平成 W 列：beat 内 4 个像素是**连续 4 列**
    return b.reshape(f, H, bpl, 4).reshape(f, H, W)


def frames_to_beats(frames, W, H):
    """(F, H, W) 或 (H, W) 帧数组 → (N, 4) 逐拍数组（pix0 最左）。

    TB 的 stim_*.hex 用的就是这个顺序。
    """
    a = np.asarray(frames, dtype=np.uint32)
    if a.ndim == 2:
        a = a[None, ...]
    f, h, w = a.shape
    if (w, h) != (W, H):
        raise ValueError("frames_to_beats: 形状 %r 与 W=%d H=%d 不符" % (a.shape, W, H))
    return a.reshape(f, H, bpl_of(W), 4).reshape(-1, 4)


# ===========================================================================
# 2. 两级算法本体（帧级，窗口中心式 —— 与 RTL 的行缓存 + ripple 结构无关）
# ===========================================================================
def dilate3x3(mask):
    """3×3 膨胀：任一邻域像素为白即白。图外补 0（黑）。

    规格原文：「把白像素在其 3×3 邻域内扩散，用来把断开的轮廓接上、把细缝堵住」。
    这里用 9 个方向逐一移位 OR —— 与 RTL 里"从 3 行 × 5 列抽头取 9 个做 OR"
    是两种不同的写法，互为独立实现。
    """
    m = np.asarray(mask, dtype=bool)
    H, W = m.shape
    out = m.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            src = m[max(0, dy):H + min(0, dy), max(0, dx):W + min(0, dx)]
            dst = out[max(0, -dy):H + min(0, -dy), max(0, -dx):W + min(0, -dx)]
            np.logical_or(dst, src, out=dst)
    return out


def scanline_fill(edge):
    """行内扫描填充 —— **只在"由黑变白"那一下翻转 inside**（上升沿判据）。

        rise = edge & ~edge_prev        （edge_prev 是**左边那个像素**；行首为 0）
        inside ^= rise
        out = edge | inside

    行首 inside 与 edge_prev 一起复位为 0，逐行独立。

    ⚠⚠ 为什么不用"每个白像素都翻一次"（原规格，**已作废**，留档）：
      每个白像素翻一次 ⇒ 翻转次数 = 边缘带的**像素宽度**：
        1/3 像素宽（奇数）→ 翻奇数次 → 内部 inside=1 → 填上 ✅
        2/4 像素宽（偶数）→ 翻偶数次 → 内部 inside=0 → **填不上** ❌
      而本模块上游是 Sobel 边缘，边缘带本来就是 2~3 像素宽且不稳定，
      "能不能填上"就成了赌奇偶。改成上升沿判据后，翻转次数 = 边缘**游程**个数，
      与宽度无关 ⇒ 1/2/3/4 像素宽全部正确填上。
      RTL 同口径（alg_region_fill_96.v §11），两边**写死一致**。

    返回 (out, inside)：
        out    (H, W) bool —— 填充结果（= edge | inside）
        inside (H, W) bool —— 每个像素**处理时**的 inside 电平
    """
    e = np.asarray(edge, dtype=bool)
    H, W = e.shape
    prev = np.zeros((H, W), dtype=bool)      # 左边那个像素（行首补 0）
    prev[:, 1:] = e[:, :-1]
    rise = e & ~prev
    pre = np.zeros((H, W), dtype=bool)
    if W > 1:
        np.bitwise_xor.accumulate(rise[:, :-1], axis=1, out=pre[:, 1:])
    return e | pre, pre


def barrier_mask(W, H):
    """RTL 掩蔽纪律对应的**像素级屏蔽图**（True = 该像素被掩蔽成黑）。

    RTL 照抄 win3x3_96 的窗口可信判据 `(r_y >= 2) && (r_x != 0) && !r_tuser`，
    等价到像素级：y ∈ {0, 1}、或 x ∈ {0,1,2,3}（每行第 0 拍的 4 个像素）、
    或帧首拍（就是 (0,0)，已被覆盖）⇒ 输出强制全黑。
    """
    m = np.zeros((H, W), dtype=bool)
    m[:min(2, H), :] = True
    m[:, :min(4, W)] = True
    return m


def apply_row_barrier(filled, W, H):
    """把掩蔽图**直接施加**在"裸膨胀+填充"的结果上（辅助函数，非主路径）。

    ⚠ 这只是"掩蔽的理想化等效"（把被掩蔽像素直接抹黑），**不等于 RTL 的时序行为**：
      RTL 是在组合阶段把窗口压成全黑，被掩蔽拍的 edge 因此为 0，于是 inside 也不会
      翻转。主路径（ref_region_fill / compare_stream）用的是 scanline_fill_masked()，
      它复刻的是 RTL 的时序语义。本函数只用于 A7 的"差异是否越界"核对。
    """
    out = np.asarray(filled, dtype=bool).copy()
    out &= ~barrier_mask(W, H)
    return out


def scanline_fill_masked(edge, W, H):
    """**与 RTL 时序语义完全一致**的填充：被掩蔽的拍先压成全黑，再逐拍串行处理。

        e_k        = raw_edge_k AND NOT masked_k          （窗口不可信 ⇒ 按黑算）
        rise_k     = e_k AND NOT e_{k-1}                  （上升沿判据，见 scanline_fill）
        行首/帧首复位 inside 与 prev；被完全掩蔽的拍也把两者拉回 0
        inside_{k+1} = inside_k ^ rise_k
        out_k      = e_k | inside_k

    返回 (out, inside)，两个都是 (H,W) bool。inside 是"每个像素**处理时**的电平"。
    """
    e = np.asarray(edge, dtype=bool).copy()
    bm = barrier_mask(W, H)
    e &= ~bm
    out = np.zeros((H, W), dtype=bool)
    ins = np.zeros((H, W), dtype=bool)
    bpl = bpl_of(W)
    for y in range(H):
        inside = False
        prev = False
        for k in range(bpl):
            x0 = 4 * k
            if bm[y, x0]:                 # 整拍被掩蔽（仅 y<2 或 x0==0 两种情形）
                inside = False
                prev = False
            for j in range(4):
                x = x0 + j
                ins[y, x] = inside
                out[y, x] = e[y, x] or inside
                inside = inside ^ (bool(e[y, x]) and not prev)
                prev = bool(e[y, x])
    return out, ins


# ===========================================================================
# 3. 对外主接口
# ===========================================================================
def ref_region_fill(frames, W, H, white_thresh=None, want_intermediate=False,
                    masked=True):
    """区域填充的帧级参考实现（供 checker 直接 import）。

    frames : 帧的可迭代对象（每帧 (H,W) 掩膜，形态见 mask_to_bool），
             或一整个 (F,H,W) 数组。
    W, H   : 图像宽高（像素）。
    white_thresh : 见 mask_to_bool；默认 None = 三字节全 0xFF 判白（RTL 口径）。
    want_intermediate : True 时返回 (filled, info)，info 含膨胀图与 inside 图。
    masked : True（默认，**与 RTL 同口径**）= 施加前 2 行 / 每行第 0 拍的掩蔽；
             False = 裸的"膨胀 + 填充"（只用于 A7 的不变量核对，不作为期望值）。

    返回 filled —— (F, H, W) uint32 数组，前景 0xFFFFFF / 背景 0x000000。
    """
    bpl_of(W)
    arr = np.asarray(frames)
    if arr.ndim == 2:
        arr = arr[None, ...]
    if arr.ndim != 3:
        raise ValueError("frames 必须是 (F,H,W) 或帧列表，收到 %r" % (arr.shape,))

    outs = np.zeros((arr.shape[0], H, W), dtype=np.uint32)
    dils = np.zeros((arr.shape[0], H, W), dtype=bool) if want_intermediate else None
    inss = np.zeros((arr.shape[0], H, W), dtype=bool) if want_intermediate else None
    for i in range(arr.shape[0]):
        mask = mask_to_bool(arr[i], white_thresh)
        if mask.shape != (H, W):
            raise ValueError("第 %d 帧形状 %r 与 H=%d W=%d 不符" % (i, mask.shape, H, W))
        edge = dilate3x3(mask)                      # 第 1 级：3×3 膨胀
        if masked:
            # 与 RTL 同口径：被掩蔽的拍先压成全黑，再逐拍串行 ripple
            filled, inside = scanline_fill_masked(edge, W, H)
        else:
            filled, inside = scanline_fill(edge)    # 裸的"膨胀 + 填充"
        outs[i] = bool_to_mask(filled)
        if want_intermediate:
            dils[i] = edge
            inss[i] = inside
    if want_intermediate:
        return outs, {"dilate": dils, "inside": inss}
    return outs


# ===========================================================================
# 4. 大图友好的流式比对（check_region_fill.py 的主入口）
# ===========================================================================
def compare_stream(beats, out_beats, W, H, want_parity=True):
    """逐拍输入 + 逐拍 RTL 输出 → 逐帧比对，返回统计（不在内存里堆所有帧）。

    参数
    ----
    beats     : (N, 4) uint32，逐拍输入（TB 实际喂进去的序列）。
    out_beats : (N, 4) uint32，RTL 实际吐出来的序列（按有效拍对齐后的）。
    W, H      : 图像宽高。
    want_parity : True 时额外复算掩蔽纪律的不变量（见 apply_row_barrier）。

    返回 dict：
        frames, n_beats_total, pix_total, pix_ok, pix_bad, first_bad(list),
        masked_area     : 被掩蔽的像素总数（**必须 > 0**，否则掩蔽根本没被测到）
        barrier_leak    : masked / unmasked 的差异**漏到掩蔽区之外**的像素数
                          （应为 0；> 0 说明掩蔽越界）
        barrier_diff    : masked / unmasked 的差异**在掩蔽区内**的像素数
                          （> 0 说明掩蔽真的改变了结果，判据因此有鉴别力）
    """
    beats = np.asarray(beats, dtype=np.uint32)
    out_beats = np.asarray(out_beats, dtype=np.uint32)
    bpl = bpl_of(W)
    per_frame = bpl * H
    if beats.shape[0] != out_beats.shape[0]:
        raise ValueError("输入 %d 拍 / 输出 %d 拍，数量不等" % (beats.shape[0], out_beats.shape[0]))
    if beats.shape[0] % per_frame != 0:
        raise ValueError("beat 总数 %d 不是整帧 %d 的整数倍" % (beats.shape[0], per_frame))
    F = beats.shape[0] // per_frame

    bm = barrier_mask(W, H)
    pix_total = 0
    pix_ok = 0
    pix_bad = 0
    first_bad = []
    barrier_blackened = 0
    ideal_diff = 0

    for f in range(F):
        b = beats[f * per_frame:(f + 1) * per_frame]
        o = out_beats[f * per_frame:(f + 1) * per_frame]
        mask = (b == WHITE).reshape(H, W)
        edge = dilate3x3(mask)
        filled, _ = scanline_fill_masked(edge, W, H)     # 与 RTL 同口径
        exp = bool_to_mask(filled)
        got = o.reshape(H, W)
        bad = exp != got
        pix_total += bad.size
        nb = int(bad.sum())
        pix_bad += nb
        pix_ok += bad.size - nb
        if nb:
            ys, xs = np.nonzero(bad)
            for i in range(min(8, len(ys))):
                first_bad.append((f, int(ys[i]), int(xs[i]),
                                  int(exp[ys[i], xs[i]]), int(got[ys[i], xs[i]])))
        if want_parity:
            ideal, _ = scanline_fill(edge)               # 裸的"膨胀+填充"
            d = ideal & ~filled                          # 被掩蔽黑掉的理想像素
            ideal_diff += int(d.sum())
            barrier_blackened += int(bm.sum())
    return {
        "frames": F,
        "n_beats_total": int(beats.shape[0]),
        "pix_total": pix_total,
        "pix_ok": pix_ok,
        "pix_bad": pix_bad,
        "first_bad": first_bad,
        "masked_area": barrier_blackened,
        "barrier_diff": ideal_diff,
    }
    return {
        "frames": F,
        "n_beats_total": int(beats.shape[0]),
        "pix_total": pix_total,
        "pix_ok": pix_ok,
        "pix_bad": pix_bad,
        "first_bad": first_bad,
        "masked_area": int(bm.sum()) * F,
        "barrier_leak": barrier_leak,
        "barrier_diff": barrier_diff,
    }


# ===========================================================================
# 5. 纯 Python 自证（含变异自证）：不依赖 RTL / ModelSim
# ===========================================================================
def _hx(beats_row):
    return "".join("%06X" % (int(v) & 0xFFFFFF) for v in beats_row)


def self_test():
    """返回 (checked, errors, msgs)。checked == 0 视为失败（没测等于没验）。"""
    checked = 0
    errors = 0
    msgs = []

    def check(name, cond, detail=""):
        nonlocal checked, errors
        checked += 1
        if not cond:
            errors += 1
            msgs.append("FAIL %s %s" % (name, detail))

    W, H = 32, 8
    bpl = bpl_of(W)

    # --- T1 闭合矩形轮廓（内部宽 22，排除被掩蔽的 x<4）---
    m = np.zeros((H, W), dtype=bool)
    m[2, 5:28] = True
    m[5, 5:28] = True
    m[2:6, 5] = True
    m[2:6, 27] = True
    o = ref_region_fill([m], W, H)[0] == WHITE
    check("T1-fill-interior", bool(o[3, 6:27].all()), "内部未填满")
    check("T1-outside-black",
          (not o[0, :].any()) and (not o[1, :].any()),
          "轮廓以上（含被掩蔽的前两行）不应为白")
    check("T1-edge-kept", bool(o[2, 5:28].all()) and bool(o[5, 5:28].all()),
          "轮廓本身必须保留")

    # --- T2 孤立白点：膨胀成 3×3，未闭合 ⇒ 该行从最左边缘一路填到行尾 ---
    m = np.zeros((H, W), dtype=bool)
    m[4, 16] = True
    o = ref_region_fill([m], W, H)[0] == WHITE
    for y, n in ((3, 17), (4, 17), (5, 17)):          # 列 15..31
        check("T2-dot-row%d" % y, int(o[y].sum()) == n,
              "孤立点第 %d 行应为 %d 个白像素，实得 %d" % (y, n, int(o[y].sum())))
    check("T2-dot-total", int(o.sum()) == 51, "孤立点总计应为 51，实得 %d" % int(o.sum()))
    check("T2-left-black", not o[:, :15].any(), "白点左侧不应有任何白像素")

    # --- T2b 实心 3×3 块（含被掩蔽的第 0 拍）---
    m = np.zeros((H, W), dtype=bool)
    m[3:6, 12:15] = True
    o = ref_region_fill([m], W, H)[0] == WHITE
    check("T2b-block-total", int(o.sum()) == 105,
          "3×3 实心块膨胀后 5 行各从列 11 填到行尾（5×21）应为 105，实得 %d" % int(o.sum()))
    check("T2b-left-black", not o[:, :11].any(), "块左侧不应有任何白像素")

    # --- T2c 真闭合环（5×5 首尾在同一拍的下一拍闭合）⇒ 内部被填、且填完就停 ---
    m = np.zeros((H, W), dtype=bool)
    m[3, 12:17] = True
    m[7, 12:17] = True
    m[3:8, 12] = True
    m[3:8, 16] = True
    o = ref_region_fill([m], W, H)[0] == WHITE
    check("T2c-ring-inner", bool(o[5, 12:17].all()), "闭合环内部必须被填满")
    check("T2c-ring-closes", not o[5, 18:].any(),
          "闭合环的填充必须在同拍内闭合并停下（不应一路填到行尾）")

    # --- T3 全黑 ---
    o = ref_region_fill([np.zeros((H, W), dtype=bool)], W, H)[0] == WHITE
    check("T3-allblack", not o.any(), "全黑帧必须全黑")

    # --- T4 全白：行首即边 ⇒ 从列 4 一路填到行尾；被掩蔽的前两行与第 0 拍全黑 ---
    o = ref_region_fill([np.ones((H, W), dtype=bool)], W, H)[0] == WHITE
    check("T4-allwhite-body", bool(o[2:, 4:].all()), "全白帧第 2 行起、列 4 起必须全白")
    check("T4-allwhite-masked",
          (not o[0, :].any()) and (not o[1, :].any()) and (not o[:, :4].any()),
          "被掩蔽的前两行与每行第 0 拍必须全黑（掩蔽纪律）")

    # --- T5 不闭合：从最后一条边一路填到行尾 ---
    m = np.zeros((H, W), dtype=bool)
    m[4, 8] = True
    o = ref_region_fill([m], W, H)[0] == WHITE
    check("T5-open-tail", bool(o[4, 7:].all()), "不闭合时右侧应被填到行尾")
    check("T5-open-head", not o[4, :7].any(), "不闭合时左侧不应被填")

    # --- T6 inside 的定义（上升沿判据的逐像素串行定义）---
    m = np.zeros((H, W), dtype=bool)
    m[4, 8] = m[4, 12] = m[4, 16] = True
    e = dilate3x3(m)
    filled, inside = scanline_fill(e)
    man = np.zeros_like(e)
    for y in range(H):
        acc = False
        prv = False
        for x in range(W):
            man[y, x] = acc
            acc = acc ^ (bool(e[y, x]) and not prv)     # 只在上升沿翻转
            prv = bool(e[y, x])
    check("T6-inside-def", bool((man == inside).all()), "inside 与逐像素串行定义不一致")
    check("T6-fill-def", bool((filled == (e | man)).all()), "输出应等于 edge | inside")

    # --- 变异自证：退回"每个白像素都翻一次"（本次修掉的那个 bug）---
    def old_rule(mask):
        ee = np.asarray(mask, dtype=bool)
        pre = np.zeros_like(ee)
        if ee.shape[1] > 1:
            np.bitwise_xor.accumulate(ee[:, :-1], axis=1, out=pre[:, 1:])
        return ee | pre

    # 2 像素宽的闭合矩形轮廓（**承重用例**）：
    #   旧规则：边缘 2 像素宽 = 偶数 ⇒ 内部填不上
    #   新规则：翻转次数 = 游程个数 ⇒ 内部填满
    m2 = np.zeros((H, W), dtype=bool)
    m2[2:9, 6:8] = True
    m2[2:9, 24:26] = True
    m2[2:4, 6:26] = True
    m2[7:9, 6:26] = True
    e2 = dilate3x3(m2)
    f_new, _ = scanline_fill(e2)
    f_old = old_rule(e2)
    check("T6b-2px-interior-filled", bool(f_new[5, 9:23].all()),
          "2 像素宽轮廓的内部必须被填满（新规则）")
    check("MUT-old-rule-differs", not np.array_equal(f_new, f_old),
          "旧规则（逐像素翻转）必须与上升沿规则不同，否则 2 像素用例没有鉴别力；"
          "差异像素数 = %d" % int((f_new != f_old).sum()))
    check("MUT-old-rule-fails-2px", not bool(f_old[5, 9:23].all()),
          "旧规则在 2 像素宽轮廓上必须**填不上**（这一步是该用例承重的证据）")

    # 4 像素宽轮廓（旁证）
    m4 = np.zeros((H, W), dtype=bool)
    m4[2:9, 4:8] = True
    m4[2:9, 22:26] = True
    m4[2:6, 4:26] = True
    m4[5:9, 4:26] = True
    e4 = dilate3x3(m4)
    f4n, _ = scanline_fill(e4)
    f4o = old_rule(e4)
    check("T6c-4px-interior-filled", bool(f4n[6, 9:21].all()),
          "4 像素宽轮廓的内部必须被填满（新规则）")
    check("MUT-old-rule-fails-4px", not np.array_equal(f4n, f4o),
          "旧规则在 4 像素宽轮廓上必须与正确结果不同")

    # --- 串行 vs 并行（每拍 4 个像素内部同时算）：output 等价、内部电平不同 ---
    # 说明：3×3 膨胀保证"每拍内的边缘游程起点不会是拍的第一个像素"，
    # 所以并行写法在**输出图**上与串行完全等价 —— 判据必须盯内部状态（RTL 的
    # r_inside 探针 + rise 中间级），不能只看输出。
    _f2, ins2 = scanline_fill(e2)
    par_inside = np.zeros_like(e2)
    for y in range(H):
        for k in range(bpl):
            st = bool(ins2[y, 4 * k])
            for j in range(4):
                if 4 * k + j < W:
                    par_inside[y, 4 * k + j] = st
    check("MUT-parallel-inner-differs", not np.array_equal(par_inside, ins2),
          "并行写法的**内部电平**必须与串行不同（否则 A9 探针没有鉴别力）；"
          "差异像素数 = %d" % int((par_inside != ins2).sum()))

    # --- 变异自证：膨胀漏一个方向（少算右上邻居）---
    def dilate_missing(mask, skip):
        mm = np.asarray(mask, dtype=bool)
        h, w = mm.shape
        out = mm.copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if (dy, dx) == skip:
                    continue
                src = mm[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)]
                dst = out[max(0, -dy):h + min(0, -dy), max(0, -dx):w + min(0, -dx)]
                np.logical_or(dst, src, out=dst)
        return out

    m1 = np.zeros((H, W), dtype=bool)
    m1[4, 16] = True
    check("MUT-dilate-9vs8", int(dilate_missing(m1, (-1, 1)).sum()) == 8,
          "漏一个方向时孤立点应只剩 8 个白像素")

    # --- 变异自证：每行不复位 inside（上一行状态带进下一行）---
    noreset = np.zeros_like(e)
    acc = False
    for y in range(H):
        for x in range(W):
            noreset[y, x] = acc
            acc = acc ^ bool(e[y, x])
    check("MUT-no-row-reset", not np.array_equal(noreset, inside),
          "不复位 inside 必须与正确结果不同")

    # --- 位序自证：pix0 必须落在 [95:72]（= beat 内第 0 个 = 最左）---
    row = np.zeros((4, W), dtype=np.uint32)
    row[0, 3] = WHITE
    beats = frames_to_beats(row, W, 4)
    check("T7-pix-order", int(beats[0, 3]) == WHITE and int(beats[0, :3].sum()) == 0,
          "pix0..pix3 的列序错了：%s" % _hx(beats[0]))
    back = ref_frames_from_beats(beats, W, 4)
    check("T7-roundtrip",
          bool(back[0, 0, 3]) and int(back[0, 0, :3].sum()) == 0,
          "frames<->beats 往返丢位序")

    # --- T8 掩蔽纪律：差异只允许出现在被掩蔽的像素上，且差异必须真的存在 ---
    m = np.zeros((H, W), dtype=bool)
    m[0, 0] = True          # 落在被掩蔽的前两行里 ⇒ 裸膨胀会点亮 (0,0)/(0,1)
    m[7, W - 1] = True
    e = dilate3x3(m)
    raw, _ = scanline_fill(e)                        # 裸：不掩蔽
    msk, _ = scanline_fill_masked(e, W, H)           # 与 RTL 同口径
    bm = barrier_mask(W, H)
    diff = raw != msk
    check("T8-barrier-changes", bool(diff.any()),
          "掩蔽在本图案上没改变任何像素 —— 掩蔽根本没被测到，A7 会变成空检查")
    check("T8-barrier-only-masked", not bool((diff & ~bm).any()),
          "掩蔽的影响漏到了掩蔽区之外（掩蔽越界）")
    check("T8-barrier-black", not bool((msk & bm).any()), "掩蔽区仍有白像素")
    check("T8-masked-idempotent", bool((apply_row_barrier(msk, W, H) == msk).all()),
          "掩蔽图的直接施加与串行模型不一致")

    return checked, errors, msgs


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    c, e, ms = self_test()
    for m in ms:
        print(m)
    print("ref_region_fill self_test: checked=%d errors=%d" % (c, e))
    sys.exit(1 if (e or c == 0) else 0)
