# -*- coding: utf-8 -*-
"""
_he_probe_switch.py —— 直方图均衡：**表切换点**探针（const 场景）

为什么写这个：
  const 场景输入恒为 128，所以输出只可能是两种值：
      128 = 走了恒等表（旁路 / map 未就绪）
      255 = 走了映射表（本场景 K 整除、无截断 ⇒ 满直方图映射到 255）
  于是"输出序列在哪个输入拍上从 128 跳到 255"就把 RTL 的表切换点暴露得一清二楚，
  可以直接拿去和规格（"第 f 帧用第 f-1 帧的表、帧边界切换"）对。

口径全部复用 check_histeq 的解析器，不另写一套。
"""
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_histeq as C  # noqa: E402
import json

SCEN = "const"
_scens = json.load(open(os.path.join(HERE, "histeq_scen.json"), encoding="utf-8"))["scenarios"]
S = [s for s in _scens if s["name"] == SCEN][0]
BPF, BPL, FRAMES = S["bpf"], S["bpl"], S["frames"]
print("场景参数（从 histeq_scen.json 读）：W=%d H=%d 帧=%d 每帧 %d 拍 每行 %d 拍 样本数=%d K=%d"
      % (S["W"], S["H"], FRAMES, BPF, BPL, S["samples"], S["K"]))

rows = C.parse_dump(os.path.join(HERE, "dump_he_%s.txt" % SCEN))
by_cyc = {r["cyc"]: r for r in rows}

seq = []          # (输入拍号 k, 输出首字节, 输出整拍 hex)
for r in rows:
    if not r["ov"]:
        continue
    src = by_cyc.get(r["cyc"] - C.LAT)
    if src is None or not src["iv"]:
        continue
    ob = C.hex_bytes(r["odata"])
    if ob is None:
        continue
    seq.append((int(src["ibeat"]), int(ob[0]), r["odata"]))

print("=" * 74)
print("场景 %s：输入恒 128（每帧 %d 拍）；输出 128=恒等表 / 255=映射表" % (SCEN, BPF))
print("对齐口径：输出 cyc 对应输入 cyc-%d 的拍号 k（与判据 D 完全一致）" % C.LAT)
print("=" * 74)
print("输出有效拍合计 %d，输入拍号范围 beat %d .. %d" % (len(seq), seq[0][0], seq[-1][0]))

print("\n--- 输出值发生变化的那些拍（表切换点）---")
prev = None
switches = []
for k, v, _h in seq:
    if v != prev:
        switches.append((k, v))
        print("  beat %-6d 输出值 -> %-4d  (处于第 %d 帧，帧内第 %d 拍)"
              % (k, v, k // BPF, k % BPF))
        prev = v

print("\n--- 每一帧的边界：前后各 4 拍 ---")
for f in range(FRAMES):
    b0, b1 = f * BPF, (f + 1) * BPF - 1
    seg = [(k, v) for k, v, _h in seq if b0 <= k <= b1]
    if not seg:
        print("  帧 %d：没有输出拍" % f)
        continue
    head = seg[:4]
    tail = seg[-4:]
    vals = sorted(set(v for _k, v in seg))
    print("  帧 %d（beat %d..%d，%d 个输出拍）：取值集合=%s" % (f, b0, b1, len(seg), vals))
    print("      帧头 %s" % (" ".join("k%d=%d" % t for t in head)))
    print("      帧尾 %s" % (" ".join("k%d=%d" % t for t in tail)))

print("\n--- 跨帧的那几拍（帧边界前后 3 拍）---")
for f in range(1, FRAMES):
    b = f * BPF
    print("  帧 %d->%d 边界 beat %d 附近：" % (f - 1, f, b))
    for k, v, _h in seq:
        if b - 3 <= k <= b + 2:
            print("      beat %-6d 值=%d" % (k, v))
