#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m0_delay_probe.py —— 钉死 M0 直通路径的真实延迟（只看 dump，不读 RTL 内部量）。

问题：M0 帧（第 0 帧）上，某些输出拍的值是 0，与我 checker 的期望不符。
两种可能：
  (A) RTL 的 M0 路径（r_m0_dat 四级链 + 掩蔽 + 输出级）真的输出了 0；
  (B) 我的 checker 把"第几个输出有效拍 <=> 第几个输入拍"这个对齐算错了。

判据（本题最干净的判据）：M0 里掩蔽是**不改变结果**的
（掩蔽期输出原图 = w_a0_dat，而非掩蔽期 M0 的 mux 输出也是 w_a0_dat），
所以 RTL 的 O_tdata 在 M0 上应当**逐周期**等于 I_tdata 延迟固定拍数 k——

    O_tdata[t] == I_tdata[t-k]     对**所有** t（含消隐拍，消隐期 I_tdata=0）

于是只要扫 k=0..12，看哪个 k 让"仅在有真实数据的周期上"全等，就能定死：
  · 存在 k 使全部相等 -> M0 数据通路是正确的纯延迟，(B) 成立（我的对齐算错）
  · 任何 k 都做不到     -> (A) 成立（RTL 真在吐 0），并给出反例周期
另外再扫"拍域"对齐 m：第 i 个输出有效拍的内容 == 第 i+m 个输入有效拍的内容？
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np            # noqa: E402
import check_alg_top_full as C  # noqa: E402
from gen_stim_top_full import BPL, H, BPF  # noqa: E402


def h(v):
    return "%024X" % int(v)


d = C.parse(os.path.join(HERE, C.DUMP), quiet=True)
Iv, Ov = d["Iv"], d["Ov"]
Id, Od = d["id"], d["od"]
n = d["ncycles"]
print("dump: cycles=%d  I_tvalid=%d  O_tvalid=%d" % (n, int(Iv.sum()), int(Ov.sum())))

print("\n=== 1) O_tvalid[t] == I_tvalid[t-k] 扫描（控制通路）===")
for k in range(0, 9):
    if k == 0:
        eq = (Ov == Iv)
    else:
        eq = np.concatenate([np.zeros(k, bool), Iv[:n - k]]) == Ov
    print("   k=%d  不符 %d / %d" % (k, int((~eq).sum()), n))

print("\n=== 2) O_tdata[t] == I_tdata[t-k] 扫描（M0 数据通路）===")
print("   只在 I_tvalid[t-k]==1 的周期上比（消隐期两边都是 0，会给出假阳性）")
for k in range(0, 13):
    if k == 0:
        idx = np.nonzero(Iv)[0]
        eq = (Od[idx] == Id[idx])
    else:
        idx = np.nonzero(Iv[:n - k])[0]          # I_tvalid[t-k]==1 的 t
        eq = (Od[idx + k] == Id[idx])
    nbad = int((~eq).sum())
    print("   k=%-2d  比较 %7d 拍，不符 %-7d %s"
          % (k, eq.size, nbad, "<= 全等" if nbad == 0 else ""))

print("\n=== 3) 拍域对齐：第 i 个输出有效拍的内容 vs 第 i+m 个输入有效拍的内容 ===")
oc = np.nonzero(Ov)[0]
ic = np.nonzero(Iv)[0]
print("   输出有效拍 %d 个，输入有效拍 %d 个" % (oc.size, ic.size))
for m in range(-3, 4):
    a = max(0, -m)
    b = min(oc.size, ic.size - m)
    if b <= a:
        continue
    same = int((Od[oc[a:b]] == Id[ic[a + m:b + m]]).sum())
    tot = b - a
    print("   m=%-3d 比 %7d 拍，相等 %-7d（%.4f%%）%s"
          % (m, tot, same, 100.0 * same / tot, "  <= 完全对齐" if same == tot else ""))

print("\n=== 4) 反例逐周期展开（若存在 k 全等则本条为空）===")
kk = None
for k in range(0, 13):
    if k == 0:
        idx = np.nonzero(Iv)[0]
        eq = (Od[idx] == Id[idx])
    else:
        idx = np.nonzero(Iv[:n - k])[0]
        eq = (Od[idx + k] == Id[idx])
    if (~eq).all() is False and int((~eq).sum()) == 0:
        kk = k
        break
print("   全等的 k = %s" % (kk,))
if kk is None:
    best = min(range(0, 13),
               key=lambda k: int((~(Od[np.nonzero(Iv[:n - k])[0] + k]
                                    == Id[np.nonzero(Iv[:n - k])[0]])).sum()) if k else 0)
    k = best
    idx = np.nonzero(Iv[:n - k])[0] if k else np.nonzero(Iv)[0]
    bad = idx[~(Od[idx + k] == Id[idx])]
    print("   最接近的 k=%d，仍有 %d 拍不符，前 12 个反例：" % (k, bad.size))
    for t in bad[:12]:
        print("     cyc=%-7d I[cyc-%d]=%s  O[cyc]=%s  I[cyc]=%s"
              % (t + k, k, h(Id[t]), h(Od[t + k]), h(Id[t + k])))

print("\n=== 5) 全部输出有效拍里 O_tdata==0 的有多少 ===")
z = (Od[oc] == 0)
print("   %d / %d 个输出有效拍的数据为 0" % (int(z.sum()), oc.size))
if z.any():
    zi = np.nonzero(z)[0]
    print("   前 12 个（输出拍号 / 对应周期 / 该周期 I_tvalid）：")
    for i in zi[:12]:
        print("     输出拍 %-7d cyc=%-7d I_tvalid[cyc]=%d I_tvalid[cyc-5]=%d"
              % (i, oc[i], Iv[oc[i]], Iv[oc[i] - 5] if oc[i] >= 5 else -1))
    print("   输出拍号 mod 320 的分布：%s" % np.unique(zi % BPL)[:12].tolist())
