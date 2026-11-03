#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_m7_sync_files.py -- M7 集成需要落地的**副本 / 工程登记**一次做完。

做四件事（全部按字节操作，绝不改行尾）：
  1. src\\alg_top.v            -> prj\\_fullchip\\alg\\ 与 prj\\board\\...\\alg\\（三副本同步）
  2. src\\alg_region_fill_96.v -> 同上两个目录（新模块三副本同步）
  3. camera_to_dsi_display.al  : 加 alg_region_fill_96.v 一条（CompileOrder 66，保持 CRLF）
  4. run_ab_alg.tcl            : read_hdl 清单里加 alg/alg_region_fill_96.v

可重复执行（已登记则跳过）。
"""
from __future__ import annotations

import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = os.path.join(ROOT, "src")
FC = os.path.join(ROOT, "prj", "_fullchip", "alg")
BR = os.path.join(ROOT, "prj", "board", "lab_ex3_osd", "user_source", "hdl_source", "alg")
AL = os.path.join(ROOT, "prj", "board", "lab_ex3_osd", "td_project",
                  "camera_to_dsi_display.al")
TCL = os.path.join(ROOT, "prj", "_fullchip", "run_ab_alg.tcl")

COPY = ["alg_top.v", "alg_region_fill_96.v"]
NEW_AL = ('            <File Path="../user_source/hdl_source/alg/alg_region_fill_96.v">\r\n'
          '                <FileInfo>\r\n'
          '                    <Attr Name="UsedInSyn" Val="true"/>\r\n'
          '                    <Attr Name="UsedInP&R" Val="true"/>\r\n'
          '                    <Attr Name="BelongTo" Val="design_1"/>\r\n'
          '                    <Attr Name="CompileOrder" Val="66"/>\r\n'
          '                </FileInfo>\r\n'
          '            </File>\r\n')
ANCHOR_AL = ('            <File Path="../user_source/hdl_source/alg/alg_framediff_96.v">',
             '            </File>\r\n')


def copy_three():
    for name in COPY:
        s = os.path.join(SRC, name)
        if not os.path.isfile(s):
            raise SystemExit("源文件缺失：%s" % s)
        for d in (FC, BR):
            os.makedirs(d, exist_ok=True)
            shutil.copyfile(s, os.path.join(d, name))
            print("  复制 %-24s -> %s" % (name, os.path.relpath(d, ROOT)))


def reg_al():
    b = open(AL, "rb").read()
    if b"alg_region_fill_96.v" in b:
        print("  .al 已登记 alg_region_fill_96.v，跳过")
        return
    if b.count(b"\r\n") != b.count(b"\n"):
        raise SystemExit(".al 里出现裸 LF —— 先查行尾，不要硬写")
    txt = b.decode("utf-8")
    i = txt.index(ANCHOR_AL[0])
    j = txt.index(ANCHOR_AL[1], i) + len(ANCHOR_AL[1])
    out = txt[:j] + NEW_AL + txt[j:]
    open(AL, "wb").write(out.encode("utf-8"))
    nb = open(AL, "rb").read()
    assert nb.count(b"\r\n") == nb.count(b"\n")
    print("  .al 加入 alg_region_fill_96.v（CompileOrder 66）")


def reg_tcl():
    b = open(TCL, "rb").read()
    if b"alg_region_fill_96.v" in b:
        print("  run_ab_alg.tcl 已登记，跳过")
        return
    nl = b"\r\n" if b.count(b"\r\n") else b"\n"
    txt = b.decode("utf-8")
    anchor = "alg/alg_framediff_96.v"
    i = txt.index(anchor) + len(anchor)
    out = txt[:i] + " alg/alg_region_fill_96.v" + txt[i:]
    open(TCL, "wb").write(out.encode("utf-8"))
    nb = open(TCL, "rb").read()
    print("  run_ab_alg.tcl read_hdl 加入 alg/alg_region_fill_96.v（原行尾 %s）"
          % ("CRLF" if nl == b"\r\n" else "LF"))


def main():
    print("工程根：%s" % ROOT)
    copy_three()
    reg_al()
    reg_tcl()
    return 0


if __name__ == "__main__":
    sys.exit(main())
