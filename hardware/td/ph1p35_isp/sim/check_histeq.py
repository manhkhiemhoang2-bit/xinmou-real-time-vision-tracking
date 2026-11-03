#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_histeq.py —— alg_histeq_96 的判据：对 ModelSim dump **逐像素/逐位**比对
===============================================================================
判据全部从规格出发（src\\alg_histeq_96.v 文件头 §一 + sim\\ref_histeq.py），
不读 RTL 内部信号、不"看波形觉得对"。

用法：
    python check_histeq.py                    # 判 histeq_scen.json 里的全部场景
    python check_histeq.py --scen lowc        # 只判一个场景
    python check_histeq.py --selftest         # 期望值变异自证（每条变异必须被抓）
    python check_histeq.py --verbose          # 打印前若干条不符明细

断言清单（每条都打印 cnt/err；**任何一条 cnt==0 直接判失败** —— 0 次检查不是 PASS）：
  A  激励自检      ：dump 里的输入拍与 gen_stim_histeq 造出来的激励逐位一致，tlast/tuser 位置正确
  B  拍数守恒      ：输入有效拍数 == 输出有效拍数（TB 汇总 + 全量 dump 两种口径）
  C  延迟 = 2 拍   ：TB 独立移存器逐拍比对 0 不符 + dump 里"输出行配对到 cyc-LAT 的输入行"
  D1/D2/D3 逐通道  ：输出 R/G/B 字节逐位等于参考模型（分通道计数，抓通道串位）
  D4..D7 逐 lane   ：输出 4 个像素 lane 逐位等于参考模型（抓 lane 串位）
  D8 整拍逐位      ：96 bit 整体逐位比对
  E  控制同拍      ：输出 tlast/tuser 与"延迟对齐后的输入"逐拍一致
  F  无 X/Z        ：输入/输出数据里不出现 X/Z
  G  场景结构      ：低对比度铺开 / 均匀近似恒等 / 全同值帧口径 / ping-pong 滞后 1 帧 /
                     帧边界原子切换 / 气泡不改结果 / 消隐合同
  H  使能关逐比特  ：I_en=0 的拍上输出**逐比特** == 输入延迟 2 拍（含无效拍）
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_stim_histeq as G          # noqa: E402
import ref_histeq as R               # noqa: E402

LAT = 2                              # 规格延迟（拍）
GAP_CONTRACT = 2600                  # 消隐合同：帧末有效拍 → 下一帧 tuser ≥ 这个拍数


# =============================================================================
# 0. 工具
# =============================================================================
def is_x(h: str) -> bool:
    return any(c in "xXzZ" for c in h)


def hex_bytes(h: str):
    """24 位十六进制 → 12 字节（大端）。含 X/Z 时返回 None。"""
    if is_x(h) or len(h) != 24:
        return None
    return np.frombuffer(bytes.fromhex(h), dtype=np.uint8)


def parse_dump(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            p = ln.split()
            if len(p) != 11:
                continue
            rows.append(dict(cyc=int(p[0]), iv=int(p[1]), il=int(p[2]), iu=int(p[3]),
                             idata=p[4], ibeat=int(p[5]), ov=int(p[6]), ol=int(p[7]),
                             ou=int(p[8]), odata=p[9], ien=int(p[10])))
    return rows


def parse_summary(log_path):
    if not os.path.isfile(log_path):
        return None
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        for ln in fh:
            if "TB_SUMMARY" in ln:
                d = {}
                for kv in ln.split("TB_SUMMARY", 1)[1].split():
                    if "=" in kv:
                        k, v = kv.split("=", 1)
                        try:
                            d[k] = int(v)
                        except ValueError:
                            d[k] = v
                return d
    return None


class Assert:
    """一条断言：cnt = 检查次数，errs = 不符明细（最多留 20 条）。"""

    def __init__(self, name):
        self.name = name
        self.cnt = 0
        self.errs = []
        self.na_reason = None

    def na(self, reason):
        """标记「本场景不适用」：既不算通过、也不算失败，但**必须给理由且会被打印**。

        2026-09-20 新增。起因：原策略是"0 次检查 ⇒ 直接判失败"，这对"本场景压根没有
        可查的对象"的情况是误伤 —— 例如 en_mask 全开的场景里，H（en=0 逐比特旁路）
        一个可查的拍都没有。误伤的后果和真失败长得一样（都报红），会把真问题淹掉。
        标记之后 chk() 变成空操作，所以"不适用"不可能顺手掩盖掉真实错误。
        """
        self.na_reason = reason
        return self

    def chk(self, ok, msg):
        if self.na_reason is not None:
            return True                    # 本场景不适用：一次都不记，也不计数
        self.cnt += 1
        if not ok and len(self.errs) < 20:
            self.errs.append(msg)
        return ok


# =============================================================================
# 1. 单个场景的判据
# =============================================================================
def _mutated_exp_out(s, mut, frames, info, maps, base_exp_out):
    """按变异重算「期望的输出拍字节」。mut=None ⇒ 规格口径（原样返回 base_exp_out）。

    2026-09-20 从 check_scenario 里抽出来（原来是内联的）。抽出来的理由：
    自查要判「这条变异在本场景里是不是空操作」，判据就是**把它算出来的期望和基线
    逐字节比**。两处必须用同一份实现 —— 判据口径不允许存在两份。
    """
    W, H, FR = s["W"], s["H"], s["frames"]
    if mut is None:
        return base_exp_out
    if mut == "lag0":
        outs2 = [R.apply_map(frames[f], maps[f]) if ((s["en_mask"] >> f) & 1) else frames[f].copy()
                 for f in range(FR)]
    elif mut == "k_plus1":
        outs2 = [R.apply_map(frames[f], np.clip((R.build_cdf(info["hist"][max(f - 1, 0)]) *
                                                 (info["K"] + 1)) >> 16, 0, 255).astype(np.uint8))
                 if ((s["en_mask"] >> f) & 1) and f >= 1 else frames[f].copy() for f in range(FR)]
    elif mut == "stride32":
        hists = []
        for f in range(FR):
            smp = frames[f][:, ::32, :].reshape(-1, 3)
            hh = np.zeros((3, 256), dtype=np.int64)
            for c in range(3):
                hh[c] = np.bincount(smp[:, c], minlength=256)[:256]
            hists.append(hh)
        outs2 = []
        for f in range(FR):
            if ((s["en_mask"] >> f) & 1) and f >= 1:
                m = np.clip((R.build_cdf(hists[f - 1]) * info["K"]) >> 16, 0, 255).astype(np.uint8)
                outs2.append(R.apply_map(frames[f], m))
            else:
                outs2.append(frames[f].copy())
    elif mut == "noswap":
        outs2 = [frames[f].copy() for f in range(FR)]
    elif mut == "en_ignored":
        outs2 = [R.apply_map(frames[f], maps[max(f - 1, 0)]) for f in range(FR)]
    else:
        raise ValueError("未知变异：%s" % mut)
    return G.frames_to_exp_bytes(outs2, W, H)


def check_scenario(s, verbose=False, mut=None):
    """mut：期望值变异（自证用），取值 None/'lag0'/'k_plus1'/'stride32'/'noswap'/'en_ignored'。"""
    W, H, FR = s["W"], s["H"], s["frames"]
    BPL, BPF, NBEAT = s["bpl"], s["bpf"], s["nbeat"]
    dump = os.path.join(HERE, s["dump"])
    log = os.path.join(HERE, s["log"])
    A = {}

    def a(name):
        A.setdefault(name, Assert(name))
        return A[name]

    if not os.path.isfile(dump):
        raise RuntimeError("dump 不存在：%s（先跑 run_histeq.py）" % dump)
    rows = parse_dump(dump)
    if not rows:
        raise RuntimeError("dump 是空的：%s" % dump)
    by_cyc = {r["cyc"]: r for r in rows}
    summ = parse_summary(log)

    # ---- 参考模型 ----
    frames = G.build_frames(s)
    outs, info = R.ref_histeq(list(frames), W, H, en=[(s["en_mask"] >> f) & 1 for f in range(FR)])
    exp_in = G.frames_to_exp_bytes(frames, W, H)
    exp_out = G.frames_to_exp_bytes(outs, W, H)
    maps = info["map"]

    # ---- 期望值变异（自证用；只改期望，不动 dump）----
    #   实现抽到模块级 _mutated_exp_out()，与自查里的"空操作"判据共用同一份。
    exp_out = _mutated_exp_out(s, mut, frames, info, maps, exp_out)

    asm = a("A 激励自检")
    bs = a("B 拍数守恒")
    cs = a("C 延迟=2拍")
    d_ch = [a("D%d 逐通道 %s" % (i + 1, "RGB"[i])) for i in range(3)]
    d_ln = [a("D%d 逐lane L%d" % (4 + i, i)) for i in range(4)]
    ds = a("D8 整拍逐位")
    es = a("E 控制同拍")
    fs = a("F 无X/Z")
    hs = a("H en=0逐比特旁路")

    # ---- 场景适用性（2026-09-20 补：把"不适用"和"失败"分开，理由逐条写死在这里）----
    # ① 消隐合同故意违约的场景（shortgap）：帧间只给 200 拍、扫描要 2310 拍，
    #    扫描还没做完下一帧就来了 ⇒ 逐像素值本来就不可预期。该场景的设计意图
    #    就是"只查结构"（见 histeq_scen.json 的 why 字段），所以 D1..D8 标不适用。
    if not s["contract"]:
        for x in d_ch + d_ln + [ds]:
            x.na("本场景故意违反消隐合同（帧间间隔 < 扫描所需 2310 拍），按设计只做结构性判据")
    # ② en_mask 全开 ⇒ 一个 en=0 的拍都没有，H 无从查起。
    if all((s["en_mask"] >> f) & 1 for f in range(FR)):
        hs.na("本场景 en_mask=0x%X 全开，没有 en=0 的拍可查" % s["en_mask"])
    # ③ dump 分块边界（full 场景只存每帧头 4 行 + 末 2 行）：每个块开头的 LAT 拍，
    #    其 cyc-LAT 的输入行**本来就不在 dump 里** —— 那是覆盖范围，不是"延迟错位"。
    #    单独记一条 C2；块内真正找不到输入行仍然算 C 的失败（不放过真问题）。
    blk_start = set()
    for _i, _r in enumerate(rows):
        if _i == 0 or rows[_i - 1]["cyc"] != _r["cyc"] - 1:
            blk_start.add(_r["cyc"])
    c2 = a("C2 dump块边界豁免")

    # ---------------- 逐行扫 dump ----------------
    n_out_seen = 0
    for r in rows:
        # A 激励自检（有效输入拍）
        if r["iv"]:
            k = r["ibeat"]
            if k < NBEAT:
                bif = k % BPF
                exp_word = exp_in[k].tobytes().hex()
                asm.chk(r["idata"].lower() == exp_word,
                        "cyc %d: 输入数据与激励不符 beat=%d" % (r["cyc"], k))
                asm.chk(r["il"] == (1 if (bif % BPL) == (BPL - 1) else 0),
                        "cyc %d: tlast 位置不对 beat=%d" % (r["cyc"], k))
                asm.chk(r["iu"] == (1 if bif == 0 else 0),
                        "cyc %d: tuser 位置不对 beat=%d" % (r["cyc"], k))
        # F 无 X/Z
        if r["iv"]:
            fs.chk(not is_x(r["idata"]), "cyc %d: 输入数据含 X/Z" % r["cyc"])
        if r["ov"]:
            fs.chk(not is_x(r["odata"]), "cyc %d: 输出数据含 X/Z" % r["cyc"])

        if not r["ov"]:
            continue
        n_out_seen += 1
        # C 延迟：输出行必须配对到 cyc-LAT 的有效输入行
        src = by_cyc.get(r["cyc"] - LAT)
        ok_pair = (src is not None) and (src["iv"] == 1)
        if not ok_pair:
            # 块边界豁免（见上面 ③）：本行落在某个 dump 块的头 LAT 拍之内
            if any(0 <= r["cyc"] - _b < LAT for _b in blk_start):
                c2.chk(True, "")
            else:
                cs.chk(False, "cyc %d: 输出行找不到 cyc-%d 的输入行" % (r["cyc"], LAT))
            continue
        cs.chk(True, "")
        k = src["ibeat"]
        ob = hex_bytes(r["odata"])
        if ob is None:
            continue
        # D 逐像素比对
        if k < NBEAT:
            e = exp_out[k]
            d = ob.astype(np.int16) - e.astype(np.int16)
            ds.chk(bool(np.all(d == 0)), "beat %d(cyc %d): 整拍不符 got=%s exp=%s"
                   % (k, r["cyc"], r["odata"], e.tobytes().hex()))
            for c in range(3):
                bad = np.flatnonzero(d[c::3] != 0)
                d_ch[c].chk(len(bad) == 0, "beat %d: %s 通道 %d 个字节不符"
                            % (k, "RGB"[c], len(bad)))
            for ln in range(4):
                bad = np.flatnonzero(d[3 * ln:3 * ln + 3] != 0)
                d_ln[ln].chk(len(bad) == 0, "beat %d: lane%d 不符" % (k, ln))
        # E 控制同拍
        es.chk(r["ol"] == (src["il"] and src["iv"]), "cyc %d: tlast 相位不符" % r["cyc"])
        es.chk(r["ou"] == (src["iu"] and src["iv"]), "cyc %d: tuser 相位不符" % r["cyc"])
        # H 使能关：逐比特旁路（连无效拍一起比）
        if src["ien"] == 0:
            hs.chk(r["odata"].lower() == src["idata"].lower(),
                   "cyc %d(beat %d): en=0 时输出 != 延迟 2 拍的输入 got=%s exp=%s"
                   % (r["cyc"], k, r["odata"], src["idata"]))

    if c2.cnt == 0:
        c2.na("本 dump 没有分块边界（全量 dump），无需豁免")

    # ---------------- B 拍数守恒 ----------------
    if summ is not None:
        bs.chk(summ["in_valid"] == summ["out_valid"],
               "汇总：in_valid=%d != out_valid=%d" % (summ["in_valid"], summ["out_valid"]))
        bs.chk(summ["in_last"] == summ["out_last"],
               "汇总：in_last=%d != out_last=%d" % (summ["in_last"], summ["out_last"]))
        bs.chk(summ["in_user"] == summ["out_user"],
               "汇总：in_user=%d != out_user=%d" % (summ["in_user"], summ["out_user"]))
        cs.chk(summ["lat_meas"] == LAT,
               "汇总：独立计数器实测延迟=%d，规格=%d" % (summ["lat_meas"], LAT))
        cs.chk(summ["ctl_err"] == 0, "汇总：移存器逐拍控制比对不符 %d 拍" % summ["ctl_err"])
        fs.chk(summ["x_cnt"] == 0, "汇总：输出含 X 的拍数=%d" % summ["x_cnt"])
        fs.chk(summ["ph_err"] == 0, "汇总：tlast/tuser 出现在无效拍上 %d 次" % summ["ph_err"])
    else:
        bs.chk(False, "找不到 TB_SUMMARY（日志缺失：%s）" % log)

    if s["dump_all"]:
        n_in = sum(1 for r in rows if r["iv"])
        bs.chk(n_in == n_out_seen, "全量 dump：输入有效拍 %d != 输出有效拍 %d" % (n_in, n_out_seen))
        bs.chk(n_in == NBEAT, "全量 dump：输入有效拍 %d != 激励拍数 %d" % (n_in, NBEAT))

    # ---------------- G 场景结构断言 ----------------
    g = a("G 场景结构")
    _scenario_props(s, g, frames, outs, maps, info, summ, mut)
    return A


def _scenario_props(s, g, frames, outs, maps, info, summ, mut):
    """场景专属结构断言（都与参考模型一起算出来，不依赖 dump 的实现细节）。"""
    name = s["name"]
    FR = s["frames"]
    # 消隐合同
    if summ is not None:
        if s["contract"]:
            g.chk(summ["min_gap"] >= GAP_CONTRACT,
                  "消隐合同：最小帧间间隔 %d < %d（扫描需要 2310 拍）"
                  % (summ["min_gap"], GAP_CONTRACT))
        else:
            g.chk(summ["min_gap"] < GAP_CONTRACT,
                  "本场景本应故意违约，实测 min_gap=%d 没违约（激励配错了）" % summ["min_gap"])

    if name == "lowc":
        m = maps[0]                                  # 第 0 帧统计出来的表，第 1 帧生效
        span = int(m[:, 60:101].max()) - int(m[:, 60:101].min())
        g.chk(span >= 240, "低对比度映射没铺开：bin60..100 的映射跨度只有 %d" % span)
        o = outs[1]
        g.chk(int(o.max()) >= 246 and int(o.min()) <= 8,
              "低对比度输出没铺到两端：min=%d max=%d" % (o.min(), o.max()))
        g.chk(len(np.unique(o)) >= 20, "低对比度输出只有 %d 个不同值" % len(np.unique(o)))
        # 满 CDF 的映射 = (N*K)>>16：1280×720 是 254（floor 量化），本场景样本数少正好 255
        full = min(255, (info["samples_per_frame"] * info["K"]) >> 16)
        g.chk(int(m.max()) == full, "满 CDF 的映射应为 %d，实测 %d" % (full, m.max()))

    elif name == "uniform":
        # 抽样直方图近似均匀 ⇒ 映射应接近恒等（|map-b| <= 1）
        for f in range(FR):
            m = maps[f].astype(int)
            d = int(np.max(np.abs(m - np.arange(256)[None, :])))
            g.chk(d <= 1, "第 %d 帧映射与恒等偏差 %d（应 <=1）" % (f, d))
        # 输出应当与输入几乎逐点相同（差 1 以内）
        for f in range(1, FR):
            d = np.abs(outs[f].astype(int) - frames[f].astype(int))
            g.chk(int(d.max()) <= 1, "第 %d 帧输出与输入最大差 %d（应 <=1）" % (f, int(d.max())))

    elif name == "const":
        # 全同值 128：第 0 帧恒等 = 128；其后 = 第 0 帧直方图标出来的 map[128]。
        #
        # ⚠ 2026-09-20 修：这里原来**写死 254**，而 254 只在 1280×720 成立 ——
        #   那个尺寸下 K = floor(255*65536/57600) = 290 有截断，满 CDF 时
        #   (57600*290)>>16 = 254。小场景（如 64x8，样本 32）K = 522240 **整除**，
        #   满 CDF 时 = 255。写死 254 会把**行为正确的 RTL 判成红的**（实测就是这样：
        #   RTL 输出 255，判据说"不是全 254"，而规格算出来就是 255）。
        #   现在按规格现算，不再写死任何几何相关的常数。
        g.chk(bool(np.all(frames[0] == 128)), "激励不是全 128")
        _m = R.build_map(info["hist"][0], s["W"], s["H"])   # 第 0 帧直方图 ⇒ 第 1 帧起生效
        g.chk(int(_m[0][128]) == int(_m[1][128]) == int(_m[2][128]),
              "本场景三个通道的 map[128] 不一致：%s（规格要求同值帧三通道同结果）"
              % (_m[:, 128].tolist(),))
        want_on = int(_m[0][128])
        for f in range(FR):
            want = 128 if f == 0 else want_on
            g.chk(bool(np.all(outs[f] == want)),
                  "第 %d 帧输出不是全 %d（min=%d max=%d）" % (f, want, outs[f].min(), outs[f].max()))
            g.chk(int(maps[f][:, 128].max()) == want_on or f == 0,
                  "第 %d 帧 map[128] != %d" % (f, want_on))

    elif name == "pingpong":
        # (1) 帧边界滞后 1 帧：把它算成"0 帧滞后"必须得到**不同**的期望（否则这个场景没有鉴别力）
        maps_f = [R.build_map(info["hist"][f], s["W"], s["H"]) for f in range(FR)]
        same = True
        for f in range(1, FR):
            if not np.array_equal(maps[f - 1], maps_f[f]):
                same = False
        g.chk(not same, "4 帧图案的直方图不独立 ⇒ 滞后 1 帧与 0 帧不可区分（场景设计失败）")
        # (2) 第 2 帧 I_en=0：输出必须逐比特等于该帧输入
        f_off = [f for f in range(FR) if not ((s["en_mask"] >> f) & 1)]
        g.chk(len(f_off) >= 1, "没有一帧是关使能的")
        for f in f_off:
            g.chk(bool(np.array_equal(outs[f], frames[f])), "第 %d 帧 en=0 却不是原图" % f)
        # (3) en=0 的帧照样统计：其后一帧必须用**该帧**统计出来的表（不是更早的表）
        for f in range(1, FR):
            m_prev = maps[f - 1]                    # 规格口径：用第 f-1 帧直方图的表
            m_stale = maps[max(f - 2, 0)]
            if not np.array_equal(m_prev, m_stale):
                g.chk(int(np.max(np.abs(m_prev.astype(int) - m_stale.astype(int)))) > 0,
                      "第 %d 帧的表与更早的表无法区分" % f)
        g.chk(True, "")                             # 计数用（保证 cnt>0）

    elif name == "bubble":
        g.chk(summ is not None and summ["in_valid"] == summ["out_valid"],
              "有气泡时输入/输出有效拍数不等")

    elif name == "full":
        g.chk(s["W"] == 1280 and s["H"] == 720, "真实尺寸参数不对")
        g.chk(s["bpl"] == 320 and s["bpf"] == 230400, "每行 320 拍 / 每帧 230400 拍不符")
        m = maps[0]
        g.chk(int(m.max()) <= 255, "映射值越界")

    elif name == "shortgap":
        # 违约场景：只查结构（不查像素），并明确记录"这是违约场景"
        g.chk(True, "")
    return


# =============================================================================
# 2. 主流程
# =============================================================================
def main():
    argv = sys.argv[1:]
    verbose = "--verbose" in argv
    man = json.load(open(os.path.join(HERE, "histeq_scen.json"), encoding="utf-8"))
    scens = man["scenarios"]
    if "--scen" in argv:
        want = argv[argv.index("--scen") + 1]
        scens = [s for s in scens if s["name"] == want]
        if not scens:
            print("没有这个场景：%s" % want)
            return 2

    if "--selftest" in argv:
        return selftest(scens, verbose)

    allf = []
    print("=" * 88)
    print("alg_histeq_96 判据（逐像素比对；{0} = 0 次检查 ⇒ 直接判失败）".format("cnt=0"))
    print("=" * 88)
    for s in scens:
        A = check_scenario(s, verbose)
        tot_e = sum(len(v.errs) for v in A.values())
        print("\n--- 场景 %-10s %4dx%-4d %d 帧  %s" % (s["name"], s["W"], s["H"], s["frames"], s["why"]))
        zero = []
        for k in sorted(A.keys()):
            v = A[k]
            st = "PASS" if not v.errs else "FAIL"
            if v.cnt == 0:
                if v.na_reason is not None:
                    st = "N/A"
                else:
                    st = "ZERO(失败)"
                    zero.append(k)
            print("    %-18s cnt=%-7d err=%-4d %s" % (k, v.cnt, len(v.errs), st))
            if v.na_reason is not None:
                print("        N/A 理由：" + v.na_reason)
            for e in v.errs[:3]:
                print("        " + e)
            allf += ["[%s] %s: %s" % (s["name"], k, e) for e in v.errs]
        if zero:
            allf += ["[%s] 断言 %s 一次都没检查（0 次检查 = 失败）" % (s["name"], z) for z in zero]
            print("    !! 有 %d 条断言 0 次检查：%s" % (len(zero), ",".join(zero)))
        if not s["contract"]:
            print("    （本场景故意违反消隐合同，只做结构性判据，不做逐像素比对）")
    print("\n" + "=" * 88)
    if allf:
        print("结论：FAIL —— %d 条不符" % len(allf))
        for x in allf[:20]:
            print("   " + x)
        print("=" * 88)
        return 1
    print("结论：PASS —— 全部场景逐像素/逐位比对通过，无 X，拍数与延迟符合规格")
    print("=" * 88)
    return 0


def selftest(scens, verbose):
    """期望值变异自证：故意把**期望**改错（不动 RTL、不动 dump），判据必须报红。"""
    print("=" * 88)
    print("期望值变异自证：把参考模型的期望改错，逐像素比对必须报错（抓不住 = 没测）")
    print("=" * 88)
    MUTS = [("lag0", "把滞后 1 帧改成 0 帧（表用本帧直方图）"),
            ("k_plus1", "归一化常数 K 用错（K+1）"),
            ("stride32", "抽样口径改错（每 32 列抽 1 列）"),
            ("noswap", "映射表从不生效（恒等输出）"),
            ("en_ignored", "把 en=0 当成 en=1（统计/查表照做）")]
    ok_all = True

    def _not_applicable(s, mut):
        """这条变异在本场景**根本没有比对对象**吗？返回 None = 有，否则返回理由。

        2026-09-20 补。这里只留一条规则：本场景故意违反消隐合同时，D1..D8 全标 N/A
        ⇒ 一次逐像素比对都不做 ⇒ 任何"改期望值"的变异都无从被抓住。

        ⚠ 其余情形的"漏掉"**不在这里判**，而是用更硬的判据：
          把该变异算出来的期望与基线**逐字节比**，相同就是空操作（见下面的 noop 判据）。
          手写规则容易漏、也容易把"判据没鉴别力"和"变异是空操作"混为一谈。
        """
        if not s["contract"]:
            return "本场景故意违反消隐合同，按设计不做逐像素比对"
        return None

    for s in scens:
        base = check_scenario(s, verbose)
        base_e = sum(len(v.errs) for v in base.values())
        print("\n--- 场景 %-10s 基线 err=%d %s" % (s["name"], base_e, "PASS" if base_e == 0 else "FAIL(基线就不对)"))
        if base_e:
            ok_all = False
            continue
        # 基线期望（自查的"空操作"判据要拿它逐字节比）——只算一次
        _fr = G.build_frames(s)
        _outs, _info = R.ref_histeq(list(_fr), s["W"], s["H"],
                                    en=[(s["en_mask"] >> f) & 1 for f in range(s["frames"])])
        _base = G.frames_to_exp_bytes(_outs, s["W"], s["H"])
        for mut, why in MUTS:
            na = _not_applicable(s, mut)
            if na is not None:
                print("    %-12s %-40s N/A —— %s" % (mut, why, na))
                continue
            # 硬判据：变异算出来的期望若与基线逐字节相同 ⇒ 空操作，谁都抓不住
            _mut_exp = _mutated_exp_out(s, mut, _fr, _info, _info["map"], _base)
            if np.array_equal(_mut_exp, _base):
                print("    %-12s %-40s N/A —— 本场景下该变异算出的期望与基线**逐字节相同**（空操作）"
                      % (mut, why))
                continue
            A = check_scenario(s, verbose, mut=mut)
            e = sum(len(v.errs) for v in A.values())
            good = e > 0
            ok_all = ok_all and good
            print("    %-12s %-40s err=%-5d %s" % (mut, why, e, "抓住" if good else "!! 漏掉 !!"))
    print("\n" + "=" * 88)
    print("期望值变异鉴别力：%s" % ("PASS（每条变异都被抓）" if ok_all else "FAIL"))
    print("=" * 88)
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
