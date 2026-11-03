# -*- coding: utf-8 -*-
"""
_he_probe_raw.py —— const 场景：帧边界附近的**原始 dump 行**（不做任何推导）

为什么要看原始行：
  推断链走到"输出=恒等"就卡住了 —— r_map_ok 只在复位清、只在扫描收尾置 1，
  按理它一直是 1。再往下猜就是浪费时间，直接把 ien / 输入数据 / 输出数据 摆出来。
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import check_histeq as C  # noqa: E402

rows = C.parse_dump(os.path.join(HERE, "dump_he_const.txt"))
by_cyc = {r["cyc"]: r for r in rows}

# 找每个输出有效拍，配到它的输入行
pairs = []
for r in rows:
    if not r["ov"]:
        continue
    src = by_cyc.get(r["cyc"] - C.LAT)
    if src is None:
        pairs.append((r["cyc"], None, None, r["odata"]))
        continue
    pairs.append((r["cyc"], src, int(src["ibeat"]) if src["iv"] else None, r["odata"]))

print("=" * 96)
print("const 场景：每帧 128 拍，3 帧。看帧 1->2 边界（输入拍 256 附近）")
print("列：输出cyc | 输入cyc | 输入拍号 | 输入tvalid | 输入I_en | 输入数据 | 输出数据")
print("=" * 96)
for cyc, src, k, od in pairs:
    if k is None:
        continue
    if 252 <= k <= 262:
        print("  %-8d %-8d %-8d %-3s %-3s %-26s %s"
              % (cyc, src["cyc"], k, src["iv"], src["ien"], src["idata"], od))

print("\n--- 每一帧头/尾的输出与输入对照（看是不是逐比特等于输入）---")
for f in range(3):
    b0, b1 = f * 128, (f + 1) * 128 - 1
    seg = [(cyc, src, k, od) for cyc, src, k, od in pairs if k is not None and b0 <= k <= b1]
    same = sum(1 for _c, s, _k, od in seg if od.lower() == s["idata"].lower())
    vals = sorted(set(od[:2] for _c, _s, _k, od in seg))
    print("  帧 %d：%d 拍；输出==输入 的有 %d 拍；输出首字节取值 %s"
          % (f, len(seg), same, vals))
    print("      帧头3拍：%s" % " | ".join("in=%s out=%s" % (s["idata"][:6], od[:6])
                                           for _c, s, _k, od in seg[:3]))
