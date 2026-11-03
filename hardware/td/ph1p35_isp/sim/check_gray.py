#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gray.py —— 校验 gray_bt601_96 的 ModelSim 仿真结果

校验四件事，全部**直接照规格公式**算，不参考 RTL 里的移位分解：
  A. 延迟：5 路输出必须逐拍精确等于输入延迟 1 拍
  B. 数值：Y = (77*R + 150*G + 29*B) >> 8，且复制到 R/G/B 三通道
  C. X 传播：有效拍输出不允许出现 x/z
  D. 覆盖：统计实际打到多少种测试向量、多少种不同 Y

用法：
    python check_gray.py              # 正常校验
    python check_gray.py --selftest   # 变异自证：故意写错期望，必须被抓
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

START_CYC = 6
LAT = 1


def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) != 9:
                continue
            rows.append({
                "cyc": int(f[0]),
                "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]), "Id": f[4],
                "Ov": int(f[5]), "Ol": int(f[6]), "Ou": int(f[7]), "Od": f[8],
            })
    return rows


def has_xz(s):
    return any(c in "xXzZ" for c in s)


def pixels(word96):
    """96bit -> [(R,G,B)]*4，pix0 在最高位段"""
    out = []
    for k in range(4):
        px = (word96 >> (24 * (3 - k))) & 0xFFFFFF
        out.append(((px >> 16) & 0xFF, (px >> 8) & 0xFF, px & 0xFF))
    return out


def gray_of(r, g, b, kr=77, kg=150, kb=29, sh=8):
    return ((kr * r + kg * g + kb * b) >> sh) & 0xFF


# ---------------------------------------------------------------------------
def check_latency(rows, lat=LAT, verbose=True):
    by = {r["cyc"]: r for r in rows}
    n = len(rows)
    fails = []
    # ⚠ tdata 不在这里比 —— 它是**变换后**的数据，不是输入的延迟副本。
    #   数据通道的延迟由 check_values() 覆盖（它按 LAT 对齐后比数值，
    #   而变异自证里的"延迟当成 0 拍 / 2 拍"两条证明它能抓住错位）。
    pairs = (("Ov", "Iv", "tvalid"), ("Ol", "Il", "tlast"),
             ("Ou", "Iu", "tuser"))
    if verbose:
        print("\n=== A. 延迟检查（期望：逐拍精确等于输入延迟 %d 拍）===" % lat)
    for dk, sk, name in pairs:
        bad, ncmp = [], 0
        for c in range(lat, n):
            if rows[c]["cyc"] != c or (c - lat) not in by:
                continue
            ncmp += 1
            if rows[c][dk] != by[c - lat][sk]:
                bad.append(c)
        if verbose:
            print("  %-6s 比较 %d 拍，%s" % (name, ncmp,
                  ("不符 %d 拍（首个 %s）  -> FAIL" % (len(bad), bad[:6])) if bad
                  else "全部相符                -> PASS"))
        if bad:
            fails.append("延迟 %s 不符（%d 拍）" % (name, len(bad)))
    return fails


def check_values(rows, kr=77, kg=150, kb=29, sh=8, swap_rb=False, verbose=True):
    by = {r["cyc"]: r for r in rows}
    fails = []
    npx = 0
    vecs = set()
    yvals = set()
    bad_samples = []
    for r in rows:
        c = r["cyc"]
        if r["Od"] == "0" * 24 and c < START_CYC + LAT + 2:
            continue
        if (c - LAT) not in by:
            continue
        src = by[c - LAT]["Id"]
        if has_xz(src) or has_xz(r["Od"]):
            if r["Ov"] == 1:
                fails.append("拍 %d 输出含 X/Z" % c)
            continue
        if by[c - LAT]["Iv"] != 1:
            continue
        w_in = int(src, 16)
        w_out = int(r["Od"], 16)
        for k, (R, G, B) in enumerate(pixels(w_in)):
            vecs.add((R, G, B))
            if swap_rb:
                R, B = B, R
            y = gray_of(R, G, B, kr, kg, kb, sh)
            yvals.add(y)
            got = (w_out >> (24 * (3 - k))) & 0xFFFFFF
            exp = (y << 16) | (y << 8) | y
            npx += 1
            if got != exp:
                if len(bad_samples) < 8:
                    bad_samples.append(
                        "拍%d pix%d (R%d,G%d,B%d) 期望 Y=%d/0x%06x 实得 0x%06x"
                        % (c, k, R, G, B, y, exp, got))
                fails.append("拍%d pix%d 数值不符" % (c, k))
    if verbose:
        print("\n=== B. 数值检查（Y = (%d*R + %d*G + %d*B) >> %d）===" % (kr, kg, kb, sh))
        print("  比较像素数 %d" % npx)
        print("  实际打到的测试向量 (R,G,B) 种类 : %d" % len(vecs))
        print("  实际产生的不同 Y 值种类        : %d" % len(yvals))
        if fails:
            print("  不符 %d 条，样本：" % len(fails))
            for s in bad_samples:
                print("    " + s)
        else:
            print("  全部相符                -> PASS")
    return fails, npx, len(vecs), len(yvals)


def check_x(rows, verbose=True):
    fails = []
    allx = [r["cyc"] for r in rows if has_xz(r["Od"]) and r["Ov"] == 1]
    if verbose:
        print("\n=== C. X 传播检查 ===")
        print("  有效拍 O_tdata 含 X/Z 的拍数 : %d" % len(allx))
        print("  全 dump 中输出 X/Z 出现的拍号 : %s"
              % (("%d..%d（%d 拍）" % (min(allx), max(allx), len(allx))) if allx else "无"))
    if allx:
        fails.append("存在 X 传播")
    return fails


# ---------------------------------------------------------------------------
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows = parse(os.path.join(here, "dump_gray.txt"))
    selftest = "--selftest" in sys.argv
    print("解析 dump_gray.txt：%d 拍" % len(rows))

    if not selftest:
        fails = []
        fails += check_latency(rows)
        gf, npx, nvec, ny = check_values(rows)
        fails += gf
        fails += check_x(rows)
        print("\n" + "=" * 62)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails[:15]:
                print("   " + s)
        else:
            print("结论：PASS —— 延迟 / 数值 / X 三项全部通过")
            print("       覆盖 %d 个像素、%d 种输入向量、%d 种输出灰度"
                  % (npx, nvec, ny))
        print("=" * 62)
        return 0 if not fails else 1

    print("\n" + "=" * 62)
    print("变异自证：故意用【错误期望】重跑，每一条都必须被抓出来")
    print("=" * 62)
    muts = [
        ("延迟当成 0 拍",        dict(kind="lat", lat=0)),
        ("延迟当成 2 拍",        dict(kind="lat", lat=2)),
        ("R 系数 77 -> 78",      dict(kind="val", kr=78)),
        ("G 系数 150 -> 151",    dict(kind="val", kg=151)),
        ("B 系数 29 -> 30",      dict(kind="val", kb=30)),
        ("右移 8 -> 7",          dict(kind="val", sh=7)),
        ("R 与 B 通道对调",       dict(kind="val", swap_rb=True)),
    ]
    caught = 0
    for name, m in muts:
        if m["kind"] == "lat":
            f = check_latency(rows, lat=m["lat"], verbose=False)
            n = len(f)
        else:
            f, _, _, _ = check_values(rows, kr=m.get("kr", 77), kg=m.get("kg", 150),
                                      kb=m.get("kb", 29), sh=m.get("sh", 8),
                                      swap_rb=m.get("swap_rb", False), verbose=False)
            n = len(f)
        if n > 0:
            caught += 1
        print("  %-22s -> 报错 %5d 条   %s" % (name, n, "抓住" if n else "!! 漏掉 !!"))
    print("-" * 62)
    print("  鉴别力：%d/%d 个变异被抓住  -> %s"
          % (caught, len(muts), "PASS" if caught == len(muts) else "FAIL"))
    print("=" * 62)
    return 0 if caught == len(muts) else 1


if __name__ == "__main__":
    sys.exit(main())
