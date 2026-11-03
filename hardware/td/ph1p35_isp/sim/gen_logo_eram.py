#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_logo_eram.py —— 把官方 anlogic_logo_rom.v 编码成「一拍读 4 像素」的 ERAM 初值。

背景（G1 返工）：官方 ROM 是 6387 条 case 的**组合**译码器，实测单份
  #lut 3143 / #slice 2559（prj\\logo_ab\\logo_a_full160\\area.txt），一拍 4 像素要 4 份
  ⇒ 约 10236 slice，器件放不下（已用 13891 / 21216）。
改成 6400 字（160x160 按 4 像素/字打包）的 ERAM：6400x24 实测 #eram 8 / #lut 20
  （prj\\_eram_init_check\\logo_mem24.area）⇒ 面积问题解决。

本脚本做三件事：
  1. 解析官方 case 表 → 160x160 位图（未命中 = 透明）；
  2. 量化成 64 色（6 bit/像素，index 0 留给透明）——顺带算 16 色（4 bit）作对照，
     **按数据决定用哪个**，并输出量化误差（最大/平均每通道误差、误差 >16 的像素数）；
  3. 写 logo_64c.hex（6400 行 x 6 个十六进制字符）与调色板 case 片段（供 RTL 内联）。

⚠ 打包口径（RTL 注释 / hex 生成 / Python 参考模型三处必须一字不差）：
      word = idx0 | (idx1 << 6) | (idx2 << 12) | (idx3 << 18)
      idx0 = 该字**最左**像素（列 4*g+0），idx3 = 最右（列 4*g+3）
      地址 = y*40 + x_grp      （y = 0..159，x_grp = 0..39）
"""
from __future__ import annotations

import os
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
ROM = os.path.join(ROOT, "prj", "board", "lab_ex3_osd", "user_source",
                   "hdl_source", "anlogic_logo_rom.v")
OUT_DIR = os.path.join(ROOT, "sim")
HEX_NAME = "logo_64c.hex"

AN_W, AN_H, XG = 160, 160, 40


# ---------------------------------------------------------------- 解析官方素材
def parse_rom(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    vals = re.findall(r"15'd(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)\s*;", txt)
    assert vals, "官方 ROM 一条 case 项都没解析到"
    img = [[None] * AN_W for _ in range(AN_H)]
    for a, v in vals:
        a, v = int(a), int(v, 16)
        assert (v >> 24) & 1, "第 %d 条不是不透明项" % a
        y, x = divmod(a, AN_W)
        assert y < AN_H, "地址 %d 超出 160x160" % a
        img[y][x] = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    return img, len(vals)


# ---------------------------------------------------------------- 中位切分量化
def median_cut(colors, weights, nbox):
    """colors: [(r,g,b)]，weights: 对应像素数 → 返回 nbox 个调色板项（加权均值）"""
    boxes = [list(range(len(colors)))]
    while len(boxes) < nbox:
        best, best_score = None, -1
        for bi, b in enumerate(boxes):
            if len(b) < 2:
                continue
            n = sum(weights[i] for i in b)
            rng = [max(colors[i][c] for i in b) - min(colors[i][c] for i in b)
                   for c in range(3)]
            score = n * max(rng)
            if score > best_score:
                best, best_score = (bi, rng), score
        if best is None:                      # 没有可再切的箱
            break
        bi, rng = best
        ch = rng.index(max(rng))
        b = sorted(boxes[bi], key=lambda i: colors[i][ch])
        # 按**像素数**中位切，而不是按颜色数中位
        tot = sum(weights[i] for i in b)
        acc, cut = 0, 1
        for j in range(len(b) - 1):
            acc += weights[b[j]]
            if acc * 2 >= tot:
                cut = j + 1
                break
        boxes[bi:bi + 1] = [b[:cut], b[cut:]]
    pal = []
    for b in boxes:
        tw = sum(weights[i] for i in b)
        pal.append(tuple(int(round(sum(colors[i][c] * weights[i] for i in b) / tw))
                         for c in range(3)))
    return pal


def quantize(img, ncolor):
    """返回 (idx 图, 调色板, 误差统计)。idx 0 = 透明；调色板下标 1..ncolor-1"""
    cnt = Counter()
    for row in img:
        for p in row:
            if p is not None:
                cnt[p] += 1
    colors = sorted(cnt)
    weights = [cnt[c] for c in colors]
    pal = median_cut(colors, weights, ncolor - 1)
    # 最近色映射（对**颜色**做，不是对像素做，省时间且等价）
    c2i = {}
    for i, c in enumerate(colors):
        best, bd = 0, None
        for k, p in enumerate(pal):
            d = sum((c[j] - p[j]) ** 2 for j in range(3))
            if bd is None or d < bd:
                best, bd = k, d
        c2i[c] = best + 1                       # +1：0 留给透明
    idx = [[0] * AN_W for _ in range(AN_H)]
    for y in range(AN_H):
        for x in range(AN_W):
            if img[y][x] is not None:
                idx[y][x] = c2i[img[y][x]]
    # 误差统计（对每个**命中像素**）
    n = 0
    maxe = 0
    sume = 0
    gt16 = gt8 = 0
    for y in range(AN_H):
        for x in range(AN_W):
            o = img[y][x]
            if o is None:
                continue
            i = idx[y][x] - 1
            q = pal[i]
            e = [abs(o[c] - q[c]) for c in range(3)]
            n += 1
            maxe = max(maxe, max(e))
            sume += sum(e)
            if max(e) > 16:
                gt16 += 1
            if max(e) > 8:
                gt8 += 1
    st = dict(n=n, max=maxe, sum=sume, gt16=gt16, gt8=gt8,
              mean=sume / (3.0 * n), pal=[tuple(p) for p in pal])
    return idx, pal, st


def stats_line(name, st):
    return ("%-8s 颜色数=%-3d 命中像素=%d  每通道误差 max=%d  mean=%.2f  "
            "误差和=%d  >16 的像素=%d (%.2f%%)  >8 的像素=%d (%.2f%%)"
            % (name, len(st["pal"]), st["n"], st["max"], st["mean"], st["sum"],
               st["gt16"], 100.0 * st["gt16"] / st["n"],
               st["gt8"], 100.0 * st["gt8"] / st["n"]))


def main():
    img, nrom = parse_rom(ROM)
    hit = sum(1 for row in img for p in row if p is not None)
    print("官方素材：%d 条 case 项 / 命中像素 %d / 尺寸 %dx%d"
          % (nrom, hit, AN_W, AN_H))
    assert nrom == hit, "case 条数与命中像素数不符"

    idx64, pal64, st64 = quantize(img, 64)
    idx16, pal16, st16 = quantize(img, 16)
    print("量化对照（index 0 = 透明，可用颜色 = 颜色数-1）：")
    print("  " + stats_line("64色/6bpp", st64))
    print("  " + stats_line("16色/4bpp", st16))

    # ---- 选哪个：先看数据 ----
    # 64 色 = 6400x24 = 8 块 ERAM；16 色 = 6400x16 = 7 块 ERAM（省 1 块 / 108）。
    # 只有 64 色的误差已经好到"看不出来"才值得多花那 1 块 —— 反之亦然，看下面这行判定。
    use64 = st64["max"] <= 24 and st64["gt16"] <= 0.02 * st64["n"]
    print("判定：%s" % ("用 64 色（6bpp）：误差极小，多花 1 块 ERAM 换掉 1/16 的色阶损失不值当省"
                      if use64 else
                      "★ 64 色误差偏大，需要重新考虑（见报告）"))
    assert use64, "64 色的量化误差超出预期，停下报告"

    # ---- 写 hex ----
    hexp = os.path.join(OUT_DIR, HEX_NAME)
    lines = []
    zero_word = 0
    for y in range(AN_H):
        for g in range(XG):
            w = (idx64[y][4 * g] | (idx64[y][4 * g + 1] << 6) |
                 (idx64[y][4 * g + 2] << 12) | (idx64[y][4 * g + 3] << 18))
            if w == 0:
                zero_word += 1
            lines.append("%06x" % w)
    assert len(lines) == AN_H * XG == 6400
    open(hexp, "w", encoding="ascii", newline="\n").write("\n".join(lines) + "\n")
    print("hex：%s  %d 行（全透明字 %d 个）" % (hexp, len(lines), zero_word))

    # ---- 调色板 case 片段（RTL 内联用）----
    pal_lines = []
    for k, p in enumerate(pal64):
        pal_lines.append("        6'd%-2d: w_pal = 24'h%02X%02X%02X;   // #%02X%02X%02X"
                         % (k + 1, p[0], p[1], p[2], p[0], p[1], p[2]))
    open(os.path.join(OUT_DIR, "_g1_anlogo", "palette_case.txt"), "w",
         encoding="utf-8", newline="\n").write("\n".join(pal_lines) + "\n")
    print("调色板片段：sim\\_g1_anlogo\\palette_case.txt（%d 项 + index0 透明）"
          % len(pal64))

    # ---- 误差统计落盘（校验器要拿它做**独立**保真度断言的界）----
    stp = os.path.join(OUT_DIR, HEX_NAME.replace(".hex", ".stats.txt"))
    with open(stp, "w", encoding="ascii", newline="\n") as f:
        f.write("n %d\nmax %d\nsum %d\ngt16 %d\ngt8 %d\npal %d\n"
                % (st64["n"], st64["max"], st64["sum"], st64["gt16"], st64["gt8"],
                   len(st64["pal"])))
        for p in st64["pal"]:
            f.write("p %02X%02X%02X\n" % p)
    print("统计：%s" % stp)
    print("调色板（64 项，index0 = 透明占位）：")
    print("  " + " ".join("%02X%02X%02X" % p for p in st64["pal"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
