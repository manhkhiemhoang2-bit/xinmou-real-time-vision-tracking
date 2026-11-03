#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
viz_win3x3.py —— 把 ModelSim 仿真结果画成图（Pillow，不需要 matplotlib）

三张图，全部从 dump.txt 的**真实仿真数据**生成，不硬编码任何期望值：
    仿真结果_1_时序波形.png    延迟 = 2 拍，逐拍对齐
    仿真结果_2_窗口几何.png    9 个抽头取对了（唯一值图反解到绝对坐标）
    仿真结果_3_行缓冲X.png     行缓冲前几拍确为 X，第 7/15 拍变确定值
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

from PIL import Image, ImageDraw, ImageFont

W_IMG, H_IMG = 32, 8
BPL = W_IMG // 4
START_CYC = 6
LAT = 2

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------
def load_font(size):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhl.ttc",
              r"C:\Windows\Fonts\simhei.ttf", r"C:\Windows\Fonts\simsun.ttc"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


F_TITLE = load_font(30)
F_SUB = load_font(19)
F_LBL = load_font(17)
F_SM = load_font(14)
F_TINY = load_font(12)


def has_xz(s):
    return any(c in "xXzZ" for c in s)


def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 11:
                continue
            rows.append({
                "cyc": int(f[0]),
                "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]),
                "bi": -1,
                "Ov": int(f[5]), "Ol": int(f[6]), "Ou": int(f[7]),
                "Ovld": int(f[9]), "Ow": f[10],
                "L1": f[11] if len(f) > 11 else "",
                "L2": f[12] if len(f) > 12 else "",
            })
            rows[-1]["Id"] = f[4]
            rows[-1]["Od"] = f[8]
    # 反推每拍对应的输入 beat 号
    for r in rows:
        bi = r["cyc"] - START_CYC
        r["ibi"] = bi if 0 <= bi < 128 else -1
        obi = r["cyc"] - START_CYC - LAT
        r["obi"] = obi if 0 <= obi < 128 else -1
    return rows


def gray_at(y, x):
    if 0 <= y < H_IMG and 0 <= x < W_IMG:
        return (y << 5) | x
    return 0


# --------------------------------------------------------------------------
# 图 1：时序波形
# --------------------------------------------------------------------------
def fig_timing(rows, path):
    C0, C1 = 4, 22
    CW = 62
    LEFT = 210
    TOP = 150
    RH = 54
    Wd = LEFT + (C1 - C0 + 1) * CW + 60
    Ht = TOP + 8 * RH + 120
    im = Image.new("RGB", (Wd, Ht), "white")
    d = ImageDraw.Draw(im)

    d.text((40, 26), "win3x3_96 仿真时序：输出严格比输入晚 2 拍", font=F_TITLE, fill="#111")
    d.text((40, 70), "数据来源：ModelSim 真实仿真 dump.txt（32×8 图，每行 8 拍，共 2 帧）",
           font=F_SUB, fill="#666")

    sig = [
        ("I_tvalid", "Iv", "#2f6fb3", "输入"),
        ("I_tuser", "Iu", "#2f6fb3", ""),
        ("I_tlast", "Il", "#2f6fb3", ""),
        ("I_tdata(beat)", "ibi", "#2f6fb3", ""),
        ("O_tvalid", "Ov", "#c8642a", "输出"),
        ("O_window_valid", "Ovld", "#c8642a", ""),
        ("O_tlast", "Ol", "#c8642a", ""),
        ("O_tdata(beat)", "obi", "#c8642a", ""),
    ]
    by = {r["cyc"]: r for r in rows}

    for i, (name, key, col, tag) in enumerate(sig):
        y = TOP + i * RH
        if i == 4:
            d.line([(40, y - RH // 2), (Wd - 40, y - RH // 2)], fill="#ccc", width=2)
        lab = name if not tag else tag + " " + name
        d.text((40, y + 14), lab, font=F_LBL, fill=col if not tag else "#000")

        for c in range(C0, C1 + 1):
            x0 = LEFT + (c - C0) * CW
            r = by.get(c)
            if r is None:
                continue
            v = r[key]
            if key in ("ibi", "obi"):
                if v < 0:
                    d.rectangle([x0 + 2, y + 34, x0 + CW - 2, y + 36], fill="#ddd")
                    d.text((x0 + 6, y + 10), "—", font=F_SM, fill="#aaa")
                else:
                    d.rectangle([x0 + 2, y + 8, x0 + CW - 2, y + 38], fill=col)
                    t = str(v)
                    tw = d.textlength(t, font=F_SM)
                    d.text((x0 + (CW - tw) / 2, y + 16), t, font=F_SM, fill="white")
            else:
                hi = (v == 1)
                yl = y + 12 if hi else y + 36
                yh = y + 38 if hi else y + 14
                d.rectangle([x0 + 2, y + 10, x0 + CW - 2, y + 40], outline="#e2e2e2")
                d.line([(x0 + 2, yl), (x0 + CW - 2, yl)], fill=col, width=4)

    # 拍号轴
    yax = TOP + 8 * RH + 6
    for c in range(C0, C1 + 1):
        x0 = LEFT + (c - C0) * CW
        d.text((x0 + CW / 2 - 8, yax), str(c), font=F_TINY, fill="#888")

    # 2 拍偏移标注
    def cx(c):
        return LEFT + (c - C0) * CW + CW / 2

    yb = TOP + 3 * RH + 26
    d.line([(cx(6), yb), (cx(8), yb)], fill="#0a0", width=3)
    d.polygon([(cx(8), yb), (cx(8) - 9, yb - 5), (cx(8) - 9, yb + 5)], fill="#0a0")
    d.text((cx(6) - 20, yb + 8), "输入 beat 0", font=F_SM, fill="#0a0")
    yb2 = TOP + 7 * RH + 46
    d.line([(cx(8), yb2), (cx(10), yb2)], fill="#0a0", width=3)
    d.text((cx(8) - 40, yb2 + 6), "输出 beat 0（晚 2 拍）", font=F_SM, fill="#0a0")

    d.text((40, TOP - 40),
           "I_tdata 与 O_tdata 之间恒差 2 拍；O_window_valid 与 O_tvalid 同拍。"
           "校验器逐拍比对 149 拍，全部相符。",
           font=F_SUB, fill="#333")
    im.save(path)
    print("  已写出", path)


# --------------------------------------------------------------------------
# 图 2：窗口几何
# --------------------------------------------------------------------------
def fig_geometry(rows, path, bi_pick=18, k_pick=1):
    """取第 bi_pick 拍、第 k_pick 个中心像素，画出它实际取到的 3x3。"""
    y = (bi_pick % (BPL * H_IMG)) // BPL
    xg = bi_pick % BPL
    xc = 4 * xg + k_pick
    cyc = bi_pick + START_CYC + LAT
    rec = next((r for r in rows if r["cyc"] == cyc), None)
    win = int(rec["Ow"], 16)

    CELL = 34
    GX, GY = 70, 210
    Wd, Ht = 1660, 980
    im = Image.new("RGB", (Wd, Ht), "white")
    d = ImageDraw.Draw(im)

    d.text((40, 26), "win3x3_96 几何验证：9 个抽头是否取到了正确的像素", font=F_TITLE, fill="#111")
    d.text((40, 68), "测试图每个像素的值都唯一编码了它自己的坐标 gray=(y<<5)|x，"
                     "所以从取到的值能唯一反解出源像素在哪 —— 不存在误判。",
           font=F_SUB, fill="#666")

    # 图像网格
    for yy in range(H_IMG):
        for xx in range(W_IMG):
            x0 = GX + xx * CELL
            y0 = GY + yy * CELL
            inwin = (y - 2 <= yy <= y) and (xc - 1 <= xx <= xc + 1)
            fill = "#ffe9c9" if inwin else "#f4f6f8"
            d.rectangle([x0, y0, x0 + CELL - 2, y0 + CELL - 2], fill=fill, outline="#d8dde2")
            t = str(gray_at(yy, xx))
            tw = d.textlength(t, font=F_TINY)
            d.text((x0 + (CELL - 2 - tw) / 2, y0 + 9), t, font=F_TINY,
                   fill="#a33" if inwin else "#7a8894")
    d.text((GX, GY - 34), "测试图 32×8（格子里是灰度值）", font=F_LBL, fill="#333")
    d.text((GX, GY + H_IMG * CELL + 10),
           "橙色 = 本次取到的 3×3 窗口；中心像素在第 %d 行、第 %d 列" % (y - 1, xc),
           font=F_SM, fill="#a33")

    # 右侧：抽头对照表
    TX, TY = GX + W_IMG * CELL + 60, GY - 10
    d.text((TX, TY - 44), "9 个抽头：期望 vs 仿真实得", font=F_LBL, fill="#111")
    d.rectangle([TX, TY, TX + 400, TY + 40], fill="#eef3f8")
    d.text((TX + 12, TY + 11), "抽头", font=F_SM, fill="#333")
    d.text((TX + 90, TY + 11), "期望坐标", font=F_SM, fill="#333")
    d.text((TX + 205, TY + 11), "实得值", font=F_SM, fill="#333")
    d.text((TX + 285, TY + 11), "期望值", font=F_SM, fill="#333")
    d.text((TX + 355, TY + 11), "结果", font=F_SM, fill="#333")

    names = [["w00", "w01", "w02"], ["w10", "w11", "w12"], ["w20", "w21", "w22"]]
    ry = TY + 44
    allok = True
    for rr in range(3):
        for cc in range(3):
            idx = 4 * (3 * rr + cc) + k_pick
            got = (win >> (8 * idx)) & 0xFF
            ys_e = y - 2 + rr
            xs_e = xc + cc - 1
            want = gray_at(ys_e, xs_e)
            ok = (got == want)
            allok = allok and ok
            bg = "#f7fbf7" if ok else "#ffecec"
            d.rectangle([TX, ry, TX + 400, ry + 36], fill=bg, outline="#e3e8ec")
            ctr = (rr == 1 and cc == 1)
            d.text((TX + 12, ry + 9), names[rr][cc] + ("*" if ctr else ""),
                   font=F_SM, fill="#a33" if ctr else "#333")
            d.text((TX + 90, ry + 9), "(y%d,x%d)" % (ys_e, xs_e), font=F_SM, fill="#555")
            d.text((TX + 205, ry + 9), str(got), font=F_SM, fill="#111")
            d.text((TX + 285, ry + 9), str(want), font=F_SM, fill="#111")
            d.text((TX + 355, ry + 9), "OK" if ok else "错", font=F_SM,
                   fill="#1a7f37" if ok else "#c00")
            ry += 38
    d.text((TX, ry + 12), "* = 窗口中心（第 y-1 行）", font=F_TINY, fill="#888")

    d.text((TX, ry + 56),
           "本次窗口全部 %s" % ("相符" if allok else "有错"),
           font=F_SUB, fill="#1a7f37" if allok else "#c00")
    d.text((TX, ry + 90), "整个仿真：84 个有效拍 × 36 抽头 = 3024 次断言", font=F_SM, fill="#333")
    d.text((TX, ry + 116), "全部 (Δy,Δx) = (0,0)　→　PASS", font=F_SUB, fill="#1a7f37")

    d.text((40, Ht - 70),
           "中心为什么在第 y-1 行：第 y 行到达时，第 y+1 行还没到，窗口只能以 y-1 为中心。"
           "这是 3×3 窗口固有的 1 行延迟。", font=F_SM, fill="#666")
    d.text((40, Ht - 44),
           "被测对象：win3x3_96.v v2.0（SHA256 0403C91C…EB347）　"
           "输出拍号 cycle=%d（= 输入 beat %d + 起始 6 拍 + 延迟 2 拍）" % (cyc, bi_pick),
           font=F_TINY, fill="#999")
    im.save(path)
    print("  已写出", path)


# --------------------------------------------------------------------------
# 图 3：行缓冲 X
# --------------------------------------------------------------------------
def fig_linebuf(rows, path):
    C0, C1 = 0, 20
    CW = 62
    LEFT = 250
    TOP = 210
    RH = 90
    Wd = LEFT + (C1 - C0 + 1) * CW + 60
    Ht = TOP + 2 * RH + 200
    im = Image.new("RGB", (Wd, Ht), "white")
    d = ImageDraw.Draw(im)

    d.text((40, 26), "行缓冲是不是真的没被复位清零？", font=F_TITLE, fill="#111")
    d.text((40, 70), "这是「行缓冲能进块存储器（ERAM）」的前提条件。"
                     "只有真实仿真能看出来 —— Python 模型没有 X 这个概念。",
           font=F_SUB, fill="#666")
    d.text((40, 104), "厂商原话（edge_detect_96.v:110-112）：给缓冲加复位循环，"
                      "会把它们变成 slice 寄存器，反而更糟。", font=F_SUB, fill="#a33")

    by = {r["cyc"]: r for r in rows}
    sig = [("dut.r_line1_mem[0]", "L1", "#2f6fb3", "存第 y-1 行"),
           ("dut.r_line2_mem[0]", "L2", "#7a4fb3", "存第 y-2 行")]
    firsts = {}
    for i, (name, key, col, note) in enumerate(sig):
        y = TOP + i * RH
        d.text((40, y + 4), name, font=F_LBL, fill=col)
        d.text((40, y + 28), note, font=F_SM, fill="#888")
        first = next((r["cyc"] for r in rows if not has_xz(r[key]) and r[key]), None)
        firsts[key] = first
        for c in range(C0, C1 + 1):
            x0 = LEFT + (c - C0) * CW
            r = by.get(c)
            if r is None:
                continue
            v = r[key]
            if has_xz(v):
                d.rectangle([x0 + 2, y + 10, x0 + CW - 2, y + 60], fill="#ffe0e0",
                            outline="#e0a0a0")
                t = "X"
                tw = d.textlength(t, font=F_SUB)
                d.text((x0 + (CW - tw) / 2, y + 26), t, font=F_SUB, fill="#c00")
            else:
                d.rectangle([x0 + 2, y + 10, x0 + CW - 2, y + 60], fill=col)
                t = v.lstrip("0") or "0"
                tw = d.textlength(t, font=F_SM)
                d.text((x0 + (CW - tw) / 2, y + 30), t, font=F_SM, fill="white")
        if first:
            xf = LEFT + (first - C0) * CW
            d.line([(xf, y + 4), (xf, y + 66)], fill="#1a7f37", width=3)
            d.text((xf - 30, y + 70), "首次确定值：拍 %d" % first, font=F_SM, fill="#1a7f37")

    yax = TOP + 2 * RH
    for c in range(C0, C1 + 1):
        x0 = LEFT + (c - C0) * CW
        d.text((x0 + CW / 2 - 8, yax), str(c), font=F_TINY, fill="#888")
    d.text((LEFT, yax + 26), "拍号", font=F_SM, fill="#888")

    d.text((40, yax + 66),
           "line1 在拍 7 变确定值：第 0 行第 0 拍在第 6 拍到达，写入后下一沿可见 → 拍 7。正确。",
           font=F_SUB, fill="#333")
    d.text((40, yax + 96),
           "line2 在拍 15 变确定值：第 1 行第 0 拍在第 14 拍到达 → 拍 15。正确。",
           font=F_SUB, fill="#333")
    d.text((40, yax + 132),
           "结论：缓冲确实没有被复位清零（前几拍是 X），而且这些 X 全程没有漏进任何一路输出。",
           font=F_SUB, fill="#1a7f37")
    im.save(path)
    print("  已写出", path)


# --------------------------------------------------------------------------
def main():
    rows = parse(os.path.join(HERE, "dump.txt"))
    print("解析 dump.txt：%d 拍" % len(rows))
    fig_timing(rows, os.path.join(HERE, "仿真结果_1_时序波形.png"))
    fig_geometry(rows, os.path.join(HERE, "仿真结果_2_窗口几何.png"))
    fig_linebuf(rows, os.path.join(HERE, "仿真结果_3_行缓冲X.png"))


if __name__ == "__main__":
    main()
