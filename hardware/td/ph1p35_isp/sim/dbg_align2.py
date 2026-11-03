#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在 Python 里复刻文字面数据通路，扫描各级延迟，找出与 O_tdata 0 不符的那组。

关键事实（从 dump 实测）：O_tdata[cyc] 携带的像素，其真实坐标要由 I_tdata 的
单射值图反解。所以"渲染是否正确"完全可以用 O_tdata 自身判定。
"""
import sys, os, collections, itertools
sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_osd as C

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.join(HERE, "osd_work")
dl = open(os.path.join(W, "dump_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
hdr, rows = None, []
for ln in dl:
    f = ln.split()
    if not f: continue
    if f[0] == "H": hdr = [int(v) for v in f[1:]]; continue
    if len(f) < 29: continue
    rows.append({"cyc": int(f[0]), "Iv": int(f[1]), "Id": f[4], "Ov": int(f[5]), "Od": f[8],
                 "rx": int(f[17], 16), "ry": int(f[18], 16), "nx": int(f[19], 16),
                 "ny": int(f[20], 16), "xg": int(f[21], 16), "yp": int(f[22], 16),
                 "beat": int(f[23])})
cfg = C.Config(*hdr)
pl = open(os.path.join(W, "probe_osd.txt"), encoding="ascii", errors="replace").read().splitlines()
PR = {}
for ln in pl:
    f = ln.split()
    if len(f) < 17: continue
    PR[int(f[0])] = {"h": [int(f[1]), int(f[2]), int(f[3]), int(f[4])],
                     "rx": int(f[5], 16), "ry": int(f[6], 16), "col0": int(f[7], 16),
                     "gb": int(f[8], 16), "cb": int(f[9], 16), "ci": int(f[10], 16),
                     "inc": int(f[12]), "inr": int(f[13]),
                     "row": int(f[14], 16), "romi": int(f[15], 16)}
TCOL = 0xFFFFFF
print("probe 可用拍数 %d" % len(PR))


def model_no_osd(i, ch):
    """第 i 拍 O_tdata 第 ch 通道的"无 OSD 原像素"该是多少 —— 用 I_tdata 反解。"""
    src = rows[max(i - 1, 0)]
    v = (int(src["Id"], 16) >> (72 - 24 * ch)) & 0xFFFFFF
    return v


# 扫描：文字命中用 (rx@cyc+dx, ry@cyc+dy, ci@cyc+dc, colbase@cyc+db, row@cyc+dr)
best = []
for dx in range(-3, 3):
    for dy in range(-3, 3):
        for dc in range(-3, 3):
            for db in range(-3, 3):
                for dr in range(-3, 3):
                    bad = 0
                    for i, r in enumerate(rows):
                        if r["Ov"] != 1: continue
                        pr = PR.get(r["cyc"])
                        if pr is None: continue
                        v = int(r["Od"], 16) & ((1 << 96) - 1)
                        for ch in range(4):
                            got = (v >> (72 - 24 * ch)) & 0xFFFFFF
                            a = PR.get(r["cyc"] + dx); b2 = PR.get(r["cyc"] + dy)
                            c = PR.get(r["cyc"] + dc); d = PR.get(r["cyc"] + db)
                            e = PR.get(r["cyc"] + dr)
                            if None in (a, b2, c, d, e):
                                continue
                            want = False
                            if e["inr"] and d["inc"]:
                                bit = (e["gb"] >> (15 - ((d["cb"] << 2)))) & 1
                                # 逐像素列由 cb 给出，但 4 个像素列不同：这里用 cb
                                # 只能判第一列，故改用 gb 全体：见下
                                want = None
                            if want is None:
                                break
                    best.append((bad, dx, dy, dc, db, dr))
print("（该模型需要逐像素列，改用更直接的做法）")
