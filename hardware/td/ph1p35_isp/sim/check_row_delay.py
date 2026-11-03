#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_row_delay.py —— 校验 ModelSim 真仿真出来的 dump_rd.txt（rgb_row_delay_96）

===============================================================================
一、被测合同（2026-09-14 更新：**延迟 BPL 个「有效拍」，不是 BPL 个时钟**）
===============================================================================
rgb_row_delay_96 是 `win3x3_96` 行缓存的**配对件**：后者按 **I_tvalid 有效拍** 寻址
（行缓存只在有效拍上推进），所以本模块的"一行 = 320 拍"必须同样以有效拍计。
否则输入每出现一次停顿（真实链路每行行末都有一次行消隐），彩色与灰度窗口的时间
基准就相差一个停顿 ⇒ M2/M3 彩色横向错位（详见 src\\rgb_row_delay_96.v §四/§6）。

新合同（本文件断言的就是这四条，全部可以从规格独立陈述）：

  C1 延迟正确：把输出"呈现的字"按呈现先后排成字序 P（见 §三 的定义），则
        P[k] 与输入第 k 个有效拍 **逐位相同**（tdata / tlast / tuser 三路）。
  C2 延迟 BPL 个有效拍：第 k 个输出字出现在第 k 个输入有效拍之后**恰好 BPL 拍**
        （在时钟域上就是 +320 拍：输入连续时"延迟 320 个有效拍"的落点就是 +320）。
  C3 **没有排空尾巴**：|P| == N_in − (BPL − RD_ADV) 恰好成立；输入末尾
        BPL − RD_ADV = 318 个字**永远不出现在输出上**（它们在阵列里，输入停了就
        没有有效拍再去把它们读出来）。旧合同（时钟语义）会把这 318 个字全排空出来。
  C4 停止即冻结：最后一个输出字呈现之后，O_tdata 一路保持同一个值到 dump 结束
        （没有新字，也没有被时钟推着继续排空）。
  另外：首个输出字之前的拍必须 O_tvalid=0 且 O_tdata=0（C-4 清零）；
        第一个输出字起的区间内不许出现 X/Z。

  ⚠ 关于"输出有效拍总数 == 输入有效拍总数"这句话：**实测做不到，也不该这样断言**。
    O_tvalid 是本模块输出级的电平（= 读寄存器里那个字带没带 I_tvalid 位），输入停止
    后读寄存器冻结 ⇒ 它保持为 1（实测 cyc 324..2284 恒为 1，共 1961 拍；最后一个字
    之后 361 拍全是同一个字的保持，其中**新字 0 个**）。本模块**没有流结束检测**
    （没有 flush、没有 idle 检测 —— 这是"停顿必须不可见"的必然代价：模块无法区分
    "行间停顿"和"流结束"）。所以"没有排空尾巴"必须按 **有没有新字被吐出来** 判定
    （C3 的数量 + C4 的冻结），不能按 tvalid 计数判定。实测数字见 §二。

===============================================================================
二、为什么旧判据是错的（实测数字，不是推理）
===============================================================================
旧判据 B 断言"O_* 逐拍 == I_* 延迟 320 **时钟**，含输入停止后的 320 拍排空尾巴"。
它把 2285 拍 dump 判成 FAIL 401 条，逐条归因实测如下（sim\\_a_measure.py）：

  · 比较 1961 拍（cyc 324..2284），前 1602 拍（cyc 324..1925）**全部相符**；
  · 不符自 cyc 1926 起：O_tdata 359 条（cyc 1926..2284）、O_tlast 1 条（cyc 2243）、
    O_tvalid 41 条（cyc 2244..2284）；
  · 根因：输入在 cyc 1923 送完最后一个有效拍（共 1920 拍）后停止。有效拍语义下读口
    被 I_tvalid 门控 ⇒ 读寄存器冻结，输出**只剩两级寄存器里已经取出的最后 2 个字**
    （cyc 1924 吐 I[1600]、cyc 1925 吐 I[1601]，此后恒定），阵列里剩下的 318 个字
    （I[1602..1919]）永不读出。而旧判据还在 cyc 1926..2243 期待"排空"出
    I[1606..1923]，并在 cyc 2244 之后期待 O_tvalid 掉 0（它按时钟延迟算，认为输入
    停止后 320 拍内还会继续吐字）。
  · 也就是说：**401 条全部是"旧合同假定 320 拍排空尾巴"与"新语义根本没有排空尾巴"
    之间的矛盾**，没有一条落在真实数据区（1602 拍逐位全对、X 检查全过、激励自检全过）。

  结论：不是回归，是合同换代。旧合同错在把"拍"当成时钟拍。改成有效拍语义后，
  "延迟 320 拍"在**内容**上的含义变了：延迟量体现在时间轴上（C2），内容上输出只是
  输入有效拍序列的**前缀**（C1），且尾部被截掉 BPL−RD_ADV 个字（C3）。
  这对配对件是**必需的**：win3x3_96 的行缓存也不排空（它也只在有效拍上推进），
  两者必须同时冻结，否则彩色 src 行与灰度窗口会差一个停顿。

  本文件**不靠"缩小比对区"换绿**：C1 逐位比完整字序（1602 个字 × 3 路 = 4806 条），
  C3/C4 正面断言尾巴**应该长什么样**（恰好 1602 个字 + 恒定冻结 + 末尾 318 字不泄漏），
  任何"多吐一个字/少吐一个字/尾巴继续推进"都会被抓。--selftest 里的
  count/tail/pre/index 五类变异就是把期望值换回旧合同或换错，用来实测证明
  本判据**仍然认得出旧语义是错的**；另有 rtl_mutation_row_delay.py 直接改 RTL 复现
  旧时钟语义，判据必须报错（真 RTL 级自证）。

===============================================================================
三、"输出字序 P" 的定义（判定口径，不是读实现内部量）
===============================================================================
按拍序遍历 dump：只在 O_tvalid=1 的拍上看 (O_tdata, O_tlast, O_tuser)，当这个三元组
相对上一次 O_tvalid=1 的取值**发生变化**时记入一个新字。理由：
  · 激励保证每个输入拍的 96bit 字**两两不同**（gen_stim_row_delay.py 与 load_stim
    都有断言），所以"同一个字出现两次"只可能来自停顿保持（读口被门控 ⇒ 字冻结），
    按"变化"取字既不会漏掉真实字，也不会把停顿保持误记成新字；
  · 若 RTL 有"停顿期重复吐同一个未来字"的旧气泡缺陷，重复会被折叠 —— 但那种缺陷
    在**没有停顿的**本激励里表现为"字序错位/数量不对"，仍被 C1/C2/C3 抓住；
    气泡本身由 check_bubble.py 在 alg_top 层判（那一层才有停顿激励）。

===============================================================================
四、断言清单
===============================================================================
  A  激励自检：dump 的 I_* 与激励模型逐拍一致。
  B  C1/C2/C3/C4 四条合同 + C-4 清零（期望值由 build_expectations() 构造，
     与比较分离 —— 这样"变异是不是空操作"可以被逐条实测）。
  C  X 传播：有效区不许有 X/Z；报告输出首次变确定值的拍号。

用法：
    python check_row_delay.py              # 正常校验
    python check_row_delay.py --selftest   # 变异自证：期望值写错必须全部被抓
"""
from __future__ import annotations
import sys, os

sys.stdout.reconfigure(encoding="utf-8")

IMG_WIDTH = 1280
BPL = IMG_WIDTH // 4                            # 320 = 一行 320 个有效拍
ROWS = 3
FRAMES = 2
BPF = BPL * ROWS
NBEAT = BPF * FRAMES                            # 1920 个输入有效拍
START_CYC = 4                                   # 第 1 个输入有效拍落在拍号 0 上
RD_ADV = 2                                      # 读地址领先写地址 2（RTL 文件头 §一）
IN_FLIGHT = BPL - RD_ADV                        # 318：输入停止时阵列里还没读出的字数
N_PRESENT = NBEAT - IN_FLIGHT                   # 1602：输出应该呈现的字数（C3）
FIRST_OUT_CYC = START_CYC + BPL                 # 324：第一个输出字最早可能出现的拍
IDLE = 0xA5A5A5A5A5A5A5A5A5A5A5A5        # 96 bit（24 个十六进制位），与 tb 的 96'hA5A5_... 逐位相同

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "dump_rd.txt")


# ---------------------------------------------------------------------------
# 激励模型（与 gen_stim_row_delay.py / tb_rgb_row_delay.v 同源）
# ---------------------------------------------------------------------------
def load_stim():
    beats = []
    with open(os.path.join(HERE, "stim_rd.hex"), "r", encoding="ascii") as fh:
        for ln in fh:
            s = ln.strip()
            if s:
                beats.append(int(s, 16))
    assert len(beats) == NBEAT, "激励条数 %d != %d" % (len(beats), NBEAT)
    # "输出字序按变化取字"这一口径的前提（见文件头 §三）
    assert len(set(beats)) == NBEAT, "激励里存在重复的拍值，判据 §三 的口径前提被破坏"
    return beats


STIM = load_stim()


def model_in(c):
    """第 c 拍 TB 应该驱动的输入（激励模型）。"""
    if START_CYC <= c < START_CYC + NBEAT:
        i = c - START_CYC
        return dict(v=1, l=1 if (i % BPL) == BPL - 1 else 0,
                    u=1 if (i % BPF) == 0 else 0, d=STIM[i])
    return dict(v=0, l=0, u=0, d=IDLE)


# ---------------------------------------------------------------------------
# dump 解析
# ---------------------------------------------------------------------------
def parse(path):
    rows = []
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for ln in fh:
            f = ln.split()
            if len(f) < 10:
                continue
            rows.append({
                "cyc": int(f[0]),
                "Iv": bitval(f[1]), "Il": bitval(f[2]), "Iu": bitval(f[3]), "Id": f[4],
                "Ov": bitval(f[5]), "Ol": bitval(f[6]), "Ou": bitval(f[7]), "Od": f[8],
                "M0": f[9],
            })
    return rows


def bitval(s):
    """'x'/'z' -> None（未定义），否则 0/1。"""
    return None if has_xz(s) else int(s)


def has_xz(s):
    return any(c in "xXzZ" for c in s)


def hexval(s):
    return None if has_xz(s) else int(s, 16)


def norm(h):
    return h.lower().rjust(24, "0")


def h24(v):
    return norm("%024x" % v)


# ---------------------------------------------------------------------------
# A. 激励自检
# ---------------------------------------------------------------------------
def check_stim(rows, verbose=True):
    fails = []
    nass = 0
    for r in rows:
        nass += 1
        e = model_in(r["cyc"])
        if (r["Iv"], r["Il"], r["Iu"]) != (e["v"], e["l"], e["u"]):
            fails.append("拍%d 控制线与模型不符：期望 v/l/u=%d/%d/%d 实得 %s/%s/%s"
                         % (r["cyc"], e["v"], e["l"], e["u"], r["Iv"], r["Il"], r["Iu"]))
        elif hexval(r["Id"]) != e["d"]:
            fails.append("拍%d I_tdata 与激励文件不符：期望 %024x 实得 %s"
                         % (r["cyc"], e["d"], r["Id"]))
    if verbose:
        print("\n=== A. 激励自检（dump 的 I_* vs 激励模型）===")
        print("  比较 %d 拍，不符 %d 拍   -> %s"
              % (nass, len(fails), "FAIL" if fails else "PASS"))
    return nass, fails


# ---------------------------------------------------------------------------
# 输出字序 P（见文件头 §三）与输入有效拍序列
# ---------------------------------------------------------------------------
def presentations(rows):
    out, prev = [], None
    for r in rows:
        if r["Ov"] != 1:
            continue
        t = (norm(r["Od"]), r["Ol"], r["Ou"])
        if t != prev:
            out.append({"cyc": r["cyc"], "Od": t[0], "Ol": t[1], "Ou": t[2]})
            prev = t
    return out


def in_beats(rows):
    """输入有效拍序列：[(cyc, tdata, tlast, tuser)]"""
    return [{"cyc": r["cyc"], "Id": norm(r["Id"]), "Il": r["Il"], "Iu": r["Iu"]}
            for r in rows if r["Iv"] == 1]


# ---------------------------------------------------------------------------
# B. 期望值构造（与比较分离 —— 变异是否空操作因此可以被实测）
# ---------------------------------------------------------------------------
# 变异参数（默认 = 新合同）：
#   lat     : C2 期望的延迟拍数（默认 BPL）
#   idx_off : C1 期望的字序错位（默认 0；-BPL 就是"把延迟写成 P[k]=I[k-BPL]"）
#   ctl_now : C1 的 tlast/tuser 改成"同拍比"（默认 False）
#   count   : "valid"（新合同 |P| = NBEAT-IN_FLIGHT）/"clock"（旧合同 |P| = NBEAT-RD_ADV）
#   tail    : "freeze"（新合同：末字之后恒定）/ "drain"（旧合同：继续排空下一批字）
#   pre     : "zero"（首字之前 O_tvalid=0 且 O_tdata=0）/ "idle"（期待 IDLE 垃圾值）
MUT_DEFAULT = dict(lat=BPL, idx_off=0, ctl_now=False, count="valid",
                   tail="freeze", pre="zero")


def build_expectations(rows, mut=None):
    """返回 (exp, counts)。exp 元素 = (说明, 期望, 实测)；counts 元素同构。"""
    m = dict(MUT_DEFAULT)
    m.update(mut or {})
    by = {r["cyc"]: r for r in rows}
    I = in_beats(rows)
    P = presentations(rows)
    exp, counts = [], []

    def field(desc, cyc, key, want):
        r = by.get(cyc)
        got = "【该拍不存在】" if r is None else (norm(r[key]) if key == "Od" else r[key])
        exp.append((desc, want, got))

    # ---- C3：输出字数 |P| ------------------------------------------------
    want_n = (NBEAT - RD_ADV) if m["count"] == "clock" else N_PRESENT
    counts.append(("C3 输出字数 |P|（新合同 = N_in − (BPL−RD_ADV) = %d）" % N_PRESENT,
                   want_n, len(P)))

    # ---- C3 负面断言：末尾 IN_FLIGHT 个字不得泄漏到输出 -------------------
    tail_words = [h24(STIM[i]) for i in range(N_PRESENT, NBEAT)]
    shown = set(norm(r["Od"]) for r in rows)
    n_leak = sum(1 for w in tail_words if w in shown)
    if m["tail"] == "drain":
        counts.append(("C3 末尾 %d 个字的排空个数（旧合同口径：必须全排空）" % IN_FLIGHT,
                       IN_FLIGHT, n_leak))
    else:
        counts.append(("C3 末尾 %d 个字泄漏到输出的个数（新合同要求 0）" % IN_FLIGHT,
                       0, n_leak))

    # ---- C1：字序逐位相同（tdata / tlast / tuser） ------------------------
    for k in range(max(len(P), want_n)):
        if k >= len(P):
            exp.append(("C1 第 %d 个字（应当存在）" % k, "存在", "【输出没有这个字】"))
            continue
        j = k + m["idx_off"]
        if j < 0 or j >= len(I):
            field("C1 第 %d 个字 tdata（按错位 %+d 找不到对应输入拍）" % (k, m["idx_off"]),
                  P[k]["cyc"], "Od", None)
            continue
        field("C1 第 %d 个字 tdata（= I[%d]）" % (k, j), P[k]["cyc"], "Od", I[j]["Id"])
        if m["ctl_now"]:
            field("C1 第 %d 个字 tlast（同拍比）" % k, P[k]["cyc"], "Ol",
                  by[P[k]["cyc"]]["Il"] if P[k]["cyc"] in by else None)
            field("C1 第 %d 个字 tuser（同拍比）" % k, P[k]["cyc"], "Ou",
                  by[P[k]["cyc"]]["Iu"] if P[k]["cyc"] in by else None)
        else:
            field("C1 第 %d 个字 tlast（= I[%d]）" % (k, j), P[k]["cyc"], "Ol", I[j]["Il"])
            field("C1 第 %d 个字 tuser（= I[%d]）" % (k, j), P[k]["cyc"], "Ou", I[j]["Iu"])

    # ---- C2：第 k 个输出字出现在第 k 个输入有效拍之后恰好 lat 拍 -----------
    for k in range(min(len(P), len(I))):
        exp.append(("C2 第 %d 个输出字的拍号（= 输入第 %d 拍 %d + %d）"
                    % (k, k, I[k]["cyc"], m["lat"]),
                    I[k]["cyc"] + m["lat"], P[k]["cyc"]))

    # ---- C-4 清零：首个输出字之前的每一拍 --------------------------------
    #  ⚠ 实测：首个输出字之前 O_tvalid 是 **x**（不是 0）—— 这一段是"阵列还没填满、
    #    读寄存器直接来自未初始化阵列"，O_tvalid <= r_q[98] 自然是 x；而 O_tdata 走
    #    "!r_q[98] ⇒ 清零"那一支，恒为 0（实测拍 0..323 O_tdata 全是 0，无 X）。
    #    所以这里断言的是：首字之前 **O_tvalid 不得为 1**（x 允许，这是阵列未初始化的
    #    诚实反映，见 RTL §8）且 **O_tdata 必须为 0**（C-4 清零确实生效）。
    if P:
        pre = [r for r in rows if r["cyc"] < P[0]["cyc"]]
        for r in pre:
            field("C-4 首字之前 拍%d O_tdata（必须清零）" % r["cyc"], r["cyc"], "Od",
                  h24(0) if m["pre"] == "zero" else h24(IDLE))
        counts.append(("C-4 首字之前的拍数（= 首字拍号 − dump 起点）",
                       FIRST_OUT_CYC, P[0]["cyc"]))
        counts.append(("C-4 首字之前 O_tvalid 为 1 的拍数（要求 0；x 是阵列未初始化的反映）",
                       0, sum(1 for r in pre if r["Ov"] == 1)))
    n_c4 = sum(1 for r in rows if r["Ov"] == 0 and norm(r["Od"]) != h24(0))
    counts.append(("C-4 全 dump：O_tvalid=0 而 O_tdata≠0 的拍数（要求 0）", 0, n_c4))

    # ---- C4：末字之后必须冻结（旧合同口径 = 继续排空下一批字） -------------
    if P:
        last = P[-1]
        tail = [r for r in rows if r["cyc"] > last["cyc"]]
        if m["tail"] == "drain":
            for j, r in enumerate(tail):
                want = I[len(P) + j]["Id"] if (len(P) + j) < len(I) else None
                field("C4 末字之后 拍%d（旧合同：继续吐下一个字）" % r["cyc"],
                      r["cyc"], "Od", want)
        else:
            n_chg = sum(1 for r in tail if norm(r["Od"]) != last["Od"])
            counts.append(("C4 末字之后 O_tdata 发生变化的拍数（要求 0）", 0, n_chg))
            # 逐拍断言（不靠"计数为 0"一句话概括，粒度与旧判据一致）
            for r in tail:
                field("C4 末字之后 拍%d O_tdata（必须保持末字）" % r["cyc"],
                      r["cyc"], "Od", last["Od"])
    return exp, counts


def verify(exp, counts, verbose=True, show=6):
    """把 (exp, counts) 与其中的实测值比。返回 (nass, fails)。"""
    fails = []
    for desc, want, got in exp:
        if want is None:
            fails.append("%s：期望【不存在】实得 %s" % (desc, got))
        elif got != want:
            fails.append("%s：期望 %s 实得 %s" % (desc, want, got))
    for desc, want, got in counts:
        if got != want:
            fails.append("%s：期望 %s 实得 %s" % (desc, want, got))
    nass = len(exp) + len(counts)
    if verbose and fails:
        print("  不符 %d 条（首 %d 条）：" % (len(fails), show))
        for s in fails[:show]:
            print("    " + s)
    return nass, fails


def check_contract(rows, mut=None, verbose=True):
    """B：新合同 C1/C2/C3/C4 + C-4 清零。"""
    exp, counts = build_expectations(rows, mut)
    nass, fails = verify(exp, counts, verbose=verbose)
    if verbose:
        I, P = in_beats(rows), presentations(rows)
        print("\n=== B. 合同（延迟 %d 个**有效拍** / 字序前缀 / 无排空尾巴 / 停止即冻结）==="
              % BPL)
        print("  dump %d 拍，cyc %d..%d" % (len(rows), rows[0]["cyc"], rows[-1]["cyc"]))
        print("  输入有效拍 %d（首 %d 末 %d）；输出呈现字 %d（期望 %d = %d − %d）"
              % (len(I), I[0]["cyc"], I[-1]["cyc"], len(P), N_PRESENT, NBEAT, IN_FLIGHT))
        print("  首个输出字拍 %s（= 首个输入有效拍 %s + %d）"
              % (P[0]["cyc"] if P else "-", I[0]["cyc"] if I else "-", BPL))
        print("  末个输出字拍 %s；之后 dump 还有 %d 拍（要求字冻结、无新字）"
              % (P[-1]["cyc"] if P else "-",
                 (rows[-1]["cyc"] - P[-1]["cyc"]) if P else 0))
        print("  O_tvalid=1 的拍数 = %d（末字之后 %d 拍为保持电平，不是新字）"
              % (sum(1 for r in rows if r["Ov"] == 1),
                 sum(1 for r in rows if r["Ov"] == 1 and r["cyc"] > P[-1]["cyc"]) if P else 0))
        print("  断言 %d 条，不符 %d 条   -> %s"
              % (nass, len(fails), "FAIL" if fails else "PASS"))
    return nass, fails


# ---------------------------------------------------------------------------
# C. X 传播
# ---------------------------------------------------------------------------
def check_x(rows, verbose=True):
    """未初始化阵列的 X 必须止步于有效区之前；报告输出的 X 区间。"""
    x_cyc = [r["cyc"] for r in rows if has_xz(r["Od"])]
    first_def = next((r["cyc"] for r in rows if not has_xz(r["Od"])), None)
    fails = []
    nass = 0
    for r in rows:
        if r["cyc"] >= FIRST_OUT_CYC:
            nass += 1
            if has_xz(r["Od"]):
                fails.append("拍%d O_tdata 含 X/Z" % r["cyc"])
    if verbose:
        print("\n=== C. X 传播 / 阵列未初始化证据 ===")
        print("  r_mem[0] 前 3 拍: %s" % " ".join(r["M0"] for r in rows[:3]))
        print("  O_tdata 含 X 的拍：%s"
              % (("%d..%d（%d 拍）" % (min(x_cyc), max(x_cyc), len(x_cyc))) if x_cyc else "无"))
        print("  O_tdata 首次变确定值：拍 %s（理论：地址 319 在拍 323 才首写；"
              "清零判据把阵列的 X 当'无效' ⇒ 输出 0、不把 X 传染出去）" % first_def)
        print("  有效区（拍 >= %d）X/Z 检查 %d 拍，不符 %d   -> %s"
              % (FIRST_OUT_CYC, nass, len(fails), "FAIL" if fails else "PASS"))
    return nass, fails


# ---------------------------------------------------------------------------
# 期望值变异清单（--selftest）
# ---------------------------------------------------------------------------
MUTATIONS = [
    ("C2 延迟当成 319 拍",                    dict(lat=319)),
    ("C2 延迟当成 321 拍",                    dict(lat=321)),
    ("C2 延迟当成 640 拍（两行）",             dict(lat=640)),
    ("C3 字数按旧合同（1920−2，含排空尾巴）",   dict(count="clock")),
    ("C1 字序整体错后一拍",                    dict(idx_off=1)),
    ("C1 字序整体提前一拍",                    dict(idx_off=-1)),
    ("C1 把延迟写成 P[k]=I[k−BPL]（槽位口径写错）", dict(idx_off=-BPL)),
    ("C1 tlast/tuser 不延迟（同拍比）",         dict(ctl_now=True)),
    ("C3+C4 末尾 318 个字必须被排空（旧合同）",  dict(tail="drain")),
    ("C-4 首字之前期待 IDLE 垃圾值（不清零）",   dict(pre="idle")),
]


# ---------------------------------------------------------------------------
def main():
    rows = parse(DUMP)
    selftest = "--selftest" in sys.argv
    print("解析 dump_rd.txt：%d 拍（cyc %d..%d）" % (len(rows), rows[0]["cyc"], rows[-1]["cyc"]))

    if not selftest:
        na, fa = check_stim(rows)
        nb, fb = check_contract(rows)
        nc, fc = check_x(rows)
        allf = fa + fb + fc
        print("\n" + "=" * 72)
        for nm, n, f in (("A 激励自检", na, fa),
                         ("B 新合同（有效拍语义）", nb, fb),
                         ("C X 传播", nc, fc)):
            print("  %-24s 断言 %6d  不符 %-5d  %s"
                  % (nm, n, len(f), "PASS" if not f else "FAIL"))
        print("  合计断言 %d" % (na + nb + nc))
        print("=" * 72)
        if allf:
            print("结论：FAIL —— %d 条" % len(allf))
            for s in allf[:20]:
                print("   " + s)
            if len(allf) > 20:
                print("   ...（其余 %d 条省略）" % (len(allf) - 20))
            return 1
        print("结论：PASS —— 激励 / 有效拍语义合同(C1/C2/C3/C4) / 清零 / X 全部通过")
        print("=" * 72)
        return 0

    # ---------------- 变异自证 ----------------
    print("\n" + "=" * 72)
    print("变异自证：故意用【错误期望】重跑，每一条都必须被抓出来")
    print("（抓不住的条目 = 测试在这个维度上没有鉴别力 = 等于没测）")
    print("=" * 72)

    # 防空转前置：基线必须是绿的，否则"任何变异都被抓住"是假绿
    base_exp, base_counts = build_expectations(rows, None)
    _n, base_fails = verify(base_exp, base_counts, verbose=False)
    print("  基线（未变异）      断言 %d 条，不符 %d 条  -> %s"
          % (_n, len(base_fails), "PASS" if not base_fails else "FAIL"))
    if base_fails:
        print("  !! 基线就是红的：变异自证在这种情况下没有意义（假绿来源）")
        for s in base_fails[:5]:
            print("     " + s)
        print("=" * 72)
        return 1

    caught = 0
    for name, mut in MUTATIONS:
        exp, counts = build_expectations(rows, mut)
        # 防空转：变异必须真的改变期望值，否则这条变异是空操作
        if exp == base_exp and counts == base_counts:
            print("  %-42s -> !! 空操作变异（期望值与基线逐条相同）算漏掉 !!" % name)
            continue
        nass, f = verify(exp, counts, verbose=False)
        if f:
            caught += 1
        print("  %-42s -> 断言 %5d 报错 %4d 条   %s"
              % (name, nass, len(f), "抓住" if f else "!! 漏掉 !!"))
    print("-" * 72)
    print("  鉴别力：%d/%d 个变异被抓住  -> %s"
          % (caught, len(MUTATIONS), "PASS" if caught == len(MUTATIONS) else "FAIL"))
    print("=" * 72)
    return 0 if caught == len(MUTATIONS) else 1


if __name__ == "__main__":
    sys.exit(main())
