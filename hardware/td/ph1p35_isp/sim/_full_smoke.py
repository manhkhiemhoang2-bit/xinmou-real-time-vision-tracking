#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_full_smoke.py —— 全尺寸链路的解析/打包自检（**不跑 ModelSim**）。

三件事，全都要独立可证伪：
  1. 激励往返：stim_top_full.hex 里的 hex 文本 -> 我的 _hex48_to_u64 解析 -> 必须逐位
     等于 gen_stim_top_full.stim_beats() 的 uint64 打包值（pip 规范同源但代码独立）；
  2. 几何自检：每行 BPL 拍、每帧 BPF 拍、tlast/tuser 位置；
  3. 合成 dump：用"已知输入 + 逐拍延迟 5 拍"人工造一份 dump，喂给 check_alg_top_full.parse，
     看解析出来的列是不是我期望的那些值（证明解析器本身不是错的）。
"""
from __future__ import annotations

import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np                       # noqa: E402
import gen_stim_top_full as G            # noqa: E402
import check_alg_top_full as C           # noqa: E402


def t1_hexroundtrip(frames):
    """hex 文件往返 + 文件至少覆盖 frames 帧（TB 的 +frames 只限制跑多少拍，
    不改变文件长度；所以要求"文件帧数 >= 要跑的帧数"）。"""
    path = os.path.join(HERE, C.HEXF)
    nb = G.nbeat(frames)
    blob = open(path, "rb").read()
    lines = blob.split(b"\n")
    assert lines[-1] == b"", "文件末尾没有换行"
    lines = lines[:-1]
    nfile = len(lines)
    assert all(len(ln) == 24 for ln in lines), \
        "hex 行宽不都是 24：%s" % sorted({len(ln) for ln in lines})
    print("  文件 %s：%d 字节，%d 行 24-char 记录（= %d 帧；本次要跑 %d 帧 -> %d 拍）"
          % (C.HEXF, len(blob), nfile, nfile // G.BPF, frames, nb))
    assert nfile >= nb, "激励文件比要跑的帧数还短：%d < %d 拍" % (nfile, nb)
    assert nfile % G.BPF == 0, "文件长度不是整帧（%d 拍）" % G.BPF
    t0 = time.time()
    raw = np.frombuffer(b"".join(lines), dtype=np.uint8).reshape(-1, 24)
    # ⚠ 2026-09-17 修（**既有失效**，与 M6 改动无关）：旧版调用 C._hex48_to_u64，
    #   而 2026-09-16 的 checker 重构把有损的 pack96/_hex48_to_u64 换成了
    #   (hi32, lo64) 成对表示 —— 该函数已不存在，本脚本从那时起就是 AttributeError。
    #   证据：check_alg_top_full.py 的 mtime = 2026-09-17 17:03（改动在本次之前），
    #   本脚本 mtime = 2026-09-16 20:30，而它最后一次 PASS 的日志 _full_smoke1.log
    #   停在 2026-09-16 20:33 且 frames=1。
    hi, lo = C._hex48_to_pair(raw[:nb])
    # ⚠ 同样修掉的第二处失效：旧版假设"本激励每帧逐位相同"（那是早期版本的行为）。
    #   现在的全尺寸激励**逐帧不同**（M5 的红块每帧右移 40 列，"画上一帧/本帧 bbox"
    #   才有鉴别力）。这里改成与生成器逐帧逐位比 —— 判据更严，不是放宽。
    want_hi, want_lo = C.pin_beats(np.stack(G.build_images(frames)))
    want_hi = want_hi.reshape(-1)[:nb]
    want_lo = want_lo.reshape(-1)[:nb]
    bad = int(((hi != want_hi) | (lo != want_lo)).sum())
    print("  1) hex <-> 打包往返：不符 %d / %d（%.1f s）  %s"
          % (bad, nb, time.time() - t0, "PASS" if bad == 0 else "FAIL"))
    nf = nfile // G.BPF
    if nf > 1:
        ah_hi, ah_lo = hi, lo
        if nfile != nb:
            ah_hi, ah_lo = C._hex48_to_pair(raw.reshape(-1, 24))
        # 逐帧与生成器生成的期望拍比（每帧独立，不再假设帧间相同）
        okf = 0
        for f in range(nf):
            bh, bl = C.pin_beats(np.ascontiguousarray(G.build_image(f)))
            sl = slice(f * G.BPF, (f + 1) * G.BPF)
            okf += int(((ah_hi[sl] != bh.reshape(-1)) | (ah_lo[sl] != bl.reshape(-1))).sum())
        print("     文件内 %d 帧逐帧与生成器比对：不符 %d 拍  %s"
              % (nf, okf, "PASS" if okf == 0 else "FAIL"))
        bad += okf
    return bad == 0


def t2_geometry(frames):
    nb = G.nbeat(frames)
    k = np.arange(nb, dtype=np.int64)
    assert G.BPL == 320 and G.H == 720 and G.BPF == 230400, (G.BPL, G.H, G.BPF)
    assert (k % G.BPL == G.BPL - 1).sum() == frames * G.H
    assert (k % G.BPF == 0).sum() == frames
    print("  2) 几何：BPL=%d BPF=%d 帧=%d 总拍=%d；行末拍 %d；帧首拍 %d  PASS"
          % (G.BPL, G.BPF, frames, nb, (k % G.BPL == G.BPL - 1).sum(), (k % G.BPF == 0).sum()))
    return True


def t3_parse_synthetic():
    """造一份 40 拍的合成 dump（已知列值 + 抖动行宽），验证解析器。"""
    tmp = os.path.join(HERE, "_synthetic_dump.txt")
    rows = []
    for i in range(40):
        iv = 1 if (10 <= i < 30) else 0
        il = 1 if i == 29 else 0
        iu = 1 if i == 10 else 0
        idt = 0x0 if not iv else (0x1122334455667788 + i)
        ov = 1 if (5 <= i < 25) else 0
        odt = 0x0 if not ov else (0xAABBCCDDEEFF0011 + i)
        rows.append("%d %d %d %d %024X %d %d %d %024X %d %d %d %d %d %d %d"
                    % (i, iv, il, iu, idt, ov, ov, ov, odt, 5, 1, 1234 + i,
                       2047, 0, 2047, 0))
    # 故意插一行 X/Z，验证 F 判据的探测路径
    rows.append("40 1 0 0 %s 1 0 0 %s 3 1 0 2047 0 2047 0"
                % ("x" * 24, "z" * 24))
    # ⚠ 2026-09-17 修（第三处既有失效）：checker 的 parse() 现在要求"最后一个有效拍
    #   之后至少还有 LAT=5 拍"（2026-09-16 气泡测试修出来的门禁），旧的 41 行合成 dump
    #   在末拍之后 0 拍 ⇒ parse() 直接 SystemExit。这里补 12 拍 tvalid=0 的收尾。
    for i in range(41, 53):
        rows.append("%d 0 0 0 %024X 0 0 0 %024X %d %d %d %d %d %d %d"
                    % (i, 0, 0, 5, 0, 0, 2047, 0, 2047, 0))
    open(tmp, "w", encoding="ascii").write("\n".join(rows) + "\n")
    d = C.parse(tmp, quiet=True)
    # ⚠ 2026-09-17 修：parse() 已不再输出有损的 id/od 单值列，改用 (hi32, lo64) 成对列。
    idv = (int(d["id_hi"][10]) << 64) | int(d["id_lo"][10])
    odv = (int(d["od_hi"][5]) << 64) | int(d["od_lo"][5])
    ok = True
    ok &= (d["ncycles"] == 53)
    ok &= (int(d["Iv"].sum()) == 21)
    ok &= (int(d["Ov"].sum()) == 21)
    ok &= (idv == 0x1122334455667788 + 10)
    ok &= (odv == 0xAABBCCDDEEFF0011 + 5)
    ok &= (int(d["cnt"][5]) == 1239)
    ok &= (int(d["bx0"][0]) == 2047 and int(d["by1"][0]) == 0)
    ok &= bool(d["Oxz"][40]) and not bool(d["Oxz"][39])
    print("  3) 合成 dump 解析：cyc=%d Iv=%d Ov=%d id[10]=%024X od[5]=%024X cnt[5]=%d "
          "bx0=%d Oxz[40]=%s  %s"
          % (d["ncycles"], int(d["Iv"].sum()), int(d["Ov"].sum()),
             idv, odv, int(d["cnt"][5]), int(d["bx0"][0]),
             bool(d["Oxz"][40]), "PASS" if ok else "FAIL"))
    os.remove(tmp)
    return ok


if __name__ == "__main__":
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    print("=" * 74)
    print("全尺寸链路自检（合成/解析层，不跑 ModelSim）  frames=%d" % frames)
    print("=" * 74)
    r = [t1_hexroundtrip(frames), t2_geometry(frames), t3_parse_synthetic()]
    print("=" * 74)
    print("结论：%s" % ("PASS" if all(r) else "FAIL"))
    sys.exit(0 if all(r) else 1)
