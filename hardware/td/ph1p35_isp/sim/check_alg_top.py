#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_alg_top.py —— 校验 ModelSim 真仿真出来的 dump_top.txt（`alg_top` 集成层）

被测对象：src/alg_top.v（6 档切换 + 掩蔽 + 延迟对齐），7 个子模块已各自验过、本次不改。

⚠ 激励工况（2026-09-14 改造）：**默认就是真实链路工况 —— 带行消隐**。
  tb_alg_top.v 默认每行 BPL 拍背靠背 + 行末 20 拍 tvalid=0（依据：官方 zhenghe.v:137-146
  的 rd_valid 在 x_cnt 清零时也清零，这一段 gap 经 data128_96/awb 纯寄存器延迟原样到达
  alg_top 输入）。改造前本文件跑的"帧间无气泡"激励在真实系统里**不存在**，等于金标准
  验了一个假工况；现在判据 I 会**强制要求**激励带行消隐（用 +noblank 跑就会在这里报错）。
  含消隐后拍数从 667 涨到 2247，A（逐拍延迟）与 H（激励自检）的断言数随之上升。

判定口径（全部来自冻结规格 + 金标准 alg_ref.py，不读被测 RTL 的任何内部量）：
  A. 全链延迟 = 5 拍：O_tvalid/O_tlast/O_tuser 逐拍 == 输入延迟 5 拍；
     且第 i 个输出有效拍必须落在"第 i 个输入有效拍 + 5"那一拍上（tdata 的对齐前提）。
  B. 6 档逐值对金标准：每一档单独一帧，O_tdata 拆成像素后与
     alg_ref.AlgPipeline(对应档位).process(该帧图, bbox_prev=上一帧 bbox) 逐像素相等。
     M0/M1 也要比（它们同样过掩蔽）。
  C. 掩蔽：前 2 行 + 每行第 0 拍（x=0..3）必须输出**原图**（不是黑屏、不是算法结果）。
  D. 档位锁存：整帧之内 O_mode 恒定且等于该帧的期望档位；换档只发生在输出流的帧边界。
  E. M3 的 src 行：从第 3 帧（M3）输出**反解** src 实际来自哪一行，
     并把它与 4 个候选（第 y-1 行 / 第 y 行 / 第 y-2 行 / 灰度中心行）逐一比对。
  F. X/Z 泄漏；G. M5 的 bbox 统计；H. 激励自检（dump 里的 I_* 与 gen_stim_top.py 是否一致）；
  I. 激励工况自检：每行行末必须有一段 tvalid=0 的行消隐（长度 = 真实链路值 20 拍）——
     这条把"金标准必须在真实工况下才算验过"变成硬门禁。

用法：
    python check_alg_top.py              # 正常校验（需要先跑完 tb_alg_top，默认含行消隐）
    python check_alg_top.py --selftest   # 改期望值的变异自证（17 条，必须全被抓住）
"""
from __future__ import annotations

import os
import sys
from collections import defaultdict

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

import numpy as np          # noqa: E402
import alg_ref as A         # noqa: E402

from gen_stim_top import (  # noqa: E402
    W, H, BPL, FRAMES, BPF, NBEAT, MODE_SCHED, MODE_SET_SCHED, MODE_SEL_MIDF,
    MODE_SEL_MIDV, KEY_FRAMES, KEY_BIF, KEY_LEN, EDGE_K, C_OFF, BLANK_LEN,
    RLO, RHI, GLO, GHI, BLO, BHI, build_images, stim_beats,
)

LAT = 5                       # 全链延迟（S1第二批_接口冻结.md §2.5）
MODE_NAMES = {0: "M0 RAW", 1: "M1 GRAY", 2: "M2 BIN", 3: "M3 EDGE",
              4: "M4 SMOOTH", 5: "M5 TARGET"}

IMAGES = build_images()
_WHASH = {}

# M5 的 bbox：金标准按"上一帧统计"画框，逐帧的 bbox 先算好
BBOXES = []
for _im in IMAGES:
    _hit = A.target_hit(_im, RLO, RHI, GLO, GHI, BLO, BHI)
    _hit = A.hit_vote(_hit) & A.window_valid_mask(H, W)
    BBOXES.append(A.bbox_stats(_hit)["bbox"])


# ===========================================================================
# 1. 金标准期望帧（含变异钩子）
# ===========================================================================
def _windows(img):
    key = int(img.sum()) * 1000003 + int(img[0, 0, 0]) * 97 + int(img[3, 4, 1])
    if key not in _WHASH:
        _WHASH[key] = A.build_windows(A.gray_bt601(img).astype(np.uint8), 3, 3)
    return _WHASH[key]


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


def variant_out(img, mode, mut, bbox_prev=None):
    """变异路径：按 alg_ref 的向量化原语重算一帧（默认参数下必须与 AlgPipeline 逐位相同）。

    只用它来造"错误期望"，正常校验一律走 AlgPipeline 本体。
    """
    valid = A.window_valid_mask(H, W, mut.get("ppb", 4), mut.get("mask_rows", 2))
    gray = A.gray_bt601(img)
    gray3 = np.repeat(gray[:, :, None], 3, axis=2).astype(np.uint8)
    win = _windows(img)

    if mode == A.MODE_RAW:
        out = img.copy()
    elif mode == A.MODE_GRAY:
        out = gray3.copy()
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
            src = gray3.astype(np.int32)                       # 错：src 是灰度中心行
        else:
            dy = mut.get("src_dy", -1)                         # -1 = 第 y-1 行（正确）
            if dy == 0:
                src = np.roll(img, -1, axis=0).astype(np.int32)     # 错：第 y 行
            elif dy == -2:
                src = np.roll(img, 1, axis=0).astype(np.int32)      # 错：第 y-2 行
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
    else:                                                      # MODE_TARGET
        out = A.draw_bbox(img, bbox_prev).astype(np.uint8)

    if mut.get("mask_black"):
        out = np.where(valid[:, :, None], out, np.uint8(0))
    elif mut.get("skip_mask_modes") and mode in mut["skip_mask_modes"]:
        pass                                                   # 错：该档不套掩蔽
    else:
        out = np.where(valid[:, :, None], out, img)
    return out.astype(np.int32)


def expected_frame(f, mut=None):
    """第 f 输出帧的期望（H,W,3）int32。mut=None 时**直接走金标准 AlgPipeline**。"""
    mut = mut or {}
    mode = MODE_SCHED[f]
    if mut.get("mode_off"):
        mode = (mode + mut["mode_off"]) % 6
    img = IMAGES[f]
    bp = BBOXES[f - 1] if f >= 1 else None
    if mut.get("bbox_current"):
        bp = BBOXES[f]
    need_var = bool(mut.get("src_dy") is not None or mut.get("src_gray")
                    or mut.get("no_row_shift") or mut.get("skip_mask_modes"))
    if not need_var:
        return _pipe(mode, mut).process(img, bbox_prev=bp).image.astype(np.int32)
    return variant_out(img, mode, mut, bbox_prev=bp)


# ===========================================================================
# 2. dump 解析
# ===========================================================================
def has_xz(s):
    return any(c in "xXzZ" for c in s)


def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 19:
                continue
            rows.append({
                "cyc": int(f[0]),
                "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]), "Idat": f[4],
                "drv": int(f[5]), "mset": int(f[6]), "msel": int(f[7]),
                "Ov": int(f[8]), "Ol": int(f[9]), "Ou": int(f[10]),
                "Odat": f[11], "Omode": int(f[12]),
                "bbv": int(f[13]), "bx0": int(f[14]), "bx1": int(f[15]),
                "by0": int(f[16]), "by1": int(f[17]), "cnt": int(f[18]),
            })
    return rows


def _h(s):
    return None if has_xz(s) else int(s, 16)


def pix_at(v, k):
    """96bit 拍的第 k 个像素 -> (R,G,B)。

    位序（S0-02 §2.2，与 alg_ref.pack_beats 同源）：pix0（最左）在 [95:72]，
    像素内 {R[23:16],G[15:8],B[7:0]} ⇒ 第 k 个像素占 [24*(3-k) +: 24]。
    """
    sh = 24 * (3 - k)
    return ((v >> (sh + 16)) & 0xFF, (v >> (sh + 8)) & 0xFF, (v >> sh) & 0xFF)


def valid_cycles(rows, key):
    return [r["cyc"] for r in rows if r[key] == 1]


def beat_pos(i):
    """第 i 个有效拍 -> (帧号, 行号, 行内拍号)。"""
    return i // BPF, (i % BPF) // BPL, i % BPL


# ===========================================================================
# 3. 五项检查
# ===========================================================================
def check_a(rows, mut=None, verbose=True):
    """A：控制信号逐拍 = 输入延迟 5 拍 + 第 i 个输出有效拍 = 第 i 个输入有效拍 + 5。"""
    mut = mut or {}
    lat = mut.get("lat", LAT)
    nass = nbad = 0
    bad_v = bad_l = bad_u = 0
    first = None
    for t in range(lat, len(rows)):
        a, b = rows[t], rows[t - lat]
        nass += 3
        if a["Ov"] != b["Iv"]:
            bad_v += 1
        if a["Ol"] != (b["Iv"] and b["Il"]):
            bad_l += 1
        if a["Ou"] != (b["Iv"] and b["Iu"]):
            bad_u += 1
        if (a["Ov"] != b["Iv"] or a["Ol"] != (b["Iv"] and b["Il"])
                or a["Ou"] != (b["Iv"] and b["Iu"])) and first is None:
            first = (a["cyc"], a["Ov"], a["Ol"], a["Ou"])
    nbad = bad_v + bad_l + bad_u

    ic = valid_cycles(rows, "Iv")
    oc = valid_cycles(rows, "Ov")
    nass += max(len(ic), len(oc))
    bad_beat = 0
    if len(ic) != len(oc):
        bad_beat = abs(len(ic) - len(oc))
    else:
        for i in range(len(ic)):
            if oc[i] != ic[i] + lat:
                bad_beat += 1
    if verbose:
        print("  O_tvalid 不符 %-4d  O_tlast 不符 %-4d  O_tuser 不符 %-4d  首错拍=%s"
              % (bad_v, bad_l, bad_u, first))
        print("  有效拍数：输入 %d / 输出 %d；第 i 个输出有效拍 = 第 i 个输入有效拍 + %d 拍，"
              "不符 %d  %s" % (len(ic), len(oc), lat, bad_beat,
                               "PASS" if (bad_v + bad_l + bad_u + bad_beat) == 0 else "FAIL"))
    return nass, nbad + bad_beat


def check_b(rows, mut=None, verbose=True):
    """B：6 档逐像素对金标准。"""
    mut = mut or {}
    oc = valid_cycles(rows, "Ov")
    omap = {r["cyc"]: r for r in rows}
    off = mut.get("beat_off", 0)
    off_modes = set(mut.get("beat_off_modes", ()))
    nass = nbad = 0
    per_mode = defaultdict(lambda: [0, 0])
    first = None
    for i, c in enumerate(oc):
        if i >= NBEAT:                     # 输出比激励多出来的拍（对齐错时会这样）
            nbad += 4
            nass += 4
            continue
        f, y, b = beat_pos(i)
        mode = MODE_SCHED[f]
        exp = expected_frame(f, mut)
        bb = b
        if off and mode in off_modes:
            bb = min(BPL - 1, max(0, b + off))
        v = _h(omap[c]["Odat"])
        per_mode[mode][1] += 4
        if v is None:
            nbad += 4
            per_mode[mode][0] += 4
            continue
        for k in range(4):
            x = 4 * bb + k
            got = pix_at(v, k)
            want = tuple(int(t) for t in exp[y, x])
            nass += 1
            if got != want:
                nbad += 1
                per_mode[mode][0] += 1
                if first is None:
                    first = (i, c, f, y, x, got, want, MODE_NAMES[mode])
    if verbose:
        for m in sorted(per_mode):
            bad, tot = per_mode[m]
            print("  %-9s 比较 %5d 像素，不符 %-5d  %s"
                  % (MODE_NAMES[m], tot, bad, "PASS" if bad == 0 else "FAIL"))
        print("  首错：%s" % (first,))
    return nass, nbad


def masked_mask(mut=None):
    """期望的掩蔽像素集：y<2 或 拍号(x//4)==0（每行第 0 拍 = 列 0..3）。"""
    mut = mut or {}
    extra = bool(mut.get("c_mask_extra_beat"))
    y = np.arange(H)[:, None]
    x = np.arange(W)[None, :]
    m = (y < 2) | ((x // 4) == 0)
    if extra:
        m = m | ((x < 8))
    return m


def check_c(rows, mut=None, verbose=True):
    """C：掩蔽区必须输出原图（不是黑屏、不是算法结果）。"""
    mut = mut or {}
    skip = set(mut.get("skip_mask_modes", ()))
    oc = valid_cycles(rows, "Ov")
    omap = {r["cyc"]: r for r in rows}
    m = masked_mask(mut)
    nass = nbad = 0
    per_mode = defaultdict(lambda: [0, 0])
    first = None
    for i, c in enumerate(oc):
        if i >= NBEAT:
            nass += 4
            nbad += 4
            continue
        f, y, b = beat_pos(i)
        mode = MODE_SCHED[f]
        v = _h(omap[c]["Odat"])
        for k in range(4):
            x = 4 * b + k
            if not m[y, x]:
                continue
            if mut.get("mask_black"):
                want = (0, 0, 0)
            elif mode in skip:
                g = int(A.gray_bt601(IMAGES[f])[y, x])
                want = (g, g, g) if mode == A.MODE_GRAY else tuple(int(t) for t in IMAGES[f][y, x])
            else:
                want = tuple(int(t) for t in IMAGES[f][y, x])
            nass += 1
            per_mode[mode][1] += 1
            if v is None:
                nbad += 1
                per_mode[mode][0] += 1
                continue
            got = pix_at(v, k)
            if got != want:
                nbad += 1
                per_mode[mode][0] += 1
                if first is None:
                    first = (i, f, y, x, got, want, MODE_NAMES[mode])
    if verbose:
        for k in sorted(per_mode):
            bad, tot = per_mode[k]
            print("  %-9s 掩蔽 %4d 像素，不符 %-4d  %s"
                  % (MODE_NAMES[k], tot, bad, "PASS" if bad == 0 else "FAIL"))
        print("  掩蔽像素合计 %d（%d 帧 x %d 像素）  首错：%s"
              % (nass, FRAMES, nass // FRAMES, first))
    return nass, nbad


def check_d(rows, mut=None, verbose=True):
    """D：整帧不换档 + 换档落在输出帧边界。"""
    mut = mut or {}
    early = bool(mut.get("d_early"))
    moff = mut.get("mode_off", 0)
    oc = valid_cycles(rows, "Ov")
    omap = {r["cyc"]: r for r in rows}
    nass = nbad = 0
    first = None
    per_frame = defaultdict(set)
    for i, c in enumerate(oc):
        if i >= NBEAT:
            nass += 1
            nbad += 1
            continue
        f, y, b = beat_pos(i)
        if early:
            f = min(FRAMES - 1, (i + 4) // BPF)
        want = (MODE_SCHED[f] + moff) % 6
        got = omap[c]["Omode"]
        nass += 1
        per_frame[i // BPF].add(got)
        if got != want:
            nbad += 1
            if first is None:
                first = (i, c, i // BPF, got, want)
    nass += FRAMES
    nonconst = [f for f, s in per_frame.items() if len(s) != 1]
    if nonconst:
        nbad += len(nonconst)
    if verbose:
        print("  逐拍 O_mode 与期望档位不符 %d 拍 / %d 拍  首错=%s  %s"
              % (nbad, nass, first, "PASS" if nbad == 0 else "FAIL"))
        print("  各帧 O_mode 取值：%s"
              % "  ".join("f%d=%s" % (f, sorted(per_frame[f])) for f in sorted(per_frame)))
        print("  整帧之内换过档的帧：%s  %s"
              % (nonconst if nonconst else "无", "PASS" if not nonconst else "FAIL"))
    return nass, nbad


def build_out_frame(rows, f):
    """把第 f 帧的输出拍写回 (H,W,3) int32 帧；未写 = -1。"""
    fr = np.full((H, W, 3), -1, dtype=np.int32)
    oc = valid_cycles(rows, "Ov")
    omap = {r["cyc"]: r for r in rows}
    for i, c in enumerate(oc):
        ff, y, b = beat_pos(i)
        if ff != f or ff >= FRAMES:
            continue
        v = _h(omap[c]["Odat"])
        if v is None:
            continue
        for k in range(4):
            p = (v >> (24 * (3 - k))) & 0xFFFFFF
            fr[y, 4 * b + k] = ((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF)
    return fr


def check_e(rows, mut=None, verbose=True):
    """E：M3 的 src 到底来自哪一行 —— 反解 + 4 候选对照。"""
    mut = mut or {}
    F = 3                                       # 第 3 帧 = M3（MODE_SCHED[3] == 3）
    assert MODE_SCHED[F] == A.MODE_EDGE, "第 3 帧不是 M3，判据 E 的前提被破坏"
    img = IMAGES[F]
    valid = A.window_valid_mask(H, W)
    fr = build_out_frame(rows, F)
    nass = nbad = 0

    # ---- E1：反解（R 通道 = 行号编码 8+8y，提亮 +128 不饱和，故可反解） ----
    hist = defaultdict(lambda: defaultdict(int))
    amb = 0
    first = None
    for y in range(H):
        for x in range(W):
            if not valid[y, x]:
                continue
            px = tuple(int(t) for t in fr[y, x])
            cands = []
            for r in range(H):
                c = tuple(int(t) for t in img[r, x])
                ck = tuple(int(min(v + EDGE_K, 255)) for v in c)
                if px == c or px == ck:
                    cands.append(r)
            nass += 1
            if len(cands) != 1:
                amb += 1
                nbad += 1
                if first is None:
                    first = (y, x, px, cands)
                continue
            dec = cands[0]
            hist[y][dec] += 1
            want = y + int(mut.get("e_dy", -1))
            if dec != want:
                nbad += 1
                if first is None:
                    first = (y, x, px, cands)
    if verbose:
        print("  反解表（行 -> 解出的 src 行:像素数）：")
        for y in range(H):
            if not hist[y]:
                continue
            s = "  ".join("row%d:%d" % (r, n) for r, n in sorted(hist[y].items()))
            print("    输出行 y=%d -> %s" % (y, s))
        print("  反解 %d 个有效像素，多解/无解 %d，解出的行 != 期望行 %d  %s"
              % (nass, amb, nbad - amb, "PASS" if nbad == 0 else "FAIL"))
        print("  首错：%s" % (first,))

    # ---- E2：4 个候选逐像素对照 ----
    #   ⚠ 只有"正确候选"必须 0 不符；错候选**必须**大面积不符（否则说明这条测试
    #     在这个维度上没有鉴别力 —— 那才是失败）。
    src_valid = valid
    cands = {
        "彩色第 y-1 行（正确）": {"src_dy": -1},
        "彩色第 y 行（少延迟一行）": {"src_dy": 0},
        "彩色第 y-2 行（多延迟一行）": {"src_dy": -2},
        "灰度中心行（规格记的坑）": {"src_gray": True},
    }
    for name, mm in cands.items():
        exp = variant_out(img, A.MODE_EDGE, mm)
        bad = int((fr[src_valid] != exp[src_valid]).any(axis=1).sum())
        is_ref = (not mm.get("src_gray")) and mm.get("src_dy", -1) == -1
        nass += int(src_valid.sum())
        if is_ref:
            nbad += bad
        elif bad == 0:
            nbad += 1
        if verbose:
            print("  候选 [%s]：不符 %3d / %d 像素  %s"
                  % (name, bad, int(src_valid.sum()),
                     "匹配（正确候选）" if is_ref else ("不匹配（应当如此）" if bad else "!! 无鉴别力 !!")))
    return nass, nbad


def check_xz(rows, verbose=True):
    """F：有效拍输出不允许 X/Z。"""
    nass = nbad = 0
    for r in rows:
        if r["Iv"] == 0:
            continue
        nass += 1
        if has_xz(r["Odat"]):
            nbad += 1
    if verbose:
        print("  有效拍输出出现 X/Z 的次数 = %d / %d  %s"
              % (nbad, nass, "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


def check_bbox(rows, verbose=True):
    """G（附加）：M5 的 bbox 统计 == 金标准（上一帧的 bbox 锁存）。"""
    nass = nbad = 0
    oc = valid_cycles(rows, "Ov")
    omap = {r["cyc"]: r for r in rows}
    for f in range(1, FRAMES):
        i = f * BPF + BPL                       # 帧中段采样，避开锁存沿
        r = omap[oc[i]]
        b = BBOXES[f - 1]                       # alg_ref 的 bbox = (x0, y0, x1, y1)
        exp = (b[0], b[2], b[1], b[3])          # RTL 端口顺序 = (x0, x1, y0, y1)
        got = (r["bx0"], r["bx1"], r["by0"], r["by1"])
        nass += 1
        if got != exp or r["bbv"] != 1:
            nbad += 1
            print("    帧 %d：O_bbox=%s（期望 %s）valid=%d  <- FAIL" % (f, got, exp, r["bbv"]))
    if verbose:
        print("  O_bbox_* 与金标准（上一帧 bbox）比对 %d 帧，不符 %d  %s"
              % (nass, nbad, "PASS" if nbad == 0 else "FAIL"))
        print("  逐帧金标准 bbox = %s" % (BBOXES,))
    return nass, nbad


def check_blanking(rows, verbose=True):
    """I：激励工况 —— 每行行末必须有一段 tvalid=0 的行消隐（真实链路工况）。

    判据（只读 dump 的 I_* 三列，不读 RTL）：
      · 行内相邻有效拍必须背靠背（间隔 1 拍）；
      · 行末有效拍到下一行首个有效拍之间必须是 BLANK_LEN 个 tvalid=0 拍（间隔 1+20）；
      · 最后一个有效拍之后必须还有 >= BLANK_LEN 拍 tvalid=0（收尾消隐）。
    为什么：真实链路（zhenghe.v:137-146 的 rd_valid / x_cnt）每行都有一段 valid=0，
    这一段经 data128_96 / awb 纯寄存器延迟到达 alg_top 输入。用 +noblank 跑出来的
    "帧间无气泡"激励在真实系统里不存在 —— 金标准在这种激励上通过不算验过。
    """
    ic = [r for r in rows if r["Iv"] == 1]
    nass = nbad = 0
    first = None
    for i in range(len(ic) - 1):
        b = i % BPL
        nass += 1
        gap = ic[i + 1]["cyc"] - ic[i]["cyc"]
        if b == BPL - 1:
            if gap != 1 + BLANK_LEN:
                nbad += 1
                if first is None:
                    first = ("行末消隐", i, ic[i]["cyc"], gap, 1 + BLANK_LEN)
        elif gap != 1:
            nbad += 1
            if first is None:
                first = ("行内背靠背", i, ic[i]["cyc"], gap, 1)
    nass += 1
    tail = rows[-1]["cyc"] - ic[-1]["cyc"]
    if tail < BLANK_LEN:
        nbad += 1
        if first is None:
            first = ("收尾消隐", len(ic) - 1, ic[-1]["cyc"], tail, BLANK_LEN)
    nass += 1
    n_line_end = sum(1 for i in range(len(ic)) if (i % BPL) == BPL - 1)
    if n_line_end != FRAMES * H:
        nbad += 1
        if first is None:
            first = ("行末拍数", n_line_end, "-", n_line_end, FRAMES * H)
    if verbose:
        print("  有效拍数 %d；行末拍 %d（期望 %d = %d 帧 x %d 行）；"
              "行末 tvalid=0 长度 %d 拍；末拍之后还有 %d 拍"
              % (len(ic), n_line_end, FRAMES * H, FRAMES, H, BLANK_LEN, tail))
        print("  行消隐（真实链路工况）自检 %d 条，不符 %d  首错=%s  %s"
              % (nass, nbad, first, "PASS" if nbad == 0 else "FAIL"))
        if nbad:
            print("    ⚠ 激励里没有行消隐 = 你验的是真实系统里不存在的工况；"
                  "默认跑法不该加 +noblank")
    return nass, nbad


def check_stim(rows, verbose=True):
    """H：激励自检 —— dump 里的输入与 gen_stim_top.py 必须逐拍一致。"""
    hexs = [ln.strip() for ln in
            open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "stim_top.hex"), encoding="ascii") if ln.strip()]
    beats = stim_beats()
    nass = nbad = 0
    i = 0
    first = None
    for r in rows:
        if r["Iv"] == 0:
            nass += 1
            if r["drv"] != 0:
                nbad += 1
            continue
        nass += 3
        if i >= NBEAT:
            nbad += 1
            continue
        y, b = (i % BPF) // BPL, i % BPL
        want_d = hexs[i].upper()
        want_l = 1 if b == BPL - 1 else 0
        want_u = 1 if (i % BPF) == 0 else 0
        if r["Idat"].upper() != want_d or r["Il"] != want_l or r["Iu"] != want_u:
            nbad += 1
            if first is None:
                first = (i, r["Idat"], want_d, r["Il"], want_l, r["Iu"], want_u)
        i += 1
    nass += 1
    if i != NBEAT:
        nbad += 1
    if verbose:
        print("  dump 输入 %d 拍 vs stim_top.hex（%d 拍），不符 %d  首错=%s  %s"
              % (i, NBEAT, nbad, first, "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


# ===========================================================================
# 4. 改期望值的变异清单（自证用）
# ===========================================================================
MUTATIONS = [
    ("A 延迟按 4 拍比（真实 5 拍）",            {"lat": 4}, "A"),
    ("A 延迟按 6 拍比",                        {"lat": 6}, "A"),
    ("B M1 期望帧整体错一拍",                   {"beat_off": 1, "beat_off_modes": (1,)}, "B"),
    ("B M5 期望帧整体错一拍",                   {"beat_off": 1, "beat_off_modes": (5,)}, "B"),
    ("B M2/M3/M4 期望帧整体错一拍",             {"beat_off": 1, "beat_off_modes": (2, 3, 4)}, "B"),
    ("B M3 的 src 期望取第 y 行",               {"src_dy": 0}, "B"),
    ("B M3 的 src 期望取窗口中心灰度",           {"src_gray": True}, "B"),
    ("B M5 期望画本帧 bbox（而不是上一帧）",      {"bbox_current": True}, "B"),
    ("B 期望去掉窗口档位的一行输出位移",          {"no_row_shift": True}, "B"),
    ("B 期望掩蔽按逐像素 x%4==0（不是每拍）",     {"ppb": 1}, "B"),
    ("C 期望掩蔽期输出黑屏（例程口径）",          {"mask_black": True}, "C"),
    ("C 期望 M1 不套掩蔽（掩蔽期输出灰度）",      {"skip_mask_modes": (1,)}, "C"),
    ("C 期望掩蔽区多盖一拍（x<8 也算掩蔽）",      {"c_mask_extra_beat": True}, "C"),
    ("D 期望档位按输入 tuser 锁存（早 4 拍换）",   {"d_early": True}, "D"),
    ("D 期望档位表整体错一档",                   {"mode_off": 1}, "D"),
    ("E 期望 src 来自第 y 行",                  {"e_dy": 0}, "E"),
    ("E 期望 src 来自第 y-2 行",                {"e_dy": -2}, "E"),
]

_CHECKERS = {"A": check_a, "B": check_b, "C": check_c, "D": check_d, "E": check_e}


# ===========================================================================
# 5. 主流程
# ===========================================================================
def run_all(rows, mut=None, verbose=True):
    """跑全部判据，返回 (counts: {名称: (断言数, 不符数)}, fails: list)。"""
    mut = mut or {}
    counts, fails = {}, []

    nass, nbad = check_a(rows, mut, verbose)
    counts["A 延迟5拍"] = (nass, nbad)
    if nbad:
        fails.append("A：控制信号/有效拍不是输入延迟 5 拍（%d 处）" % nbad)

    nass, nbad = check_b(rows, mut, verbose)
    counts["B 六档对金标准"] = (nass, nbad)
    if nbad:
        fails.append("B：%d 个像素不符金标准" % nbad)

    nass, nbad = check_c(rows, mut, verbose)
    counts["C 掩蔽区=原图"] = (nass, nbad)
    if nbad:
        fails.append("C：掩蔽区 %d 个像素不是原图" % nbad)

    nass, nbad = check_d(rows, mut, verbose)
    counts["D 档位锁存"] = (nass, nbad)
    if nbad:
        fails.append("D：%d 拍档位不符/帧内换档" % nbad)

    nass, nbad = check_e(rows, mut, verbose)
    counts["E M3的src行"] = (nass, nbad)
    if nbad:
        fails.append("E：M3 的 src 行反解/候选对照 %d 处不符" % nbad)

    if not mut:
        nass, nbad = check_xz(rows, verbose)
        counts["F X/Z泄漏"] = (nass, nbad)
        if nbad:
            fails.append("F：输出 X/Z 泄漏 %d 次" % nbad)

        nass, nbad = check_bbox(rows, verbose)
        counts["G M5 bbox"] = (nass, nbad)
        if nbad:
            fails.append("G：bbox 统计 %d 帧不符" % nbad)

        nass, nbad = check_stim(rows, verbose)
        counts["H 激励自检"] = (nass, nbad)
        if nbad:
            fails.append("H：dump 输入与激励文件不符 %d 处" % nbad)

        nass, nbad = check_blanking(rows, verbose)
        counts["I 行消隐工况"] = (nass, nbad)
        if nbad:
            fails.append("I：激励不是真实链路工况（行消隐自检不符 %d 处）" % nbad)
    return counts, fails


def self_consistency():
    """自洽性：variant_out 在默认参数下必须与金标准 AlgPipeline 逐位相同。"""
    bad = 0
    for f in range(FRAMES):
        mode = MODE_SCHED[f]
        img = IMAGES[f]
        bp = BBOXES[f - 1] if f >= 1 else None
        ref = _pipe(mode, None).process(img, bbox_prev=bp).image
        var = variant_out(img, mode, {}, bbox_prev=bp)
        if not np.array_equal(ref, var):
            bad += int((ref != var).any(axis=2).sum())
    return bad


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows = parse(os.path.join(here, "dump_top.txt"))
    selftest = "--selftest" in sys.argv
    print("解析 dump_top.txt：%d 拍（激励 %d 拍 + 复位/收尾）" % (len(rows), NBEAT))

    sc = self_consistency()
    print("自洽性：variant_out(默认参数) vs 金标准 AlgPipeline —— 不符像素 %d  %s"
          % (sc, "PASS" if sc == 0 else "FAIL"))
    if sc:
        print("  ⚠ 变异路径自己就不等于金标准，先修这个再看别的")
        return 2

    if not selftest:
        print("\n=== A. 全链延迟 = 5 拍（控制逐拍 + 有效拍落点）===")
        print("\n=== B. 6 档逐像素对金标准 AlgPipeline ===")
        print("\n=== C. 掩蔽：前 2 行 + 每行第 0 拍 = 原图 ===")
        print("\n=== D. 档位锁存：整帧不换档 / 换档在帧边界 ===")
        print("\n=== E. M3 的 src 行反解（第 3 帧）===")
        counts, fails = run_all(rows, None, verbose=True)
        print("\n=== F/G/H/I. X/Z、M5 bbox、激励自检、行消隐工况 ===")
        tot = sum(a for a, _b in counts.values())
        print("\n" + "=" * 72)
        for k, (n, b) in counts.items():
            print("  %-16s 断言 %6d  不符 %-5d  %s" % (k, n, b, "PASS" if b == 0 else "FAIL"))
        print("  合计断言 %d" % tot)
        print("=" * 72)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails:
                print("   " + s)
            return 1
        print("结论：PASS —— A/B/C/D/E 五项全过，合计 %d 条断言" % tot)
        return 0

    # ---------------- 改期望值变异自证 ----------------
    print("\n" + "=" * 72)
    print("变异自证（改期望值）：故意用错误期望重跑，每条都必须被对应判据抓住")
    print("=" * 72)
    # 防空转前置：基线必须是绿的。否则"任何变异都被抓住"必然成立 —— 那是假绿
    # （2026-09-14 实测抓到过一次：基线 FAIL 时 17/17 全绿毫无意义）。
    _c, base_fails = run_all(rows, None, verbose=False)
    _tot = sum(a for a, _b in _c.values())
    print("  基线（未变异）  断言 %d 条，报错 %d 条  -> %s"
          % (_tot, len(base_fails), "PASS" if not base_fails else "FAIL"))
    if base_fails:
        print("  !! 基线就是红的：变异自证在这种情况下没有意义（假绿来源）")
        for s in base_fails[:5]:
            print("     " + s)
        print("=" * 72)
        return 1
    caught = 0
    for name, mut, who in MUTATIONS:
        red = []
        for key, fn in _CHECKERS.items():
            f_, n_ = fn(rows, mut, verbose=False)
            if n_:
                red.append("%s(%d)" % (key, n_))
        ok = len(red) > 0
        caught += 1 if ok else 0
        print("  %-38s 期望抓=%s  实际报错: %-28s %s"
              % (name, who, ",".join(red) if red else "无", "抓住" if ok else "!! 漏掉 !!"))
    print("-" * 72)
    print("  改期望值鉴别力：%d/%d  -> %s"
          % (caught, len(MUTATIONS), "PASS" if caught == len(MUTATIONS) else "FAIL"))
    print("=" * 72)
    return 0 if caught == len(MUTATIONS) else 1


if __name__ == "__main__":
    sys.exit(main())
