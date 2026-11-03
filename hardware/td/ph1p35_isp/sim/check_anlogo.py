#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_anlogo.py —— 安路官方 Logo（G1）专项校验器

期望值**只**来自两处，DUT 内部信号一个都不读（dump 里也没有像素探针）：
  1. logo_64c.hex + alg_logo_eram.v 里的调色板 —— 展开成 160x160 的 RGB/透明图
     （= "官方素材经我们编码后的样子"；口径见 alg_logo_eram.v §二）；
  2. TB 的激励值图 —— 每像素自带拍号，可反解 (beat, ch)，thus 坐标与原像素值。
⇒ 不存在"期望模型把 RTL 的缺陷一起吸收掉"的循环论证。

另有一条**独立的编码保真度断言**（F）：展开图 vs 官方素材 anlogic_logo_rom.v
逐像素比对，误差必须落在 gen_logo_eram.py 报出的界内，并与 logo_64c.stats.txt
台账逐项相等。这条专门防"编码器写错、参考模型跟着一起错"。

断言（每条都打印检查次数；0 次检查 = 失败）：
  A1  安路命中像素：输出 == 展开图的颜色（逐 bit）
  A2  区内透明像素（且其它 OSD 面都没命中）：输出 == 原像素
  A3  区左列（x < ANLOGO_X）：输出 == 原像素
  A4  区右列（x >= ANLOGO_X + 160）：输出 == 原像素
  A5  区外（校正窗口内、矩形外）：输出 == 原像素
  A6  四角（4 个像素）+ 四条边（区域内首末行/首末列）
  A7  紧邻一圈（x = X+W..X+W+3 与 y = Y+H..Y+H+3）
  A8  时序：数据/控制延迟从激励反解、两者同拍；O_tvalid=0 时 O_tdata 必须 0
  A9  覆盖率：上面每条都必须 > 0 次检查
  A10 有效拍上不允许 X/Z
  A11 优先级（三层重叠的 dut_c）：文字 > 安路 > 自研
  A12 配置护栏：合法配置 r_an_cfg_err=0、非法用例（ANLOGO_X=6）必须 =1
  F   编码保真度：展开图 vs 官方素材的量化误差 + 与台账逐项相等
  P   假像素机会：把"区外钳位 + r_ok 屏蔽"一起去掉会读出多少个非透明像素
      （必须 > 0，否则这个变异根本不可能被抓到 —— 证明测试有鉴别力）

用法：
    python check_anlogo.py --dir <仿真目录> [--selftest]
"""
from __future__ import annotations

import argparse
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = HERE
ROOT = os.path.dirname(SIM)
SRC = os.path.join(ROOT, "src")
DEFAULT_ROM = os.path.join(ROOT, "prj", "board", "lab_ex3_osd", "user_source",
                           "hdl_source", "anlogic_logo_rom.v")

# 自研素材的解析直接复用 check_osd.py（单一真值来源，不复制一份表）
sys.path.insert(0, SIM)
import check_osd as CO  # noqa: E402

AN_W_DEFAULT = 160
AN_H_DEFAULT = 160
AN_STRIDE = 160          # 官方 ROM 的行跨距，硬编址在素材里
TEXT_W = 16
TEXT_H = 16
N_CHAR_MAX = 16
OSD_TEXT_COLOR = 0xFFFFFF

# 编码保真度的界（来自 gen_logo_eram.py 的报告：64 色/6bpp 实测 max 20）
# ⚠ 这两个数**故意写死在这里**：将来谁改了量化，断言的界不会跟着漂。
FID_MAX_ERR = 24           # 每通道最大误差的硬界（实测 20，留 4 级余量）
FID_STATS = {}             # main() 里从 logo_64c.stats.txt 读入


# ===========================================================================
# 1. 官方素材（anlogic_logo_rom.v）—— 只给"编码保真度"断言当基准
#    展开图（期望值本体）在 check_osd 里从 logo_64c.hex + RTL 调色板算出来，
#    这里再独立解析官方 case 表，两条路互不依赖。
# ===========================================================================
def parse_anrom(path, verbose=True):
    txt = open(path, "r", encoding="utf-8", errors="replace").read()
    vals = re.findall(r"15'd(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)\s*;", txt)
    assert vals, "anlogic_logo_rom 解析失败（一条 case 项都没解析到）"
    tab = {}
    dup = 0
    for a, v in vals:
        a, v = int(a), int(v, 16)
        if a in tab:
            dup += 1
        tab[a] = v
    # default 分支：必须是透明（25'd0），否则"未命中"就无从谈起
    m = re.findall(r"default\s*:\s*O_pixel\s*=\s*(\d+)'d(\d+)", txt)
    assert len(m) == 1, "default 分支不是唯一的 `N'dM` 形式：%r" % m
    default_val = int(m[0][1])
    if verbose:
        cols = sorted(set(v & 0xFFFFFF for v in tab.values()))
        rows_used = sorted(set(a // AN_STRIDE for a in tab))
        print("  官方素材：%d 条 case 项（重复地址 %d），default = %d"
              % (len(tab), dup, default_val))
        print("  官方素材：bit24 全为 1 = %s；distinct 颜色 = %d"
              % (all((v >> 24) & 1 for v in tab.values()), len(cols)))
        print("  官方素材：占用行 %d..%d；列 %d..%d"
              % (rows_used[0], rows_used[-1],
                 min(a % AN_STRIDE for a in tab), max(a % AN_STRIDE for a in tab)))
    assert default_val == 0, "★ default 不是 0，而是 %d —— 透明语义不成立" % default_val
    assert dup == 0, "case 表里有 %d 个重复地址（后写的赢，素材可疑）" % dup
    return tab, default_val


# ===========================================================================
# 2. 激励值图（与 tb_osd_anlogo.v 逐字一致）
# ===========================================================================
def src_pix(beat, ch):
    return (beat << 7) | (((beat % 32) & 0x1F) << 2) | (ch & 3)


def beat_of(pix24, ch):
    """从像素值反解拍号；不是本 TB 的激励值就返回 None"""
    if (pix24 & 0x3) != (ch & 3):
        return None
    b = pix24 >> 7
    if b >= (1 << 17):
        return None
    return b if src_pix(b, ch) == pix24 else None


# ===========================================================================
# 3. 版面 / 平面模型
# ===========================================================================
class Plane:
    """一个 dump 的版面参数（全部来自 dump 首行，不来自 RTL）"""

    def __init__(self, hdr):
        (self.W, self.H, self.AX, self.AY, self.AW, self.AH,
         self.MX, self.MY, self.TX, self.TY,
         self.MODE, self.FPS, self.LAT, self.INF_X) = hdr
        self.BPL = self.W // 4
        # 自研 Logo / 文字是否与安路区重叠 → 决定要不要把它们建进模型
        self.other_planes = (self.MX < self.AX + self.AW) and (self.MY < self.AY + self.AH)
        # 校正窗口：不建模其它面时，只断言"只可能有安路面"的那片区域
        self.win_y = self.H if self.other_planes else self.MY

    def __str__(self):
        return ("W=%d H=%d | 安路区 x[%d,%d) y[%d,%d) | 自研(%d,%d) 文字(%d,%d) | "
                "窗口 y<%d | 其它面建模=%s"
                % (self.W, self.H, self.AX, self.AX + self.AW, self.AY, self.AY + self.AH,
                   self.MX, self.MY, self.TX, self.TY, self.win_y, self.other_planes))


AN_XG = 40                # 字/行（160/4）
AN_WORDS = 6400           # 160*40
AN_W = CO.AN_W            # 160（与 check_osd 的展开图同口径，单一真值来源）
AN_H = CO.AN_H            # 160


def an_probe(x, y, p):
    """复刻 alg_logo_eram.v 的模型，返回 (hit, color, ok, phantom)

    区内外是**整拍**判据（4px/字 对齐 + ANLOGO_X 是 4 的倍数 ⇒ 一拍的 4 个像素
    要么全在区内要么全在区外）；透明由 index 0 表示。
      ok      = 该像素所在的拍在区内 且 展开图该点非透明
      phantom = 若把"区外地址钳位 + r_ok 屏蔽"一起去掉，这个像素会读到的 index 是否非零
                （用来证明那两条保护线路是**有鉴别力**的，不是摆设）
    """
    inrow = (p.AY <= y < p.AY + p.AH)
    incol = (p.AX <= x < p.AX + p.AW)
    dy, dx = y - p.AY, x - p.AX
    hit = False
    col = 0
    if inrow and incol:
        c = CO.AN_IMG[dy][dx]
        if c is not None:
            hit, col = True, (c[0] << 16) | (c[1] << 8) | c[2]
    # 假像素机会（模型侧，只看数据）：去掉钳位+屏蔽后的字地址与 lane 下标
    ph = False
    if not (inrow and incol):
        dy_m = (y - p.AY) & 0x3FF
        dx_m = (x - p.AX) & 0xFFF
        adr = (((dy_m * AN_XG) & 0x1FFF) + (dx_m >> 2)) & 0x1FFF
        if adr >= AN_WORDS:
            ph = True                      # 地址越界 ⇒ 读出的绝不是原像素
        else:
            ph = ((CO.AN_WORD[adr] >> (6 * (x % 4))) & 0x3F) != 0
    return hit, col, (inrow and incol), ph


def _cfg_like(p):
    class C:
        pass
    c = C()
    c.MODE, c.FPS, c.LAT, c.INF_X = p.MODE, p.FPS, p.LAT, p.INF_X
    return c


def text_probe(x, y, p):
    if not (p.TX <= x < p.TX + N_CHAR_MAX * TEXT_W):
        return False
    if not (p.TY <= y < p.TY + TEXT_H):
        return False
    dx = x - p.TX
    code = CO.char_code(dx // TEXT_W, _cfg_like(p))
    gb = CO.CHAR_BITS(CO.char_rom_idx(code), (y - p.TY) & 0xF)
    return bool((gb >> (15 - (dx % TEXT_W))) & 1)


def my_probe(x, y, p):
    return CO.LOGO_HIT(y - p.MY, x - p.MX)


# ===========================================================================
# 4. 统计
# ===========================================================================
class Stats:
    def __init__(self):
        self.chk, self.bad, self.sam = {}, {}, {}

    def add(self, key, ok, msg=""):
        self.chk[key] = self.chk.get(key, 0) + 1
        if not ok:
            self.bad[key] = self.bad.get(key, 0) + 1
            if len(self.sam.setdefault(key, [])) < 3 and msg:
                self.sam[key].append(msg)

    def rec(self, key, ok, cyc=0, x=0, y=0, ch=0, got=0, want=0, kind=""):
        """逐像素断言：只在失败时才格式化消息（性能）"""
        self.chk[key] = self.chk.get(key, 0) + 1
        if not ok:
            self.bad[key] = self.bad.get(key, 0) + 1
            if len(self.sam.setdefault(key, [])) < 3:
                self.sam[key].append(
                    "cyc %d (x=%d y=%d ch=%d) got=%06X want=%06X kind=%s"
                    % (cyc, x, y, ch, got, want, kind))

    def n(self, key, min_n=1):
        """覆盖率断言：这条断言必须至少被检查过 min_n 次"""
        c = self.chk.get(key, 0)
        if c < min_n:
            self.bad[key] = self.bad.get(key, 0) + 1
            self.sam.setdefault(key, []).append(
                "★ 只检查了 %d 次（要求 >= %d）—— 这条断言是空转的" % (c, min_n))


def parse_dump(path):
    hdr, rows = None, []
    for ln in open(path, "r", encoding="ascii", errors="replace"):
        f = ln.split()
        if not f:
            continue
        if f[0] == "H":
            hdr = [int(v) for v in f[1:]]
            continue
        if len(f) < 10:
            continue
        rows.append({"cyc": int(f[0]), "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]),
                     "Id": f[4], "Ov": int(f[5]), "Ol": int(f[6]), "Ou": int(f[7]),
                     "Od": f[8], "beat": int(f[9])})
    assert hdr is not None, "%s 没有首行 H 头" % path
    assert len(hdr) == 14, "%s 的首行字段数 = %d（期望 14）" % (path, len(hdr))
    return hdr, rows


# ===========================================================================
# 5. 单个 dump 的完整校验
# ===========================================================================
def measure_latency(rows):
    """从激励反解数据延迟：输出拍携带的拍号 == 输入第 i-DS 拍总线上的拍号"""
    counts = {}
    for s in (1, 2, 3, 4):
        hit = tot = 0
        for i in range(s, len(rows)):
            if rows[i]["Ov"] != 1:
                continue
            tot += 1
            v = int(rows[i]["Od"], 16)
            beats = set()
            for ch in range(4):
                b = beat_of((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
                if b is not None:
                    beats.add(b)
            if not beats:
                continue
            ib = beat_of((int(rows[i - s]["Id"], 16) >> 72) & 0xFFFFFF, 0)
            if ib is not None and ib in beats:
                hit += 1
        counts[s] = (hit, tot)
    best = max(counts, key=lambda s: counts[s][0])
    order = sorted(counts, key=lambda s: -counts[s][0])
    second = counts[order[1]][0] if len(order) > 1 else 0
    uniq = counts[best][0] > 10 * max(1, second)
    return (best if (counts[best][0] > 0 and uniq) else None), counts


def check_one(tag, path, mut=None, verbose=True):
    hdr, rows = parse_dump(path)
    p = Plane(hdr)
    st = Stats()
    BPL = p.BPL

    if verbose:
        print("  ---- %s ----" % tag)
        print("  %s" % p)

    # ---- 时序 ----
    DS, dcounts = measure_latency(rows)
    ctrl = None
    for sh in (1, 2, 3, 4):
        hit = tot = 0
        for i in range(sh, len(rows)):
            if rows[i]["Ov"] != 1:
                continue
            tot += 1
            if (rows[i]["Ov"], rows[i]["Ol"], rows[i]["Ou"]) == \
               (rows[i - sh]["Iv"], rows[i - sh]["Il"], rows[i - sh]["Iu"]):
                hit += 1
        if tot and hit >= tot - 2:
            ctrl = sh
            break
    st.add("A8a 数据延迟==2", DS == 2, "实测 DS=%s (候选 %s)" % (DS, dcounts))
    st.add("A8b 控制延迟==2", ctrl == 2, "实测 ctrl=%s" % ctrl)
    st.add("A8c 数据/控制同拍", DS == ctrl, "DS=%s ctrl=%s" % (DS, ctrl))
    if verbose:
        print("  延迟：数据 %s / 控制 %s 拍（候选 %s）" % (DS, ctrl, dcounts))
    if DS is None:
        DS = 2

    ph_left = ph_right = 0
    n_prio_multi = n_prio_ta = n_prio_ma = 0

    for i, r in enumerate(rows):
        if set(r["Od"]) & set("xXzZ") or set(r["Id"]) & set("xXzZ"):
            st.add("A10 有效拍无 X/Z", False, "cyc %d: Od=%s Id=%s" % (r["cyc"], r["Od"], r["Id"]))
        if r["Ov"] != 1:
            st.add("A8d tvalid=0 ⇒ tdata=0", int(r["Od"], 16) == 0,
                   "cyc %d: Od=%s" % (r["cyc"], r["Od"]))
            continue
        j = i - DS
        if j < 0 or rows[j]["Iv"] != 1:
            continue
        beat = ((int(rows[j]["Id"], 16) >> 72) & 0xFFFFFF) >> 7
        if beat >= p.BPL * p.H:
            continue
        crx, cry = beat % BPL, beat // BPL
        v = int(r["Od"], 16)
        for ch in range(4):
            x, y = 4 * crx + ch, cry
            if y >= p.win_y:
                continue
            got = (v >> (72 - 24 * ch)) & 0xFFFFFF
            hit, col, ok, ph = an_probe(x, y, p)
            if mut == "ignore_an":                 # 变异：把安路面当透明
                hit = False
            elif mut == "color_inv":               # 变异：颜色取反
                col = (~col) & 0xFFFFFF
            elif mut == "no_mask":                 # 变异：去掉区外钳位 + r_ok 屏蔽
                hit, col, ok = ph, 0, True

            in_rect = (p.AX <= x < p.AX + p.AW) and (p.AY <= y < p.AY + p.AH)
            t_hit = text_probe(x, y, p) if p.other_planes else False
            m_hit = my_probe(x, y, p) if p.other_planes else False

            # 全优先级期望值：文字 > 安路 > 自研 > 原像素
            if t_hit:
                want, kind = OSD_TEXT_COLOR, "text"
            elif hit:
                want, kind = col, "an"
            elif m_hit:
                want, kind = CO.LOGO_FG, "my"
            else:
                want, kind = src_pix(beat, ch), "orig"
            good = (got == want)
            args = (r["cyc"], x, y, ch, got, want, kind)

            # A1 命中像素：逐 bit 等于展开图的颜色
            if hit:
                st.rec("A1 安路命中==展开图颜色", good, *args)
            # A2 区内透明且其它面没命中 ⇒ 原像素
            if in_rect and not hit and not t_hit and not m_hit:
                st.rec("A2 区内透明==原像素", good, *args)
            # A3 区左列（x < AX）
            if x < p.AX:
                st.rec("A3 区左列==原像素", good, *args)
            # A4 区右列（x >= AX+AW，含紧邻与更远）
            if p.AY <= y < p.AY + p.AH and x >= p.AX + p.AW:
                st.rec("A4 区右列==原像素", good, *args)
            # A5 区外（窗口内、矩形外）
            if not in_rect:
                st.rec("A5 区外==原像素", good, *args)
            # A6 四角 + 四条边
            if (x, y) in ((p.AX, p.AY), (p.AX + p.AW - 1, p.AY),
                          (p.AX, p.AY + p.AH - 1), (p.AX + p.AW - 1, p.AY + p.AH - 1)):
                st.rec("A6a 四角", good, *args)
            if in_rect and (x == p.AX or x == p.AX + p.AW - 1 or
                            y == p.AY or y == p.AY + p.AH - 1):
                st.rec("A6b 四条边", good, *args)
            # A7 紧邻一圈
            if (p.AY <= y < p.AY + p.AH and p.AX + p.AW <= x < p.AX + p.AW + 4) or \
               (p.AX <= x < p.AX + p.AW and p.AY + p.AH <= y < p.AY + p.AH + 4):
                st.rec("A7 紧邻一圈", good, *args)
            # A11 优先级（三层都建模时才有意义）
            if p.other_planes:
                nhit = int(t_hit) + int(hit) + int(m_hit)
                if nhit >= 2:
                    n_prio_multi += 1
                    st.rec("A11 优先级(多面重叠)", good, *args)
                if t_hit and hit:
                    n_prio_ta += 1
                if m_hit and hit:
                    n_prio_ma += 1
            # P 假像素机会（模型侧计算，不看 DUT）
            if ph:
                if x < p.AX:
                    ph_left += 1
                elif p.AY <= y < p.AY + p.AH and x >= p.AX + p.AW:
                    ph_right += 1

    # 覆盖率断言
    st.n("A1 安路命中==展开图颜色", 100)
    st.n("A2 区内透明==原像素", 100)
    st.n("A4 区右列==原像素", 100)
    st.n("A5 区外==原像素", 100)
    st.n("A6a 四角", 4)
    st.n("A6b 四条边", 100)
    st.n("A7 紧邻一圈", 100)
    st.add("P 假像素机会 > 0", (ph_left + ph_right) > 0,
           "左=%d 右=%d（若为 0，说明'删掉钳位+屏蔽'这个变异不可观测）" % (ph_left, ph_right))
    if p.other_planes:
        st.n("A11 优先级(多面重叠)", 1)
        st.add("A11b 文字×安路 重叠像素", n_prio_ta > 0, "重叠 %d" % n_prio_ta)
        st.add("A11c 自研×安路 重叠像素", n_prio_ma > 0, "重叠 %d" % n_prio_ma)
    if p.AX > 0:
        st.n("A3 区左列==原像素", 1)

    ok_all = not st.bad
    if verbose:
        keys = sorted(st.chk)
        print("  %-34s %10s %8s" % ("断言", "检查次数", "失配"))
        for k in keys:
            bad = st.bad.get(k, 0)
            print("  %-34s %10d %8d%s" % (k, st.chk[k], bad, "" if not bad else "   <<<"))
            for s in st.sam.get(k, [])[:2]:
                print("        " + s)
        print("  窗口内像素/变体：假像素机会 左=%d 右=%d；三层重叠 %d（文字×安路 %d / 自研×安路 %d）"
              % (ph_left, ph_right, n_prio_multi, n_prio_ta, n_prio_ma))
        print("  %s: %s" % (tag, "PASS" if ok_all else "FAIL"))
    return ok_all, st


# ===========================================================================
# 6. 独立断言：编码保真度 + 配置护栏
# ===========================================================================
def check_fidelity(tab, rtl_pal):
    """展开图（hex+调色板）vs 官方素材：量化误差必须落在台账内，且逐项相等

    这条是**防"编码器写错、参考模型跟着一起错"**的关键：期望值本来就从 hex 来，
    如果 hex 本身错了（打包顺序、调色板、行宽），DUT 与模型会一起错、测试全绿。
    这里换一个**独立数据源**（官方 anlogic_logo_rom.v）来钉住 hex 的正确性。

    rtl_pal = [ (r,g,b) × 63 ]（从 alg_logo_eram.v 抠出来的调色板，index 1..63）
    """
    st = Stats()
    n = maxe = sume = gt16 = gt8 = 0
    lost = added = 0
    for y in range(AN_H):
        for x in range(AN_W):
            v = tab.get(y * AN_STRIDE + x)
            c = CO.AN_IMG[y][x]
            if v is None:
                # 官方素材在这里透明 ⇒ 展开图也必须透明
                st.rec("F1 官方透明处必须透明", c is None, 0, x, y, 0,
                       (c[0] << 16) | (c[1] << 8) | c[2] if c else 0, 0, "transparent")
                if c is not None:
                    added += 1
                continue
            assert (v >> 24) & 1, "官方第 (%d,%d) 项不是不透明项" % (x, y)
            o = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
            if c is None:
                st.rec("F2 官方不透明处必须有像素", False, 0, x, y, 0, 0,
                       (o[0] << 16) | (o[1] << 8) | o[2], "dropped")
                lost += 1
                continue
            e = [abs(o[k] - c[k]) for k in range(3)]
            n += 1
            maxe = max(maxe, max(e))
            sume += sum(e)
            if max(e) > 16:
                gt16 += 1
            if max(e) > 8:
                gt8 += 1
            st.rec("F3 量化误差在本报告界内", max(e) <= FID_MAX_ERR, 0, x, y, 0,
                   (c[0] << 16) | (c[1] << 8) | c[2],
                   (o[0] << 16) | (o[1] << 8) | o[2], "err=%d" % max(e))
    st.n("F1 官方透明处必须透明", 1)
    st.n("F3 量化误差在本报告界内", 100)
    print("  编码保真度：命中像素 %d / 每通道误差 max=%d mean=%.3f / >16 的 %d / >8 的 %d"
          % (n, maxe, sume / (3.0 * n if n else 1), gt16, gt8))
    print("              官方透明处被编成不透明 %d 个；官方不透明处被丢掉 %d 个" % (added, lost))
    st.add("F4 误差 max 与台账一致", maxe == FID_STATS["max"], "实测 %d 台账 %d" % (maxe, FID_STATS["max"]))
    st.add("F5 误差和与台账一致", sume == FID_STATS["sum"], "实测 %d 台账 %d" % (sume, FID_STATS["sum"]))
    st.add("F6 >16 像素数与台账一致", gt16 == FID_STATS["gt16"], "实测 %d 台账 %d" % (gt16, FID_STATS["gt16"]))
    st.add("F7 命中像素数与台账一致", n == FID_STATS["n"], "实测 %d 台账 %d" % (n, FID_STATS["n"]))
    st.add("F8 调色板与台账一致", rtl_pal == FID_STATS["pal"], "RTL 调色板与 stats 台账不符")
    st.add("F9 透明/不透明映射零丢失", lost == 0 and added == 0, "lost=%d added=%d" % (lost, added))
    return (not st.bad), st


def load_stats(path):
    """读 gen_logo_eram.py 写下的量化台账

    台账格式（全部整数，便于逐项精确比对，不用浮点）：
        n <命中像素数> / max <每通道最大误差> / sum <误差和> / gt16 / gt8 / pal <项数>
        p RRGGBB × 63
    ⚠ `pal` 那一行是**项数**、`p` 才是颜色项 —— 这里踩过一次类型混淆（int 当 list 用）。
    """
    d = {"pal": []}
    for l in open(path, encoding="ascii"):
        f = l.split()
        if not f:
            continue
        if f[0] == "p":
            d["pal"].append(tuple(int(f[1][i:i + 2], 16) for i in (0, 2, 4)))
        elif f[0] == "pal":
            d["pal_n"] = int(f[1])
        else:
            d[f[0]] = int(f[1])
    return d


def check_cfg(path):
    """配置护栏：合法配置（a/b/c）必须 0，非法用例（d，ANLOGO_X=6）必须 1"""
    st = Stats()
    txt = open(path, encoding="ascii").read().split()
    assert txt and txt[0] == "CFG" and len(txt) == 5, "配置文件格式异常：%r" % txt
    exp = [0, 0, 0, 1]
    for i, (got, want) in enumerate(zip(txt[1:], exp)):
        st.add("A12 配置护栏标志[%d]" % i, int(got) == want,
               "cfg_%s = %s（期望 %d）" % ("abcd"[i], got, want))
    return (not st.bad), st


# ===========================================================================
# 7. main
# ===========================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--rom", default=DEFAULT_ROM)
    ap.add_argument("--stats", default=os.path.join(SIM, "logo_64c.stats.txt"))
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    print("=" * 78)
    print("check_anlogo.py   dir=%s" % a.dir)
    print("=" * 78)
    tab, dflt = parse_anrom(a.rom)
    if CO.AN_IMG is None:
        print("★ 展开图没建起来（logo_64c.hex 或 alg_logo_eram.v 缺失）")
        return 1
    print("  展开图：hex 6400 字 + RTL 调色板 4 份一致 = %s" % CO.AN_PAL_OK)
    print("  展开图：不透明像素 %d（官方素材 %d）"
          % (sum(1 for row in CO.AN_IMG for c in row if c is not None), len(tab)))

    dumps = [("dut_a 真实版面(0,0)", os.path.join(a.dir, "dump_anlogo_a.txt")),
             ("dut_b 错位摆放(X=8)", os.path.join(a.dir, "dump_anlogo_b.txt")),
             ("dut_c 三层优先级", os.path.join(a.dir, "dump_anlogo_c.txt"))]

    if a.selftest:
        print("\n--- 校验器自证：模型侧变异必须被抓住 ---")
        allmut_ok = True
        for mut in ("ignore_an", "color_inv", "no_mask"):
            caught = 0
            for tag, path in dumps:
                ok, st = check_one(tag, path, mut=mut, verbose=False)
                if not ok:
                    caught += 1
            print("  [mut] %-10s -> %s (%d/3 个 dump 抓到)"
                  % (mut, "caught" if caught else "NOT CAUGHT (测试无效!)", caught))
            allmut_ok &= caught > 0
        print("  基线（无变异）：")
        base = all(check_one(t, p, verbose=False)[0] for t, p in dumps)
        print("        -> %s" % ("PASS" if base else "FAIL"))
        print("  自证结论：%s" % ("变异全被抓 + 基线通过" if (allmut_ok and base)
                                  else "★ 有变异漏网或基线不过"))
        return 0 if (allmut_ok and base) else 1

    print("\n--- 独立断言 1：编码保真度（展开图 vs 官方素材）---")
    global FID_STATS
    FID_STATS = load_stats(a.stats)
    # RTL 里的调色板 → [(r,g,b) × 63]，口径与台账的 p 行一致
    rtl_pal = [((CO.AN_PAL[i] >> 16) & 0xFF, (CO.AN_PAL[i] >> 8) & 0xFF,
                CO.AN_PAL[i] & 0xFF) for i in range(1, 64)]
    assert CO.AN_PAL[0] == 0, "调色板 index 0 必须是 0（透明占位）"
    fid_ok, fid_st = check_fidelity(tab, rtl_pal)
    print("  %-34s %10s %8s" % ("断言", "检查次数", "失配"))
    for k in sorted(fid_st.chk):
        print("  %-34s %10d %8d%s" % (k, fid_st.chk[k], fid_st.bad.get(k, 0),
                                      "" if not fid_st.bad.get(k) else "   <<<"))
    for k in sorted(fid_st.sam):
        for s in fid_st.sam[k][:2]:
            print("        " + s)

    print("\n--- 独立断言 2：配置护栏（ANLOGO_X %% 4）---")
    cfg_ok, cfg_st = check_cfg(os.path.join(a.dir, "dump_anlogo_cfg.txt"))
    for k in sorted(cfg_st.chk):
        print("  %-34s %10d %8d%s" % (k, cfg_st.chk[k], cfg_st.bad.get(k, 0),
                                      "" if not cfg_st.bad.get(k) else "   <<<"))
    for k in sorted(cfg_st.sam):
        for s in cfg_st.sam[k][:2]:
            print("        " + s)

    print("\n--- 逐 dump 像素断言 ---")
    ok = fid_ok and cfg_ok
    for tag, path in dumps:
        o, _ = check_one(tag, path)
        ok &= o
    print("-" * 78)
    print("总判定：%s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
