#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_win3x3.py —— 校验 ModelSim 真实仿真出来的 dump.txt

校验三件事，全部以**规格**为准，不读 RTL 实现：

  A. 延迟：O_tvalid / O_tlast / O_tuser / O_tdata 必须逐拍精确等于输入延迟 2 拍
  B. 几何：有效拍的 36 个抽头，每个都必须等于
         gray( y-2+r , 4*x_grp+k+c-1 )
     反解用严格单射的唯一值图，观察到的字节值唯一确定源像素坐标，
     所以任何偏差都会以 (dy, dx) 的形式暴露 —— 不存在"混叠导致的假通过"。
  C. X 传播：有效拍上 O_window / O_tdata 不允许出现 x / z
  D. 行缓冲探针：证明"复位不清零行缓冲"确实成立（早期为 X），且 X 没漏到输出

用法：
    python check_win3x3.py              # 正常校验
    python check_win3x3.py --selftest   # 变异自证：故意写错期望，必须被抓出来
"""
from __future__ import annotations
import sys, os
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

W, H = 32, 8
BPL = W // 4
FRAMES = 2
NBEAT = BPL * H * FRAMES
START_CYC = 6
LAT = 2


# ---------------------------------------------------------------------------
# 唯一值图与其逆映射（构造时就断言单射，杜绝混叠）
# ---------------------------------------------------------------------------
def build_image():
    fwd = {}
    for y in range(H):
        for x in range(W):
            fwd[(y, x)] = (y << 5) | x
    rev = {}
    for (y, x), v in fwd.items():
        assert v not in rev, "唯一值图不是单射！值 %d 同时属于 %s 和 %s" % (v, rev[v], (y, x))
        rev[v] = (y, x)
    assert len(rev) == W * H, "唯一值图有空洞"
    return fwd, rev


FWD, REV = build_image()


def expected_gray(y, x):
    if 0 <= y < H and 0 <= x < W:
        return FWD[(y, x)]
    return 0


def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 11:
                continue
            rows.append({
                "cyc": int(f[0]),
                "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]), "Id": f[4],
                "Ov": int(f[5]), "Ol": int(f[6]), "Ou": int(f[7]), "Od": f[8],
                "Ovld": int(f[9]), "Ow": f[10],
                "L1": f[11] if len(f) > 11 else "",
                "L2": f[12] if len(f) > 12 else "",
            })
    return rows


def has_xz(s):
    return any(c in "xXzZ" for c in s)


# ---------------------------------------------------------------------------
# A. 延迟
# ---------------------------------------------------------------------------
def check_latency(rows, lat=LAT, verbose=True):
    by = {r["cyc"]: r for r in rows}
    n = len(rows)
    pairs = (("Ov", "Iv", "tvalid"), ("Ol", "Il", "tlast"),
             ("Ou", "Iu", "tuser"), ("Od", "Id", "tdata"))
    fails = []
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
            if bad:
                print("  %-6s 比较 %d 拍，不符 %d 拍（首个 %s）  -> FAIL"
                      % (name, ncmp, len(bad), bad[:6]))
            else:
                print("  %-6s 比较 %d 拍，全部相符                -> PASS" % (name, ncmp))
        if bad:
            fails.append("延迟 %s 不符（%d 拍）" % (name, len(bad)))
    return fails


# ---------------------------------------------------------------------------
# B. 几何
# ---------------------------------------------------------------------------
def check_geometry(rows, row_off=0, col_off=0, beat_off=0, verbose=True):
    nvalid = ntap = 0
    fails = []
    delta_stat = [Counter() for _ in range(9)]
    for r in rows:
        if r["Ovld"] != 1:
            continue
        c = r["cyc"]
        bi = c - START_CYC - LAT + beat_off
        if bi < 0 or bi >= NBEAT:
            continue
        if has_xz(r["Ow"]):
            fails.append("拍 %d 的 O_window 含 X/Z" % c)
            continue
        y = (bi % (BPL * H)) // BPL
        xg = bi % BPL
        win = int(r["Ow"], 16)
        nvalid += 1
        for rr in range(3):
            for cc in range(3):
                for k in range(4):
                    idx = 4 * (3 * rr + cc) + k
                    val = (win >> (8 * idx)) & 0xFF
                    ys_exp = y - 2 + rr + row_off
                    xs_exp = 4 * xg + k + cc - 1 + col_off
                    want = expected_gray(ys_exp, xs_exp)
                    ntap += 1
                    if val == 0 and want == 0:
                        delta_stat[3 * rr + cc][(0, 0)] += 1
                        continue
                    if val not in REV:
                        fails.append("拍%d tap(r%d,c%d,k%d) 值 %d 无法反解" % (c, rr, cc, k, val))
                        continue
                    ys, xs = REV[val]
                    dy, dx = ys - ys_exp, xs - xs_exp
                    delta_stat[3 * rr + cc][(dy, dx)] += 1
                    if (dy, dx) != (0, 0):
                        fails.append("拍%d tap(r%d,c%d,k%d) 期望(y%d,x%d) 实得(y%d,x%d) Δ=(%+d,%+d)"
                                     % (c, rr, cc, k, ys_exp, xs_exp, ys, xs, dy, dx))
    if verbose:
        print("\n=== B. 几何检查（绝对坐标反解）===")
        print("  有效拍数 %d，抽头断言数 %d" % (nvalid, ntap))
        anybad = False
        for i in range(9):
            rr, cc = divmod(i, 3)
            nz = {k: v for k, v in delta_stat[i].items() if k != (0, 0)}
            if nz:
                anybad = True
                print("    (r%d,c%d) 非零偏移: %s" % (rr, cc, nz))
        if not anybad:
            print("    全部 (Δy,Δx) = (0,0)   -> PASS")
    return fails, nvalid, ntap


# ---------------------------------------------------------------------------
# C/D. X 传播与行缓冲探针
# ---------------------------------------------------------------------------
def check_x(rows, verbose=True):
    fails = []
    nxw = sum(1 for r in rows if r["Ovld"] == 1 and has_xz(r["Ow"]))
    nxo = sum(1 for r in rows if r["Ov"] == 1 and has_xz(r["Od"]))
    allx = [r["cyc"] for r in rows if has_xz(r["Ow"]) or has_xz(r["Od"])]
    if verbose:
        print("\n=== C. X 传播检查 ===")
        print("  有效拍 O_window 含 X/Z : %d 拍" % nxw)
        print("  有效拍 O_tdata  含 X/Z : %d 拍" % nxo)
        print("  全 dump 中任何输出 X/Z : %s"
              % (("%d..%d（%d 拍）" % (min(allx), max(allx), len(allx))) if allx else "无"))
        print("\n=== D. 行缓冲探针（证明'复位不清零行缓冲'）===")
        first_def1 = next((r["cyc"] for r in rows if not has_xz(r["L1"])), None)
        first_def2 = next((r["cyc"] for r in rows if not has_xz(r["L2"])), None)
        print("  line1_mem[0] 前几拍: %s"
              % " ".join(r["L1"] for r in rows[:6] if r["L1"]))
        print("  line2_mem[0] 前几拍: %s"
              % " ".join(r["L2"] for r in rows[:6] if r["L2"]))
        print("  line1_mem[0] 首次变确定值 : 拍 %s" % first_def1)
        print("  line2_mem[0] 首次变确定值 : 拍 %s" % first_def2)
    if nxw or nxo:
        fails.append("存在 X 传播")
    return fails


# ---------------------------------------------------------------------------
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rows = parse(os.path.join(here, "dump.txt"))
    selftest = "--selftest" in sys.argv

    print("解析 dump.txt：%d 拍" % len(rows))

    if not selftest:
        fails = []
        fails += check_latency(rows)
        gf, _, _ = check_geometry(rows)
        fails += gf
        fails += check_x(rows)
        print("\n" + "=" * 62)
        if fails:
            print("结论：FAIL —— %d 条" % len(fails))
            for s in fails[:20]:
                print("   " + s)
            if len(fails) > 20:
                print("   ...（其余 %d 条省略）" % (len(fails) - 20))
        else:
            print("结论：PASS —— 延迟 / 几何 / X 三项全部通过")
        print("=" * 62)
        return 0 if not fails else 1

    # ---------------- 变异自证 ----------------
    print("\n" + "=" * 62)
    print("变异自证：故意用【错误期望】重跑，每一条都必须被抓出来")
    print("（抓不住的条目 = 测试在这个维度上没有鉴别力 = 等于没测）")
    print("=" * 62)
    mutations = [
        ("把延迟当成 1 拍",        dict(kind="lat", lat=1)),
        ("把延迟当成 3 拍",        dict(kind="lat", lat=3)),
        ("窗口行整体下移一行",      dict(kind="geo", row_off=+1)),
        ("窗口行整体上移一行",      dict(kind="geo", row_off=-1)),
        ("窗口列整体右移一列",      dict(kind="geo", col_off=+1)),
        ("窗口列整体左移一列",      dict(kind="geo", col_off=-1)),
        ("把拍号映射错一拍",        dict(kind="geo", beat_off=+1)),
    ]
    caught = 0
    for name, m in mutations:
        if m["kind"] == "lat":
            f = check_latency(rows, lat=m["lat"], verbose=False)
            n = len(f)
        else:
            f, nv, nt = check_geometry(rows, row_off=m.get("row_off", 0),
                                       col_off=m.get("col_off", 0),
                                       beat_off=m.get("beat_off", 0), verbose=False)
            n = len(f)
        mark = "抓住" if n > 0 else "!! 漏掉 !!"
        if n > 0:
            caught += 1
        print("  %-22s -> 报错 %4d 条   %s" % (name, n, mark))
    print("-" * 62)
    print("  鉴别力：%d/%d 个变异被抓住  -> %s"
          % (caught, len(mutations), "PASS" if caught == len(mutations) else "FAIL"))
    print("=" * 62)
    return 0 if caught == len(mutations) else 1


if __name__ == "__main__":
    sys.exit(main())
