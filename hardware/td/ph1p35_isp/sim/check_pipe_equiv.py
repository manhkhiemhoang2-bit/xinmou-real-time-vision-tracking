#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_pipe_equiv.py —— 流水级改造的**逐拍等价性证明**

⚠⚠ 2026-09-16 起本脚本**降级为历史证据，不要再当放行门禁**：
    它把"改造前 v1.1"当金标准，而 v1.1 的 O_tvalid/O_tlast/O_tuser 比 O_tdata
    **晚 1 拍**（真 bug；实测见 sim/_skew_work/tb_skew_probe.v + sim/check_skew.py：
    O_tuser=1 那一拍携带的是 beat 1 而不是 beat 0）。v1.3 修掉该错位后，本脚本的
    判据 "dut[i] == ref[i-1]" 必然在控制位上失配 —— 那是**预期行为**，不是回归。
    v1.3 起的放行门禁是 **sim/check_contract.py**（输出流必须恰好 = 输入流延迟 2 拍、
    四路同拍、O_tuser 那拍必须是 beat 0、有效期不许携带气泡数据），
    变异自证见 sim/rtl_mutation_align.py。
    本脚本仍可用于复核"v1.2 的流水级确实只加了 1 拍延迟"这一历史结论。

判据（全部只用"改造前的 RTL"作期望值，**不读任何 DUT 内部信号**）：
  A. 逐拍等价：dut[i] == ref[i-1]（4 路输出整体 96+3 bit），失配数必须为 **0**
  B. 反证 0 拍：dut[i] != ref[i]   必须成立，失配数必须 **> 0**
  C. 反证 2 拍：dut[i] != ref[i-2] 必须成立，失配数必须 **> 0**
  D. 激励覆盖：文字区 / Logo 区 / 重叠区 / 都不命中区、复位、以及
     I_info_x / I_info_lat 的 8 个边界值（0,9,10,99,100,999,1000,1999）都要走到
     —— 每一项都必须 > 0 次，否则算失败（0 次检查 = 失败）

相位怎么来的：**从激励反解**，不假设常数。像素值图是严格单射的
    pix = (beat<<7) | ((beat%32)<<2) | ch
所以 dump 里 I_tdata 每个像素自带拍号，可以直接算"第 i 拍输出对应第几拍输入"。

用法：
    python check_pipe_equiv.py [--dump dump_pe.txt]
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))

# 版面/规模由 dump 首行 H 头给出（TB 侧驱动），这里只是默认值
BPL = 64
BPF = 64 * 64
NBEAT = BPF * 8
TEXT_X, TEXT_Y = 0, 16
LOGO_X, LOGO_Y = 40, 0
BOUNDARY = (0, 9, 10, 99, 100, 999, 1000, 1999)


# ===========================================================================
# 1. 激励自带的像素编码（严格单射，可反解拍号）
# ===========================================================================
def pix(beat, ch):
    return (beat << 7) | ((beat % 32) << 2) | ch


def decode_beat(v, ch):
    """v 若是 pix(beat,ch) 则返回 beat，否则 None（替换过的像素解不出来）"""
    if (v & 0x3) != ch:
        return None
    b = v >> 7
    if b >= NBEAT:
        return None
    if pix(b, ch) != v:
        return None
    return b


def row_beats(tdata_hex):
    """一拍 4 个像素里能反解出拍号的那些（集合）"""
    v = int(tdata_hex, 16)
    out = set()
    for ch in range(4):
        b = decode_beat((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
        if b is not None:
            out.add(b)
    return out


# ===========================================================================
# 2. 解析 dump
# ===========================================================================
def parse(path):
    global BPL, BPF, NBEAT, TEXT_X, TEXT_Y, LOGO_X, LOGO_Y
    rows = []
    hdr = None
    for ln in open(path, "r", encoding="ascii", errors="replace"):
        f = ln.split()
        if not f:
            continue
        if f[0] == "H":
            hdr = [int(v) for v in f[1:]]
            (w, h, LOGO_X, LOGO_Y, TEXT_X, TEXT_Y, BPF, NBEAT) = hdr
            BPL = w // 4
            continue
        if len(f) < 19:
            continue
        rows.append({
            "cyc": int(f[0]), "rstn": int(f[1]),
            "Iv": int(f[2]), "Il": int(f[3]), "Iu": int(f[4]), "Id": f[5],
            "beat": int(f[6]),
            "Rv": int(f[7]), "Rl": int(f[8]), "Ru": int(f[9]), "Rd": f[10],
            "Dv": int(f[11]), "Dl": int(f[12]), "Du": int(f[13]), "Dd": f[14],
            "lat": int(f[15], 16), "x": int(f[16], 16),
            "mode": int(f[17], 16), "fps": int(f[18], 16),
        })
    assert hdr is not None, "dump 没有 H 头"
    return rows


REF = ("Rv", "Rl", "Ru", "Rd")
DUT = ("Dv", "Dl", "Du", "Dd")
# (dut 列, ref 列, 字段名, 是否十六进制数据)
FIELDS = (("Dd", "Rd", "tdata", True),
          ("Dv", "Rv", "tvalid", False),
          ("Dl", "Rl", "tlast", False),
          ("Du", "Ru", "tuser", False))
FNAMES = tuple(f[2] for f in FIELDS)


def tuplediff(r, i, ref_i, shift):
    """返回 4 个字段里不等的字段名列表"""
    if ref_i < 0 or ref_i >= len(r):
        return None
    bad = []
    for dk, rk, name, ishex in FIELDS:
        a = r[i][dk]
        b = r[ref_i][rk]
        if ishex:
            same = int(a, 16) == int(b, 16)
        else:
            same = a == b
        if not same:
            bad.append(name)
    return bad


# ===========================================================================
# 3. 主校验
# ===========================================================================
def run(dump, verbose=True):
    rows = parse(dump)
    n = len(rows)
    assert n > 1000, "dump 太短：%d 行" % n

    n_err = 0
    samples = []

    def err(msg):
        nonlocal n_err
        n_err += 1
        if len(samples) < 12:
            samples.append(msg)

    # ---- A/B/C：三个延迟假设的逐拍比对 ----
    # ⚠ 异步复位窗口单独处理：复位是**同时**加到两版 RTL 上的（不是被延迟的），
    #   复位期间两侧输出都被立刻清 0，所以"延迟 1 拍"的关系在复位沿那一拍必然
    #   不成立 —— 这不是偏差，是复位语义本身。这里把两侧都不在复位窗口的拍拿来
    #   做 A 判定，复位窗口内的拍另做 D3 判定（两侧必须都为 0）。
    stat = {}
    for sh in (0, 1, 2, 3):
        cnt = 0        # 实际比较过的拍数（= 检查次数）
        bad = 0
        n_rst = 0      # 因复位窗口被排除的拍
        per_field = dict((f, 0) for f in FNAMES)
        first = None
        for i in range(n):
            j = i - sh
            if j < 0:
                continue
            if rows[i]["rstn"] == 0 or rows[j]["rstn"] == 0:
                n_rst += 1
                continue
            d = tuplediff(rows, i, j, sh)
            cnt += 1
            if d:
                bad += 1
                for f in d:
                    per_field[f] += 1
                if first is None:
                    first = (rows[i]["cyc"], d, rows[i]["Dd"], rows[j]["Rd"])
        stat[sh] = (cnt, bad, per_field, first, n_rst)

    # 正确性断言（延迟 1 拍）
    cnt1, bad1, pf1, first1, nrst1 = stat[1]
    if cnt1 == 0:
        err("延迟 1 拍：0 次比较 —— 检查是空的")
    if bad1:
        err("延迟 1 拍：%d/%d 拍不等（应当为 0）first=%s" % (bad1, cnt1, first1))
    # 反证：延迟 0 拍 / 2 拍必须不成立
    for sh in (0, 2, 3):
        cnt, bad, _pf, _f, _nr = stat[sh]
        if cnt == 0:
            err("反证 %d 拍：0 次比较 —— 检查是空的" % sh)
        if bad == 0:
            err("反证 %d 拍：失配 0 —— 说明比对口径错了（延迟 %d 拍也与实际全等）" % (sh, sh))

    # ---- D3：异步复位期间，两侧输出必须都被清 0 ----
    n_rst_chk = 0
    n_rst_bad = 0
    for r in rows:
        if r["rstn"] == 0:
            n_rst_chk += 1
            if any([r["Rv"], r["Rl"], r["Ru"]]) or int(r["Rd"], 16) != 0:
                n_rst_bad += 1
            if any([r["Dv"], r["Dl"], r["Du"]]) or int(r["Dd"], 16) != 0:
                n_rst_bad += 1
    if n_rst_chk == 0:
        err("复位窗口 0 拍 —— 复位没被测到")
    if n_rst_bad:
        err("复位期间有 %d 次输出不为 0" % n_rst_bad)

    # ---- D4：有效拍上不许出现 X/Z ----
    n_xz = 0
    for r in rows:
        for k in ("Id", "Rd", "Dd"):
            if set(r[k]) & set("xXzZ"):
                n_xz += 1
                break
    if n_xz:
        err("有 %d 拍的输出/输入含 X/Z" % n_xz)

    # ---- D1：位移 1 拍时每个字段各自的检查次数（不许有字段 0 次） ----
    active = dict((f, 0) for f in FNAMES)
    for i in range(1, n):
        j = i - 1
        for dk, rk, name, ishex in FIELDS:
            a = rows[i][dk]
            b = rows[j][rk]
            av = int(a, 16) if ishex else a
            bv = int(b, 16) if ishex else b
            if av or bv:
                active[name] += 1
    for f in FNAMES:
        if active[f] == 0:
            err("字段 %s 在位移 1 拍下 0 次非零比较 —— 该字段没被真正测到" % f)

    # ---- D2：区域覆盖（用激励自带拍号算像素坐标，不读 DUT 探针） ----
    n_valid = 0
    n_reset = 0
    n_replaced = 0
    zone = {"text_only": 0, "logo_only": 0, "both": 0, "neither": 0}
    lat_seen = dict((v, 0) for v in BOUNDARY)
    x_seen = dict((v, 0) for v in BOUNDARY)
    mode_seen = set()
    for i in range(1, n):
        r, p = rows[i], rows[i - 1]        # dut[i] 用的是 ref[i-1] = 输入第 i-1 拍
        if r["rstn"] == 0:
            n_reset += 1
        if p["Iv"] != 1:
            continue
        n_valid += 1
        if p["lat"] in lat_seen:
            lat_seen[p["lat"]] += 1
        if p["x"] in x_seen:
            x_seen[p["x"]] += 1
        mode_seen.add(p["mode"])
        # 从输入那一拍的像素反解拍号（严格单射）
        v = int(p["Id"], 16)
        for ch in range(4):
            b = decode_beat((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
            if b is None:
                continue
            xx = 4 * (b % BPL) + ch
            yy = b // BPL
            in_txt = (TEXT_X <= xx < TEXT_X + 16 * 16) and (TEXT_Y <= yy < TEXT_Y + 16)
            in_log = (LOGO_X <= xx < LOGO_X + 128) and (LOGO_Y <= yy < LOGO_Y + 64)
            if in_txt and in_log:
                zone["both"] += 1
            elif in_txt:
                zone["text_only"] += 1
            elif in_log:
                zone["logo_only"] += 1
            else:
                zone["neither"] += 1
            # 是否被 OSD 替换过（与"原样透传"应有的值比）
            got = (int(r["Dd"], 16) >> (72 - 24 * ch)) & 0xFFFFFF
            if got != pix(b, ch):
                n_replaced += 1

    for k, v in zone.items():
        if v == 0:
            err("区域 %s 一个像素都没有 —— 覆盖不足" % k)
    for v in BOUNDARY:
        if lat_seen[v] == 0:
            err("I_info_lat 边界值 %d 没走到" % v)
        if x_seen[v] == 0:
            err("I_info_x 边界值 %d 没走到" % v)
    if n_reset == 0:
        err("没有复位拍")
    if n_replaced == 0:
        err("没有任何像素被 OSD 替换 —— 混合通路没被测到")
    if len(mode_seen) < 6:
        err("I_info_mode 只走到 %d 种取值" % len(mode_seen))

    # ---- 报告 ----
    if verbose:
        print("dump                : %s (%d 拍)" % (dump, n))
        print("A 正确性 dut[i]==ref[i-1] : 检查 %d 拍 / 失配 %d  (tdata %d, tvalid %d, tlast %d, tuser %d)"
              % (cnt1, bad1, pf1["tdata"], pf1["tvalid"], pf1["tlast"], pf1["tuser"]))
        for sh in (0, 1, 2, 3):
            cnt, bad, _pf, _f, nr = stat[sh]
            tag = "  <-- 正确" if sh == 1 else "  (反证，必须 >0)"
            print("B/C dut[i]==ref[i-%d]     : 检查 %d 拍 / 失配 %d%s  [排除复位窗口 %d 拍]"
                  % (sh, cnt, bad, tag, nr))
        print("D3 复位窗口清 0           : 检查 %d 拍 / 违例 %d" % (n_rst_chk, n_rst_bad))
        print("D4 X/Z 检查               : %d 拍含 X/Z" % n_xz)
        print("字段非零比较次数          : " +
              ", ".join("%s %d" % (f, active[f]) for f in FNAMES))
        print("有效输入拍                : %d ; 复位拍 %d ; 被替换像素 %d" % (n_valid, n_reset, n_replaced))
        print("区域像素                  : text_only %d, logo_only %d, both %d, neither %d"
              % (zone["text_only"], zone["logo_only"], zone["both"], zone["neither"]))
        print("I_info_lat 边界覆盖       : %s" % ", ".join(
            "%d:%d" % (v, lat_seen[v]) for v in BOUNDARY))
        print("I_info_x   边界覆盖       : %s" % ", ".join(
            "%d:%d" % (v, x_seen[v]) for v in BOUNDARY))
        print("I_info_mode 取值集合      : %s" % sorted(mode_seen))

    if n_err:
        print("  FAIL: %d error(s)" % n_err)
        for s in samples:
            print("    " + s)
        return False
    print("  PASS: %d 拍逐 bit 等价（延迟 1 拍）；延迟 0/2 拍的反例 %d/%d 拍"
          % (cnt1, stat[0][1], stat[2][1]))
    return True


def main():
    argv = sys.argv[1:]
    dump = os.path.join(HERE, "_pipe_work", "dump_pe.txt")
    if "--dump" in argv:
        dump = argv[argv.index("--dump") + 1]
    print("check_pipe_equiv.py  dump=%s" % dump)
    sys.exit(0 if run(dump) else 1)


if __name__ == "__main__":
    main()
