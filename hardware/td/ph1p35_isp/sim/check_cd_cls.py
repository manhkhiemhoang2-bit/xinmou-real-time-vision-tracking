#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_cd_cls.py —— alg_color_detect_96 的 O_color_class 判据

判什么（只有这一件事，别的都在原有 TB/判据里）：
  ① **类别正确**：帧首有效拍后 2 拍，O_color_class == 该帧之前那一帧的命中像素
     主导通道（0=R / 1=G / 2=B），逐帧比对 7 个采样点。
  ② **与"有没有"同相**：同一个采样点上 O_bbox_valid == 那一帧是否有命中像素。
     类别是在下一帧帧首锁存的，若两者不同相，屏上会出现"NONE"配着某个颜色名。
  ③ **复位后为 0**：第 0 帧帧首锁存出来的是复位值（三计数器全 0 ⇒ 按 R>G>B 取 R=0）。

采样点的推导（不猜 START_CYC、不读 RTL 内部）：
  dump 每行是"该周期内的信号值"。tuser 出现在第 c 行 ⇒ 在 c 结束的那个时钟沿，
  r_tu_d1 被置 1；于是 **c+1 行** 上 w_frame_start=1，计数器在这一沿被重置、
  O_color_class 在这一沿被更新 ⇒ **c+2 行** 开始 O_color_class 就是新值。
  ⇒ 帧 f 的帧首在第 c 行 ⇒ 在 c+2 行采样，得到"帧 f-1 的类别"。

期望值从哪来：
  直接 import gen_stim_cd_cls 的 build_frames / TARGETS / _classify（**同一个来源**，
  不在这里把分类器再写第三遍），并**先核对磁盘上的激励文件与重新生成的一致** ——
  否则判据可能在验一份根本不是 DUT 吃到的东西。

用法：
  python check_cd_cls.py [--dump <路径>] [--selftest]
"""
from __future__ import annotations

import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

_HERE = os.path.dirname(os.path.abspath(__file__))
for _d in (os.environ.get("ALG_REF_DIR", ""),
           r"C:\Users\29072\PycharmProjects\PythonProject8",
           _HERE):
    if _d and os.path.isfile(os.path.join(_d, "alg_ref.py")):
        if _d not in sys.path:
            sys.path.insert(0, _d)
        break
else:  # pragma: no cover
    raise SystemExit("找不到 alg_ref.py，请设 ALG_REF_DIR")

import numpy as np            # noqa: E402
import alg_ref as A           # noqa: E402
import gen_stim_cd_cls as G   # noqa: E402

FRAMES = G.FRAMES
DEFAULT_DUMP = os.path.join(_HERE, "dump_cd_cls.txt")


# ===========================================================================
# 1. 激励完整性：磁盘上的 hex / 目标表必须与"判据假设的"逐字节一致
# ===========================================================================
def check_stim_files(verbose=True):
    """重新生成一遍，与磁盘上的比。不一致 = 判据在验一份错的东西 ⇒ 直接失败。"""
    frames = G.build_frames()
    beats = [A.frame_to_beats(im) for im in frames]
    flat = np.concatenate(beats, axis=0).reshape(-1, 2)
    want_hex = A.beats_to_hex(flat)

    p_hex = os.path.join(_HERE, "stim_cd_cls.hex")
    with open(p_hex, "r", encoding="ascii") as fh:
        got_hex = [ln.strip() for ln in fh if ln.strip()]
    ok_hex = (got_hex == want_hex)

    p_tgt = os.path.join(_HERE, "cd_cls_tgt.txt")
    with open(p_tgt, "r", encoding="ascii") as fh:
        got_tgt = []
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            a, b = ln.split()
            got_tgt.append((int(a, 16), int(b)))
    want_tgt = [((t[0] << 16) | (t[1] << 8) | t[2], tol) for t, tol in G.TARGETS]
    ok_tgt = (got_tgt == want_tgt)

    if verbose:
        print("  激励完整性：stim_cd_cls.hex %s（%d 拍，期望 %d）  %s"
              % ("一致" if ok_hex else "**不一致**", len(got_hex), len(want_hex),
                 "PASS" if ok_hex else "FAIL"))
        print("  激励完整性：cd_cls_tgt.txt  %s（%d 行，期望 %d）  %s"
              % ("一致" if ok_tgt else "**不一致**", len(got_tgt), len(want_tgt),
                 "PASS" if ok_tgt else "FAIL"))
    # ⚠ 返回值是**失败数**（0 = 通过），不是"通过标志" ——
    #   第一版这里返回的是 1/0 表示成败，而调用方按失败数累加，结果全 PASS 也会报 FAIL。
    return (0 if ok_hex else 1), (0 if ok_tgt else 1)


def check_track_id(d, id_gold, verbose=True, mutate=None):
    """判据 V：跟踪编号（O_track_id）—— 目标"丢失 → 重现"后必须 +1。

    id_gold[f] = 第 f 帧**处理完之后**的编号（见 gen_stim_cd_cls.golden_track_ids）。
    第 f 帧帧首锁存的是 f-1 的结果 ⇒ 在帧 f 的采样点读到的是 id_gold[f-1]，
    第 0 帧读到复位值 0。
    """
    starts = sample_cycles(d, verbose=False)
    nass = nbad = 0
    exp = [0] + list(id_gold[:-1])
    if mutate:
        if mutate["kind"] == "id_plus1":
            exp = [v + 1 for v in exp]
        elif mutate["kind"] == "id_no_lost":
            # 变异：无视"丢失"条件，每次看见目标就 +1（对应 RTL 漏判 lost 比较）
            v, out = 0, []
            for h in G.EXPECT_HIT:
                out.append(v)
                if h:
                    v += 1
            exp = [0] + out[:-1]
        elif mutate["kind"] == "id_stuck":
            exp = [0] * len(exp)
        else:
            raise AssertionError(mutate)

    rows = []
    for k, (f, c) in enumerate(starts):
        s = c + 2
        if s >= len(d["cyc"]) or k >= len(exp):
            nbad += 1
            break
        got = int(d["otid"][s])
        nass += 1
        ok = (got == exp[k])
        if not ok:
            nbad += 1
        rows.append((f, c, s, got, exp[k], ok))
    if verbose:
        print("  逐帧跟踪编号（帧首行 c → 采样行 c+2）：")
        print("    采样帧  帧首行  采样行  编号(实测/期望)  判")
        for (f, c, s, got, e, ok) in rows:
            print("    %-6d  %-6d  %-6d  %d / %d%s  %s"
                  % (f, c, s, got, e, "" if ok else "  <-FAIL", "ok" if ok else "FAIL"))
        print("  实测编号序列 = %s" % ([r[3] for r in rows],))
        print("  期望编号序列 = %s" % (exp,))
        print("  期望里不同取值 %d 种 —— 只有 1 种时本判据没有鉴别力"
              % len(set(exp)))
        print("  O_track_id 采样 %d 点，不符 %d  %s"
              % (len(rows), nbad, "PASS" if nbad == 0 else "FAIL"))
    return nass, nbad


def check_id_teeth(d, id_gold, verbose=True):
    """编号判据的鉴别力门禁：实测序列必须有 >= 2 种取值（否则证明不了"会递增"）。"""
    starts = sample_cycles(d, verbose=False)
    got = [int(d["otid"][c + 2]) for _f, c in starts if c + 2 < len(d["cyc"])]
    if len(set(got)) < 2:
        print("  **实测编号序列只有 %d 种取值 %s ⇒ 递增逻辑根本没被激励到"
              % (len(set(got)), sorted(set(got))))
        return 1
    if verbose:
        print("  编号鉴别力门禁：实测 %d 种取值 %s，>= 2  PASS"
              % (len(set(got)), sorted(set(got))))
    return 0


def golden(frames):
    """逐帧金标准 (类别, bbox 是否有效)。

    ⚠ 两条金标准的**口径不同，这是刻意的**（都写在 alg_color_detect_96 的文件头）：

      · 类别：统计**原始命中**（不表决、不掩蔽）—— 问的是"这一片目标色像素
        主导通道是什么"。表决只是去噪，不改变颜色；掩蔽是空间有效性，与颜色无关。
      · O_bbox_valid：来自 **hit_vote 后再套 window_valid_mask**（y>=2 且 拍号!=0）的
        命中数是否非零 —— 问的是"有没有一个空间上站得住的目标"。
        （与 alg_ref 的口径逐条相同：check_alg_top_full.bboxes() 也是这么算的。）

    两者在屏上不会互相矛盾：osd_mixer 只在命中数非零时才显示类别。
    """
    cls, hit = [], []
    for f, img in enumerate(frames):
        tgt, tol = G.TARGETS[f]
        c, _cnts, _nhit = G._classify(img, tgt, tol)
        cls.append(c)

        (rlo, rhi), (glo, ghi), (blo, bhi) = G._box(tgt, tol)
        raw = A.target_hit(img, rlo, rhi, glo, ghi, blo, bhi)
        valid = A.hit_vote(raw) & _window_mask(G.H, G.W)
        hit.append(int(valid.sum()) > 0)
    return cls, hit


def _window_mask(H, W):
    """alg_ref.window_valid_mask 的同口径包装（y >= 2 且 拍号 != 0）。

    显式写出来是为了让"掩蔽的行/拍"这两个数在判据里看得见 ——
    直接调 alg_ref 时它们是默认参数，读代码时容易以为是"全都算"。
    """
    return A.window_valid_mask(H, W, A.PIXELS_PER_BEAT, 2)


# ===========================================================================
# 2. 解析 dump
# ===========================================================================
COLS = ["cyc", "iv", "iu", "beat", "fidx", "tgt", "tol",
        "ov", "ocls", "ovalid", "ocnt", "otid"]


def parse(path):
    d = {k: [] for k in COLS}
    bad = 0
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            p = ln.split()
            if len(p) != len(COLS):
                bad += 1
                continue
            d["cyc"].append(int(p[0]))
            d["iv"].append(int(p[1]))
            d["iu"].append(int(p[2]))
            d["beat"].append(int(p[3]))
            d["fidx"].append(int(p[4]))
            d["tgt"].append(int(p[5], 16))
            d["tol"].append(int(p[6]))
            d["ov"].append(int(p[7]))
            d["ocls"].append(int(p[8], 2))
            d["ovalid"].append(int(p[9]))
            d["ocnt"].append(int(p[10]))
            d["otid"].append(int(p[11]))
    for k in COLS:
        d[k] = np.array(d[k], dtype=np.int64)
    d["_badlines"] = bad
    return d


# ===========================================================================
# 3. 判据本体
# ===========================================================================
def sample_cycles(d, verbose=True):
    """帧 f 的帧首所在行号 c_f（tvalid && tuser 的那一行）。"""
    idx = np.nonzero((d["iv"] == 1) & (d["iu"] == 1))[0]
    # 同一帧首可能连续两行都是 tuser（激励连续时不会），按帧号去重取第一个
    seen, out = set(), []
    for i in idx:
        f = int(d["fidx"][i])
        if f in seen:
            continue
        seen.add(f)
        out.append((f, int(i)))
    out.sort()
    if verbose:
        print("  找到帧首 %d 个：%s" % (len(out), [(f, c) for f, c in out]))
    return out


def check_class(d, cls_gold, hit_gold, verbose=True, mutate=None):
    """mutate: None 或 dict(kind=..., ...)，用于变异自证。"""
    nass = nbad = 0
    starts = sample_cycles(d, verbose=False)
    if len(starts) != FRAMES:
        print("  **帧首个数 %d != FRAMES=%d ⇒ 激励或 TB 时序不对，判据无法进行"
              % (len(starts), FRAMES))
        return 0, 1

    # 期望序列：第 f 个帧首采样得到"帧 f-1"的类别；f=0 采到的是复位值 0
    exp_cls = [0] + list(cls_gold[:-1])
    exp_hitv = [False] + list(hit_gold[:-1])
    # 注：帧 6 是垫帧，它的类别要在"第 7 个帧首"才能看到 —— 没有第 7 帧，
    #     所以 cls_gold[6] 只用来给帧 5 的采样当期望（下面 len(starts) 自然对上）。

    if mutate:
        if mutate["kind"] == "shift":
            exp_cls = exp_cls[1:] + exp_cls[:1]
        elif mutate["kind"] == "flip_all":
            exp_cls = [(c + 1) % 3 for c in exp_cls]
        elif mutate["kind"] == "flip_frame":
            k = mutate["frame"]
            exp_cls[k] = (exp_cls[k] + 1) % 3
        elif mutate["kind"] == "all_red":
            exp_cls = [0] * len(exp_cls)
        else:
            raise AssertionError(mutate)

    rows = []
    for k, (f, c) in enumerate(starts):
        s = c + 2
        if s >= len(d["cyc"]):
            nbad += 1
            rows.append((f, c, s, None, exp_cls[k], None, exp_hitv[k], "采不到"))
            continue
        gc = int(d["ocls"][s])
        gv = bool(d["ovalid"][s])
        nass += 2
        okc = (gc == exp_cls[k])
        okv = (gv == exp_hitv[k])
        if not okc:
            nbad += 1
        if not okv:
            nbad += 1
        rows.append((f, c, s, gc, exp_cls[k], gv, exp_hitv[k],
                     ("ok" if (okc and okv) else
                      ("类别不符" if not okc else "") + ("/valid 不符" if not okv else ""))))

    if verbose:
        print("  逐帧采样（帧首行 c → 采样行 c+2）：")
        print("    采样帧  帧首行  采样行  类别(实测/期望)  bbox_valid(实测/期望)  判")
        for (f, c, s, gc, ec, gv, ev, msg) in rows:
            print("    %-6d  %-6d  %-6d  %s / %s%s  %-5s / %-5s%s  %s"
                  % (f, c, s,
                     "N/A" if gc is None else gc, ec,
                     "" if gc == ec else "  <-FAIL",
                     "N/A" if gv is None else int(gv), int(ev),
                     "" if gv == ev else "  <-FAIL",
                     msg))
        print("  O_color_class / O_bbox_valid 采样 %d 点，不符 %d  %s"
              % (len(rows), nbad, "PASS" if nbad == 0 else "FAIL"))
        got = [r[3] for r in rows]
        print("  实测类别序列 = %s" % (got,))
        print("  期望类别序列 = %s" % (exp_cls,))
        print("  期望类别里不同取值 %d 种（%s）—— 只有 1 种时本判据没有鉴别力"
              % (len(set(exp_cls)), sorted(set(exp_cls))))
    return nass, nbad


def check_teeth(d, cls_gold, hit_gold, verbose=True):
    """鉴别力门禁：实测序列不能是常数、期望序列不能是常数。"""
    nbad = 0
    starts = sample_cycles(d, verbose=False)
    got = [int(d["ocls"][c + 2]) for _f, c in starts if c + 2 < len(d["cyc"])]
    if len(set(got)) < 2:
        nbad += 1
        print("  **实测类别序列只有 %d 种取值 %s ⇒ DUT 可能卡在常数（或激励不足）"
              % (len(set(got)), sorted(set(got))))
    exp = [0] + list(cls_gold[:-1])
    if len(set(exp)) < 2:
        nbad += 1
        print("  **期望类别序列只有 1 种取值 ⇒ 判据无鉴别力")
    if verbose and nbad == 0:
        print("  鉴别力门禁：实测 %d 种取值、期望 %d 种取值，均 >= 2  PASS"
              % (len(set(got)), len(set(exp))))
    return nbad


# ===========================================================================
# 4. 变异自证
# ===========================================================================
def do_selftest(d, cls_gold, hit_gold):
    print("\n===== 变异自证：故意把**期望值**改错，确认判据会报红 =====")
    cases = [({"kind": "shift"}, "期望序列整体平移一帧"),
             ({"kind": "flip_all"}, "期望类别全体 +1"),
             ({"kind": "all_red"}, "期望全填 RED（0）")]
    for k in range(FRAMES):
        cases.append(({"kind": "flip_frame", "frame": k}, "只把第 %d 个采样点的期望改错" % k))

    caught = missed = 0
    for mut, desc in cases:
        _na, nb = check_class(d, cls_gold, hit_gold, verbose=False, mutate=mut)
        if nb > 0:
            caught += 1
        else:
            missed += 1
            print("  **漏掉**：%s（%s）—— 判据对这类错误不敏感" % (desc, mut))

    # ---- 判据 V（跟踪编号）的变异：这三条改的都是**编号状态机**的行为 ----
    id_gold = G.golden_track_ids(hit_gold)
    for mut, desc in (({"kind": "id_plus1"},   "编号整体 +1"),
                      ({"kind": "id_no_lost"}, "漏判'丢失'条件：看见目标就 +1"),
                      ({"kind": "id_stuck"},   "编号卡死不动")):
        _na, nb = check_track_id(d, id_gold, verbose=False, mutate=mut)
        if nb > 0:
            caught += 1
        else:
            missed += 1
            print("  **漏掉**：%s（%s）—— 判据对这类错误不敏感" % (desc, mut))

    print("  变异 %d 例：抓到 %d，漏 %d  %s"
          % (len(cases) + 3, caught, missed, "PASS" if missed == 0 else "FAIL"))
    return missed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", default=DEFAULT_DUMP)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    print("=" * 78)
    print("alg_color_detect_96 —— O_color_class 判据")
    print("=" * 78)
    print("dump: %s" % args.dump)
    if not os.path.isfile(args.dump):
        raise SystemExit("找不到 dump：%s" % args.dump)

    fail = 0
    print("\n----- 判据 S：激励完整性 -----")
    a, b = check_stim_files()
    fail += a + b

    frames = G.build_frames()
    cls_gold, hit_gold = golden(frames)
    print("\n  金标准逐帧类别 = %s" % (cls_gold,))
    print("  金标准逐帧有命中 = %s" % (hit_gold,))

    d = parse(args.dump)
    if d["_badlines"]:
        print("\n  **dump 有 %d 行列数不对，已跳过" % d["_badlines"])
        fail += 1
    print("\n  dump 共 %d 行；判据输出 O_tvalid 为 1 的行数 = %d"
          % (len(d["cyc"]), int((d["ov"] == 1).sum())))

    print("\n----- 判据 T：类别 + 同相性 -----")
    na, nb = check_class(d, cls_gold, hit_gold)
    fail += 1 if nb else 0
    print("  断言数 %d，不符 %d" % (na, nb))

    print("\n----- 判据 U：鉴别力门禁 -----")
    fail += check_teeth(d, cls_gold, hit_gold)

    print("\n----- 判据 V：跟踪编号（丢失→重现 ⇒ +1）-----")
    id_gold = G.golden_track_ids(hit_gold)
    print("  金标准逐帧编号（第 f 帧处理完之后）= %s" % (id_gold,))
    na, nb = check_track_id(d, id_gold)
    fail += 1 if nb else 0
    print("  断言数 %d，不符 %d" % (na, nb))
    fail += check_id_teeth(d, id_gold)

    if args.selftest:
        fail += do_selftest(d, cls_gold, hit_gold)

    print("\n" + "=" * 78)
    print("VERDICT: %s" % ("PASS" if fail == 0 else "FAIL (fail=%d)" % fail))
    print("=" * 78)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
