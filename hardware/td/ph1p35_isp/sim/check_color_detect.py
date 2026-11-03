#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_color_detect.py —— 校验 ModelSim 真实仿真出来的 dump_cd.txt（alg_color_detect_96）

期望值**全部来自金标准 alg_ref.py**（本脚本 import 它，直接用它的
target_hit / hit_vote / bbox_stats / draw_bbox / window_valid_mask），
不重写一遍算法 —— 重写就等于"自己给自己出题"，抓不住"口径理解错"这一类错。

五项检查：
  A. 激励自检：dump 的 I_* 与激励文件/驱动规则逐拍一致
  B. 图像：O_tdata 逐拍 = 期望帧（延迟 2 拍）的对应 beat
  C. 控制：O_tvalid/O_tlast/O_tuser = 输入延迟 2 拍
  D. 统计：O_bbox_*/O_pix_count/O_bbox_valid 逐拍等于"上一帧统计"（帧首那一拍还是上上帧）
  E. X 传播：四路输出 + 统计端口不允许出现 x/z

用法：
    python check_color_detect.py              # 正常校验
    python check_color_detect.py --selftest   # 变异自证：故意写错期望，必须被抓出来
"""
from __future__ import annotations
import sys, os

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, r"C:\Users\29072\PycharmProjects\PythonProject8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import alg_ref                                                  # noqa: E402
import gen_stim_color_detect as gen                             # noqa: E402

W, H = gen.W, gen.H
BPL = gen.BPL
FRAMES = gen.FRAMES
NBEAT = gen.NBEAT
BPF = BPL * H
START_CYC = 6
LAT = 2                    # 实测钉死：2 拍时与 alg_ref 逐 beat 一致；1 拍/3 拍都不符（见 RTL 文件头 §三）
TGT = gen.TGT
TOL = gen.TOL
EMPTY = dict(x0=2047, x1=0, y0=2047, y1=0, count=0, valid=0)

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "dump_cd.txt")
FRAMES_IMG = gen.build_frames()


# ---------------------------------------------------------------------------
# 期望模型（参数化，便于变异自证）
# ---------------------------------------------------------------------------
def compute_stats(f, tol=TOL, use_vote=True, use_mask=True):
    img = FRAMES_IMG[f]
    hit = alg_ref.target_hit(img,
                             max(0, TGT[0] - tol), min(255, TGT[0] + tol),
                             max(0, TGT[1] - tol), min(255, TGT[1] + tol),
                             max(0, TGT[2] - tol), min(255, TGT[2] + tol))
    if use_vote:
        hit = alg_ref.hit_vote(hit)
    if use_mask:
        hit = hit & alg_ref.window_valid_mask(H, W, 4, 2)
    return alg_ref.bbox_stats(hit)


def build_expectation(tol=TOL, use_vote=True, use_mask=True, draw_src="prev"):
    stats = [compute_stats(f, tol, use_vote, use_mask) for f in range(FRAMES)]
    imgs = []
    for f in range(FRAMES):
        if draw_src == "prev":
            bbox = stats[f - 1]["bbox"] if f >= 1 else None
        elif draw_src == "cur":
            bbox = stats[f]["bbox"]
        elif draw_src == "none":
            bbox = None
        imgs.append(alg_ref.draw_bbox(FRAMES_IMG[f], bbox))
    return stats, imgs


def beat_hex_map(imgs):
    """(f, y, xg) -> 24 位十六进制字符串。"""
    out = {}
    for f, img in enumerate(imgs):
        beats = alg_ref.frame_to_beats(img)
        hexs = alg_ref.beats_to_hex(beats.reshape(-1, 2))
        for y in range(H):
            for xg in range(BPL):
                out[(f, y, xg)] = hexs[y * BPL + xg]
    return out


def stat_state(stats, f):
    if f < 0:
        return EMPTY
    s = stats[f]
    if s["bbox"] is None:
        return EMPTY
    return dict(x0=s["min_x"], x1=s["max_x"], y0=s["min_y"], y1=s["max_y"],
                count=s["count"], valid=1)


# ---------------------------------------------------------------------------
def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 15:
                continue
            rows.append(dict(
                cyc=int(f[0]),
                Iv=f[1], Il=f[2], Iu=f[3], Id=f[4],
                Ov=f[5], Ol=f[6], Ou=f[7], Od=f[8],
                Ox0=f[9], Ox1=f[10], Oy0=f[11], Oy1=f[12], Ocnt=f[13], Ovl=f[14]))
    return rows


def has_xz(s):
    return any(c in "xXzZ" for c in s)


def hx(s):
    return None if has_xz(s) else int(s, 16)


def norm24(s):
    return s.lower().rjust(24, "0")


def model_in(i):
    """第 i 个 beat 的驱动（tvalid/tlast/tuser 由 tb 推导）。"""
    if 0 <= i < NBEAT:
        return dict(v=1, l=1 if (i % BPL) == BPL - 1 else 0,
                    u=1 if (i % BPF) == 0 else 0)
    return dict(v=0, l=0, u=0)


# ---------------------------------------------------------------------------
# A. 激励自检
# ---------------------------------------------------------------------------
def check_stim(rows, verbose=True):
    fails = []
    stim = []
    with open(os.path.join(HERE, "stim_cd.hex"), "r", encoding="ascii") as fh:
        for ln in fh:
            if ln.strip():
                stim.append(ln.strip().lower().rjust(24, "0"))
    assert len(stim) == NBEAT, len(stim)
    for r in rows:
        c = r["cyc"]
        i = c - START_CYC
        if i < 0 or i >= NBEAT:
            e = dict(v=0, l=0, u=0)
            want_d = None
        else:
            e = model_in(i)
            want_d = stim[i]
        got = (1 if r["Iv"] == "1" else 0, 1 if r["Il"] == "1" else 0,
               1 if r["Iu"] == "1" else 0)
        if got != (e["v"], e["l"], e["u"]):
            fails.append("拍%d 控制线不符：期望 %s 实得 %s" % (c, (e["v"], e["l"], e["u"]), got))
        elif want_d is not None and hx(r["Id"]) != int(want_d, 16):
            fails.append("拍%d I_tdata 与 stim_cd.hex 不符" % c)
    if verbose:
        print("\n=== A. 激励自检（dump 的 I_* vs stim_cd.hex + 驱动规则）===")
        print("  比较 %d 拍，不符 %d 拍   -> %s"
              % (len(rows), len(fails), "FAIL" if fails else "PASS"))
    return fails


# ---------------------------------------------------------------------------
# B/C. 图像与控制（延迟 lat 拍）
# ---------------------------------------------------------------------------
def check_image(rows, stats, imgs, lat=LAT, verbose=True):
    bhex = beat_hex_map(imgs)
    by = {r["cyc"]: r for r in rows}
    fails = []
    ncmp = 0
    for r in rows:
        c = r["cyc"]
        src = by.get(c - lat)
        if src is None:
            continue
        i_in = (c - lat) - START_CYC
        if i_in < 0 or i_in >= NBEAT:
            want_v, want_d = 0, "%024x" % 0
        else:
            want_v = 1
            f = i_in // BPF
            i = i_in % BPF
            want_d = bhex[(f, i // BPL, i % BPL)]
        ncmp += 1
        if r["Ov"] != str(want_v):
            fails.append("拍%d O_tvalid 期望 %d 实得 %s" % (c, want_v, r["Ov"]))
        if has_xz(r["Od"]):
            fails.append("拍%d O_tdata 含 X/Z" % c)
        elif norm24(r["Od"]) != norm24(want_d):
            fails.append("拍%d O_tdata 期望 %s 实得 %s" % (c, norm24(want_d), norm24(r["Od"])))
        if i_in >= 0:
            e = model_in(i_in)
            if r["Ol"] != str(e["l"]):
                fails.append("拍%d O_tlast 期望 %d 实得 %s" % (c, e["l"], r["Ol"]))
            if r["Ou"] != str(e["u"]):
                fails.append("拍%d O_tuser 期望 %d 实得 %s" % (c, e["u"], r["Ou"]))
    if verbose:
        print("\n=== B/C. 图像与控制（延迟 %d 拍）===" % lat)
        print("  比较 %d 拍" % ncmp)
        if fails:
            print("  不符 %d 条（首 6 条）：" % len(fails))
            for s in fails[:6]:
                print("    " + s)
            print("  -> FAIL")
        else:
            print("  O_tdata（金标准画框结果逐 beat）/ O_tvalid / O_tlast / O_tuser 全相符 -> PASS")
    return fails


# ---------------------------------------------------------------------------
# D. 统计端口
# ---------------------------------------------------------------------------
def visible_stats(g, lat=LAT, latch_shift=0):
    """第 g 个输出 beat 上，O_bbox_* 反映的是哪一帧的统计（-1 表示还是空）。"""
    off = 2 - lat + latch_shift
    F = -1
    for f in range(FRAMES + 1):
        if f * BPF + off <= g:
            F = f
    return stat_state(stats_global, F - 1)


stats_global = None


def check_stats(rows, stats, lat_latch=0, verbose=True):
    """O_bbox_*/O_pix_count/O_bbox_valid 的逐拍期望（按**全局 beat 号**推）。

    锁存事件：第 f 帧的帧首拍（tuser）上总线时，把第 f-1 帧的统计锁进 O_bbox_*。
    该事件发生在"输出第 f*BPF + 1 - LAT 个 beat"那一拍，下一个输出 beat 起生效，
    即第 f-1 帧统计对**输出 beat g >= f*BPF + (2 - LAT)** 可见。
      · LAT=2 ⇒ 正好从第 f 帧的第 0 个 beat 可见 —— 与 alg_ref 的 bbox_prev 语义完全重合
        （整帧画上一帧的框），**不存在"帧首那一拍还是旧统计"的窗口**。
      · LAT=1 ⇒ 从第 f 帧的第 1 个 beat 可见，第 0 个 beat 还停在上上帧。
    突变 lat_latch=-1 表示"锁存早一拍"。
    """
    global stats_global
    stats_global = stats
    by = {r["cyc"]: r for r in rows}
    fails = []
    ncmp = 0
    for r in rows:
        c = r["cyc"]
        src = by.get(c - LAT)
        if src is None:
            continue
        i_in = (c - LAT) - START_CYC
        if i_in < 0 or i_in >= NBEAT:
            continue
        s = visible_stats(i_in, LAT, lat_latch)
        ncmp += 1
        got = (hx(r["Ox0"]), hx(r["Ox1"]), hx(r["Oy0"]), hx(r["Oy1"]),
               int(r["Ocnt"]) if not has_xz(r["Ocnt"]) else None,
               1 if r["Ovl"] == "1" else 0)
        want = (s["x0"], s["x1"], s["y0"], s["y1"], s["count"], s["valid"])
        if got != want:
            fails.append("拍%d(输出beat %d) 统计期望 x0/x1/y0/y1/cnt/valid=%s 实得 %s"
                         % (c, i_in, want, got))
    if verbose:
        print("\n=== D. 统计端口（O_bbox_* / O_pix_count / O_bbox_valid）===")
        print("  比较 %d 拍" % ncmp)
        print("  逐帧金标准统计：")
        for f, s in enumerate(stats):
            print("    F%d bbox=%s count=%d" % (f, s["bbox"], s["count"]))
        if fails:
            print("  不符 %d 条（首 6 条）：" % len(fails))
            for s in fails[:6]:
                print("    " + s)
            print("  -> FAIL")
        else:
            print("  全部相符   -> PASS")
    return fails


def check_x(rows, verbose=True):
    bad = [r["cyc"] for r in rows
           if has_xz(r["Od"]) or has_xz(r["Ox0"]) or has_xz(r["Ocnt"])]
    fails = []
    if bad:
        fails.append("输出含 X/Z：%d 拍（首 %s）" % (len(bad), bad[:5]))
    if verbose:
        print("\n=== E. X 传播 ===")
        print("  输出含 X/Z 的拍数 %d   -> %s" % (len(bad), "FAIL" if bad else "PASS"))
    return fails


# ---------------------------------------------------------------------------
def main():
    rows = parse(DUMP)
    selftest = "--selftest" in sys.argv
    print("解析 dump_cd.txt：%d 拍（%dx%d，%d 帧，%d 拍/帧）"
          % (len(rows), W, H, FRAMES, BPF))

    if not selftest:
        stats, imgs = build_expectation()
        fails = []
        fails += check_stim(rows)
        fails += check_image(rows, stats, imgs)
        fails += check_stats(rows, stats)
        fails += check_x(rows)
        print("\n" + "=" * 66)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails[:20]:
                print("   " + s)
            if len(fails) > 20:
                print("   ...（其余 %d 条省略）" % (len(fails) - 20))
        else:
            print("结论：PASS —— 激励 / 图像(金标准画框) / 控制延迟 / 统计 / X 全通过")
        print("=" * 66)
        return 0 if not fails else 1

    # ---------------- 变异自证 ----------------
    print("\n" + "=" * 66)
    print("变异自证：故意用【错误期望】重跑，每一条都必须被抓出来")
    print("（抓不住的条目 = 测试在这个维度上没有鉴别力 = 等于没测）")
    print("=" * 66)

    def run(name, **kw):
        n = 0
        if "lat" in kw:
            stats, imgs = build_expectation()
            n = len(check_image(rows, stats, imgs, lat=kw["lat"], verbose=False))
        elif "lat_latch" in kw:
            stats, _ = build_expectation()
            n = len(check_stats(rows, stats, lat_latch=kw["lat_latch"], verbose=False))
        else:
            stats, imgs = build_expectation(**kw)
            n = len(check_image(rows, stats, imgs, verbose=False))
            n += len(check_stats(rows, stats, verbose=False))
        mark = "抓住" if n else "!! 漏掉 !!"
        print("  %-34s -> 报错 %5d 条   %s" % (name, n, mark))
        return 1 if n else 0

    caught = 0
    caught += run("容差判据改成 < （TOL-1）", tol=TOL - 1)
    caught += run("不做行内表决 hit_vote", use_vote=False)
    caught += run("不做有效掩蔽（& valid）", use_mask=False)
    caught += run("画框用本帧 bbox（应为上一帧）", draw_src="cur")
    caught += run("干脆不画框", draw_src="none")
    caught += run("输出延迟当成 1 拍", lat=1)
    caught += run("输出延迟当成 3 拍", lat=3)
    caught += run("bbox 锁存早一拍", lat_latch=-1)
    total = 8
    print("-" * 66)
    print("  鉴别力：%d/%d 个变异被抓住  -> %s"
          % (caught, total, "PASS" if caught == total else "FAIL"))
    print("=" * 66)
    return 0 if caught == total else 1


if __name__ == "__main__":
    sys.exit(main())
