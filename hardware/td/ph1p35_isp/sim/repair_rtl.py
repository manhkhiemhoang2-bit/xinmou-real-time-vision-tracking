#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""修复 osd_mixer.v.mangled：
   1) 把 13 处"注释+代码"合并行拆开（代码部分原样保留）
   2) 被 Set-Content 打成 '?' 的中文注释换成干净的说明
   3) 输出 UTF-8 无 BOM、LF 换行
"""
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
SRC = r"D:\TD\bin\work_for_all\ph1p35_isp\src\osd_mixer.v.mangled"
DST = r"D:\TD\bin\work_for_all\ph1p35_isp\src\osd_mixer.v"
lines = open(SRC, encoding="utf-8").read().split("\n")

# 按行号给出修复：把该行替换成若干行
FIX = {}

FIX[18] = [
    "//  O_tready is a combinational passthrough (`assign O_tready = I_tready;`);",
    "//  the whole chain never back-pressures.",
]
FIX[87] = [
    "localparam BEATS_PER_LINE = IMG_WIDTH >> 2;             // 1280 >> 2 = 320 beats/line",
    "localparam XW             = $clog2(BEATS_PER_LINE);     // 320 -> 9",
]
FIX[92] = [
    "localparam TEXT_W     = 16;                             // glyph width  in pixels",
    "localparam TEXT_H     = 16;                             // glyph height in pixels",
]
FIX[97] = [
    "reg [XW-1:0] r_x_grp;        // beat counter 0..319 (NOT a pixel counter)",
    "reg [10:0]   r_y_pos;        // row counter  0..719",
]
FIX[104] = [
    "        if (I_tuser) begin                              // frame start: sync coords",
    "            r_x_grp <= {XW{1'b0}};",
]
FIX[139] = ["reg [10:0]   r_x_now;"]
FIX[154] = [
    "// OSD hit test must use the coordinates of the pixel being loaded, so text and",
    "// logo share this one pair (r_x / r_y).",
    "wire [10:0] r_x = r_x_now;",
]
FIX[158] = ["wire [10:0] w_x_base = {r_x[8:0], 2'b00};"]
FIX[160] = ["wire [11:0] w_txt_dx_cur = {1'b0, w_x_base} - {1'b0, TEXT_X};"]
FIX[182] = [
    "        //   (earlier it was [1:0], which is always 0 -> every beat read",
    "        //    glyph bits [15:12]; that caused 447/16384 mismatched pixels).",
    "        r_txt_col_base <= w_txt_dx_cur[3:2];",
]
FIX[271] = ["wire [3:0]  w_x_th = (r_info_x >= 11'd1000) ? 4'd1 : 4'd0;"]
FIX[315] = ["wire [7:0] w_ch_fps_hi = 8'h30 + {4'h0, r_info_fps[7:4]};"]
FIX[430] = ["wire w_txt_hit0 = r_in_txt_row && r_in_txt_col && w_glyph_bits[15 - w_txt_col0];"]

out = []
for i, l in enumerate(lines, 1):
    if i in FIX:
        out.extend(FIX[i])
        continue
    # 其它把两行代码粘在一起的补一刀：只在 "//" 注释里出现 RTL 且行尾是 ; 的情况再处理
    out.append(l.rstrip())

# 兜底：把仍含 '?' 的整行（纯注释行）替换成英文占位，避免留下乱码
clean = []
for l in out:
    if "?" in l and l.lstrip().startswith("//"):
        clean.append("// (comment lost in repair; see git history)")
    else:
        clean.append(l)

open(DST, "w", encoding="utf-8", newline="\n").write("\n".join(clean))
print("wrote %d lines" % len(clean))
