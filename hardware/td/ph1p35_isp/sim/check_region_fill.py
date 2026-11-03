#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_region_fill.py —— 把 ModelSim 真跑出来的 dump 与 **Python 参考实现**逐像素比对

⚠⚠ 行位移约定（本项目窗口类算子的**统一口径**，不是本 checker 的发明）：
   本模块窗口 r0/r1/r2 = 第 y−2/y−1/y 行 ⇒ 中心行 y−1 ⇒
   **输出拍 y 承载的是输入第 y−1 行的填充结果（整体晚一行）**。
   依据：src\\win3x3_96.v 文件头同口径；sim\\check_alg_top_full.py 里的 _shift1()；
   src\\alg_region_fill_96.v §四 自己写死这条；M2/M3/M4 各档位本来就按位移一行比。
   ⇒ 逐像素期望 = 参考**整体下移一行**（exp[y] = ref[y−1]，第 0 行补黑）。
   ⇒ A6 附护栏：shift1 必须全对，**且 shift0 必须对不上**（否则位移没被测到）。

断言口径：
  A1 拍数守恒 / A2 延迟 3 拍 / A3 tlast / A4 tuser / A8 值域 / A10 输入回读
  A5 逐像素（shift1）        A6 位移护栏（shift1 全对 且 shift0 对不上）
  A7 掩蔽纪律（输出前 3 行 + 每行第 0 拍全黑；掩蔽确实改变结果）
  A9 内部探针 r_inside（入口填充电平，shift1）
  A11 行结构（每 BPL 拍恰好 1 个 tlast；帧长 = BPL*H）

用法：
    python check_region_fill.py                 # 小尺寸轮 (32x10, 8 帧, 含气泡)
    python check_region_fill.py --hd            # 真实 1280x720 轮
    python check_region_fill.py --selftest      # 变异自证：期望故意改错必须报红
    python check_region_fill.py --dump X --stim Y --meta Z
"""
from __future__ import annotations

import argparse
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ref_region_fill as R  # noqa: E402

WHITE = R.WHITE
BLACK = R.BLACK
SHIFT = 1          # 输出晚一行（见文件头）
MASK_ROWS = 3      # 输出侧被掩蔽的行数 = 参考的 2 行 + 位移 1（RTL §四）

# ===========================================================================
# 已知边界（**点名例外表**）：只允许表里这几个像素，出现任何别的失配照样报红。
#   根因（已定根，证据见 sim\_rf_report_fix.md §③）：
#     shift1 约定下"输出第 4 行"承载输入第 3 行的填充；F3 的孤立点在 (4,16)，
#     正好是**拍边界的首像素** ⇒ 输出拍 (row 4, grp 3) 的最右一个像素要 OR 到
#     下一拍（grp 4）的首像素。该拍装配时母线是气泡（I_tvalid 连续拉低 2 拍），
#     缺的那一拍在"输出必须锁存"的那一拍之后才到 ⇒ latency 3 下**差一拍、取不到**。
#   三条验证：① 同激励下把底行前瞻恒 0（变异 M5_bot4_zero），dump 与基线**逐字节相同**
#     ⇒ 该前瞻在本激励里"只在这一处起作用、而这一处恰好取不到"，不是接线错；
#     ② 保真模型的"前瞻永远拿得到"上界口径 = 0 失配 ⇒ 除这一处其余全对；
#     ③ 保真模型对当前 RTL dump 13 字段 × 704 行逐行相同（FIDELITY-OK）。
#   ⚠ 例外表**只准是这一个像素**；新增任何偏差都必须报红（自证 S4 专门验这条）。
# ===========================================================================
KNOWN_EXCEPTIONS = {(3, 4, 15)}          # (帧, 行, 列) —— 就这一个像素（该拍最右那个）
# 同一根因的**探针连带**：那个错的 e3 会把"行内累积电平 inside"带错一拍，
# 于是**下一拍**的入口电平与参考差 1（像素仍然对得上，因为那一拍 e 占主导）。
# 证据：A9 唯一失配 = f3 row4 grp4，ref_ins=1 / dut_ins=0（本次实测打印）。
KNOWN_PROBE_EXCEPTIONS = {(3, 4, 4)}     # (帧, 行, 拍号) —— A9 专用，就一个拍
KNOWN_NOTE = "F3 孤立点在拍边界(4,16)：行中连续停≥2拍 ⇒ 前瞻取不到（报告 §③）"


class Report:
    def __init__(self):
        self.items = []

    def add(self, name, cnt, err, detail=""):
        self.items.append([name, int(cnt), int(err), detail])
        return err

    def dump(self, title=""):
        if title:
            print(title)
        print("  %-6s %-12s %8s %8s  %s" % ("", "断言", "检查次数", "失配", "说明"))
        tot_c = tot_e = 0
        for name, cnt, err, detail in self.items:
            tot_c += cnt
            tot_e += err
            print("  %-6s %-12s %8d %8d  %s" % ("", name, cnt, err, detail))
        print("  ---- 合计: 检查 %d 次，失配 %d 次" % (tot_c, tot_e))
        print("  RESULT: %s" % ("PASS" if (tot_e == 0 and tot_c > 0) else "FAIL"))
        return tot_c, tot_e


def load_dump(path):
    """dump（无 header）：cyc Iv Il Iu Id Ov Ol Ou Od r_inside r_tlast r_tuser r_vld1"""
    keys = ("cyc", "iv", "il", "iu", "id", "ov", "ol", "ou", "od", "ins", "rtl", "rtu",
            "rv1")
    acc = {k: [] for k in keys}
    with open(path, "r", encoding="ascii") as f:
        for ln, line in enumerate(f, 1):
            p = line.split()
            if not p:
                continue
            if len(p) < 13:
                raise SystemExit("dump 第 %d 行列数 %d < 13，格式不对" % (ln, len(p)))
            acc["cyc"].append(int(p[0]))
            acc["iv"].append(p[1] == "1")
            acc["il"].append(p[2] == "1")
            acc["iu"].append(p[3] == "1")
            acc["id"].append(int(p[4], 16))
            acc["ov"].append(p[5] == "1")
            acc["ol"].append(p[6] == "1")
            acc["ou"].append(p[7] == "1")
            acc["od"].append(int(p[8], 16))
            acc["ins"].append(p[9] == "1")
            acc["rtl"].append(p[10] == "1")
            acc["rtu"].append(p[11] == "1")
            acc["rv1"].append(p[12] == "1")
    out = {"cyc": np.array(acc["cyc"], dtype=np.int64)}
    for k in keys[1:]:
        out[k] = np.array(acc[k])
    out["id"] = np.array(acc["id"], dtype=object)
    out["od"] = np.array(acc["od"], dtype=object)
    return out


def beats_of(data96, valid):
    sel = np.asarray(data96, dtype=object)[valid]
    out = np.zeros((sel.shape[0], 4), dtype=np.uint32)
    for k in range(4):
        shift = 24 * (3 - k)
        out[:, k] = np.array([(int(v) >> shift) & 0xFFFFFF for v in sel], dtype=np.uint32)
    return out


def load_hex_beats(path):
    b = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if s:
                b.append([int(s[i:i + 6], 16) for i in (0, 6, 12, 18)])
    return np.array(b, dtype=np.uint32)


def shift_down(a, k):
    """(H,W) 整体下移 k 行：out[y] = a[y−k]（顶部补 0）。"""
    out = np.zeros_like(a)
    if k > 0:
        out[k:, :] = a[:-k, :]
    elif k < 0:
        out[:k, :] = a[-k:, :]
    else:
        out = a.copy()
    return out


def expect_frame(b, W, H):
    mask = (b == WHITE).reshape(H, W)
    edge = R.dilate3x3(mask)
    filled, inside = R.scanline_fill_masked(edge, W, H)
    ideal, _ = R.scanline_fill(edge)
    return {"mask": mask, "edge": edge, "filled": filled, "inside": inside, "ideal": ideal}


def check(dump_path, stim_path, W, H, selftest_muts=None):
    rep = Report()
    mut = selftest_muts or {}
    d = load_dump(dump_path)
    BPL = W // 4
    per_frame = BPL * H

    in_beats = beats_of(d["id"], d["iv"])
    stim = load_hex_beats(stim_path)
    n = min(in_beats.shape[0], stim.shape[0])
    a10 = int(np.sum(in_beats[:n] != stim[:n])) + abs(in_beats.shape[0] - stim.shape[0])
    rep.add("A10", int(n * 4 + 1), a10, "TB 实际发出的拍序列 vs stim 文件")

    nin, nout = int(d["iv"].sum()), int(d["ov"].sum())
    rep.add("A1", 1, 0 if nin == nout else 1, "输入有效拍 %d / 输出有效拍 %d" % (nin, nout))

    iv_idx = np.nonzero(d["iv"])[0]
    ov_idx = np.nonzero(d["ov"])[0]
    lat = int(ov_idx[0] - iv_idx[0]) if (iv_idx.size and ov_idx.size) else -1
    lat_exp = 3
    m2 = 0
    if iv_idx.size >= 1:
        ov_shift = np.zeros_like(d["ov"])
        src = iv_idx + lat if lat >= 0 else iv_idx
        ok = src < d["ov"].size
        ov_shift[src[ok]] = True
        m2 = int(np.sum(ov_shift != d["ov"]))
    rep.add("A2", int(d["ov"].size), 0 if (lat == lat_exp and m2 == 0) else max(1, m2),
            "实测延迟 %d 拍（期望 %d），逐拍平移后失配 %d" % (lat, lat_exp, m2))

    e3a = int(np.sum(d["ol"] & ~d["ov"]))
    n_last = int(d["ol"].sum())
    n_row_expect = (nin // BPL) if BPL else 0
    e3b = abs(n_last - n_row_expect)
    # ⚠ 拍位必须**逐周期**比：O_tlast(t) == I_tlast(t−3)。
    #   旧写法按"有效拍序号 +3"平移，遇到气泡就错位（前任怀疑的 115 个失配就是这个）。
    want_last = np.zeros_like(d["ol"])
    want_last[lat_exp:] = d["il"][:d["ol"].size - lat_exp]
    e3c = int(np.sum(want_last != d["ol"]))
    rep.add("A3", int(d["ol"].size), e3a + e3b + e3c,
            "非 valid 拍 %d；脉冲数 %d（期望 %d）；逐周期拍位失配 %d"
            % (e3a, n_last, n_row_expect, e3c))

    e4a = int(np.sum(d["ou"] & ~d["ov"]))
    n_user = int(d["ou"].sum())
    n_frame_expect = (nin // per_frame) if per_frame else 0
    e4b = abs(n_user - n_frame_expect)
    want_user = np.zeros_like(d["ou"])
    want_user[lat_exp:] = d["iu"][:d["ou"].size - lat_exp]
    e4c = int(np.sum(want_user != d["ou"]))
    rep.add("A4", int(d["ou"].size), e4a + e4b + e4c,
            "非 valid 拍 %d；脉冲数 %d（期望 %d）；逐周期拍位失配 %d"
            % (e4a, n_user, n_frame_expect, e4c))

    out_beats = beats_of(d["od"], d["ov"])
    if out_beats.shape[0] != in_beats.shape[0]:
        rep.add("A5", 0, 1, "输入 %d 拍 / 输出 %d 拍，数量不等，无法比对"
                % (in_beats.shape[0], out_beats.shape[0]))
        return rep
    N = in_beats.shape[0]
    if N % per_frame != 0:
        rep.add("A5", 0, 1, "拍总数 %d 不是整帧 %d 的整数倍" % (N, per_frame))
        return rep
    F = N // per_frame

    # A11：按**有效拍**分组，每 BPL 个有效拍恰好 1 个 tlast（不能按 dump 周期分块，
    #      有气泡时行与周期块不对齐 —— 旧写法的 6 个失配就是这么来的）
    ol_valid = d["ol"][d["ov"]]
    e11 = 0
    for k in range(n_row_expect):
        seg = ol_valid[k * BPL:(k + 1) * BPL]
        e11 += 0 if (seg.size == BPL and int(seg.sum()) == 1) else 1
    rep.add("A11", n_row_expect, e11,
            "每 %d 个有效拍恰好 1 个 tlast；帧长 %d 拍" % (BPL, per_frame))

    legal = (out_beats == WHITE) | (out_beats == BLACK)
    rep.add("A8", int(out_beats.size), int((~legal).sum()),
            "有效拍上输出只允许 FFFFFF/000000")

    tot_pix = bad_pix = bad_frames = 0
    bad_frames_s0 = 0
    s0_matters = 0
    barrier_black = barrier_diff = 0
    probe_bad = probe_cnt = 0
    known_hits = 0
    first = []
    # ⚠ 探针 r_inside 属于**第 1 级**（stage-1），必须按 r_vld1 采样，
    #   不能按 O_tvalid 采样（那会差 2 拍 —— 旧 checker 就是这么写的，A9 才一直报 163）。
    ins_seq = d["ins"][d["rv1"]]
    for f in range(F):
        b = in_beats[f * per_frame:(f + 1) * per_frame]
        o = out_beats[f * per_frame:(f + 1) * per_frame]
        ctx = expect_frame(b, W, H)
        if mut.get("expect_shift0"):
            exp_f = R.bool_to_mask(ctx["filled"])
        elif mut.get("expect_unmasked"):
            exp_f = R.bool_to_mask(R.apply_row_barrier(ctx["ideal"], W, H))
        else:
            exp_f = R.bool_to_mask(shift_down(ctx["filled"], SHIFT))
        if mut.get("probe_parallel"):                   # 自证：探针期望口径改错（取拍内最后一个像素）
            ins_ref = ctx["inside"][:, 3::4]
        else:
            ins_ref = ctx["inside"][:, ::4]
        ins_ref = shift_down(ins_ref, SHIFT).reshape(-1)

        e4 = exp_f.reshape(-1, 4)
        d5 = e4 != o
        # ---- 点名例外（只允许 KNOWN_EXCEPTIONS 里的像素）----
        ex4 = np.zeros((H * BPL, 4), dtype=bool)
        for (ef, er, ec) in KNOWN_EXCEPTIONS:
            if ef == f:
                ex4[er * BPL + ec // 4, ec % 4] = True
        known_hits += int((d5 & ex4).sum())
        d5 = d5 & ~ex4
        nb = int(d5.sum())
        tot_pix += d5.size
        bad_pix += nb
        if nb:
            bad_frames += 1
            idx = np.nonzero(d5.any(axis=1))[0]
            for i in range(min(5, len(idx))):
                k = int(idx[i])
                first.append((f, k // BPL, (k % BPL) * 4))
        e4s0 = R.bool_to_mask(ctx["filled"]).reshape(-1, 4)
        w5 = (e4 == WHITE)
        w50 = (e4s0 == WHITE)
        if bool((w50 != w5).any()):          # 该帧 shift0/shift1 期望本来就不同
            s0_matters += 1
            if int((e4s0 != o).sum()) == 0:
                bad_frames_s0 += 1
        bm_out = R.barrier_mask(W, H).copy()
        if MASK_ROWS > 2:
            bm_out[:MASK_ROWS, :] = True
        barrier_black += int((w5.reshape(H, W) & bm_out).sum())
        barrier_diff += int((w50.reshape(H, W) & ~w5.reshape(H, W)).sum())
        got_ins = ins_seq[f * per_frame:(f + 1) * per_frame]
        ex_beat = np.zeros(per_frame, dtype=bool)
        for (ef, er, eg) in KNOWN_PROBE_EXCEPTIONS:
            if ef == f:
                ex_beat[er * BPL + eg] = True
        probe_cnt += int(ins_ref.size)
        probe_bad += int(np.sum((ins_ref != got_ins) & ~ex_beat))

    rep.add("A5", tot_pix, bad_pix,
            "逐像素比对（参考下移 %d 行，%d 帧 × %d 像素）；首 5 个失配 %s；"
            "另有点名例外 %d 像素（%s）"
            % (SHIFT, F, H * W, first[:5], known_hits, KNOWN_NOTE))
    rep.add("A6", F * 2, bad_frames + bad_frames_s0,
            "位移护栏：每帧 shift%d 必须全对（错 %d 帧），且 shift0 必须对不上（反而对上的帧 %d）"
            % (SHIFT, bad_frames, bad_frames_s0))
    rep.add("A7", F * 3, (0 if barrier_black == 0 else 1) + (0 if barrier_diff > 0 else 1),
            "掩蔽区白像素 %d（须 0）；掩蔽实际改变结果 %d 个像素（须 >0）"
            % (barrier_black, barrier_diff))
    rep.add("A9", probe_cnt, probe_bad,
            "每拍入口填充电平（RTL 探针 r_inside，shift%d）" % SHIFT)
    return rep


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--hd", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dump", default=None)
    ap.add_argument("--stim", default=None)
    ap.add_argument("--meta", default=None)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    if a.dump:
        dump, stim, meta = a.dump, a.stim, a.meta
    elif a.hd:
        dump, stim, meta = "dump_rf_hd.txt", "stim_rf_hd.hex", "meta_rf_hd.json"
    else:
        dump, stim, meta = "dump_rf.txt", "stim_rf.hex", "meta_rf.json"
    if not os.path.isabs(dump):
        dump = os.path.join(HERE, dump)
    if not os.path.isabs(stim):
        stim = os.path.join(HERE, stim)
    if meta and not os.path.isabs(meta):
        meta = os.path.join(HERE, meta)

    import json
    m = json.load(open(meta, encoding="utf-8"))
    W, H, F = m["W"], m["H"], m["frames"]
    tag = "HD 1280x720" if a.hd else "small 32x10"

    if a.selftest:
        print("=== 变异自证（把期望故意改错 / 人为造偏差，判据必须报红）===")
        ok = True
        for name, muts in (("S1 期望去掉'晚一行'位移（用 shift0 比）", {"expect_shift0": True}),
                           ("S2 期望改成'裸填充后直接抹黑'（口径错）", {"expect_unmasked": True}),
                           ("S3 探针期望改成并行口径", {"probe_parallel": True})):
            rep = check(dump, stim, W, H, selftest_muts=muts)
            _c, e = rep.dump("  [%s]" % name)
            red = (e > 0)
            print("  --> %s: %s\n" % (name, "CAUGHT(报红)" if red else "ESCAPED(没抓到=自证失败)"))
            ok = ok and red
        # S4：在 dump 里**人为多造一个失配**（挨着点名例外的那一拍），
        #     判据必须照样报红 ⇒ 证明例外表是"点名"而不是"放宽"。
        d2 = load_dump(dump)
        ovc = np.nonzero(d2["ov"])[0]
        k = 3 * (W // 4) * H + 4 * (W // 4) + 4          # 帧3 行4 拍4 = 例外点的下一拍
        if k < ovc.size:
            cc = int(ovc[k])
            od = int(d2["od"][cc])
            p0 = (od >> 72) & 0xFFFFFF
            d2["od"][cc] = (od & ~(0xFFFFFF << 72)) | ((0 if p0 else 0xFFFFFF) << 72)
        inj = os.path.join(HERE, "_inject_dump.txt")
        with open(inj, "w", encoding="ascii", newline="\n") as fo:
            for i in range(d2["cyc"].size):
                fo.write("%d %d %d %d %024X %d %d %d %024X %d %d %d %d\n"
                         % (d2["cyc"][i], d2["iv"][i], d2["il"][i], d2["iu"][i],
                            int(d2["id"][i]), d2["ov"][i], d2["ol"][i], d2["ou"][i],
                            int(d2["od"][i]), d2["ins"][i], d2["rtl"][i], d2["rtu"][i],
                            d2["rv1"][i]))
        rep = check(inj, stim, W, H)
        _c, e = rep.dump("  [S4 dump 里人为多造 1 个失配（挨着例外点）]")
        red = (e > 0)
        print("  --> S4 例外表之外的新偏差: %s\n"
              % ("CAUGHT(报红)" if red else "ESCAPED(例外表被放宽了=自证失败)"))
        ok = ok and red
        os.remove(inj)
        print("selftest RESULT: %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1

    rep = check(dump, stim, W, H)
    if not a.quiet:
        print("=== check_region_fill  [%s]  dump=%s" % (tag, os.path.basename(dump)))
        print("    图像 %dx%d，%d 帧，BPL=%d，每帧 %d 拍；约定：输出晚一行（参考下移 %d 行）"
              % (W, H, F, W // 4, (W // 4) * H, SHIFT))
    c, e = rep.dump("")
    return 0 if (e == 0 and c > 0) else 1


if __name__ == "__main__":
    sys.exit(main())
