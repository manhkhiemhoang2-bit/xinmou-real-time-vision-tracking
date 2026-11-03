#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
_probe_rtlmodel.py —— alg_region_fill_96（v3.1）的**逐拍复刻模型** + 抽头来源探针

用途：
  1) 保真性证明：模型逐拍跑出的 dump 字段必须与 ModelSim 真 dump 一致。
  2) 定死几何：给行缓存 / 位移链里的每个 bit 打上来源标签 (row, grp, col)，
     于是 15 个抽头的绝对坐标是**实测打印**出来的，不是靠推理推出来的。
  3) 不开 ModelSim 做组合实验（taps / reset / 参考位移 三口径扫描）。

用法：
    python _probe_rtlmodel.py                 # 保真性比对 + 抽头来源表
    python _probe_rtlmodel.py --taps --rows 2 --beats 4
    python _probe_rtlmodel.py --eoff          # 窗口的"行"归属直接测量
    python _probe_rtlmodel.py --sweep         # 抽头 x 清零 x 参考位移 组合扫描
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ref_region_fill as R  # noqa: E402

WHITE = R.WHITE


def load_stim(path):
    b = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if s:
                b.append([int(s[i:i + 6], 16) for i in (0, 6, 12, 18)])
    return np.array(b, dtype=np.uint32)


def _bit(word, i):
    return (word >> i) & 1


class Tap:
    """一个抽头：值 + 来源标签 (row, grp, col)。row 为 None 表示来源未定义。"""
    __slots__ = ("v", "row", "grp", "col")

    def __init__(self, v=0, row=None, grp=None, col=None):
        self.v = int(v)
        self.row = row
        self.grp = grp
        self.col = col

    def __repr__(self):
        return "x" if self.row is None else "y%d/c%d" % (self.row, self.col)


def model(stim, W, H, *, reset_mode="cur", bot4_mode="bus", bubbles=True,
          taps_mode="cur", mask_rows=2, rst_cyc=4, start_cyc=6, bub_period=37,
          bub_skip=2, ncyc=None):
    """逐拍复刻 RTL。

    reset_mode : "cur"        —— 现在的 RTL（r_tlast/r_tuser 再打一拍的 r_clr）
                 "rowhead"    —— 行首入口状态强制 0（判据 = 输出侧拍号 r_x）
                 "rowhead_la" —— 同上，写成"行末拍置 0 ⇒ 下一拍行首入口为 0"
    bot4_mode  : "bus"  = 现在的 RTL（w_bot_4 = w_w0，输入总线前瞻）；"zero" = 恒 0
    taps_mode  : "cur"  = 现在的 RTL（上/中行取 s2，左邻取 r_bl2/r_bl3）
                 "fixed" = 上/中行改取 s1（本组）+ 读口新值（右邻）+ s2[3]（左邻）
    """
    BPL = W // 4
    BPF = BPL * H
    N = stim.shape[0]
    LAST_BEAT = BPL - 1

    x_grp = y_pos = 0
    r_x = r_y = 0
    r_word = Tap()
    r_word_row, r_word_grp = None, None
    r_vld1 = r_tlast = r_tuser = r_clr = 0
    r_inside = r_edge_prev = 0
    r_vld2 = r_last2 = r_user2 = 0
    r_fill2 = [0] * 4
    O_v = O_l = O_u = 0
    O_d = [0] * 4
    l1, l2 = {}, {}
    c1 = [Tap() for _ in range(3)]          # [0]=r_rd1(新) [1]=s1 [2]=s2(旧)
    c2 = [Tap() for _ in range(3)]
    r_bl1 = r_bl2 = r_bl3 = Tap()

    dump, trace, out_beats = [], [], []
    tb_beat = 0
    last_drv = 0
    c = 0
    while True:
        allow = ((tb_beat % BPF) == 0) or ((c % bub_period) >= bub_skip)
        if not bubbles:
            allow = True
        drv = (c >= start_cyc) and (tb_beat < N) and allow
        if drv:
            last_drv = c
        tdata = stim[tb_beat] if drv else np.zeros(4, dtype=np.uint32)
        piv = [int(p == WHITE) for p in tdata]
        iv = 1 if drv else 0
        il = 1 if (drv and (tb_beat % BPL) == LAST_BEAT) else 0
        iu = 1 if (drv and (tb_beat % BPF) == 0) else 0
        masks = (piv[0] << 3) | (piv[1] << 2) | (piv[2] << 1) | piv[3]

        idat = (int(tdata[0]) << 72) | (int(tdata[1]) << 48) | \
               (int(tdata[2]) << 24) | int(tdata[3])
        odat = (O_d[0] << 72) | (O_d[1] << 48) | (O_d[2] << 24) | O_d[3]
        dump.append((c, iv, il, iu, idat, O_v, O_l, O_u, odat,
                     r_inside, r_tlast, r_tuser, r_vld1))
        if O_v:
            out_beats.append(list(O_d))

        # ---------------- 组合逻辑（第 1 级）----------------
        win_valid = 1 if (r_y >= mask_rows and r_x != 0 and r_tuser == 0) else 0
        if taps_mode == "fixed":
            c1c, c1r, c1l = c1[1], c1[0], c1[2]
            c2c, c2r, c2l = c2[1], c2[0], c2[2]
            top = [Tap(0) if r_x == 0 else Tap(_bit(c2l.v, 0), c2l.row, c2l.grp,
                                               None if c2l.grp is None else 4 * c2l.grp + 3),
                   Tap(_bit(c2c.v, 3), c2c.row, c2c.grp, c2c.col),
                   Tap(_bit(c2c.v, 2), c2c.row, c2c.grp,
                       None if c2c.col is None else c2c.col + 1),
                   Tap(_bit(c2c.v, 1), c2c.row, c2c.grp,
                       None if c2c.col is None else c2c.col + 2),
                   Tap(_bit(c2c.v, 0), c2c.row, c2c.grp,
                       None if c2c.col is None else c2c.col + 3),
                   Tap(0) if r_x == LAST_BEAT else Tap(_bit(c2r.v, 3), c2r.row, c2r.grp,
                                                       c2r.col)]
            mid = [Tap(0) if r_x == 0 else Tap(_bit(c1l.v, 0), c1l.row, c1l.grp,
                                               None if c1l.grp is None else 4 * c1l.grp + 3),
                   Tap(_bit(c1c.v, 3), c1c.row, c1c.grp, c1c.col),
                   Tap(_bit(c1c.v, 2), c1c.row, c1c.grp,
                       None if c1c.col is None else c1c.col + 1),
                   Tap(_bit(c1c.v, 1), c1c.row, c1c.grp,
                       None if c1c.col is None else c1c.col + 2),
                   Tap(_bit(c1c.v, 0), c1c.row, c1c.grp,
                       None if c1c.col is None else c1c.col + 3),
                   Tap(0) if r_x == LAST_BEAT else Tap(_bit(c1r.v, 3), c1r.row, c1r.grp,
                                                       c1r.col)]
        else:
            top = [Tap(0) if r_x == 0 else Tap(_bit(c2[2].v, 3), c2[2].row, c2[2].grp,
                                               None if c2[2].col is None
                                               else c2[2].col - 1),
                   Tap(_bit(c2[2].v, 3), c2[2].row, c2[2].grp, c2[2].col),
                   Tap(_bit(c2[2].v, 2), c2[2].row, c2[2].grp,
                       None if c2[2].col is None else c2[2].col + 1),
                   Tap(_bit(c2[2].v, 1), c2[2].row, c2[2].grp,
                       None if c2[2].col is None else c2[2].col + 2),
                   Tap(_bit(c2[2].v, 0), c2[2].row, c2[2].grp,
                       None if c2[2].col is None else c2[2].col + 3),
                   Tap(0) if r_x == LAST_BEAT else Tap(_bit(c2[1].v, 3), c2[1].row,
                                                       c2[1].grp, c2[1].col)]
            mid = [Tap(0) if r_x == 0 else Tap(r_bl2.v, r_bl2.row, r_bl2.grp, r_bl2.col),
                   Tap(_bit(c1[2].v, 3), c1[2].row, c1[2].grp, c1[2].col),
                   Tap(_bit(c1[2].v, 2), c1[2].row, c1[2].grp,
                       None if c1[2].col is None else c1[2].col + 1),
                   Tap(_bit(c1[2].v, 1), c1[2].row, c1[2].grp,
                       None if c1[2].col is None else c1[2].col + 2),
                   Tap(_bit(c1[2].v, 0), c1[2].row, c1[2].grp,
                       None if c1[2].col is None else c1[2].col + 3),
                   Tap(0) if r_x == LAST_BEAT else Tap(_bit(c1[1].v, 3), c1[1].row,
                                                       c1[1].grp, c1[1].col)]
        if bot4_mode in ("ideal", "late", "bus1"):
            # 底行右邻 = 行内**下一组**的首像素 = 激励里 index == tb_beat 的那一拍
            # （气泡时 tb_beat 不前进 ⇒ stim[tb_beat] 正好是"还没发出来的那一拍"）
            if r_x != LAST_BEAT and tb_beat < N:
                nx = int(stim[tb_beat][0] == WHITE)
                if bot4_mode == "ideal":
                    ok = True
                else:
                    lim = 1 if bot4_mode == "bus1" else 2
                    ok = False
                    dd = 0                          # 到 c+n 为止已发出的拍数
                    for n in range(1, lim + 1):
                        cn = c + n
                        b = tb_beat + dd
                        drive = (cn >= start_cyc) and (b < N) and \
                                (((b % BPF) == 0) or ((cn % bub_period) >= bub_skip))
                        if drive and dd == 0:
                            ok = True               # 缺的那一拍正好在 c+n 发出来
                            break
                        if drive:
                            dd += 1
                b4 = Tap(nx, y_pos, x_grp + 1, 4 * (x_grp + 1)) if ok else Tap(0)
            else:
                b4 = Tap(0)
        elif bot4_mode == "bus":
            b4 = Tap(piv[0], y_pos, x_grp, 4 * x_grp) if drv else Tap(0)
        else:
            b4 = Tap(0)
        bot = [Tap(0) if r_x == 0 else Tap(r_bl1.v, r_bl1.row, r_bl1.grp, r_bl1.col),
               Tap(_bit(r_word.v, 3), r_word_row, r_word_grp,
                   None if r_word_grp is None else 4 * r_word_grp + 0),
               Tap(_bit(r_word.v, 2), r_word_row, r_word_grp,
                   None if r_word_grp is None else 4 * r_word_grp + 1),
               Tap(_bit(r_word.v, 1), r_word_row, r_word_grp,
                   None if r_word_grp is None else 4 * r_word_grp + 2),
               Tap(_bit(r_word.v, 0), r_word_row, r_word_grp,
                   None if r_word_grp is None else 4 * r_word_grp + 3),
               Tap(0) if r_x == LAST_BEAT else b4]
        win = (top, mid, bot)
        e = [0] * 4
        if win_valid:
            for k in range(4):
                e[k] = 1 if any(win[r][k + d].v for r in range(3) for d in range(3)) else 0

        # ---------------- 填充状态机（输出侧：门控 r_vld1）----------------
        entry_ins, entry_prev = r_inside, r_edge_prev
        forced = False
        if reset_mode == "rowhead" and r_vld1 and r_x == 0:
            entry_ins, entry_prev = 0, 0
            forced = True
        rise = [e[0] & (1 - entry_prev), e[1] & (1 - e[0]),
                e[2] & (1 - e[1]), e[3] & (1 - e[2])]
        ins = [entry_ins]
        for k in range(4):
            ins.append(ins[-1] ^ rise[k])
        fill = [e[k] | ins[k] for k in range(4)]

        if r_vld1:
            trace.append((len(trace), c, r_x, r_y, win, e, ins, fill, forced, entry_prev,
                          win_valid))

        # ---------------- 边沿更新（全部用边沿前的值算新值）----------------
        rd_addr = 0 if x_grp == LAST_BEAT else (x_grp + 1) % BPL
        n1 = l1.get(rd_addr, Tap())
        n2 = l2.get(rd_addr, Tap())
        # ⚠ RTL 里整块（写 + 读 + 位移链）都被 I_tvalid 门控：
        #   气泡拍不写、不读、链也不移位。模型曾经漏了这个门控（链照移），
        #   于是气泡后的抽头会整体偏一组 —— 那是模型错，不是 RTL 错。
        if iv:
            n_c1 = [Tap(n1.v, n1.row, n1.grp,
                        4 * n1.grp if n1.grp is not None else None), c1[0], c1[1]]
            n_c2 = [Tap(n2.v, n2.row, n2.grp,
                        4 * n2.grp if n2.grp is not None else None), c2[0], c2[1]]
        else:
            n_c1 = list(c1)
            n_c2 = list(c2)
        n_l1, n_l2 = dict(l1), dict(l2)
        if iv:
            n_l2[x_grp] = c1[0]
            n_l1[x_grp] = Tap(masks, y_pos, x_grp, None)

        n_f2 = [WHITE if fill[k] else 0 for k in range(4)] if r_vld1 else r_fill2
        n_Od = list(r_fill2) if r_vld2 else [0, 0, 0, 0]
        n_Ov, n_Ol, n_Ou = r_vld2, (r_last2 if r_vld2 else 0), (r_user2 if r_vld2 else 0)

        n_inside, n_eprev = r_inside, r_edge_prev
        if r_vld1:
            if reset_mode == "cur":
                if r_clr:
                    n_inside, n_eprev = 0, 0
                else:
                    n_inside, n_eprev = ins[4], e[3]
            elif reset_mode == "rowhead_la":
                if r_x == LAST_BEAT:
                    n_inside, n_eprev = 0, 0
                else:
                    n_inside, n_eprev = ins[4], e[3]
            else:
                n_inside, n_eprev = ins[4], e[3]

        n_word, n_word_row, n_word_grp = r_word, r_word_row, r_word_grp
        n_bl1, n_bl2, n_bl3 = r_bl1, r_bl2, r_bl3
        if iv:
            n_bl1 = Tap(_bit(r_word.v, 0), r_word_row, r_word_grp,
                        4 * r_word_grp + 3 if r_word_grp is not None else None)
            n_bl2, n_bl3 = r_bl1, r_bl2
            n_word = Tap(masks, y_pos, x_grp, None)
            n_word_row, n_word_grp = y_pos, x_grp

        n_xg, n_yp = x_grp, y_pos
        if iv:
            if tb_beat % BPF == 0:
                n_xg, n_yp = 1 % BPL, 0
            elif x_grp == LAST_BEAT:
                n_xg, n_yp = 0, (0 if y_pos == H - 1 else y_pos + 1)
            else:
                n_xg = x_grp + 1

        r_clr_new = 1 if (r_tlast or r_tuser) else 0

        l1, l2 = n_l1, n_l2
        c1, c2 = n_c1, n_c2
        r_fill2, O_d = n_f2, n_Od
        O_v, O_l, O_u = n_Ov, n_Ol, n_Ou
        r_inside, r_edge_prev = n_inside, n_eprev
        r_clr = r_clr_new
        r_word, r_word_row, r_word_grp = n_word, n_word_row, n_word_grp
        r_bl1, r_bl2, r_bl3 = n_bl1, n_bl2, n_bl3
        r_vld2, r_last2, r_user2 = r_vld1, r_tlast, r_tuser
        r_vld1 = iv
        if iv:
            r_tlast, r_tuser = il, iu
        r_x, r_y = x_grp, y_pos
        x_grp, y_pos = n_xg, n_yp
        if drv:
            tb_beat += 1
        c += 1
        if ncyc is not None and c >= ncyc:
            break
        if (tb_beat >= N) and (c >= last_drv + 3 + 20):
            break
    return {"dump": dump, "trace": trace, "out_beats": out_beats,
            "BPL": BPL, "BPF": BPF, "N": N}


# ===========================================================================
# 保真性：模型 dump vs ModelSim 真 dump
# ===========================================================================
def validate(dump_path="dump_rf.txt", stim_path="stim_rf.hex"):
    import check_region_fill as C
    d = C.load_dump(os.path.join(HERE, dump_path))
    stim = load_stim(os.path.join(HERE, stim_path))
    res = model(stim, 32, 10)
    dl = res["dump"]
    n = min(len(dl), len(d["cyc"]))
    keys = ("cyc", "iv", "il", "iu", "id", "ov", "ol", "ou", "od", "ins",
            "rtl", "rtu", "rv1")
    bad = {k: 0 for k in keys}
    first = None
    for i in range(n):
        got = (int(d["cyc"][i]), int(d["iv"][i]), int(d["il"][i]), int(d["iu"][i]),
               int(d["id"][i]), int(d["ov"][i]), int(d["ol"][i]), int(d["ou"][i]),
               int(d["od"][i]), int(d["ins"][i]), int(d["rtl"][i]), int(d["rtu"][i]),
               int(d["rv1"][i]))
        exp = dl[i]
        for j, k in enumerate(keys):
            if got[j] != exp[j]:
                bad[k] += 1
                if first is None:
                    first = (i, k, got[j], exp[j])
    print("== 模型保真性（模型 dump vs ModelSim 真 dump）==")
    print("   dump 行数: 真 %d / 模型 %d   (比对 %d 行)" % (len(d["cyc"]), len(dl), n))
    tot = sum(bad.values())
    for k in keys:
        print("   %-4s 失配 %d" % (k, bad[k]))
    if first:
        print("   首个不一致: 行%d 字段%s 真=%s 模型=%s" % first)
    print("   RESULT: %s" % ("FIDELITY-OK" if tot == 0 else "FIDELITY-FAIL"))
    return tot == 0


# ===========================================================================
# 抽头来源表 / 行归属测量 / 组合扫描
# ===========================================================================
def taps_table(stim, W, H, rows=2, beats=20, taps_mode="cur", reset_mode="cur"):
    res = model(stim, W, H, reset_mode=reset_mode, taps_mode=taps_mode)
    tr = res["trace"]
    print("== 抽头来源表（模型，taps=%s）：坐标 = (行, 列) ==" % taps_mode)
    sel = [t for t in tr if t[3] < rows]
    for (_, c, rx, ry, win, e, ins, fill, forced, prev, wv) in sel[:max(rows, 1) * beats]:
        top, mid, bot = win

        def fmt(t):
            return "x" if t.row is None else "%d/%d" % (t.row, t.col)
        print("   beat y=%d x=%d wv=%d | top %s | mid %s | bot %s | e=%s"
              % (ry, rx, wv,
                 " ".join(fmt(t) for t in top), " ".join(fmt(t) for t in mid),
                 " ".join(fmt(t) for t in bot), "".join(str(v) for v in e)))
    return res


def e_row_offset(W, H, F, stim, taps_mode="fixed", reset_mode="rowhead_la", bubbles=True):
    """直接量：模型逐拍算出的 e（膨胀结果）对应参考的**第几行**膨胀图。

    k = 0 ⇒ 窗口算的就是输出行的膨胀（正确）；k = -1 ⇒ 算的是上一行的膨胀。
    只统计 w_win_valid=1 的拍（被掩蔽的拍 e 恒 0，没有信息）。
    """
    res = model(stim, W, H, taps_mode=taps_mode, reset_mode=reset_mode, bubbles=bubbles)
    BPL, BPF = res["BPL"], res["BPF"]
    tr = res["trace"]
    offs = {}
    for f in range(F):
        mask = (stim[f * BPF:(f + 1) * BPF] == WHITE).reshape(H, W)
        D = R.dilate3x3(mask)
        for i in range(BPF):
            (_, c, rx, ry, win, e, ins, fill, forced, prev, wv) = tr[f * BPF + i]
            if not wv:
                continue
            for k in range(-2, 3):
                y2 = ry + k
                if y2 < 0 or y2 >= H:
                    continue
                o = offs.setdefault(k, [0, 0])
                for j in range(4):
                    o[1] += 1
                    if int(D[y2, 4 * rx + j]) != e[j]:
                        o[0] += 1
    return offs


def cmp_ref(W, H, F, stim, reset_mode="cur", bot4_mode="bus", bubbles=True,
            taps_mode="cur", row_shift=0, mask_rows=2):
    res = model(stim, W, H, reset_mode=reset_mode, bot4_mode=bot4_mode,
                bubbles=bubbles, taps_mode=taps_mode, mask_rows=mask_rows)
    BPL, BPF = res["BPL"], res["BPF"]
    ob = np.array(res["out_beats"], dtype=np.uint32).reshape(-1, 4)
    bad = 0
    shapes = []
    per_frame = []
    for f in range(F):
        b = stim[f * BPF:(f + 1) * BPF]
        o = ob[f * BPF:(f + 1) * BPF]
        mask = (b == WHITE).reshape(H, W)
        edge = R.dilate3x3(mask)
        filled, _ = R.scanline_fill_masked(edge, W, H)
        exp = R.bool_to_mask(filled).reshape(H, W)
        exp_s = np.zeros_like(exp)
        if row_shift == 0:
            exp_s = exp
        elif row_shift > 0:
            exp_s[row_shift:, :] = exp[:-row_shift, :]
        else:
            exp_s[:row_shift, :] = exp[-row_shift:, :]
        e4 = exp_s.reshape(-1, 4)
        d = e4 != o
        n = int(d.sum())
        bad += n
        per_frame.append(n)
        if n:
            idx = np.nonzero(d.any(axis=1))[0]
            for k in idx[:6]:
                r, g = k // BPL, k % BPL
                cols = [g * 4 + j for j in range(4) if d[k, j]]
                shapes.append((f, int(r), cols, [int(v) for v in e4[k]],
                               [int(v) for v in o[k]]))
    return bad, per_frame, shapes, ob


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--taps", action="store_true")
    ap.add_argument("--fix", default=None, choices=["cur", "rowhead", "rowhead_la", "none"])
    ap.add_argument("--sweep", action="store_true")
    ap.add_argument("--eoff", action="store_true")
    ap.add_argument("--bubbles", default="1")
    ap.add_argument("--rows", type=int, default=2)
    ap.add_argument("--beats", type=int, default=20)
    a = ap.parse_args()

    meta = json.load(open(os.path.join(HERE, "meta_rf.json"), encoding="utf-8"))
    W, H, F = meta["W"], meta["H"], meta["frames"]
    stim = load_stim(os.path.join(HERE, "stim_rf.hex"))
    bub = a.bubbles == "1"

    if a.taps or (not a.fix and not a.sweep and not a.eoff):
        if not validate():
            print("!! 模型与真 dump 不一致 —— 先修模型，别改 RTL")
            return 1
        taps_table(stim, W, H, rows=a.rows, beats=a.beats)

    if a.eoff:
        print("== 窗口的**行**归属直接测量（模型 e 比特 vs 参考膨胀图第 y+k 行）==")
        print("   k=-1 ⇒ 窗口算的是上一行的膨胀（输出整体晚一行）；k=0 ⇒ 窗口中心=输出行")
        for tm in ("cur", "fixed"):
            offs = e_row_offset(W, H, F, stim, taps_mode=tm)
            print("   taps=%s" % tm)
            for k in range(-2, 3):
                if k in offs:
                    b, t = offs[k]
                    print("      k=%+d : e 比特失配 %4d / %4d  (%.1f%%)"
                          % (k, b, t, 100.0 * b / max(t, 1)))

    if a.fix:
        for bm in ("bus", "zero"):
            bad, pf, shapes, _ = cmp_ref(W, H, F, stim, reset_mode=a.fix,
                                         bot4_mode=bm, bubbles=bub)
            print("reset=%-10s bot4=%-4s bubbles=%d -> 失配 %4d  逐帧 %s"
                  % (a.fix, bm, int(bub), bad, pf))
            for s in shapes[:8]:
                print("      f%d y%d cols%s  ref=%s dut=%s" % s)

    if a.sweep:
        print("== 组合扫描（不开 ModelSim）：抽头口径 x 清零口径 x 参考位移 ==")
        print("   taps=cur   = 现在的 RTL（上/中行取 s2，左邻取 r_bl2/r_bl3）")
        print("   taps=fixed = 上/中行改取 s1（本组）+ 读口新值（右邻）+ s2[3]（左邻）")
        print("   %-11s %-11s %-6s %-6s %s" % ("taps", "reset", "shift", "失配", "逐帧"))
        for tm in ("cur", "fixed"):
            for rm in ("cur", "rowhead_la"):
                for sh in (0, 1, -1):
                    bad, pf, _, _ = cmp_ref(W, H, F, stim, reset_mode=rm,
                                            taps_mode=tm, row_shift=sh, bubbles=bub)
                    print("   %-11s %-11s %+4d  %6d   %s" % (tm, rm, sh, bad, pf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
