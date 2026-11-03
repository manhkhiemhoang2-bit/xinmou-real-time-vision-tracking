# -*- coding: utf-8 -*-
"""
check_roll_ppd_prod.py —— **生产值** PULSE_PER_DEG 的安全判据（2026-09-28 新增）

为什么单独写一个：
  原来两个 TB 都用 `PULSE_PER_DEG=1200` 覆盖参数（故意取大，让脉宽限幅"咬住"），
  于是 **`gim_top.v` 里真正下载到板子上的那个值从来没被任何测试跑过**。
  那个值曾经是 1000（大 3.6 倍）：±25° 被算成 ±25000 counts、顶满 1~2ms，
  舵机实际转 **±90°** —— 而摄像头软排线是按"最多扭 25°"设计的安全边界。
  这个洞一路全绿漏到 2026-09-28 读代码时才发现。

  ⇒ 本脚本只干一件事：**在 -gPULSE_PER_DEG=278 那一跑上，验证脉宽不超排线预算。**

判据：
  P1 HEADER_PPD    dump 头部记录的 PPD == 生产值（防止忘了传 -g，跑成默认 1200）
  P2 FORMULA       脉宽 == clamp(MID − deg×PPD, MIN, MAX)，deg = roll >> 16（与 RTL 同取整）
  P3 OFFSET_BUDGET |脉宽 − MID| ≤ 25° × PPD（= 排线安全预算）
  P4 NO_CLIP       **一条都不许**触到 [MIN, MAX] 边界（触到 = 物理角已超 25°）
  P5 ANGLE_LIMIT   |roll| ≤ 25°（角度本身被正确限幅）
  P6 COVERAGE      样本数够多 **且** 角度/脉宽确实动过（防"一直不动所以全绿"）

用法：
  python check_roll_ppd_prod.py --dump _gim_roll/dump_gim_roll_prod.txt
  python check_roll_ppd_prod.py --dump ... --selftest    # 变异自证（抓住 → exit 0）
"""
import sys, os, re, argparse

sys.stdout.reconfigure(encoding="utf-8")

PROD_PPD  = 278       # 每度多少 counts：50000 / 180 = 277.78
LIMIT_DEG = 25        # ROLL_LIMIT_Q16 = 25° × 65536，受摄像头软排线限制
Q16       = 65536

nchk = 0
nbad = 0
bad_msgs = []


def chk(cond, label, detail=""):
    global nchk, nbad
    nchk += 1
    if not cond:
        nbad += 1
        if len(bad_msgs) < 10:
            bad_msgs.append("%s || %s" % (label, detail))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--ppd", type=int, default=PROD_PPD,
                    help="期望的生产值（默认 %d）" % PROD_PPD)
    a = ap.parse_args()

    if not os.path.exists(a.dump):
        print("FAIL: 找不到 %s" % a.dump)
        return 1

    hdr, O = {}, []
    with open(a.dump, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if ln.startswith("# tb_gim_imu_roll"):
                for m in re.finditer(r"(\w+)=(-?\d+)", ln):
                    hdr[m.group(1)] = int(m.group(2))
            elif ln.startswith("O "):
                p = ln.split()
                if len(p) >= 4:
                    O.append((int(p[1]), int(p[2]), int(p[3])))

    pmin = hdr.get("PULSE_MIN", 50000)
    pmid = hdr.get("PULSE_MID", 75000)
    pmax = hdr.get("PULSE_MAX", 100000)
    ppd  = hdr.get("PULSE_PER_DEG", -1)
    lim_q16 = hdr.get("ROLL_LIMIT_Q16", LIMIT_DEG * Q16)
    lim_deg = lim_q16 // Q16

    if not O:
        print("FAIL: dump 里没有 O 记录（%s）" % a.dump)
        return 1

    selftest = a.selftest
    budget   = lim_deg * a.ppd
    # 变异模式：预算收紧到 0 ⇒ P3 必须大量报错，用来证明它不是在空转
    budget_check = 0 if selftest else budget

    print("=" * 92)
    print("  生产值 PULSE_PER_DEG 安全判据 —— %s" % os.path.basename(a.dump))
    print("=" * 92)
    print("  头部: MIN=%d MID=%d MAX=%d PULSE_PER_DEG=%d ROLL_LIMIT=%d°"
          % (pmin, pmid, pmax, ppd, lim_deg))
    if selftest:
        print("  【变异模式】排线预算被收紧到 0 counts —— 判据必须报错才算有效")

    # ---- P1：头部记录的 PPD 必须是生产值 ----
    if not selftest:
        chk(ppd == a.ppd, "P1 HEADER_PPD 头部 PPD == 生产值 %d" % a.ppd,
            "实测头部 PPD=%d（是否忘了传 -gPULSE_PER_DEG=%d？）" % (ppd, a.ppd))

    max_off, max_abs_roll, n_clip, n_form = 0, 0, 0, 0
    rolls, pulses = set(), set()

    for (k, rq, pulse) in O:
        deg  = rq >> 16                        # 与 RTL 的 >>> 16 一致（向下取整）
        want = max(pmin, min(pmax, pmid - deg * ppd))
        n_form += 1

        # P2 公式
        chk(pulse == want, "P2[样本%d] 脉宽 == clamp(MID − deg×PPD)" % k,
            "实测 %d，期望 %d（roll=%d → deg=%d，PPD=%d）" % (pulse, want, rq, deg, ppd))

        off = pulse - pmid
        max_off = max(max_off, abs(off))

        # P3 偏移预算
        chk(abs(off) <= budget_check,
            "P3[样本%d] |脉宽偏移| ≤ %d（= %d°×%d，排线预算）" % (k, budget_check, lim_deg, a.ppd),
            "实测偏移 %d（roll=%d → deg=%d）" % (off, rq, deg))

        # P4 不许触到边界
        if pulse in (pmin, pmax):
            n_clip += 1

        # P5 角度限幅
        chk(abs(rq) <= lim_q16, "P5[样本%d] |roll| ≤ %d°" % (k, lim_deg),
            "实测 roll=%d > %d" % (rq, lim_q16))
        max_abs_roll = max(max_abs_roll, abs(rq))

        rolls.add(rq)
        pulses.add(pulse)

    phys = max_off / float(pmax - pmin) * 180.0
    print("  样本: %d 条   最大|roll| = %.2f°   最大|脉宽偏移| = %d counts"
          % (len(O), max_abs_roll / Q16, max_off))
    print("  按 180° 行程舵机换算物理角: %.2f°   ← 必须 ≤ %d°（排线边界）" % (phys, lim_deg))
    print("  排线预算: %d° × %d = %d counts" % (lim_deg, a.ppd, budget))
    print("  触到 [MIN,MAX] 边界的样本: %d" % n_clip)

    # ---------------- 变异模式 ----------------
    if selftest:
        caught = (nbad > 0)
        print("-" * 92)
        print("  预算收紧到 0 后：断言 %d 条，失配 %d 条" % (nchk, nbad))
        if bad_msgs:
            print("  例：%s" % bad_msgs[0])
        print("  变异自证: %s" % ("抓住（P3 判据非空转）" if caught else "**没抓住 ⇒ 判据是空转的**"))
        return 0 if caught else 1

    # ---------------- 正常模式 ----------------
    chk(n_clip == 0, "P4 NO_CLIP 脉宽从不触到 [%d,%d] 边界" % (pmin, pmax),
        "有 %d 条触到边界 ⇒ 物理角已超 %d°" % (n_clip, lim_deg))
    chk(len(O) >= 3000, "P6a 样本数 ≥ 3000", "只有 %d 条" % len(O))
    chk(len(rolls) > 50,  "P6b roll 确实在变", "只有 %d 个不同 roll 值" % len(rolls))
    chk(len(pulses) > 20, "P6c 脉宽确实在变", "只有 %d 个不同脉宽" % len(pulses))
    chk(max_off > 0,      "P6d 确实出现过脉宽偏移", "最大偏移 = 0")

    print("-" * 92)
    if bad_msgs:
        print("  前几条失配：")
        for m in bad_msgs:
            print("    %s" % m)
    print("  断言 %d 条，失配 %d 条" % (nchk, nbad))
    ok = (nbad == 0)
    print("  结论: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
