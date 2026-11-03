"""alg_top 气泡鲁棒性判据。

被测主张：输入侧的停顿（I_tvalid 连续若干拍为低，**拍序不变**）在"拍空间"里必须是
不可见的 —— 有停顿跑与无停顿跑，**有效拍上的输出序列必须逐位相同**。

这个判据不需要黄金模型：无停顿那一跑自己就是参照。
它直接打在"一拍"的定义上 —— 一个模块若按有效拍计数，停顿对它不可见；若按时钟计数，
它的"一行以前"就会随停顿悄悄漂移。

⚠ 改造后的跑法（2026-09-14，tb_alg_top.v 默认已带行消隐）：
    · 参考跑 = `+nokey +noblank`       → dump_top_ref.txt（无停顿）
    · 被测跑 = `+nokey`（默认含消隐）   → dump_top_bub.txt（每行行末 20 拍 tvalid=0）
  也就是"有/无行消隐对照"。判据口径**没有放宽**：仍然是输出有效拍序列逐位相同。

用法：
    python check_bubble.py dump_top_ref.txt dump_top_bub.txt
    python check_bubble.py --selftest        # 变异自证：判据必须抓得住假不符
"""
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))

# dump_top.txt 列序（见 tb_alg_top.v 的 $fwrite，0 基）
C_IV, C_IL, C_IU, C_ID = 1, 2, 3, 4
C_OV, C_OL, C_OU, C_OD, C_OM = 8, 9, 10, 11, 12
C_BBV, C_BBX0, C_BBX1, C_BBY0, C_BBY1, C_BBPC = 13, 14, 15, 16, 17, 18


def parse(path):
    rows = []
    for ln in open(path, "r", encoding="ascii", errors="replace"):
        f = ln.split()
        if len(f) < 21:
            continue
        rows.append(f)
    return rows


def in_beats(rows):
    """输入侧有效拍序列：(tlast, tuser, tdata)"""
    out = []
    for f in rows:
        if f[C_IV] == "1":
            out.append((f[C_IL], f[C_IU], f[C_ID].lower()))
    return out


def out_beats(rows):
    """输出侧有效拍序列：(tlast, tuser, tdata, mode, bbox_valid, x0,x1,y0,y1, pix)"""
    out = []
    for f in rows:
        if f[C_OV] == "1":
            out.append((f[C_OL], f[C_OU], f[C_OD].lower(), f[C_OM],
                        f[C_BBV], f[C_BBX0], f[C_BBX1], f[C_BBY0], f[C_BBY1],
                        f[C_BBPC]))
    return out


def xz_problems(rows, tag):
    bad = 0
    for f in rows:
        if f[C_OV] == "1" and any(c in "xXzZ" for c in f[C_OD]):
            bad += 1
        # C-4：tvalid=0 时数据必须清零
        if f[C_OV] == "0" and f[C_OD].lower().strip("0") != "":
            bad += 1
    return bad


def compare(ref, bub, verbose=True):
    n_err = 0
    samples = []

    def err(m):
        nonlocal n_err
        n_err += 1
        if len(samples) < 8:
            samples.append(m)

    ri, bi = in_beats(ref), in_beats(bub)
    ro, bo = out_beats(ref), out_beats(bub)

    # --- 自检：两次跑的**输入**拍序必须一致，否则这个测试本身没有意义 ---
    if ri != bi:
        err("输入拍序不一致（%d vs %d 拍）—— 测试前提被破坏，结论无效"
            % (len(ri), len(bi)))
        for k in range(min(len(ri), len(bi))):
            if ri[k] != bi[k]:
                err("  首个输入差异在拍 %d: ref=%s bub=%s" % (k, ri[k], bi[k]))
                break

    # --- 主判据：输出有效拍序列必须逐位相同 ---
    if len(ro) != len(bo):
        err("有效输出拍数不同：ref=%d bub=%d（相差 %+d）"
            % (len(ro), len(bo), len(bo) - len(ro)))
    n = min(len(ro), len(bo))
    first_bad = None
    nbad = 0
    for k in range(n):
        if ro[k] != bo[k]:
            nbad += 1
            if first_bad is None:
                first_bad = k
            if nbad <= 6:
                err("拍 %d 不符:\n        ref=%s\n        bub=%s"
                    % (k, ro[k], bo[k]))

    # --- 结构检查：tlast / tuser 落在相同的拍号上 ---
    def marks(seq):
        return ([k for k, v in enumerate(seq) if v[0] == "1"],
                [k for k, v in enumerate(seq) if v[1] == "1"])
    rl, ru = marks(ro)
    bl, bu = marks(bo)
    if rl != bl:
        err("tlast（行末）位置不同：ref %d 个 / bub %d 个，首个差异 %s"
            % (len(rl), len(bl),
               next((i for i, (a, b) in enumerate(zip(rl, bl)) if a != b), "长度不同")))
    if ru != bu:
        err("tuser（帧首）位置不同：ref %d 个 / bub %d 个" % (len(ru), len(bu)))

    # --- 模式序列 ---
    rm = [v[3] for v in ro]
    bm = [v[3] for v in bo]
    if rm != bm:
        err("档位序列不同（前 20 拍）: ref=%s bub=%s" % (rm[:20], bm[:20]))

    n_xz = xz_problems(ref, "ref") + xz_problems(bub, "bub")
    if n_xz:
        err("X/Z 或 C-4 违例共 %d 处" % n_xz)

    if verbose:
        print("  输入有效拍      : ref %d / bub %d" % (len(ri), len(bi)))
        print("  输出有效拍      : ref %d / bub %d" % (len(ro), len(bo)))
        print("  逐位不符        : %d" % nbad)
        if first_bad is not None:
            print("  首个不符在拍    : %d" % first_bad)
        print("  tlast 标记      : ref %d 个 / bub %d 个" % (len(rl), len(bl)))
        print("  tuser 标记      : ref %d 个 / bub %d 个" % (len(ru), len(bu)))
        print("  X/Z 与 C-4 违例 : %d" % n_xz)

    if n_err:
        print("  FAIL: %d 类问题" % n_err)
        for s in samples:
            print("    " + s)
        return False
    print("  PASS: 有气泡与无气泡的有效拍输出序列逐位相同（%d 拍）" % len(ro))
    return True


# ===========================================================================
# 变异自证：判据必须抓得住"假不符"
# ===========================================================================
def selftest(ref_path, bub_path):
    print("=" * 72)
    print("变异自证：把气泡跑的序列人工弄错，判据必须变红")
    print("=" * 72)

    base_bytes = open(bub_path, "rb").read()

    def write_mut(path, fn):
        rows = parse(bub_path)
        idx = [i for i, f in enumerate(rows) if f[C_OV] == "1"]
        fn(rows, idx)
        with open(path, "w", encoding="ascii", newline="\n") as fp:
            for f in rows:
                fp.write(" ".join(f) + "\n")
        # 防空转：变异写出来的 dump 必须与基线气泡 dump **逐字节不同**。
        # 相同 = 这个变异是空操作（改动落在不影响输出的字段/位置上）——那就是假绿。
        return open(path, "rb").read() != base_bytes

    muts = {}

    def m_shift(rows, idx):          # 整体错一拍
        v = rows[idx[0]][C_OD]
        for k in range(len(idx) - 1):
            rows[idx[k]][C_OD] = rows[idx[k + 1]][C_OD]
        rows[idx[-1]][C_OD] = v
    muts["E1_整体错一拍"] = m_shift

    def m_drop(rows, idx):           # 丢一个有效拍
        rows[idx[len(idx) // 2]][C_OV] = "0"
    muts["E2_丢一个有效拍"] = m_drop

    # ⚠ 2026-09-14 修正两处**空操作变异**（只动变异实现，compare() 一字未改）。
    #   基线（未变异的气泡跑）原本是 FAIL 的，于是"任何变异都必然被抓住"——变异自证
    #   5/5 是假绿。基线修好之后真相显出来：
    #     · E3 原来挑的是 idx[len//2]，那是**有效行**（C_OV 本来就是 "1"），置"1"等于没改；
    #     · E5 原来交换 idx[10]/idx[11] 的档位，而本激励每 64 拍才换档，第 10/11 拍档位
    #       相同，交换等于没改。
    #   实测证据：把两者各自的输出与基线 dump 逐字节比对 —— 完全相同（no-op）。
    #   改成真变异后鉴别力是**变强**而不是放宽：E3 现在挑一行当前无效的拍标成有效，
    #   E5 现在挑相邻且档位确实不同的一对交换。
    def m_extra(rows, idx):          # 多出一个有效拍
        off = [i for i, f in enumerate(rows) if f[C_OV] == "0"]
        rows[off[len(off) // 2]][C_OV] = "1"
    muts["E3_多一个有效拍"] = m_extra

    def m_bit(rows, idx):            # 一个像素改 1 bit
        k = idx[len(idx) // 2]
        v = int(rows[k][C_OD], 16) ^ 1
        rows[k][C_OD] = "%024x" % v
    muts["E4_像素翻 1 bit"] = m_bit

    def m_mode(rows, idx):           # 档位错一拍
        pairs = [k for k in range(len(idx) - 1)
                 if rows[idx[k]][C_OM] != rows[idx[k + 1]][C_OM]]
        if pairs:
            a, b = idx[pairs[0]], idx[pairs[0] + 1]
            rows[a][C_OM], rows[b][C_OM] = rows[b][C_OM], rows[a][C_OM]
        else:                        # 兜底：整段只有一个档位时，直接把首拍档位挪一位
            rows[idx[0]][C_OM] = str((int(rows[idx[0]][C_OM]) + 1) % 8)
    muts["E5_档位交换"] = m_mode

    caught = 0
    for name, fn in muts.items():
        p = os.path.join(HERE, "_bub_mut.txt")
        changed = write_mut(p, fn)
        if not changed:
            print("[mut] %-18s -> 空操作变异（dump 与基线逐字节相同）-> NOT CAUGHT (判据无效!)"
                  % name)
            continue
        ok = compare(parse(ref_path), parse(p), verbose=False)
        print("[mut] %-18s -> %s" % (name, "NOT CAUGHT (判据无效!)" if ok else "caught"))
        caught += 0 if ok else 1
    print("\n基线（未变异，应当通过）")
    base = compare(parse(ref_path), parse(bub_path), verbose=False)
    print("        -> %s" % ("PASS" if base else "FAIL"))
    print("-" * 72)
    print("变异自证：%d/%d 被抓住；基线 %s" % (caught, len(muts), "通过" if base else "失败"))
    return caught == len(muts) and base


def main():
    argv = sys.argv[1:]
    if "--selftest" in argv:
        ref = os.path.join(HERE, "dump_top_ref.txt")
        bub = os.path.join(HERE, "dump_top_bub.txt")
        sys.exit(0 if selftest(ref, bub) else 1)
    ref = argv[0] if len(argv) > 0 else os.path.join(HERE, "dump_top_ref.txt")
    bub = argv[1] if len(argv) > 1 else os.path.join(HERE, "dump_top_bub.txt")
    print("check_bubble.py\n  ref=%s\n  bub=%s" % (ref, bub))
    ok = compare(parse(ref), parse(bub))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
