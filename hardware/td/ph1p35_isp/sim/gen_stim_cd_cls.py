#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_cd_cls.py —— 为 alg_color_detect_96 的**颜色类别**输出（O_color_class）生成专项激励

为什么单独做一份：全尺寸回归（1280x720）的激励里，命中像素全是红色主导
（R 目标 235±20、G/B 只有 0..40），分类器的期望值**恒为 RED** ——
那样的测试对"分类器对不对"零鉴别力：把实现换成"永远输出 RED"也照样 PASS。
本文件造一组小图，让类别的期望值**逐帧变化**，并专门给两类错误下套。

几何：32x8（每行 8 拍），7 帧，共 448 拍。

逐帧目标色/容差与期望类别（容差框 = 目标色 ± 容差，逐通道独立）：

  F0  目标(20,200,20)  容差20  框 R[0,40] G[180,220] B[0,40]
      行 2..5 × 列 4..13 = 40 个 (20,200,20)          → G 主导，期望 1
  F1  目标(20,20,200)  容差20  框 R[0,40] G[0,40] B[180,220]
      **只有第 0 拍（行 0 的列 0..3）** 4 个 (20,20,200) → B 主导，期望 2
      ★ 这一帧是给"统计窗口错 1 拍"下套的：把命中像素全放在**帧首那一拍**，
        窗口一平移就整帧丢光 ⇒ 期望 2 会变成 0。全尺寸回归里命中像素有上千个、
        且分布均匀，这种错根本照不出来。
  F2  目标(200,20,20)  容差20  框 R[180,220] G[0,40] B[0,40]
      行 3..6 × 列 8..17 = 40 个 (200,20,20)          → R 主导，期望 0
  F3  目标(200,200,20) 容差20  框 R[180,220] G[180,220] B[0,40]
      20 个 (220,180,0) [R 主导] + 20 个 (180,220,0) [G 主导]
      ★ 计数 20:20:0 是**平局** → 期望 0（平局判给 R）。
        判据链若写成"先判 G"，这里会输出 1 ⇒ 抓到。
  F4  目标(20,200,200) 容差20  框 R[0,40] G[180,220] B[180,220]
      20 个 (0,220,180) [G 主导] + 20 个 (0,180,220) [B 主导]
      ★ 计数 0:20:20 是**平局** → 期望 1（平局判给 G，不是 B）。
  F5  目标(200,20,20)  容差20  全背景 ⇒ **一个命中都没有**
      → 期望类别 0 且 O_bbox_valid = 0（"有没有"与"是什么"必须同相）
  F6  目标(200,20,20)  容差20  全背景（**垫帧**）
      不是凑数：类别是在"下一帧帧首"那一拍锁存的，所以想看到 F5 的类别，
      必须**再给一帧**把它的统计冲出来。少了这一帧，最后一帧的类别永远观测不到。

背景一律 (128,128,128)：对上面每一个容差框都在框外（框要么要求某通道 ≥180，
要么要求 R∈[180,220]），所以背景必然不命中。

打包用 alg_ref.frame_to_beats / beats_to_hex（金标准自己的位序实现），
避免"激励位序"和"校验位序"两边各写一遍、一起错。

输出：
  stim_cd_cls.hex   448 拍，每行 24 个十六进制字符
  cd_cls_tgt.txt    7 行，每行 "<RRGGBB> <TOL>"（TB 与判据**共用同一份**，
                    不各写一遍常数）
"""
from __future__ import annotations
import sys, os

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, r"C:\Users\29072\PycharmProjects\PythonProject8")
import alg_ref                                            # noqa: E402

W, H = 32, 8
BPL = W // 4                                              # 8 拍/行
FRAMES = 13
NBEAT = BPL * H * FRAMES                                  # 832 拍

BKG = (128, 128, 128)

# 逐帧 (目标色, 容差)，顺序即帧序
TARGETS = [
    ((20, 200, 20), 20),          # F0 → 期望类别 1（G 主导）
    ((20, 20, 200), 20),          # F1 → 期望 2（B 主导；命中只在帧首那一拍）
    ((200, 20, 20), 20),          # F2 → 期望 0
    ((200, 200, 20), 20),         # F3 → 期望 0（R/G 平局）
    ((20, 200, 200), 20),         # F4 → 期望 1（G/B 平局）
    # ---- 2026-09-20 追加（进阶 2.5(2) 跟踪编号）：把"该加/不该加"两侧都钉死 -----
    #   ⚠ 第一版只造了"丢 4 帧再重现"，那只钉住了"丢满 4 帧必须 +1"；
    #     "只丢 1~3 帧**不许**加"这一侧根本没被激励到（丢 1 帧之后没有重新捕获），
    #     所以把 LOST_N 从 4 改成 1 那种错**照样能过**。现在补一次"短间隔重现"。
    ((200, 20, 20), 20),          # F5 → 无命中（丢失第 1 帧）
    ((20, 200, 20), 20),          # F6 → **短间隔重现**（只丢 1 帧）⇒ 编号必须**还是 1**
    ((200, 20, 20), 20),          # F7 → 无命中（丢失第 1 帧）
    ((200, 20, 20), 20),          # F8 → 无命中（丢失第 2 帧）
    ((200, 20, 20), 20),          # F9 → 无命中（丢失第 3 帧）
    ((200, 20, 20), 20),          # F10 → 无命中（丢失第 4 帧）
    ((200, 20, 20), 20),          # F11 → **长间隔重现**（丢满 4 帧）⇒ 编号必须变成 2
    ((200, 20, 20), 20),          # F12 → 垫帧，把 F11 的类别与编号冲出来
]
assert len(TARGETS) == FRAMES

# 每帧的期望类别（= 该帧命中像素的主导通道，平局按 R > G > B）。
# 这些值由本文件末尾的 selfcheck() 用**独立算一遍**的方式核对，不靠人工数。
EXPECT_CLS = [1, 2, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]
EXPECT_HIT = [True, True, True, True, True, False, True,
              False, False, False, False, True, False]
# 编号状态机的两个"卡点"（selfcheck 会逐条核对）：
#   · 第 6 帧是**短间隔重现**（只丢 1 帧）⇒ 编号必须仍为 1
#   · 第 11 帧是**长间隔重现**（丢满 4 帧）⇒ 编号必须变成 2
ID_SHORT_REACQ = 6
ID_LONG_REACQ = 11

LOST_N = 4                # 与 alg_color_detect_96 的 localparam LOST_N 逐字一致
LOST_MAX = 7              # 同上（3 bit 饱和值）


def base():
    img = np.zeros((H, W, 3), dtype=np.uint8)
    img[:, :] = BKG
    return img


def fill(img, r0, r1, c0, c1, rgb):
    img[r0:r1 + 1, c0:c1 + 1] = rgb


def build_frames():
    """返回 FRAMES 个 (H, W, 3) uint8 帧。"""
    fr = []

    # ---- F0：40 个 G 主导 ----
    a = base()
    fill(a, 2, 5, 4, 13, (20, 200, 20))
    fr.append(a)

    # ---- F1：只有第 0 拍（行 0 列 0..3）是 B 主导 ----
    b = base()
    fill(b, 0, 0, 0, 3, (20, 20, 200))
    fr.append(b)

    # ---- F2：40 个 R 主导 ----
    c = base()
    fill(c, 3, 6, 8, 17, (200, 20, 20))
    fr.append(c)

    # ---- F3：R/G 各 20（平局） ----
    d = base()
    fill(d, 1, 2, 0, 9, (220, 180, 0))            # 20 个 R 主导
    fill(d, 5, 6, 0, 9, (180, 220, 0))            # 20 个 G 主导
    fr.append(d)

    # ---- F4：G/B 各 20（平局） ----
    e = base()
    fill(e, 1, 2, 12, 21, (0, 220, 180))          # 20 个 G 主导
    fill(e, 5, 6, 12, 21, (0, 180, 220))          # 20 个 B 主导
    fr.append(e)

    # ---- F5：全背景（丢失第 1 帧）----
    fr.append(base())

    # ---- F6：**短间隔重现**（只丢 1 帧）⇒ 编号必须仍然不动 ----
    h = base()
    fill(h, 2, 5, 4, 13, (20, 200, 20))           # 40 个 G 主导
    fr.append(h)

    # ---- F7 ~ F10：全背景（连续丢到第 4 帧）----
    for _ in range(4):
        fr.append(base())

    # ---- F11：**长间隔重现**（丢满 4 帧）⇒ 编号必须 1→2 ----
    g = base()
    fill(g, 3, 6, 8, 17, (200, 20, 20))           # 40 个 R 主导
    fr.append(g)

    # ---- F12：全背景（垫帧，把 F11 的类别与编号冲出来）----
    fr.append(base())

    assert len(fr) == FRAMES, len(fr)
    return fr


def _box(tgt, tol):
    return tuple((max(0, c - tol), min(255, c + tol)) for c in tgt)


def _classify(img, tgt, tol):
    """按**规格**独立算一遍：命中像素的主导通道 + 平局 R>G>B。

    实现放在金标准 alg_ref.color_class() 里（**一处定义**，全尺寸判据 check_alg_top_full.py
    调的是同一个函数）—— 不在这里再写第二份"然后祈祷两边相等"。
    本函数只负责把 (目标色, 容差) 折算成容差框再转调。
    """
    (rlo, rhi), (glo, ghi), (blo, bhi) = _box(tgt, tol)
    return alg_ref.color_class(img, None, rlo, rhi, glo, ghi, blo, bhi)


def golden_track_ids(hit):
    """逐帧的**跟踪编号**状态机（2026-09-20，进阶 2.5(2)）。

    规格（与 alg_color_detect_96 §10c 同条，但这里是**另写一遍**）：
      · 目标连续丢失 >= LOST_N 帧之后**再看见**目标 ⇒ 编号 +1，否则编号不变；
      · 复位时视作"已经丢了很久"，所以第一次捕获就能编到 1；
      · 丢失计数饱和在 LOST_MAX（3 bit）。
    返回 out[f] = **第 f 帧处理完之后**的编号。
    """
    idv, lost, out = 0, LOST_MAX, []
    for f in range(len(hit)):
        if hit[f]:
            if lost >= LOST_N:
                idv = 1 if idv >= 99 else idv + 1
            lost = 0
        else:
            lost = min(lost + 1, LOST_MAX)
        out.append(idv)
    return out


def selfcheck(frames):
    """对着 EXPECT_CLS / EXPECT_HIT 核一遍 —— 人工数错了在这里就炸。"""
    ok = True
    print("逐帧金标准（独立算一遍）：")
    for f, img in enumerate(frames):
        tgt, tol = TARGETS[f]
        cls, (cr, cg, cb), nhit = _classify(img, tgt, tol)
        # 容差框必须只有本帧那几种颜色进来（防止"背景意外命中"）
        mark = "OK " if (cls == EXPECT_CLS[f] and (nhit > 0) == EXPECT_HIT[f]) else "!! "
        if mark == "!! ":
            ok = False
        print("  %sF%d 目标%s 容差%d  命中 R/G/B = %d/%d/%d（总 %d）→ 类别 %d（期望 %d）"
              % (mark, f, tgt, tol, cr, cg, cb, nhit, cls, EXPECT_CLS[f]))
    if not ok:
        raise SystemExit("生成器自检失败：期望值与独立计算不一致，先修激励设计")

    # ---- 跟踪编号：状态机跑一遍，把边界（丢掉 1 帧 vs 丢满 4 帧）打印出来 ----
    ids = golden_track_ids(EXPECT_HIT)
    print("逐帧跟踪编号（第 f 帧处理完之后）=")
    print("  %s" % (ids,))
    print("  ⇒ 屏上第 f 帧看到的是 %s（帧 f 首锁存的是 f-1 的结果，第 0 帧为复位值 0）"
          % ([0] + ids[:-1],))
    print("  边界两侧都要钉住：F%d 是**短间隔重现**（只丢 1 帧）⇒ 编号必须仍是 1；"
          "F%d 是**长间隔重现**（丢满 %d 帧）⇒ 编号必须变成 2"
          % (ID_SHORT_REACQ, ID_LONG_REACQ, LOST_N))
    bad = []
    if ids[ID_SHORT_REACQ] != 1:
        bad.append("短间隔重现处编号 = %d，应为 1（LOST_N 判小了）"
                   % ids[ID_SHORT_REACQ])
    if ids[ID_LONG_REACQ] != 2:
        bad.append("长间隔重现处编号 = %d，应为 2（LOST_N 判大了）"
                   % ids[ID_LONG_REACQ])
    if ids[ID_LONG_REACQ - 1] != 1:
        bad.append("长间隔重现**之前**编号就变了（= %d）" % ids[ID_LONG_REACQ - 1])
    if bad:
        raise SystemExit("生成器自检失败：跟踪编号边界行为与设计不符 —— %s（ids=%s）"
                         % ("；".join(bad), ids))
    print("  编号边界自检：短间隔不动 / 长间隔 +1 —— 两侧都成立  OK")
    return ok


def check_discriminating(frames):
    """★ 鉴别力自证：把几种**典型错误实现**套上去，确认本激励能把它们照出来。

    这一节是"这测试到底看不看得见我要测的东西"的正面回答 ——
    不做这一步，PASS 只能说明"没崩"，不能说明"测到了"。
    """
    def run(kind):
        got = []
        for f, img in enumerate(frames):
            tgt, tol = TARGETS[f]
            if kind == "drop_first_beat":
                # 统计窗口错 1 拍：丢帧首那一拍、吃下一帧首拍（只在帧首放命中时可见）
                im = img.copy()
                im[0, 0:4] = BKG
                nxt = frames[f + 1] if f + 1 < FRAMES else None
                if nxt is not None:
                    im[0, 0:4] = nxt[0, 0:4]
                cls, _, nh = _classify(im, tgt, tol)
                got.append((cls, nh))
                continue
            if kind == "tie_g_first":       # 帧级平局先判 G（就是我改掉的那个 bug）
                cls, (cr, cg, cb), nh = _classify(img, tgt, tol)
                cls = 1 if (cg >= cr and cg >= cb) else cls
                got.append((cls, nh))
                continue
            if kind == "tie_b_first":       # 帧级平局先判 B
                cls, (cr, cg, cb), nh = _classify(img, tgt, tol)
                cls = 2 if (cb >= cr and cb >= cg) else cls
                got.append((cls, nh))
                continue
            if kind == "always_red":        # 写死 RED
                got.append((0, 1))
                continue
            raise AssertionError(kind)
        return got

    print("\n鉴别力自证（把这些错误实现套上去，看本激励能不能照出来）：")
    allseen = True
    for kind, desc in (("drop_first_beat", "统计窗口错 1 拍"),
                       ("tie_g_first",    "帧级平局先判 G"),
                       ("tie_b_first",    "帧级平局先判 B"),
                       ("always_red",     "写死永远输出 RED")):
        got = run(kind)
        cls_list = [g[0] for g in got]
        seen = cls_list != list(EXPECT_CLS)
        allseen &= seen
        print("  %s%-16s 逐帧类别 %s（正确 %s）"
              % ("抓到 " if seen else "!!漏 ", desc, cls_list, list(EXPECT_CLS)))
    if not allseen:
        raise SystemExit("有错误实现照不出来 ⇒ 激励鉴别力不足，必须先加强激励")
    return True


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    frames = build_frames()
    assert len(frames) == FRAMES

    selfcheck(frames)
    check_discriminating(frames)

    beats = [alg_ref.frame_to_beats(im) for im in frames]
    flat = np.concatenate(beats, axis=0).reshape(-1, 2)
    assert flat.shape[0] == NBEAT, flat.shape
    hexs = alg_ref.beats_to_hex(flat)

    out_hex = os.path.join(here, "stim_cd_cls.hex")
    with open(out_hex, "w", encoding="ascii") as fh:
        for hstr in hexs:
            fh.write("%s\n" % hstr)

    out_tgt = os.path.join(here, "cd_cls_tgt.txt")
    with open(out_tgt, "w", encoding="ascii") as fh:
        for tgt, tol in TARGETS:
            fh.write("%02X%02X%02X %d\n" % (tgt[0], tgt[1], tgt[2], tol))

    print("\n已生成 %s" % out_hex)
    print("  %dx%d，每行 %d 拍，%d 帧，共 %d 拍" % (W, H, BPL, FRAMES, NBEAT))
    print("已生成 %s（每行 <RRGGBB> <TOL>，TB 与判据共用）" % out_tgt)
    print("期望类别逐帧 = %s" % (EXPECT_CLS,))


if __name__ == "__main__":
    main()
