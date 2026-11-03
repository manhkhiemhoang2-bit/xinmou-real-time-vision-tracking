#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""_mut_lostn.py —— 生成 alg_color_detect_96 的"LOST_N 改小"变异版，用于判据反向对照。

用途：验证小图专项（tb_cd_cls + check_cd_cls）**真的**钉住了"丢 1~3 帧不许加编号"
这一侧边界。把 LOST_N 从 4 改成 1，编号就会在"只丢 1 帧"的重现处提前 +1，
判据必须报红；抓不住就说明激励的鉴别力是假的。

输出：sim\\_cd_cls\\alg_cd_mut.v（不改 src\\ 里的正式文件）
"""
from __future__ import annotations
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

SRC = r"D:\TD\bin\work_for_all\ph1p35_isp\src\alg_color_detect_96.v"
DST = r"D:\TD\bin\work_for_all\ph1p35_isp\sim\_cd_cls\alg_cd_mut.v"

OLD = "localparam [2:0] LOST_N   = 3'd4;"
NEW = "localparam [2:0] LOST_N   = 3'd1;"


def main():
    txt = open(SRC, encoding="utf-8").read()
    n = txt.count(OLD)
    if n != 1:
        raise SystemExit("在源文件里找到 %d 处 LOST_N 定义（应为 1 处），先核对源码再改" % n)
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(txt.replace(OLD, NEW))
    print("已生成 %s（LOST_N 4 -> 1）" % DST)


if __name__ == "__main__":
    main()
