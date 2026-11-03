#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
patch_pipe.py —— 给 osd_mixer.v 插入一级流水（v1.1 → v1.2）

只做 4 处**锚点替换**，其余 400 多行保持逐字节不变：
  P1  文件头 §二 延迟契约 1 拍 → 2 拍，并补写"为什么加这一级/加在哪/延迟怎么变"
  P2  把 §7~§9（ASCII / 字符码 / 字库索引 / my_charlib）从原位置删除（下移到第 2 级）
  P3  在 §10（Logo ROM）之后插入 §11 第 1 级流水寄存器 + §12 第 2 级组合逻辑
      + §13 第 2 级输出寄存器（原 §11/§12/§13 在此处被替换掉）
  P4  §14 上电初值块补齐全部新增寄存器

写文件用 UTF-8 无 BOM + LF（PowerShell 的 Set-Content -Encoding UTF8 会写 BOM，
会破坏 ModelSim / TD，故本脚本一律用 Python 写）。

用法：
    python patch_pipe.py            # 打补丁（自动先备份）
    python patch_pipe.py --check    # 只校验能否打补丁，不写文件
"""
from __future__ import annotations

import os
import shutil
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "src", "osd_mixer.v")
COPY = os.path.join(ROOT, "prj", "_fullchip", "alg", "osd_mixer.v")

# ===========================================================================
# P1 —— 文件头：版本 + 延迟契约 + 新增"为什么要加这一级"
# ===========================================================================
A1_OLD = """// 日期     : 2026-09-14
// 版本     : v1.1"""
A1_NEW = """// 日期     : 2026-09-16
// 版本     : v1.2"""

A2_OLD = """//  ---------------------------------------------------------------------------
//  【二、延迟契约（S0-02 §8.1⑥：所有输出同拍）】
//  ---------------------------------------------------------------------------
//  输出相对输入**恒定延迟 1 拍**，4 路输出（tdata/tvalid/tlast/tuser）全部在
//  同一个第 1 级寄存器上装载 —— 不存在"数据走 2 拍、控制走 1 拍"的错位。
//  O_tready 是组合直通（`assign O_tready = I_tready;`），全链路不反压。
"""
A2_NEW = """//  ---------------------------------------------------------------------------
//  【二、延迟契约（S0-02 §8.1⑥：所有输出同拍）】
//  ---------------------------------------------------------------------------
//  输出相对输入**恒定延迟 2 拍**（v1.2 起；v1.1 是 1 拍），4 路输出
//  （tdata/tvalid/tlast/tuser）全部在**同一个第 2 级寄存器**上装载 ——
//  不存在"数据走 2 拍、控制走 1 拍"的错位。
//  O_tready 是组合直通（`assign O_tready = I_tready;`），全链路不反压。
//
//  ---------------------------------------------------------------------------
//  【二·补、为什么把延迟从 1 拍改成 2 拍（2026-09-16 时序优化）】
//  ---------------------------------------------------------------------------
//  TD 布线后报告：本模块是全设计**自研代码的最差路径** ——
//      Begin: u_isp_top/u_osd_mixer/r_info_x_reg[8]
//      End  : u_isp_top/u_osd_mixer/O_tdata_reg[14]
//      Data Path Delay 14.623ns / Logic Level 17 / Slack 1.853ns @16.668ns(60MHz)
//  逐级展开就是一条**没有寄存器的长组合链**：
//      r_info_x → 十进制拆位(9 级优先比较链 + 4 级行波加法) → 十位链 → 个位
//      → ASCII → case(w_txt_ci) 选字符码 → w_rom_index → my_charlib 查表
//      → 点阵位选 w_txt_hit0..3 → w_pix_text_hit → w_mix → O_tdata
//
//  **加在哪**：在"十进制数字/字符码算完"与"查表 + 命中 + 混合"之间，插入一级
//  流水寄存器（§11）。第 1 级 = 原来的组合逻辑（只把它的结果寄存下来）；
//  第 2 级 = ASCII/字符码/字库索引/查表/命中/混合/输出（§12、§13）。
//
//  **核心纪律**：合并点另一侧的所有信号必须**一起寄存同样一拍**，两边才仍然
//  逐拍对齐 —— 位置侧（行/列/字符下标/字内列基址）、Logo 侧（4 命中 + 4 颜色
//  = 100 bit）、像素数据（96 bit）、以及控制（tvalid/tlast/tuser 派生的
//  r_vld1/r_tlast/r_tuser）一个都不能漏。漏一个就是两面错位，不是"少一点功能"。
//
//  **代价与收益**：O_tdata / O_tvalid / O_tlast / O_tuser 相对输入的延迟由
//  1 拍变成 2 拍（这是**唯一**的行为变化，用改造前的 RTL 当参考模型逐拍比对
//  证明：输出序列 = 老版本整体延迟 1 拍，见 sim/check_pipe_equiv.py）。
//  掩蔽规则、文字>Logo>原像素的优先级、O_tready 语义一律不动。
//
//  ⚠ 两个最容易漏的"活叶子"（第 2 级绝不能再直接读，否则等价性被破坏）：
//    · w_mode_chars 由**端口** I_info_mode 组合而来（不是 r_info_mode）；
//    · FPS 的两个半字节由 r_info_fps 组合而来。
//    两者都在第 1 级一起寄存（§11），连"输入侧同一沿变化"也逐拍对齐。
"""

# ===========================================================================
# P2 —— 删除 §7~§9（整体下移到第 2 级）
# ===========================================================================
P2_START = "// 7. 字符槽 ASCII（下标定义见文件头 §六）"
P2_END = "    .O_bits  (w_glyph_bits)\n);\n"
P2_NEW = """//------------------------------------------------------------------------------
// 7~9. 字符槽 ASCII / 字符码选择(case) / ASCII→字库索引 / my_charlib 例化
//      —— v1.2 起这三节**整体下移到第 2 级流水**（见本文件 §12）。
//         理由：它们的输入（十进制各位、w_txt_ci、w_txt_row）已经在 §11 被
//         寄存了一拍，留在这里会让第 1 级重新长出那条长链。
//------------------------------------------------------------------------------
"""

# ===========================================================================
# P3 —— §11 第 1 级流水寄存器 + §12 第 2 级组合 + §13 输出级
# ===========================================================================
P3_START = "// 11. 逐像素命中判据（文字面）"
P3_END = """    else
        O_tuser <= r_tuser;
end
"""
P3_NEW = """//------------------------------------------------------------------------------
// 11. 【v1.2 新增 · 第 1 级流水】把第 2 级要用到的**全部叶子值**寄存一拍
//
//  这一级就是老版本"组合到 w_mix 为止"的前半段：数字拆位、位置判据、Logo 查表
//  都在这一级算完（与 v1.1 逐 bit 相同），然后在同一个时钟沿把结果整体捕获
//  —— 即"把老版本 O_tdata 的整个输入锥体一起打一拍"。
//
//  ⚠ 合并点另一侧一个都不能漏，清单（共 264 bit + 3 控制位）：
//      十进制各位 7x4 = 28  · FPS 半字节 8   · 档位 ASCII 16（来自端口！）
//      位置 13（inrow/incol/ci[4:0]/col_base[2]/row[4]）
//      Logo 4+96 = 100      · 原像素 96      · 控制 r_vld2/r_tlast2/r_tuser2
//  本模块**不门控**这一级（与老版本输出级同语义）：有效与否只由控制位决定，
//  第 2 级在控制位为 0 时把 O_tdata 强制置 0 —— 所以气泡期捕获到什么值都不影响。
//------------------------------------------------------------------------------
reg [3:0]  r_x_th_p1, r_x_h_p1, r_x_t_p1, r_x_o_p1;         // I_info_x 的十进制各位
reg [3:0]  r_lat_h_p1, r_lat_t_p1, r_lat_o_p1;              // I_info_lat 的十进制各位
reg [3:0]  r_fps_hi_p1, r_fps_lo_p1;                        // I_info_fps 低字节的两个半字节
reg [15:0] r_mode_chars_p1;                                 // 端口 I_info_mode 的组合结果（活叶子）
reg        r_txt_inrow_p1, r_txt_incol_p1;                  // 文字面行/列区间
reg [4:0]  r_txt_ci_p1;                                     // 字符槽下标
reg [1:0]  r_txt_col_base_p1;                               // 字内列基址（一拍 4 像素）
reg [3:0]  r_txt_row_p1;                                    // 字模行号
reg        r_logo_hit0_p1, r_logo_hit1_p1,
           r_logo_hit2_p1, r_logo_hit3_p1;                  // Logo 命中（4 像素）
reg [23:0] r_logo_col0_p1, r_logo_col1_p1,
           r_logo_col2_p1, r_logo_col3_p1;                  // Logo 颜色（4 像素）
reg [95:0] r_pix_data_p1;                                   // 原像素（4 x RGB888）
reg        r_vld2, r_tlast2, r_tuser2;                      // 控制：r_vld1/r_tlast/r_tuser 再延一拍

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_th_p1   <= 4'd0;
        r_x_h_p1    <= 4'd0;
        r_x_t_p1    <= 4'd0;
        r_x_o_p1    <= 4'd0;
        r_lat_h_p1  <= 4'd0;
        r_lat_t_p1  <= 4'd0;
        r_lat_o_p1  <= 4'd0;
        r_fps_hi_p1 <= 4'd0;
        r_fps_lo_p1 <= 4'd0;
        r_mode_chars_p1 <= 16'd0;
        r_txt_inrow_p1  <= 1'b0;
        r_txt_incol_p1  <= 1'b0;
        r_txt_ci_p1     <= 5'd0;
        r_txt_col_base_p1 <= 2'd0;
        r_txt_row_p1    <= 4'd0;
        r_logo_hit0_p1  <= 1'b0;
        r_logo_hit1_p1  <= 1'b0;
        r_logo_hit2_p1  <= 1'b0;
        r_logo_hit3_p1  <= 1'b0;
        r_logo_col0_p1  <= 24'd0;
        r_logo_col1_p1  <= 24'd0;
        r_logo_col2_p1  <= 24'd0;
        r_logo_col3_p1  <= 24'd0;
        r_pix_data_p1   <= 96'd0;
        r_vld2          <= 1'b0;
        r_tlast2        <= 1'b0;
        r_tuser2        <= 1'b0;
    end else begin
        r_x_th_p1   <= w_x_th;
        r_x_h_p1    <= w_x_h;
        r_x_t_p1    <= w_x_t;
        r_x_o_p1    <= w_x_o;
        r_lat_h_p1  <= w_lat_h;
        r_lat_t_p1  <= w_lat_t;
        r_lat_o_p1  <= w_lat_o;
        r_fps_hi_p1 <= r_info_fps[7:4];
        r_fps_lo_p1 <= r_info_fps[3:0];
        r_mode_chars_p1 <= w_mode_chars;
        r_txt_inrow_p1  <= w_txt_inrow;
        r_txt_incol_p1  <= w_txt_incol;
        r_txt_ci_p1     <= w_txt_ci;
        r_txt_col_base_p1 <= w_txt_col_base;
        r_txt_row_p1    <= w_txt_row;
        r_logo_hit0_p1  <= w_logo_hit0;
        r_logo_hit1_p1  <= w_logo_hit1;
        r_logo_hit2_p1  <= w_logo_hit2;
        r_logo_hit3_p1  <= w_logo_hit3;
        r_logo_col0_p1  <= w_logo_col0;
        r_logo_col1_p1  <= w_logo_col1;
        r_logo_col2_p1  <= w_logo_col2;
        r_logo_col3_p1  <= w_logo_col3;
        r_pix_data_p1   <= I_tdata;
        r_vld2          <= r_vld1;
        r_tlast2        <= r_tlast;
        r_tuser2        <= r_tuser;
    end
end

//------------------------------------------------------------------------------
// 12. 【第 2 级】ASCII → 字符码 → 字库索引 → 点阵 → 逐像素命中 → 混合
//
//  输入**全部**来自 §11 的寄存器：这里不许再读任何端口或未寄存量。
//  与 v1.1 的对应关系（逐字）：
//      w_x_o/w_lat_h/... → r_x_o_p1/r_lat_h_p1/...   （十进制各位）
//      w_txt_ci          → r_txt_ci_p1                （case 的选择量）
//      w_txt_row         → r_txt_row_p1               （字模行号）
//      w_txt_col_base    → r_txt_col_base_p1          （字内列基址）
//      w_txt_inrow/incol → r_txt_inrow_p1/r_txt_incol_p1
//      w_logo_hit*/col*  → r_logo_hit*_p1/r_logo_col*_p1
//      I_tdata           → r_pix_data_p1
//------------------------------------------------------------------------------
// ---- 12.1 字符槽 ASCII（下标定义见文件头 §六，与 v1.1 完全一致）----
wire [7:0] w_ch_x_o   = {4'h0, r_x_o_p1}   + 8'h30;
wire [7:0] w_ch_x_t   = {4'h0, r_x_t_p1}   + 8'h30;
wire [7:0] w_ch_x_h   = {4'h0, r_x_h_p1}   + 8'h30;
wire [7:0] w_ch_x_th  = {4'h0, r_x_th_p1}  + 8'h30;
wire [7:0] w_ch_lat_o = {4'h0, r_lat_o_p1} + 8'h30;
wire [7:0] w_ch_lat_t = {4'h0, r_lat_t_p1} + 8'h30;
wire [7:0] w_ch_lat_h = {4'h0, r_lat_h_p1} + 8'h30;
// FPS 十六进制：半字节 0..9 → '0'..'9'，10..15 → ':'..'?'（可辨认；不做 A..F 映射以省 LUT）
wire [7:0] w_ch_fps_hi = 8'h30 + {4'h0, r_fps_hi_p1};
wire [7:0] w_ch_fps_lo = 8'h30 + {4'h0, r_fps_lo_p1};

reg [7:0] w_char_code;

always @ (*) begin
    case (r_txt_ci_p1)
        5'd0:    w_char_code = r_mode_chars_p1[15:8];   // 'M'
        5'd1:    w_char_code = r_mode_chars_p1[7:0];    // 档位数字
        5'd2:    w_char_code = 8'h20;                // 空格
        5'd3:    w_char_code = 8'h46;                // 'F'
        5'd4:    w_char_code = 8'h50;                // 'P'
        5'd5:    w_char_code = 8'h53;                // 'S'
        5'd6:    w_char_code = 8'h3A;                // ':'
        5'd7:    w_char_code = w_ch_fps_hi;
        5'd8:    w_char_code = w_ch_fps_lo;
        5'd9:    w_char_code = 8'h20;                // 空格
        5'd10:   w_char_code = 8'h4C;                // 'L'
        5'd11:   w_char_code = 8'h41;                // 'A'
        5'd12:   w_char_code = 8'h54;                // 'T'
        5'd13:   w_char_code = 8'h3A;                // ':'
        5'd14:   w_char_code = w_ch_lat_h;
        5'd15:   w_char_code = w_ch_lat_t;
        5'd16:   w_char_code = w_ch_lat_o;
        5'd17:   w_char_code = 8'h20;                // 空格
        5'd18:   w_char_code = 8'h58;                // 'X'
        5'd19:   w_char_code = 8'h3A;                // ':'
        5'd20:   w_char_code = w_ch_x_th;
        5'd21:   w_char_code = w_ch_x_h;
        5'd22:   w_char_code = w_ch_x_t;
        5'd23:   w_char_code = w_ch_x_o;
        5'd24:   w_char_code = 8'h59;                // 'Y'
        default: w_char_code = 8'h3F;                // '?'（占位，见 §六）
    endcase
end

// ---- 12.2 ASCII → my_charlib 索引（表见 my_charlib.v 头部 / gen_osd_rom.py:CHARLIB_INDEX）
//      '0'..'9' 0x30..0x39 → idx  0..9    idx = ascii - 0x30
//      'A'..'Z' 0x41..0x5A → idx 10..35   idx = ascii - 0x37
//      ':' 0x3A → 36   '.' 0x2E → 37   '/' 0x2F → 38   ' ' 0x20 → 39
reg [7:0] w_rom_index;

always @ (*) begin
    if ((w_char_code >= 8'h30) && (w_char_code <= 8'h39))
        w_rom_index = w_char_code - 8'h30;          // 数字
    else if ((w_char_code >= 8'h41) && (w_char_code <= 8'h5A))
        w_rom_index = w_char_code - 8'h37;          // 大写字母
    else if (w_char_code == 8'h20)
        w_rom_index = 8'd39;                        // 空格
    else if (w_char_code == 8'h3A)
        w_rom_index = 8'd36;                        // ':'
    else if (w_char_code == 8'h2E)
        w_rom_index = 8'd37;                        // '.'
    else if (w_char_code == 8'h2F)
        w_rom_index = 8'd38;                        // '/'
    else
        w_rom_index = 8'd39;                        // 未定义 → 空格
end

// ---- 12.3 字库例化（自研原创素材；只读、组合读）
//      一拍 4 个像素共用同一行字模（字符下标与行号都是拍级量），所以只例化 1 个，
//      4 个像素各自从返回的 16 bit 里取自己那一位（§12.5）。
wire [15:0] w_glyph_bits;      // 该字符该行的点阵，bit[15] = 最左

my_charlib u_charlib (
    .I_index (w_rom_index),
    .I_row   (r_txt_row_p1),
    .O_bits  (w_glyph_bits)
);

// ---- 12.4 逐像素命中判据（文字面）
//      文字：本拍落在文字行/列范围内 && 该字该行该列的点阵 bit = 1 → 命中
//      字内列 = (x - TEXT_X) & 15 = {r_txt_col_base_p1, 2'b00} + k
//      字库 bit[15] 是最左像素，所以取 w_glyph_bits[15 - 列号]。
wire [3:0] w_txt_col0 = {r_txt_col_base_p1, 2'b00};
wire [3:0] w_txt_col1 = w_txt_col0 + 4'd1;
wire [3:0] w_txt_col2 = w_txt_col0 + 4'd2;
wire [3:0] w_txt_col3 = w_txt_col0 + 4'd3;

wire w_txt_hit0 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col0];
wire w_txt_hit1 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col1];
wire w_txt_hit2 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col2];
wire w_txt_hit3 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col3];

wire [3:0] w_pix_text_hit = {w_txt_hit3, w_txt_hit2, w_txt_hit1, w_txt_hit0};

// ---- 12.5 像素混合：文字 > Logo > 原像素（优先级与 v1.1 一字不改）
//      ⚠⚠ 下标必须是 k，**不是** 3-k：w_pix_text_hit = {hit3,hit2,hit1,hit0}，而
//         w_mixk 送的是原像素的第 k 个（pix0 = [95:72] = 最左，x 偏移 k）。
//         写成 3-k 会把一拍的 4 个像素整体镜像翻转（2026-09-14 已修，此处只是搬家）。
wire [23:0] w_mix0 = w_pix_text_hit[0] ? OSD_TEXT_COLOR :
                     (r_logo_hit0_p1   ? r_logo_col0_p1 : r_pix_data_p1[95:72]);
wire [23:0] w_mix1 = w_pix_text_hit[1] ? OSD_TEXT_COLOR :
                     (r_logo_hit1_p1   ? r_logo_col1_p1 : r_pix_data_p1[71:48]);
wire [23:0] w_mix2 = w_pix_text_hit[2] ? OSD_TEXT_COLOR :
                     (r_logo_hit2_p1   ? r_logo_col2_p1 : r_pix_data_p1[47:24]);
wire [23:0] w_mix3 = w_pix_text_hit[3] ? OSD_TEXT_COLOR :
                     (r_logo_hit3_p1   ? r_logo_col3_p1 : r_pix_data_p1[23:0]);

wire [95:0] w_mix = {w_mix0, w_mix1, w_mix2, w_mix3};

//------------------------------------------------------------------------------
// 13. 输出级（第 2 级寄存器）：4 路输出全部在同一级装载
//     ⇒ 延迟严格 2 拍、天然同拍；有效标志用 r_vld2（= I_tvalid 延迟 2 拍）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld2)
        O_tdata <= w_mix;
    else
        O_tdata <= 96'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld2;             // = I_tvalid 延迟 2 拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tlast <= 1'b0;
    else
        O_tlast <= r_tlast2;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tuser <= 1'b0;
    else
        O_tuser <= r_tuser2;
end
"""

# ===========================================================================
# P4 —— 上电初值块
# ===========================================================================
P4_START = "// 14. 上电初值"
P4_NEW = """//------------------------------------------------------------------------------
// 14. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//------------------------------------------------------------------------------
initial begin
    r_x_grp     = {XW{1'b0}};
    r_y_pos     = 11'd0;
    r_x_now     = 11'd0;
    r_y_now     = 11'd0;
    r_tlast     = 1'b0;
    r_tuser     = 1'b0;
    r_vld1      = 1'b0;
    r_info_mode = 11'd0;
    r_info_fps  = 32'd0;
    r_info_lat  = 11'd0;
    r_info_x    = 11'd0;
    r_info_y    = 11'd0;
    // ---- v1.2 第 1 级流水（与 §11 的复位分支逐一相同）----
    r_x_th_p1   = 4'd0;
    r_x_h_p1    = 4'd0;
    r_x_t_p1    = 4'd0;
    r_x_o_p1    = 4'd0;
    r_lat_h_p1  = 4'd0;
    r_lat_t_p1  = 4'd0;
    r_lat_o_p1  = 4'd0;
    r_fps_hi_p1 = 4'd0;
    r_fps_lo_p1 = 4'd0;
    r_mode_chars_p1 = 16'd0;
    r_txt_inrow_p1  = 1'b0;
    r_txt_incol_p1  = 1'b0;
    r_txt_ci_p1     = 5'd0;
    r_txt_col_base_p1 = 2'd0;
    r_txt_row_p1    = 4'd0;
    r_logo_hit0_p1  = 1'b0;
    r_logo_hit1_p1  = 1'b0;
    r_logo_hit2_p1  = 1'b0;
    r_logo_hit3_p1  = 1'b0;
    r_logo_col0_p1  = 24'd0;
    r_logo_col1_p1  = 24'd0;
    r_logo_col2_p1  = 24'd0;
    r_logo_col3_p1  = 24'd0;
    r_pix_data_p1   = 96'd0;
    r_vld2          = 1'b0;
    r_tlast2        = 1'b0;
    r_tuser2        = 1'b0;
    O_tdata     = 96'd0;
    O_tvalid    = 1'b0;
    O_tlast     = 1'b0;
    O_tuser     = 1'b0;
end
"""


def cut(txt, start_marker, end_marker, upto_line_start=True):
    """返回 (head, body, tail)：body = [start_marker 所在行的 '//---' 起始 .. end_marker 结束]"""
    i = txt.index(start_marker)
    if upto_line_start:
        j = txt.rindex("//---", 0, i)
    else:
        j = i
    k = txt.index(end_marker, i) + len(end_marker)
    return txt[:j], txt[j:k], txt[k:]


def apply_patches(txt):
    n = 0
    for old, new in ((A1_OLD, A1_NEW), (A2_OLD, A2_NEW)):
        assert txt.count(old) == 1, "锚点出现 %d 次：%r" % (txt.count(old), old[:60])
        txt = txt.replace(old, new)
        n += 1

    head, _body, tail = cut(txt, P2_START, P2_END)
    assert "my_charlib u_charlib" in _body and "w_rom_index" in _body
    txt = head + P2_NEW + tail
    n += 1

    head, _body, tail = cut(txt, P3_START, P3_END)
    assert "w_pix_text_hit" in _body and "O_tuser <= r_tuser;" in _body
    txt = head + P3_NEW + tail
    n += 1

    head, _body, tail = cut(txt, P4_START, "    O_tuser     = 1'b0;\nend\n", upto_line_start=False)
    # 从 §14 注释块的开头切（保留 "//----" 行以上的内容）
    j = head.rindex("//---")
    txt = head[:j] + P4_NEW + tail
    n += 1
    return txt, n


def main():
    check_only = "--check" in sys.argv
    orig = open(SRC, encoding="utf-8", newline="").read()
    assert "\r" not in orig, "源文件含 CR，本脚本只处理 LF"
    new, n = apply_patches(orig)
    # ---- 静态自检 ----
    import re as _re
    for bad in (r"^\s*function\b", r"^\s*task\b", r"^\s*fork\b", r"^\s*wait\b",
                r"^\s*force\b", r"^\s*release\b", r"#\s*\d"):
        m = _re.search(bad, new, _re.M)
        assert m is None, "违禁语法 %s 出现在：%r" % (bad, new[m.start():m.start() + 40] if m else "")
    for reg in ("r_vld2", "r_tlast2", "r_tuser2", "r_pix_data_p1", "r_txt_ci_p1",
                "r_logo_hit3_p1", "r_logo_col3_p1", "r_mode_chars_p1", "r_fps_lo_p1"):
        assert new.count(reg) >= 3, "%s 出现次数过少（声明/复位/初值/使用）" % reg
    # initial 块与复位分支必须逐一覆盖同一个集合
    print("补丁数: %d ; 原 %d 行 → 新 %d 行" % (n, orig.count("\n"), new.count("\n")))
    if check_only:
        print("[check] 锚点全部匹配，未写文件")
        return
    ts = time.strftime("%Y%m%d-%H%M%S")
    bak = os.path.join(os.path.dirname(SRC), "osd_mixer.v.bak-%s" % ts)
    shutil.copy(SRC, bak)
    for path in (SRC, COPY):
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new)
    print("备份 : %s" % bak)
    print("写入 : %s" % SRC)
    print("同步 : %s" % COPY)


if __name__ == "__main__":
    main()
