#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
lint_second_batch.py —— 第二批两个模块的规范门禁自检（文本级，不跑工具）

对照 S1第二批_接口冻结.md §0 通用约定 + §4/§5 端口表：
  1. UTF-8 且**不带 BOM**（BOM 拼进 Verilog 会让 TD 报 non-printable character 0xef）
  2. 无 Tab
  3. 禁 function / task / fork / join / wait / force / release / #<数字>
  4. 单文件单模块，模块名 == 文件名
  5. 端口表**逐字**对照 §4 / §5（名字、方向、位宽、顺序）
  6. 端口名 I_/O_ 前缀；内部 reg/wire 名 r_/w_ 前缀
  7. 时序块一律 posedge I_clk（可带 negedge I_rst_n）；组合块不得出现在 RTL 里
"""
from __future__ import annotations
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "src"))

SPEC = {
    "alg_color_detect_96.v": ("alg_color_detect_96", [
        ("input",  "wire", "I_clk", 1), ("input", "wire", "I_rst_n", 1),
        ("input",  "wire", "I_tdata", 96), ("input", "wire", "I_tvalid", 1),
        ("input",  "wire", "I_tlast", 1), ("input", "wire", "I_tuser", 1),
        ("input",  "wire", "I_tready", 1),
        ("input",  "wire", "I_tgt_color", 24), ("input", "wire", "I_tgt_tol", 8),
        ("output", "reg", "O_tdata", 96), ("output", "reg", "O_tvalid", 1),
        ("output", "reg", "O_tlast", 1), ("output", "reg", "O_tuser", 1),
        ("output", "wire", "O_tready", 1),
        ("output", "reg", "O_bbox_x0", 11), ("output", "reg", "O_bbox_x1", 11),
        ("output", "reg", "O_bbox_y0", 11), ("output", "reg", "O_bbox_y1", 11),
        ("output", "reg", "O_pix_count", 32), ("output", "reg", "O_bbox_valid", 1),
    ]),
    "rgb_row_delay_96.v": ("rgb_row_delay_96", [
        ("input",  "wire", "I_clk", 1), ("input", "wire", "I_rst_n", 1),
        ("input",  "wire", "I_tdata", 96), ("input", "wire", "I_tvalid", 1),
        ("input",  "wire", "I_tlast", 1), ("input", "wire", "I_tuser", 1),
        ("input",  "wire", "I_tready", 1),
        ("output", "reg", "O_tdata", 96), ("output", "reg", "O_tvalid", 1),
        ("output", "reg", "O_tlast", 1), ("output", "reg", "O_tuser", 1),
        ("output", "wire", "O_tready", 1),
    ]),
}

BANNED = [r"\bfunction\b", r"\btask\b", r"\bfork\b", r"\bjoin\b", r"\bwait\b",
          r"\bforce\b", r"\brelease\b", r"#\s*\d"]

PORT_RE = re.compile(
    r"^\s*(input|output|inout)\s+(wire|reg)\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)\s*(?:[,;)]|$)",
    re.M)


def width_of(decl):
    if not decl:
        return 1
    m = re.match(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", decl)
    hi, lo = int(m.group(1)), int(m.group(2))
    return hi - lo + 1


def check(fname):
    path = os.path.join(SRC, fname)
    raw = open(path, "rb").read()
    fails, notes = [], []

    # 1. BOM
    if raw[:3] == b"\xef\xbb\xbf":
        fails.append("带 BOM")
    try:
        txt = raw.decode("utf-8")
        notes.append("UTF-8 无 BOM")
    except UnicodeDecodeError as e:
        fails.append("不是合法 UTF-8：%s" % e)
        return fails, notes

    # 2. Tab
    ntab = txt.count("\t")
    if ntab:
        fails.append("含 %d 个 Tab" % ntab)
    else:
        notes.append("无 Tab")

    # 3. 禁用结构（**先剥注释**：文件头注释里正列举了这些禁用词，不能自己告自己）
    code = re.sub(r"/\*.*?\*/", " ", txt, flags=re.S)
    code = re.sub(r"//[^\n]*", " ", code)
    for pat in BANNED:
        hits = re.findall(pat, code)
        if hits:
            fails.append("代码里出现禁用结构 %s ×%d" % (pat, len(hits)))
    if not any("禁用" in f for f in fails):
        notes.append("无 function/task/fork/join/wait/force/release/#delay（已剥注释）")

    # 4. 单文件单模块
    mods = re.findall(r"^\s*module\s+(\w+)", txt, re.M)
    want_mod = SPEC[fname][0]
    if len(mods) != 1 or mods[0] != want_mod:
        fails.append("模块列表 %s != ['%s']" % (mods, want_mod))
    else:
        notes.append("单文件单模块，名 = %s" % want_mod)

    # 5. 端口表逐字（从 module 关键字之后找端口表的收尾 ");"）
    mstart = code.index("module")
    head = code[mstart:code.index(");", mstart)]
    got = [(d, t, n, width_of(w)) for (d, t, w, n) in PORT_RE.findall(head)]
    want = SPEC[fname][1]
    if got != want:
        fails.append("端口表不符：\n    期望 %s\n    实得 %s" % (want, got))
    else:
        notes.append("端口表与施工图逐字一致（%d 项，含顺序）" % len(want))

    # 6. 命名前缀
    ports = set(p[2] for p in want)
    bad_port = [p for p in ports if not (p.startswith("I_") or p.startswith("O_"))]
    if bad_port:
        fails.append("端口未用 I_/O_ 前缀：%s" % bad_port)
    decls = re.findall(r"^\s*(?:reg|wire)\s*(?:\[[^\]]*\])?\s*([A-Za-z_]\w*)", txt, re.M)
    bad_int = [d for d in decls if not (d.startswith("r_") or d.startswith("w_"))]
    if bad_int:
        fails.append("内部信号未用 r_/w_ 前缀：%s" % sorted(set(bad_int)))
    else:
        notes.append("端口 I_/O_、内部 r_/w_ 前缀全部合规（内部信号 %d 个）" % len(decls))

    # 7. always 块
    blocks = re.findall(r"always\s*@\s*\(([^)]*)\)", txt)
    bad_blocks = [b for b in blocks if "posedge" not in b]
    if bad_blocks:
        fails.append("存在非时序 always 块：%s" % bad_blocks)
    else:
        notes.append("%d 个 always 块全部为 posedge I_clk（无组合块 ⇒ 结构上不可能有 latch）"
                     % len(blocks))
    return fails, notes


def main():
    allok = True
    for fname in SPEC:
        fails, notes = check(fname)
        print("\n=== %s ===" % fname)
        for n in notes:
            print("  [ok] %s" % n)
        for f in fails:
            print("  [FAIL] %s" % f)
        allok &= not fails
    print("\n" + "=" * 60)
    print("规范门禁：%s" % ("全部通过" if allok else "存在 FAIL"))
    print("=" * 60)
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
