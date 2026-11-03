#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_alg_ops.py —— 校验 ModelSim 真实仿真出来的 dump_alg.txt（M2/M3/M4 三档）

判定口径（全部来自规格，不读 RTL 实现）：
  金标准   : alg_ref.py 的逐像素数学（nearest 到函数与行号见下）
  接口位序 : S1第二批_接口冻结.md §3
             tap(r,c,k) = I_window[8*(4*(3*r+c)+k) +: 8]
             r = 0/1/2 → 行 y-2 / y-1 / y；c = 0/1/2 → 列 4x+k-1 / 4x+k / 4x+k+1

  A. 延迟 / 同拍：三档的 O_tvalid / O_tlast / O_tuser 必须逐拍等于
     I_tvalid / I_tlast / I_tuser 延迟 1 拍；O_tdata 必须逐拍等于
     f(上一拍的 I_window, I_rgb_center) —— 直接把"输出延迟 1 拍"钉死。
  B. 算法：A 里那条 f 就是本文件按金标准重写的标量模型（不用 RTL 的任何中间量）。
  C. 窗口几何：有效拍上 dump 出来的 I_window 必须逐字节等于
     alg_ref 的 3x3 窗口（按 beat → (y,x_grp) 映射）。
  D. M3 的 src 行：I_rgb_center 的中心行段必须等于原图**第 y-1 行**的 RGB 拍。
  E. 端到端：把 RTL 三档输出按 beat 写回帧，与 alg_ref.AlgPipeline(mode).process(img)
     的最终图像在 window_valid 像素上逐值比对（第 3 帧，行缓存稳态）。
  F. X/Z 泄漏：有效拍的三档输出不允许出现 x / z。
  G. 激励鉴别力：逐个变异列出"有多少拍的期望值会因此改变"。

用法：
    python check_alg_ops.py              # 正常校验
    python check_alg_ops.py --selftest   # 变异自证：故意用错误期望重跑，必须被抓出来
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

import numpy as np          # noqa: E402
import alg_ref as A         # noqa: E402

from gen_stim_alg import (  # noqa: E402
    build_image, gray_frame, W, H, BPL, FRAMES, NBEAT,
)

# ---- 与 RTL 的 parameter 默认值一致（alg_top 例化时必须同步）----
C_OFF, TH_MIN, TH_MAX = 0, 0, 255
EDGE_K = 128
BPF = BPL * H
LAT = 1

# ---- 三档 RTL 输出的列号（与 tb_alg_ops.v 的 $fwrite 顺序逐字对应）----
MODS = [("bin", 10, 11, 12, 13, "M2 alg_binarize_96"),
        ("sob", 14, 15, 16, 17, "M3 alg_sobel_96"),
        ("smo", 18, 19, 20, 21, "M4 alg_smooth_96")]


# ===========================================================================
# 1. 位序原语（冻结文档 §3，唯一权威）
# ===========================================================================
def tap(win, r, c, k, mut=None):
    """I_window 的第 k 个中心像素在窗口 (r,c) 处的灰度。

    ⚠ 不提供"行/列镜像"变异：三个算子在数学上对窗口的行列镜像与转置**完全不敏感**
      （9 点求和、1-2-1 可分离核、|Gx|+|Gy| 都对称），镜像只能由检查 C 抓。
    """
    if mut and mut.get("tap_kswap"):
        k = 3 - k
    return (win >> (8 * (4 * (3 * r + c) + k))) & 0xFF


def rgb_at(rgb, k, mut=None):
    """I_rgb_center（96bit = 图像第 y-1 行、列 4x+0..4x+3）第 k 个像素的 RGB888。

    冻结文档 §2（2026-09-14 更正为 [95:0]）：位序同 I_tdata，
    pix0（列 4x+0，最左）在 [95:72] ⇒ rgb >> (24*(3-k))。
    """
    if mut and mut.get("rgb_pix_order"):
        k = 3 - k
    return (rgb >> (24 * (3 - k))) & 0xFFFFFF


def win9(win, k, mut=None):
    """第 k 个中心像素的 9 个抽头，命名与 alg_ref §4.4 一致（a11 = 中心）。"""
    return [tap(win, r, c, k, mut) for r in (0, 1, 2) for c in (0, 1, 2)]


# ===========================================================================
# 2. 三档金标准标量模型（与 alg_ref.py 逐行对应，mut 用于变异自证）
# ===========================================================================
def local_mean(S, mut=None):
    """alg_ref.local_mean（:150-163）：m=(S*MEAN_NUM)>>MEAN_SHIFT；TH=clamp(m+C_off)。"""
    num = mut.get("mean_num", A.MEAN_NUM) if mut else A.MEAN_NUM
    sh = mut.get("mean_shift", A.MEAN_SHIFT) if mut else A.MEAN_SHIFT
    return min(max(((S * num) >> sh) + C_OFF, TH_MIN), TH_MAX)


def exp_bin(win, mut=None):
    """M2：alg_ref.py:635-641 / beat_ref.py:413-417。"""
    ge = bool(mut.get("bin_ge")) if mut else False
    out = 0
    for k in range(4):
        a = win9(win, k, mut)
        th = local_mean(sum(a), mut)
        ctr = tap(win, 1, 1, k, mut)
        white = (ctr >= th) if ge else (ctr > th)
        out = (out << 24) | (0xFFFFFF if white else 0x000000)
    return out


def exp_sob(win, rgb, mut=None):
    """M3：alg_ref.py:642-649 / beat_ref.py:418-425。"""
    scale = mut.get("edge_scale", A.EDGE_TH_SCALE) if mut else A.EDGE_TH_SCALE
    kv = mut.get("edge_k", EDGE_K) if mut else EDGE_K
    ge = True if not mut else (not mut.get("sob_gt"))
    out = 0
    for k in range(4):
        a00, a01, a02, a10, a11, a12, a20, a21, a22 = win9(win, k, mut)
        gx = -a00 + a02 - (a10 << 1) + (a12 << 1) - a20 + a22
        gy = a00 + (a01 << 1) + a02 - a20 - (a21 << 1) - a22
        mag = abs(gx) + abs(gy)
        th = local_mean(a00 + a01 + a02 + a10 + a11 + a12 + a20 + a21 + a22, mut)
        edge = (mag >= th * scale) if ge else (mag > th * scale)
        if mut and mut.get("src_gray"):
            src = a11 * 0x010101                       # 错：拿窗口中心灰度当 RGB
        else:
            src = rgb_at(rgb, k, mut)
        r, g, b = (src >> 16) & 0xFF, (src >> 8) & 0xFF, src & 0xFF
        pix = (((min(r + kv, 255)) << 16) | ((min(g + kv, 255)) << 8) | min(b + kv, 255)) if edge else src
        out = (out << 24) | pix
    return out


def exp_smo(win, mut=None):
    """M4：alg_ref.py:650-654 / alg_ref.gauss_121（:432-445）。"""
    wmid = mut.get("gauss_w", 2) if mut else 2
    sh = mut.get("gauss_shift", 4) if mut else 4
    split = bool(mut.get("gauss_split")) if mut else False
    out = 0
    for k in range(4):
        a = win9(win, k, mut)
        r0 = a[0] + (a[1] << 1) + a[2]
        r1 = a[3] + (a[4] << 1) + a[5]
        r2 = a[6] + (a[7] << 1) + a[8]
        if split:
            g = (r0 >> sh) + (r1 >> (sh - 1)) + (r2 >> sh)     # 错：分项移位
        else:
            g = (r0 + (r1 * wmid) + r2) >> sh
        g = min(max(g, 0), 255)
        out = (out << 24) | (g * 0x010101)
    return out


EXPF = {"bin": lambda w, r, m: exp_bin(w, m),
        "sob": lambda w, r, m: exp_sob(w, r, m),
        "smo": lambda w, r, m: exp_smo(w, m)}


# ===========================================================================
# 3. dump 解析
# ===========================================================================
def has_xz(s):
    return any(c in "xXzZ" for c in s)


def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 22:
                continue
            r = {"cyc": int(f[0]), "bidx": int(f[1]), "bix2": int(f[2]),
                 "drv": int(f[3]),
                 "Iv": int(f[4]), "Il": int(f[5]), "Iu": int(f[6]),
                 "Iwv": int(f[7]), "win": f[8], "rgb": f[9]}
            for nm, c0, c1, c2, c3, _t in MODS:
                r[nm] = f[c0]
                r[nm + "_v"] = int(f[c1])
                r[nm + "_l"] = int(f[c2])
                r[nm + "_u"] = int(f[c3])
            rows.append(r)
    return rows


# ===========================================================================
# 4. 检查
# ===========================================================================
def _h(s):
    return int(s, 16) if not has_xz(s) else None


def check_latency(rows, lat=LAT, verbose=True):
    """A：控制透传 + tdata 的延迟与同拍。"""
    ncyc = 0
    fails = []
    for nm, _c0, _c1, _c2, _c3, _t in MODS:
        bad_v = bad_l = bad_u = 0
        for t in range(lat, len(rows)):
            a, b = rows[t], rows[t - lat]
            ncyc += 1
            if a[nm + "_v"] != b["Iv"]:
                bad_v += 1
            if a[nm + "_l"] != (b["Iv"] and b["Il"]):
                bad_l += 1
            if a[nm + "_u"] != (b["Iv"] and b["Iu"]):
                bad_u += 1
        if verbose:
            print("  %-4s O_tvalid 不符 %-4d  O_tlast 不符 %-4d  O_tuser 不符 %-4d  %s"
                  % (nm, bad_v, bad_l, bad_u,
                     "PASS" if (bad_v or bad_l or bad_u) == 0 else "FAIL"))
        if bad_v or bad_l or bad_u:
            fails.append("延迟：%s 的 tvalid/tlast/tuser 不是 1 拍对齐" % nm)
    return fails, ncyc * 3 * len(MODS)


def check_algo(rows, mut=None, verbose=True):
    """B：三档输出 = 金标准模型（对上一拍的窗口/RGB 求值）。"""
    fails, ncmp = [], 0
    for nm, _c0, _c1, _c2, _c3, title in MODS:
        bad, first, nmod = 0, None, 0
        for t in range(1, len(rows)):
            b = rows[t - 1]
            if b["Iv"] == 0:
                exp = 0
            elif has_xz(b["win"]) or has_xz(b["rgb"]):
                continue                                   # 输入本身是 X：跳过（另有 X 检查）
            else:
                exp = EXPF[nm](_h(b["win"]), _h(b["rgb"]), mut)
            nmod += 1
            got = _h(rows[t][nm])
            if got != exp:
                bad += 1
                if first is None:
                    first = (rows[t]["cyc"], rows[t]["bix2"])
        ncmp += nmod
        if verbose:
            print("  %-4s 比较 %5d 拍，不符 %-5d  首错=%s  %s"
                  % (nm, nmod, bad, first, "PASS" if bad == 0 else "FAIL"))
        if bad:
            fails.append("%s：%d 拍不符金标准模型" % (title, bad))
    return fails, ncmp


def check_window_geom(rows, gy, gmut=None, verbose=True):
    """C：dump 出来的 I_window 必须逐字节等于 alg_ref 的 3x3 窗口。

    冻结公式 tap(r,c,k) = gray(y-2+r, 4xg+k+c-1)，而 build_windows 的
    win[a,b,r,c] = gray(a-1+r, b-1+c) ⇒ 参考取 win[y-1, 4*xg+k]。
    （y<2 的拍被掩蔽，本来就不参与，所以 y-1 >= 1 恒成立。）

    gmut 用于变异自证：镜像/平移窗口的参考，必须全部被本检查抓住 ——
    因为 M2/M3/M4 三个算子对窗口的**镜像与转置在数学上完全不可见**
    （9 点求和对称、1-2-1 可分离核对称、|Gx|+|Gy| 对称），
    所以"窗口没接反"这件事只能由本检查（对照 alg_ref 的绝对几何）来保证。
    """
    win3 = A.build_windows(gy.astype(np.uint8), 3, 3)
    bad = nvalid = ntap = 0
    first = None
    for r in rows:
        if r["Iv"] == 0 or r["Iwv"] == 0 or has_xz(r["win"]):
            continue
        bidx = r["bix2"]
        if bidx >= NBEAT:
            continue
        y, xg = (bidx % BPF) // BPL, bidx % BPL
        if gmut and gmut.get("beat_off"):
            bidx2 = min(NBEAT - 1, bidx + gmut["beat_off"])
            y, xg = (bidx2 % BPF) // BPL, bidx2 % BPL
        nvalid += 1
        wv = _h(r["win"])
        for k in range(4):
            for rr in range(3):
                for cc in range(3):
                    ntap += 1
                    got = (wv >> (8 * (4 * (3 * rr + cc) + k))) & 0xFF
                    a, b_, r2, c2 = y - 1, 4 * xg + k, rr, cc
                    if gmut:
                        if gmut.get("row_mirror"):
                            r2 = 2 - rr
                        if gmut.get("col_mirror"):
                            c2 = 2 - cc
                        if gmut.get("row_off"):
                            a += gmut["row_off"]
                        if gmut.get("kswap"):
                            b_ = 4 * xg + (3 - k)
                    if 0 <= a < H and 0 <= b_ < W:
                        want = int(win3[a, b_, r2, c2])
                    else:
                        want = 0
                    if got != want:
                        bad += 1
                        if first is None:
                            first = (r["cyc"], y, xg, k, rr, cc, got, want)
    if verbose:
        print("  有效拍 %d 个，抽头 %d 个，不符 %d 个  首错=%s  %s"
              % (nvalid, ntap, bad, first, "PASS" if bad == 0 else "FAIL"))
    return ([] if bad == 0 else ["窗口几何：%d 个抽头不符 alg_ref.build_windows" % bad]), ntap, bad


def check_rgb_row(rows, img, rmut=None, verbose=True):
    """D：I_rgb_center（96bit）== 原图**第 y-1 行**、列 4x+0..4x+3 的 RGB 拍。

    冻结文档 §2 更正后端口就是 96 位 = 图像第 y-1 行那 4 个像素的 RGB888，
    位序同 I_tdata（pix0 在 [95:72]）。

    ⚠ y=0 时"第 y-1 行"是**上一帧的最后一行**，那几拍本来就被 window_valid 掩蔽
      （window_valid 要求 y>=2），不参与算法，所以不做断言
      （否则等于要求 TB 的行延迟跨帧不回绕）。

    rmut 用于变异自证：行取错 / 列平移 / 像素序反 都必须被本检查抓住 ——
    "这条总线到底搬的是哪一行"是 M3 唯一无法自查的性质。
    """
    bad = nchk = 0
    first = None
    dy = -1 if rmut is None else rmut.get("dy", -1)
    dx = 0 if rmut is None else rmut.get("dx", 0)
    ksw = bool(rmut and rmut.get("kswap"))
    for r in rows:
        if r["Iv"] == 0 or has_xz(r["rgb"]):
            continue
        bidx = r["bix2"]
        if bidx >= NBEAT:
            continue
        y, xg = (bidx % BPF) // BPL, bidx % BPL
        nchk += 1
        rv = _h(r["rgb"])
        for k in range(4):
            if y + dy < 0:
                continue
            got = (rv >> (24 * (3 - (3 - k if ksw else k)))) & 0xFFFFFF
            yy = y + dy
            x = 4 * xg + k + dx
            if not (0 <= x < W):
                want = 0
            else:
                want = (int(img[yy, x, 0]) << 16) | (int(img[yy, x, 1]) << 8) | int(img[yy, x, 2])
            if got != want:
                bad += 1
                if first is None:
                    first = (r["cyc"], y, xg, k, got, want)
    if verbose:
        print("  检查 %d 拍 × 4 像素（y=0 的跨帧行跳过），不符 %d 个  首错=%s  %s"
              % (nchk, bad, first, "PASS" if bad == 0 else "FAIL"))
    return ([] if bad == 0 else ["I_rgb_center 行对齐：%d 个像素不符原图 y-1 行" % bad]), nchk * 4, bad


def check_end2end(rows, img, verbose=True):
    """E：把 RTL 三档输出按 beat 写回帧，与 alg_ref 的帧级输出在 window_valid 像素上比对。

    beat 行号 y_b 的结果落在帧的第 y_b 行（3x3 窗口固有的一行延迟已经体现在
    "窗口中心行 = y_b-1" 上），这一点与 alg_ref.process 的 `out[:1]+out[:-1]` 位移等价。
    """
    fails = []
    gy = gray_frame(img)
    valid = A.window_valid_mask(H, W)
    for nm, _c0, _c1, _c2, _c3, title in MODS:
        mode = {"bin": A.MODE_BIN, "sob": A.MODE_EDGE, "smo": A.MODE_SMOOTH}[nm]
        ref = A.AlgPipeline(mode=mode, c_off=C_OFF, edge_k=EDGE_K,
                            th_min=TH_MIN, th_max=TH_MAX).process(img).image
        frame = np.full((H, W, 3), -1, dtype=np.int32)
        for t in range(1, len(rows)):
            b = rows[t - 1]
            bidx = b["bix2"]
            if b["Iv"] == 0 or b["Iwv"] == 0 or bidx >= NBEAT:
                continue
            if bidx // BPF != FRAMES - 1:                  # 只比第 3 帧（稳态）
                continue
            y, xg = (bidx % BPF) // BPL, bidx % BPL
            v = _h(rows[t][nm])
            if v is None:
                frame[y, 4 * xg:4 * xg + 4] = -2           # X 标记
                continue
            for k in range(4):
                p = (v >> (24 * (3 - k))) & 0xFFFFFF
                frame[y, 4 * xg + k] = [(p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF]
        got = frame[valid]
        want = ref[valid].astype(np.int32)
        unwritten = int((frame[valid][:, 0] < 0).sum())
        badpx = int((got != want).any(axis=1).sum())
        if verbose:
            print("  %-4s %-20s 比对 %d 像素，不符 %d，未写入 %d  %s"
                  % (nm, title, int(valid.sum()), badpx, unwritten,
                     "PASS" if (badpx == 0 and unwritten == 0) else "FAIL"))
        if badpx or unwritten:
            fails.append("%s：端到端 %d 像素不符 / %d 未写入" % (title, badpx, unwritten))
    return fails, int(valid.sum()) * len(MODS)


def check_xz(rows, verbose=True):
    """F：有效拍输出不允许 X/Z。"""
    bad = 0
    for t in range(1, len(rows)):
        if rows[t - 1]["Iv"] == 0:
            continue
        for nm, _c0, _c1, _c2, _c3, _t in MODS:
            if has_xz(rows[t][nm]):
                bad += 1
    if verbose:
        print("  有效拍输出出现 X/Z 的次数 = %d  %s" % (bad, "PASS" if bad == 0 else "FAIL"))
    return ([] if bad == 0 else ["输出 X/Z 泄漏 %d 次" % bad])


# ===========================================================================
# 5. 变异清单
# ===========================================================================
MUTATIONS = [
    ("M2 判决 > 改成 >=",          {"bin_ge": True}),
    ("M2 均值系数 57 改成 58",      {"mean_num": 58}),
    ("M2 移位 >>9 改成 >>8",        {"mean_shift": 8}),
    ("M3 阈值不乘 4",               {"edge_scale": 1}),
    ("M3 判决 >= 改成 >",           {"sob_gt": True}),
    ("M3 提亮量 K=128 改成 64",     {"edge_k": 64}),
    ("M3 src 用窗口中心灰度",        {"src_gray": True}),
    ("M3 src 像素序反（pix0 放低位）", {"rgb_pix_order": True}),
    ("M2/M3/M4 窗口像素序反(k→3-k)", {"tap_kswap": True}),
    ("M4 核 1-2-1 改成 1-3-1",      {"gauss_w": 3}),
    ("M4 移位 >>4 改成 >>3",         {"gauss_shift": 3}),
    ("M4 分项移位（丢 LSB）",        {"gauss_split": True}),
]

# 窗口几何的变异：由检查 C 负责抓（算法层面对镜像/转置是盲的，见 check_window_geom docstring）
GEOM_MUTATIONS = [
    ("窗口行序对调（r0<->r2）",      {"row_mirror": True}),
    ("窗口列序对调（c0<->c2）",      {"col_mirror": True}),
    ("窗口整体上移一行",             {"row_off": -1}),
    ("窗口整体下移一行",             {"row_off": +1}),
    ("拍号错一拍",                  {"beat_off": 1}),
    ("窗口像素序反（k→3-k）",        {"kswap": True}),
]

# I_rgb_center 这条总线搬的内容对不对：由检查 D 负责抓
RGB_MUTATIONS = [
    ("搬成第 y 行（少延迟一行）",     {"dy": 0}),
    ("搬成第 y-2 行（多延迟一行）",   {"dy": -2}),
    ("整拍平移一列",                {"dx": 1}),
    ("像素序反（pix0 放低位）",       {"kswap": True}),
]


def coverage(rows, verbose=True):
    """G：每个变异会让多少拍的期望值改变（激励的鉴别力）。"""
    if verbose:
        print("  变异                                        期望值改变的拍数")
    res = []
    for name, m in MUTATIONS:
        n = 0
        for t in range(1, len(rows)):
            b = rows[t - 1]
            if b["Iv"] == 0 or has_xz(b["win"]) or has_xz(b["rgb"]):
                continue
            wv, rv = _h(b["win"]), _h(b["rgb"])
            for nm, _c0, _c1, _c2, _c3, _t in MODS:
                if EXPF[nm](wv, rv, m) != EXPF[nm](wv, rv, None):
                    n += 1
                    break
        res.append((name, n))
        if verbose:
            print("  %-44s %5d %s" % (name, n, "" if n else "  <== 无鉴别力!"))
    return res


# ===========================================================================
# 6. 主流程
# ===========================================================================
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows = parse(os.path.join(here, "dump_alg.txt"))
    img = build_image()
    gy = gray_frame(img)
    selftest = "--selftest" in sys.argv
    print("解析 dump_alg.txt：%d 拍（期望 %d 拍）" % (len(rows), NBEAT + 6 + 3 + 24 + 1))

    if not selftest:
        fails, ncmp = [], {}
        print("\n=== A. 延迟 / 同拍（三档各自 O_tvalid/O_tlast/O_tuser = 输入延迟 1 拍）===")
        f, n = check_latency(rows)
        fails += f
        ncmp["A 控制透传"] = n
        print("\n=== B. 算法：三档输出 = 金标准模型（对上一拍的 I_window/I_rgb_center）===")
        f, n = check_algo(rows)
        fails += f
        ncmp["B 三档算法"] = n
        print("\n=== C. 窗口几何：dump 的 I_window = alg_ref.build_windows ===")
        f, n, _b = check_window_geom(rows, gy)
        fails += f
        ncmp["C 窗口几何"] = n
        print("\n=== D. I_rgb_center 行对齐（96bit = 原图第 y-1 行的 4 个 RGB888）===")
        f, n, _b = check_rgb_row(rows, img)
        fails += f
        ncmp["D RGB行对齐"] = n
        print("\n=== E. 端到端：RTL 输出帧 vs alg_ref.AlgPipeline（第 %d 帧，window_valid 像素）===" % FRAMES)
        f, n = check_end2end(rows, img)
        fails += f
        ncmp["E 端到端"] = n
        print("\n=== F. X/Z 泄漏 ===")
        f = check_xz(rows)
        fails += f
        print("\n=== G. 激励鉴别力（每个变异影响多少拍）===")
        cov = coverage(rows)

        tot = sum(ncmp.values())
        print("\n" + "=" * 70)
        print("断言计数：%s  合计 %d" % ("  ".join("%s=%d" % kv for kv in ncmp.items()), tot))
        print("=" * 70)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails[:20]:
                print("   " + s)
        else:
            print("结论：PASS —— 延迟/算法/窗口几何/RGB行对齐/端到端/X 六项全过，"
                  "共 %d 条断言" % tot)
        weak = [n for n, c in cov if c == 0]
        print("鉴别力：%d/%d 个变异至少有一个拍能区分%s"
              % (len(MUTATIONS) - len(weak), len(MUTATIONS),
                 "" if not weak else "（无鉴别力：%s）" % weak))
        print("=" * 70)
        return 0 if not fails else 1

    # ---------------- 变异自证 ----------------
    print("\n" + "=" * 70)
    print("变异自证：故意用【错误期望】重跑，每一条都必须被抓出来")
    print("（抓不住的条目 = 测试在这个维度上没有鉴别力 = 等于没测）")
    print("=" * 70)
    print("[1] 算法变异（由检查 B 抓）")
    caught = 0
    for name, m in MUTATIONS:
        bad = 0
        for t in range(1, len(rows)):
            b = rows[t - 1]
            if b["Iv"] == 0 or has_xz(b["win"]) or has_xz(b["rgb"]):
                continue
            for nm, _c0, _c1, _c2, _c3, _t in MODS:
                if _h(rows[t][nm]) != EXPF[nm](_h(b["win"]), _h(b["rgb"]), m):
                    bad += 1
        ok = bad > 0
        caught += 1 if ok else 0
        print("  %-44s -> 报错 %5d 拍   %s" % (name, bad, "抓住" if ok else "!! 漏掉 !!"))

    print("[2] 窗口几何变异（由检查 C 抓；算法层对这些镜像/平移是盲的）")
    gcaught = 0
    for name, g in GEOM_MUTATIONS:
        _f, _n, hit = check_window_geom(rows, gy, gmut=g, verbose=False)
        ok = hit > 0
        gcaught += 1 if ok else 0
        print("  %-44s -> 报错 %5d 个抽头   %s" % (name, hit, "抓住" if ok else "!! 漏掉 !!"))

    print("[3] I_rgb_center 行/像素对齐变异（由检查 D 抓）")
    rcaught = 0
    for name, rm in RGB_MUTATIONS:
        _f, _n, hit = check_rgb_row(rows, img, rmut=rm, verbose=False)
        ok = hit > 0
        rcaught += 1 if ok else 0
        print("  %-44s -> 报错 %5d 个像素   %s" % (name, hit, "抓住" if ok else "!! 漏掉 !!"))

    print("-" * 70)
    tot_ok = caught + gcaught + rcaught
    tot_n = len(MUTATIONS) + len(GEOM_MUTATIONS) + len(RGB_MUTATIONS)
    print("  鉴别力：算法 %d/%d，窗口几何 %d/%d，RGB 行对齐 %d/%d，合计 %d/%d  -> %s"
          % (caught, len(MUTATIONS), gcaught, len(GEOM_MUTATIONS),
             rcaught, len(RGB_MUTATIONS), tot_ok, tot_n,
             "PASS" if tot_ok == tot_n else "FAIL"))
    print("=" * 70)
    return 0 if tot_ok == tot_n else 1


if __name__ == "__main__":
    sys.exit(main())
