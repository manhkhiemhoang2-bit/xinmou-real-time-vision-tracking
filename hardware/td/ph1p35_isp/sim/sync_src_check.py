#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
sync_src_check.py —— `src\\` 与 `prj\\_fullchip\\alg\\` 的 12 个 .v 必须逐字节一致（MD5 相同）

为什么要有这一步：交付 RTL 有两份（设计源 src\\ 与 TD 工程读的 prj\\_fullchip\\alg\\）。
改 src\\ 忘了同步 prj\\ 的话，TD 综合出来的还是旧逻辑，而仿真验的是新逻辑 ——
"仿真绿、板级错"的经典来源。本脚本把这条做成硬门禁（MD5 逐文件比 + 多退少补检查）。
⚠ 实际有**三份**副本：src\\、prj\\_fullchip\\alg\\、
  prj\\board\\lab_ex3_osd\\user_source\\hdl_source\\alg\\（板级那份由交付报告里的三方 MD5 核对覆盖）。

用法：
    python sync_src_check.py            # 只检查（不通过返回 1）
    python sync_src_check.py --sync     # 先按 src\\ 覆盖 prj\\ 再检查
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "src")
DST = os.path.join(ROOT, "prj", "_fullchip", "alg")

# 12 个交付文件（顺序固定，便于对照）
FILES = ["alg_binarize_96.v", "alg_color_detect_96.v", "alg_framediff_96.v",
         "alg_smooth_96.v", "alg_sobel_96.v", "alg_top.v", "gray_bt601_96.v",
         "my_charlib.v", "my_logo_rom.v", "osd_mixer.v", "rgb_row_delay_96.v",
         "win3x3_96.v"]


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def main():
    do_sync = "--sync" in sys.argv
    if not os.path.isdir(DST):
        print("!! 目标目录不存在：%s" % DST)
        return 1
    bad = 0
    print("%-24s %-34s %-34s %s" % ("文件", "src MD5", "prj MD5", "一致"))
    for f in FILES:
        a, b = os.path.join(SRC, f), os.path.join(DST, f)
        if not os.path.isfile(a):
            print("%-24s !! src 里不存在" % f)
            bad += 1
            continue
        if do_sync:
            shutil.copyfile(a, b)
        if not os.path.isfile(b):
            print("%-24s %-34s !! prj 里不存在" % (f, md5(a)))
            bad += 1
            continue
        ma, mb = md5(a), md5(b)
        same = (ma == mb)
        bad += 0 if same else 1
        print("%-24s %-34s %-34s %s" % (f, ma, mb, "是" if same else "!! 否 !!"))
    # 多退少补：prj 里不允许出现 src 没有的 .v（stale 文件会被 TD 一起综合）
    extra = sorted(set(x for x in os.listdir(DST) if x.endswith(".v")) - set(FILES))
    if extra:
        print("!! prj\\_fullchip\\alg 里有 src 不存在的 .v：%s" % extra)
        bad += len(extra)
    print("-" * 100)
    print("  12 个文件 MD5 全部一致：%s%s"
          % ("是" if bad == 0 else "否（%d 处不一致）" % bad,
             "（已 --sync 覆盖）" if do_sync else ""))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
