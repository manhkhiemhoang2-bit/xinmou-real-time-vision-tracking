#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_probe_cmp.py —— 用探针 dump 把 M7 支路与 Python 参考模型**按拍序**对齐。

做法（不做坐标推理，按"有效拍序列"对齐，lag 用扫描定）：
  · 探针里 u_rf.I_tvalid 为 1 的周期 = 填充模块的输入拍；取最后 2560 个 = 帧 7。
  · ① 输入流  ：这些周期的 I_tdata 序列  vs  参考的"二值 M3 帧 7"逐拍展开
  · ② 膨胀 e  ：这些周期的 e0..e3    vs  参考 dilate3x3 逐拍展开（lag 扫描）
  · ③ 输出流  ：u_rf.O_tvalid 为 1 的周期里 O_tdata  vs 参考"填充后下移一行"逐拍展开
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                 # noqa: E402
import check_alg_top_full as C       # noqa: E402
import ref_region_fill as RF         # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "_m7dbg", "dump_m7_probe.txt")


def hex4(txt):
    v = int(txt, 16)
    return [(v >> (24 * (3 - k))) & 0xFFFFFF for k in range(4)]


def main():
    rows = []
    with open(DUMP, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                rows.append([t for t in ln.split() if t != "|"])
    n = len(rows)
    p_iv = np.array([int(r[4]) for r in rows], dtype=bool)
    p_ov = np.array([int(r[15]) for r in rows], dtype=bool)
    # %b%b%b%b 不带空格 ⇒ 一个 4 字符 token；bit0（最右）对应 e0
    ebits = [r[11] for r in rows]
    fbits = [r[12] for r in rows]
    ins = np.array([int(r[13]) for r in rows], dtype=bool)
    epv = np.array([int(r[14]) for r in rows], dtype=bool)
    ivc = np.nonzero(p_iv)[0]
    ovc = np.nonzero(p_ov)[0]
    N = C.BPL * C.H
    print("探针 %d 拍；u_rf 输入有效拍 %d（期望 %d）；输出有效拍 %d"
          % (n, ivc.size, 8 * N, ovc.size))
    f7_in = ivc[-N:]
    f7_out = ovc[-N:]

    # ---- 参考 ----
    img = C.images(8)[7]
    bin3 = C.m7_binarize(C.m3_raw(img), C.RF_TH)
    mask = (bin3[:, :, 0] == 255)
    ref_in = mask.reshape(N, 4)                                 # 填充模块输入（逐拍 4 像素）
    e_raw = RF.dilate3x3(mask)
    ref_e = e_raw.reshape(N, 4)
    ref_e_m = (e_raw & ~RF.barrier_mask(C.W, C.H)).reshape(N, 4)
    filled, ref_ins = RF.scanline_fill_masked(e_raw, C.W, C.H)
    ref_out = C._shift1(filled).reshape(N, 4)
    ref_ins_s = C._shift1(ref_ins).reshape(N, 4)

    got_in = np.array([hex4(rows[i][7]) for i in f7_in]) == 0xFFFFFF
    got_e = np.array([[c == "1" for c in ebits[i][::-1]] for i in f7_in], dtype=bool)
    got_f = np.array([[c == "1" for c in fbits[i][::-1]] for i in f7_in], dtype=bool)
    got_ins = ins[f7_in]
    got_out = np.array([hex4(rows[i][17]) for i in f7_out]) == 0xFFFFFF

    print("-" * 76)
    print("① 输入流（同序逐拍）与参考「二值 M3」不符：%d / %d 拍"
          % (int((got_in != ref_in).any(axis=1).sum()), N))
    for lag in (-1, 0, 1):
        a = got_in[max(0, lag):N + min(0, lag)]
        b = ref_in[max(0, -lag):N + min(0, -lag)]
        print("     lag=%+d：不符 %d 拍" % (lag, int((a != b).any(axis=1).sum())))
    print("-" * 76)
    print("② 膨胀 e（未掩蔽）同序 vs 参考 dilate3x3：")
    for lag in (-1, 0, 1):
        a = got_e[max(0, lag):N + min(0, lag)]
        b = ref_e[max(0, -lag):N + min(0, -lag)]
        print("     lag=%+d：不符 %d 拍 / %d" % (lag, int((a != b).any(axis=1).sum()),
                                                 a.shape[0]))
    print("   膨胀 e（掩蔽后）vs 参考 masked dilate：")
    for lag in (-1, 0, 1):
        a = got_e[max(0, lag):N + min(0, lag)]
        b = ref_e_m[max(0, -lag):N + min(0, -lag)]
        print("     lag=%+d：不符 %d 拍" % (lag, int((a != b).any(axis=1).sum())))
    print("-" * 76)
    print("③ 模块内 w_fill0..3 同序 vs 参考 out（未下移）：")
    for lag in (-1, 0, 1):
        a = got_f[max(0, lag):N + min(0, lag)]
        b = filled.reshape(N, 4)[max(0, -lag):N + min(0, -lag)]
        print("     lag=%+d：不符 %d 拍" % (lag, int((a != b).any(axis=1).sum())))
    print("④ u_rf 输出流同序 vs 参考 shift1(fill)：不符 %d / %d 拍"
          % (int((got_out != ref_out).any(axis=1).sum()), N))
    for lag in (-1, 0, 1):
        a = got_out[max(0, lag):N + min(0, lag)]
        b = ref_out[max(0, -lag):N + min(0, -lag)]
        print("     lag=%+d：不符 %d 拍" % (lag, int((a != b).any(axis=1).sum())))
    # 逐拍打印第一处不符的上下文
    d = (got_f != filled.reshape(N, 4)).any(axis=1)
    idx = np.nonzero(d)[0]
    if idx.size:
        print("-" * 76)
        print("w_fill 首错拍 index=%d（行 %d 拍号 %d）" % (idx[0], idx[0] // C.BPL,
                                                          idx[0] % C.BPL))
        for t in range(max(0, idx[0] - 2), min(N, idx[0] + 3)):
            print("  拍 %4d 行 %2d 拍号 %2d  e=%s  fill=%s  参考 e=%s 参考 fill=%s  inside=%d"
                  % (t, t // C.BPL, t % C.BPL,
                     "".join("1" if v else "0" for v in got_e[t]),
                     "".join("1" if v else "0" for v in got_f[t]),
                     "".join("1" if v else "0" for v in ref_e[t]),
                     "".join("1" if v else "0" for v in filled.reshape(N, 4)[t]),
                     int(got_ins[t])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
