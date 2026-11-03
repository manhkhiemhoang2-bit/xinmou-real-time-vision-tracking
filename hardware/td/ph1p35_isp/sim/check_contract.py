#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_contract.py —— osd_mixer 输出流**契约测试**（v1.3 对齐修复的主判据）

判据只用契约本身，**不拿任何旧版本当金标准**（旧版把控制做成比数据晚 1 拍，是错的）：

  A0  输出流 == 输入流延迟 2 拍（逐拍、四路分别判）
      A0a O_tvalid(i) == I_tvalid(i-2)
      A0b O_tdata (i) == (I_tvalid(i-2) ? I_tdata(i-2) : 0)      ← OSD 版面已推出画面
      A0c 有效期上 O_tlast(i) == I_tlast(i-2)
      A0d 有效期上 O_tuser(i) == I_tuser(i-2)
  A1  O_tuser=1 那一拍携带的必须是**帧首拍**（beat % BURST == 0，修复前是 beat 1）
  A2  O_tlast=1 那一拍携带的必须是**该行最后一个有效拍**（beat % ROW == ROW-1）
  A3  任何 O_tvalid=1 的拍都不得携带气泡期标记数据 0x0BAD
  A4  有效拍数严格相等；且输出首拍 = 输入首拍、输出末拍 = 输入末拍
  A5  异步复位窗口内四路输出必须全 0
  A6  有效拍上不许出现 X/Z

每条断言都打印**检查次数 / 失配数**；0 次检查 = 失败。
异步复位窗口（rst_n=0 及其后 2 拍）不参与 A0：复位是**同时**打到所有寄存器上的，
"延迟 2 拍"的关系在冲洗窗口内本就不适用，单独由 A5 判。

用法：
    python check_contract.py [--dump _contract_work\\dump_contract.txt]
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
GAP_TAG = 0x0BAD


def pix(beat, ch):
    return (beat << 7) | ((beat % 32) << 2) | ch


def dec(v, ch):
    if (v & 3) != ch:
        return None
    b = v >> 7
    if b < 0 or b >= (1 << 13):
        return None
    return b if pix(b, ch) == v else None


def beat_of(tdata):
    """该拍 24x4 数据里能反解出的拍号（唯一才返回，否则 None）"""
    v = int(tdata, 16)
    bs = set()
    for ch in range(4):
        b = dec((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
        if b is not None:
            bs.add(b)
    return bs.pop() if len(bs) == 1 else None


def in_beat(id_hex):
    return dec((int(id_hex, 16) >> 72) & 0xFFFFFF, 0)


def is_gap(tdata):
    v = int(tdata, 16)
    for ch in range(4):
        if (((v >> (72 - 24 * ch)) & 0xFFFFFF) >> 8) == GAP_TAG:
            return True
    return False


def parse(path):
    rows, hdr = [], None
    for ln in open(path, encoding="ascii", errors="replace"):
        f = ln.split()
        if not f:
            continue
        if f[0] == "H":
            hdr = [int(x) for x in f[1:]]
            continue
        if len(f) < 10:
            continue
        rows.append({
            "cyc": int(f[0]), "rn": int(f[1]),
            "Iv": int(f[2]), "Il": int(f[3]), "Iu": int(f[4]), "Id": f[5],
            "Ov": int(f[6]), "Ol": int(f[7]), "Ou": int(f[8]), "Od": f[9],
        })
    assert hdr is not None, "dump 没有 H 头"
    return hdr, rows


class Res:
    def __init__(self):
        self.bad = []
        self.err = 0

    def add(self, name, nchk, nbad, detail=""):
        self.bad.append((name, nchk, nbad, detail))
        if nchk == 0 or nbad:
            self.err += 1


def main():
    argv = sys.argv[1:]
    dump = os.path.join(HERE, "_contract_work", "dump_contract.txt")
    if "--dump" in argv:
        dump = argv[argv.index("--dump") + 1]
    NPROBE, BURST, ROW, START, MID_AT, MID_LEN = parse(dump)[0]
    rows = parse(dump)[1]
    print("check_contract.py  dump=%s" % dump)
    print("配置：NPROBE=%d  BURST=%d  ROW=%d  START=%d  mid_rst@%d(len %d)  共 %d 拍"
          % (NPROBE, BURST, ROW, START, MID_AT, MID_LEN, len(rows)))
    R = Res()

    def flushed(i):
        """第 i 拍是否落在异步复位冲洗窗口（它或它前 2 拍 rst_n=0）"""
        return rows[i]["rn"] == 0 or rows[i - 1]["rn"] == 0 or rows[i - 2]["rn"] == 0

    # ---------- A0：逐拍延迟 2 拍的流等价 ----------
    c = {k: 0 for k in "abcd"}
    b = {k: 0 for k in "abcd"}
    first_bad = {}
    for i in range(2, len(rows)):
        if flushed(i):
            continue
        p, r = rows[i - 2], rows[i]
        c["a"] += 1
        if r["Ov"] != p["Iv"]:
            b["a"] += 1
        c["b"] += 1
        want = int(p["Id"], 16) & ((1 << 96) - 1) if p["Iv"] else 0
        if int(r["Od"], 16) != want:
            b["b"] += 1
            first_bad.setdefault("b", (r["cyc"], r["Od"], "%024X" % want))
        if p["Iv"] == 1:
            c["c"] += 1
            if r["Ol"] != p["Il"]:
                b["c"] += 1
            c["d"] += 1
            if r["Ou"] != p["Iu"]:
                b["d"] += 1
    R.add("A0a O_tvalid == I_tvalid(i-2)", c["a"], b["a"])
    R.add("A0b O_tdata  == I_tdata (i-2, 有效期)", c["b"], b["b"],
          "首个不符：cyc=%s got=%s want=%s" % first_bad.get("b", ("-", "-", "-")))
    R.add("A0c O_tlast  == I_tlast(i-2) 有效期", c["c"], b["c"])
    R.add("A0d O_tuser  == I_tuser(i-2) 有效期", c["d"], b["d"])

    # ---------- A1：O_tuser 那一拍必须是帧首拍 ----------
    n1 = n1b = 0
    q1 = []
    for i, r in enumerate(rows):
        if r["Ou"] != 1:
            continue
        n1 += 1
        got = beat_of(r["Od"])
        exp = in_beat(rows[i - 2]["Id"]) if i >= 2 else None
        q1.append((r["cyc"], got, exp, (got % BURST) if got is not None else None))
        if got is None or got % BURST != 0 or got != exp:
            n1b += 1
    R.add("A1 O_tuser 拍携带帧首拍", n1, n1b,
          "各拍 (cyc, 实测拍号, 延迟2拍期望, 实测 mod BURST) = %s" % q1)

    # ---------- A2：O_tlast 那一拍必须是行末拍 ----------
    n2 = n2b = 0
    q2 = []
    for i, r in enumerate(rows):
        if r["Ol"] != 1 or r["Ov"] != 1:
            continue
        n2 += 1
        got = beat_of(r["Od"])
        exp = in_beat(rows[i - 2]["Id"]) if i >= 2 else None
        q2.append((r["cyc"], got, exp, (got % ROW) if got is not None else None))
        if got is None or got % ROW != (ROW - 1) or got != exp:
            n2b += 1
    R.add("A2 O_tlast 拍携带行末拍", n2, n2b,
          "各拍 (cyc, 实测拍号, 延迟2拍期望, 实测 mod ROW) = %s%s"
          % (q2[:8], "..." if len(q2) > 8 else ""))

    # ---------- A3：有效期不许携带气泡标记 ----------
    n3 = n3b = 0
    leak = []
    for r in rows:
        if r["Ov"] == 1:
            n3 += 1
            if is_gap(r["Od"]):
                n3b += 1
                leak.append(r["cyc"])
    R.add("A3 有效期无气泡标记 0x0BAD", n3, n3b, "泄漏拍：%s" % leak[:8])

    # ---------- A4：有效拍数 + 首末拍 ----------
    # ⚠ 异步复位会**冲掉在飞的拍**（复位是立刻把寄存器清零，管线上那几拍必然到不了
    #   输出）—— 这是复位语义本身，不是丢数据。所以"有效拍数严格相等"的正确口径是：
    #   排除复位冲洗窗口后必须**严格相等**，且丢掉的数量必须**恰好等于**冲洗窗口内
    #   输入侧的有效拍数（多丢一拍就说明有别的问题）。
    kill_lo, kill_hi = MID_AT - 2, MID_AT + MID_LEN - 1
    nin = sum(1 for r in rows if r["Iv"] == 1)
    nout = sum(1 for r in rows if r["Ov"] == 1)
    n_killed = sum(1 for r in rows if r["Iv"] == 1 and kill_lo <= r["cyc"] <= kill_hi)
    first_in = next((in_beat(r["Id"]) for r in rows if r["Iv"] == 1), None)
    last_in = next((in_beat(r["Id"]) for r in reversed(rows) if r["Iv"] == 1), None)
    first_out = next((beat_of(r["Od"]) for r in rows if r["Ov"] == 1), None)
    last_out = next((beat_of(r["Od"]) for r in reversed(rows) if r["Ov"] == 1), None)
    R.add("A4 有效拍数相等（复位冲洗除外）", 1,
          0 if (nin - n_killed) == nout else 1,
          "输入 %d - 复位冲洗 %d = %d / 输出 %d" % (nin, n_killed, nin - n_killed, nout))
    R.add("A4c 只丢复位窗口内那几拍", 1,
          0 if (nin - nout) == n_killed else 1,
          "实际少 %d 拍 / 冲洗窗口内输入有效 %d 拍" % (nin - nout, n_killed))
    ok_head = (first_in == first_out and first_in is not None)
    ok_tail = (last_in == last_out and last_in is not None)
    R.add("A4b 输出首拍/末拍内容", 2, (0 if ok_head else 1) + (0 if ok_tail else 1),
          "首拍 in/out=%s/%s 末拍 in/out=%s/%s" % (first_in, first_out, last_in, last_out))

    # ---------- A5：复位窗口全 0 ----------
    n5 = n5b = 0
    for r in rows:
        if r["rn"] == 0:
            n5 += 1
            if r["Ov"] or r["Ol"] or r["Ou"] or int(r["Od"], 16) != 0:
                n5b += 1
    R.add("A5 复位窗口四路输出全 0", n5, n5b)

    # ---------- A6：X/Z ----------
    n6 = n6b = 0
    for r in rows:
        if r["Ov"] == 1:
            n6 += 1
            if set(r["Od"]) & set("xXzZ"):
                n6b += 1
    R.add("A6 有效期无 X/Z", n6, n6b)

    print("-" * 78)
    for name, nchk, nbad, detail in R.bad:
        print("  %-34s 检查 %6d 次 / 失配 %d %s" % (name, nchk, nbad,
                                                    ("  " + detail) if detail else ""))
    print("-" * 78)
    if R.err:
        print("  FAIL：%d 条断言未通过（0 次检查也算失败）" % R.err)
        return False
    print("  PASS：全部 %d 条契约断言通过" % len(R.bad))
    return True


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
