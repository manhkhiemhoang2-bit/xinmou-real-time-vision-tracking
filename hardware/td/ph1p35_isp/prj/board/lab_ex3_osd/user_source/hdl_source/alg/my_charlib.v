// ============================================================================
// my_charlib.v
//   —— 点阵数据由 gen_osd_rom.py 生成（自研原创素材，**不复制**官方 ROM）
//   生成时间：2026-09-12 21:11:57（点阵内容与旧版逐 bit 相同，本次未改数据）
//   规格：字符 ROM 42 字 x 16x16 点阵
//   说明：每行 16 bit，bit[15] = 最左像素（MSB first）
//         '1' = 点亮（取前景色），'0' = 透明/背景
//
// ============================================================================
//  ★★ 2026-10-24 v1.1：组合 case → **同步读 ROM（片上 ERAM / 块 RAM）**
// ============================================================================
//  【为什么改】旧版是 672 条 case 的**组合**译码器（`always @(*) case({I_index,I_row})`）。
//    TD 综合实测 u_charlib 的 #lut = 3785
//    （camera_to_dsi_display_Runs\syn_1\camera_to_dsi_display_rtl.area），
//    是全设计最大的单块 LUT 消耗；而它驱动的 "r_info_x → O_tdata" 链约 20 级 LUT。
//    改成存储器后，这 3785 个 LUT 整体挪进 ERAM（预计 1 块：672x16 = 10752 bit，
//    按本工程实测的 ERAM 规模 2048x18/块，见 alg_logo_eram.v §一）。
//
//  【接口变化（唯一一处，别的都不变）】
//    · 新增 I_clk：ERAM 是同步读，"地址进 → **下一拍**数据出"（1 拍读延迟）。
//    · O_bits 由 output reg（组合）改称 output wire（同步）：**比 I_index/I_row 晚 1 拍**。
//    · I_index/I_row 的语义、点阵内容、bit[15] 最左 —— 全部不变。
//    ⚠ 调用方（osd_mixer）必须按"晚 1 拍"消费：ROM 返回的这一拍，
//      所有同拍的陪跑信号（像素/Logo/字内列基址/行区间/控制）也得一起再延 1 拍，
//      漏一个就是文字面错位。osd_mixer 的做法见它自己的 §11b（p2 寄存器组）。
//
//  【输出与旧版的等价性（逐 bit，不是"差不多"）】
//    · I_index 0..41：O_bits = char_rom[{index,row}]，数据与旧版 case 逐 bit 相同。
//    · I_index 42..255：旧版落 case 的 default = 16'h0000；
//      新版由 r_idx_ok 掩蔽成 16'h0000 ⇒ 也逐 bit 相同。
//    · 逐拍等价的实证：sim_charlib_ram\tb_osd_equiv.v 同时例化新旧 osd_mixer，
//      新版输出 = 旧版整体延迟 1 拍、其余逐 bit 相等（ALL PASS）。
//
//  【ERAM 推断要点（照抄 alg_logo_eram.v §四，别随手改）】
//    ① 读地址位宽必须**恰好** $clog2(深度) = 10 位；
//    ② 读数据寄存器 r_bits **直连**阵列，中间不许有任何运算；
//    ③ 阵列上**没有复位、没有初值寄存器**（初值只用 initial）；
//    ④ ram_style 同时给属性 (* rom_style = "block" *) 和 TD 自家注释
//       //synthesis ram_style = bram（与 alg_logo_eram.v 同款，TD 认这条）。
//    ⚠ 是否真的吃到 ERAM，**只能等 TD 综合**看 report_area 的 #eram / #dram lut；
//      仿真看不出这件事（ModelSim 把阵列当普通数组，行为一样）。
//
//  【已知限制】
//    1. 读出的是**整行** 16 bit（一拍 4 个像素共用同一行字模），使用方自己按列选位。
//    2. 字库内容不能在线改写（只读）；要改字体得改本文件的 initial 段。
//    3. 读延迟固定 1 拍，不可参数化。
// ============================================================================
`timescale 1ns / 1ps

module my_charlib #(
    parameter CHAR_W = 16,        // 点阵宽（bit/行）
    parameter CHAR_H = 16,        // 点阵高（行/字）
    parameter CHAR_N = 42         // 字库字数
)(
    input  wire        I_clk,     // v1.1 新增：同步读时钟
    input  wire [ 7:0] I_index,   // 字符索引（见下面 CHAR_* 索引表）
    input  wire [ 3:0] I_row,     // 行地址 0..15
    output wire [15:0] O_bits     // 该行点阵，bit[15] = 最左（比 I_index/I_row 晚 1 拍）
);

localparam MEM_DEPTH = CHAR_N * CHAR_H;      // 672 = 42 x 16
localparam AW        = $clog2(MEM_DEPTH);    // 10 —— 必须恰好 10 位（§四①）

// ---- 字符索引表（与生成本文件时的 CHARLIB_ORDER 完全一致）----
//   idx= 0  '0'  code=0x30      idx=21  'L'  code=0x4C
//   idx= 1  '1'  code=0x31      idx=22  'M'  code=0x4D
//   idx= 2  '2'  code=0x32      idx=23  'N'  code=0x4E
//   idx= 3  '3'  code=0x33      idx=24  'O'  code=0x4F
//   idx= 4  '4'  code=0x34      idx=25  'P'  code=0x50
//   idx= 5  '5'  code=0x35      idx=26  'Q'  code=0x51
//   idx= 6  '6'  code=0x36      idx=27  'R'  code=0x52
//   idx= 7  '7'  code=0x37      idx=28  'S'  code=0x53
//   idx= 8  '8'  code=0x38      idx=29  'T'  code=0x54
//   idx= 9  '9'  code=0x39      idx=30  'U'  code=0x55
//   idx=10  'A'  code=0x41      idx=31  'V'  code=0x56
//   idx=11  'B'  code=0x42      idx=32  'W'  code=0x57
//   idx=12  'C'  code=0x43      idx=33  'X'  code=0x58
//   idx=13  'D'  code=0x44      idx=34  'Y'  code=0x59
//   idx=14  'E'  code=0x45      idx=35  'Z'  code=0x5A
//   idx=15  'F'  code=0x46      idx=36  ':'  code=0x3A
//   idx=16  'G'  code=0x47      idx=37  '.'  code=0x2E
//   idx=17  'H'  code=0x48      idx=38  '/'  code=0x2F
//   idx=18  'I'  code=0x49      idx=39  'SPACE' code=0x20
//   idx=19  'J'  code=0x4A      idx=40  '安' code=0xA1A2
//   idx=20  'K'  code=0x4B      idx=41  '路' code=0xA1A3

//------------------------------------------------------------------------------
// 1. 存储器本体（只读 + initial 初值。**没有复位、没有初值寄存器**，§四③）
//    地址 = {index[5:0], row}，即 index*16 + row；index 0..41 ⇒ 0..671。
//------------------------------------------------------------------------------
(* rom_style = "block" *)
reg [15:0] char_rom [0:MEM_DEPTH-1];   //synthesis ram_style = bram

initial begin

    // ---- '0' (idx 0) ----
    char_rom[  0] = 16'h3FF0;
    char_rom[  1] = 16'h6018;
    char_rom[  2] = 16'h6018;
    char_rom[  3] = 16'h6018;
    char_rom[  4] = 16'h6018;
    char_rom[  5] = 16'h6018;
    char_rom[  6] = 16'h6018;
    char_rom[  7] = 16'h6018;
    char_rom[  8] = 16'h6018;
    char_rom[  9] = 16'h6018;
    char_rom[ 10] = 16'h6018;
    char_rom[ 11] = 16'h6018;
    char_rom[ 12] = 16'h6018;
    char_rom[ 13] = 16'h3FF0;
    char_rom[ 14] = 16'h0000;
    char_rom[ 15] = 16'h0000;

    // ---- '1' (idx 1) ----
    char_rom[ 16] = 16'h0300;
    char_rom[ 17] = 16'h0F00;
    char_rom[ 18] = 16'h3F00;
    char_rom[ 19] = 16'h0300;
    char_rom[ 20] = 16'h0300;
    char_rom[ 21] = 16'h0300;
    char_rom[ 22] = 16'h0300;
    char_rom[ 23] = 16'h0300;
    char_rom[ 24] = 16'h0300;
    char_rom[ 25] = 16'h0300;
    char_rom[ 26] = 16'h0300;
    char_rom[ 27] = 16'h0300;
    char_rom[ 28] = 16'h3FFC;
    char_rom[ 29] = 16'h3FFC;
    char_rom[ 30] = 16'h0000;
    char_rom[ 31] = 16'h0000;

    // ---- '2' (idx 2) ----
    char_rom[ 32] = 16'h3FF0;
    char_rom[ 33] = 16'h6018;
    char_rom[ 34] = 16'h000C;
    char_rom[ 35] = 16'h000C;
    char_rom[ 36] = 16'h0030;
    char_rom[ 37] = 16'h00C0;
    char_rom[ 38] = 16'h0300;
    char_rom[ 39] = 16'h0C00;
    char_rom[ 40] = 16'h3000;
    char_rom[ 41] = 16'h6000;
    char_rom[ 42] = 16'h6000;
    char_rom[ 43] = 16'h6000;
    char_rom[ 44] = 16'h7FFE;
    char_rom[ 45] = 16'h7FFE;
    char_rom[ 46] = 16'h0000;
    char_rom[ 47] = 16'h0000;

    // ---- '3' (idx 3) ----
    char_rom[ 48] = 16'h3FF0;
    char_rom[ 49] = 16'h6018;
    char_rom[ 50] = 16'h000C;
    char_rom[ 51] = 16'h000C;
    char_rom[ 52] = 16'h00F0;
    char_rom[ 53] = 16'h00F0;
    char_rom[ 54] = 16'h000C;
    char_rom[ 55] = 16'h000C;
    char_rom[ 56] = 16'h000C;
    char_rom[ 57] = 16'h000C;
    char_rom[ 58] = 16'h000C;
    char_rom[ 59] = 16'h6018;
    char_rom[ 60] = 16'h3FF0;
    char_rom[ 61] = 16'h0000;
    char_rom[ 62] = 16'h0000;
    char_rom[ 63] = 16'h0000;

    // ---- '4' (idx 4) ----
    char_rom[ 64] = 16'h00F0;
    char_rom[ 65] = 16'h03F0;
    char_rom[ 66] = 16'h0C30;
    char_rom[ 67] = 16'h3030;
    char_rom[ 68] = 16'h6030;
    char_rom[ 69] = 16'h6030;
    char_rom[ 70] = 16'h7FFE;
    char_rom[ 71] = 16'h7FFE;
    char_rom[ 72] = 16'h0030;
    char_rom[ 73] = 16'h0030;
    char_rom[ 74] = 16'h0030;
    char_rom[ 75] = 16'h0030;
    char_rom[ 76] = 16'h0030;
    char_rom[ 77] = 16'h0000;
    char_rom[ 78] = 16'h0000;
    char_rom[ 79] = 16'h0000;

    // ---- '5' (idx 5) ----
    char_rom[ 80] = 16'h7FFE;
    char_rom[ 81] = 16'h7FFE;
    char_rom[ 82] = 16'h6000;
    char_rom[ 83] = 16'h6000;
    char_rom[ 84] = 16'h6000;
    char_rom[ 85] = 16'h7FF0;
    char_rom[ 86] = 16'h7FF0;
    char_rom[ 87] = 16'h000C;
    char_rom[ 88] = 16'h000C;
    char_rom[ 89] = 16'h000C;
    char_rom[ 90] = 16'h000C;
    char_rom[ 91] = 16'h6018;
    char_rom[ 92] = 16'h3FF0;
    char_rom[ 93] = 16'h0000;
    char_rom[ 94] = 16'h0000;
    char_rom[ 95] = 16'h0000;

    // ---- '6' (idx 6) ----
    char_rom[ 96] = 16'h03F0;
    char_rom[ 97] = 16'h0C0C;
    char_rom[ 98] = 16'h3000;
    char_rom[ 99] = 16'h6000;
    char_rom[100] = 16'h6000;
    char_rom[101] = 16'h7FF0;
    char_rom[102] = 16'h6018;
    char_rom[103] = 16'h6018;
    char_rom[104] = 16'h6018;
    char_rom[105] = 16'h6018;
    char_rom[106] = 16'h6018;
    char_rom[107] = 16'h3030;
    char_rom[108] = 16'h0FC0;
    char_rom[109] = 16'h0000;
    char_rom[110] = 16'h0000;
    char_rom[111] = 16'h0000;

    // ---- '7' (idx 7) ----
    char_rom[112] = 16'h7FFE;
    char_rom[113] = 16'h7FFE;
    char_rom[114] = 16'h000C;
    char_rom[115] = 16'h0018;
    char_rom[116] = 16'h0030;
    char_rom[117] = 16'h0060;
    char_rom[118] = 16'h00C0;
    char_rom[119] = 16'h0180;
    char_rom[120] = 16'h0300;
    char_rom[121] = 16'h0300;
    char_rom[122] = 16'h0700;
    char_rom[123] = 16'h0700;
    char_rom[124] = 16'h0700;
    char_rom[125] = 16'h0000;
    char_rom[126] = 16'h0000;
    char_rom[127] = 16'h0000;

    // ---- '8' (idx 8) ----
    char_rom[128] = 16'h0FC0;
    char_rom[129] = 16'h3030;
    char_rom[130] = 16'h6018;
    char_rom[131] = 16'h6018;
    char_rom[132] = 16'h3030;
    char_rom[133] = 16'h0FC0;
    char_rom[134] = 16'h3030;
    char_rom[135] = 16'h6018;
    char_rom[136] = 16'h6018;
    char_rom[137] = 16'h6018;
    char_rom[138] = 16'h6018;
    char_rom[139] = 16'h3030;
    char_rom[140] = 16'h0FC0;
    char_rom[141] = 16'h0000;
    char_rom[142] = 16'h0000;
    char_rom[143] = 16'h0000;

    // ---- '9' (idx 9) ----
    char_rom[144] = 16'h0FC0;
    char_rom[145] = 16'h3030;
    char_rom[146] = 16'h6018;
    char_rom[147] = 16'h6018;
    char_rom[148] = 16'h6018;
    char_rom[149] = 16'h3038;
    char_rom[150] = 16'h0FFC;
    char_rom[151] = 16'h000C;
    char_rom[152] = 16'h000C;
    char_rom[153] = 16'h000C;
    char_rom[154] = 16'h0030;
    char_rom[155] = 16'h3060;
    char_rom[156] = 16'h3FC0;
    char_rom[157] = 16'h0000;
    char_rom[158] = 16'h0000;
    char_rom[159] = 16'h0000;

    // ---- 'A' (idx 10) ----
    char_rom[160] = 16'h03C0;
    char_rom[161] = 16'h07E0;
    char_rom[162] = 16'h0C30;
    char_rom[163] = 16'h1818;
    char_rom[164] = 16'h1818;
    char_rom[165] = 16'h300C;
    char_rom[166] = 16'h300C;
    char_rom[167] = 16'h3FFC;
    char_rom[168] = 16'h3FFC;
    char_rom[169] = 16'h6006;
    char_rom[170] = 16'h6006;
    char_rom[171] = 16'h6006;
    char_rom[172] = 16'hC003;
    char_rom[173] = 16'h0000;
    char_rom[174] = 16'h0000;
    char_rom[175] = 16'h0000;

    // ---- 'B' (idx 11) ----
    char_rom[176] = 16'h7FF0;
    char_rom[177] = 16'h6018;
    char_rom[178] = 16'h6018;
    char_rom[179] = 16'h6018;
    char_rom[180] = 16'h7FF0;
    char_rom[181] = 16'h7FF0;
    char_rom[182] = 16'h6018;
    char_rom[183] = 16'h6018;
    char_rom[184] = 16'h6018;
    char_rom[185] = 16'h6018;
    char_rom[186] = 16'h6018;
    char_rom[187] = 16'h7FF0;
    char_rom[188] = 16'h0000;
    char_rom[189] = 16'h0000;
    char_rom[190] = 16'h0000;
    char_rom[191] = 16'h0000;

    // ---- 'C' (idx 12) ----
    char_rom[192] = 16'h0FFC;
    char_rom[193] = 16'h3003;
    char_rom[194] = 16'h6000;
    char_rom[195] = 16'h6000;
    char_rom[196] = 16'hC000;
    char_rom[197] = 16'hC000;
    char_rom[198] = 16'hC000;
    char_rom[199] = 16'hC000;
    char_rom[200] = 16'hC000;
    char_rom[201] = 16'h6000;
    char_rom[202] = 16'h6000;
    char_rom[203] = 16'h3003;
    char_rom[204] = 16'h0FFC;
    char_rom[205] = 16'h0000;
    char_rom[206] = 16'h0000;
    char_rom[207] = 16'h0000;

    // ---- 'D' (idx 13) ----
    char_rom[208] = 16'h7FF0;
    char_rom[209] = 16'h6018;
    char_rom[210] = 16'h600C;
    char_rom[211] = 16'h6006;
    char_rom[212] = 16'h6006;
    char_rom[213] = 16'h6006;
    char_rom[214] = 16'h6006;
    char_rom[215] = 16'h6006;
    char_rom[216] = 16'h6006;
    char_rom[217] = 16'h600C;
    char_rom[218] = 16'h6018;
    char_rom[219] = 16'h7FF0;
    char_rom[220] = 16'h0000;
    char_rom[221] = 16'h0000;
    char_rom[222] = 16'h0000;
    char_rom[223] = 16'h0000;

    // ---- 'E' (idx 14) ----
    char_rom[224] = 16'h7FFE;
    char_rom[225] = 16'h7FFE;
    char_rom[226] = 16'h6000;
    char_rom[227] = 16'h6000;
    char_rom[228] = 16'h7FF0;
    char_rom[229] = 16'h7FF0;
    char_rom[230] = 16'h6000;
    char_rom[231] = 16'h6000;
    char_rom[232] = 16'h6000;
    char_rom[233] = 16'h6000;
    char_rom[234] = 16'h6000;
    char_rom[235] = 16'h7FFE;
    char_rom[236] = 16'h7FFE;
    char_rom[237] = 16'h0000;
    char_rom[238] = 16'h0000;
    char_rom[239] = 16'h0000;

    // ---- 'F' (idx 15) ----
    char_rom[240] = 16'h7FFE;
    char_rom[241] = 16'h7FFE;
    char_rom[242] = 16'h6000;
    char_rom[243] = 16'h6000;
    char_rom[244] = 16'h7FF0;
    char_rom[245] = 16'h7FF0;
    char_rom[246] = 16'h6000;
    char_rom[247] = 16'h6000;
    char_rom[248] = 16'h6000;
    char_rom[249] = 16'h6000;
    char_rom[250] = 16'h6000;
    char_rom[251] = 16'h6000;
    char_rom[252] = 16'h6000;
    char_rom[253] = 16'h0000;
    char_rom[254] = 16'h0000;
    char_rom[255] = 16'h0000;

    // ---- 'G' (idx 16) ----
    char_rom[256] = 16'h0FFC;
    char_rom[257] = 16'h3003;
    char_rom[258] = 16'h6000;
    char_rom[259] = 16'h6000;
    char_rom[260] = 16'hC000;
    char_rom[261] = 16'hC000;
    char_rom[262] = 16'hC0FF;
    char_rom[263] = 16'hC0FF;
    char_rom[264] = 16'hC00C;
    char_rom[265] = 16'h600C;
    char_rom[266] = 16'h600C;
    char_rom[267] = 16'h300C;
    char_rom[268] = 16'h0FFC;
    char_rom[269] = 16'h0000;
    char_rom[270] = 16'h0000;
    char_rom[271] = 16'h0000;

    // ---- 'H' (idx 17) ----
    char_rom[272] = 16'h6006;
    char_rom[273] = 16'h6006;
    char_rom[274] = 16'h6006;
    char_rom[275] = 16'h6006;
    char_rom[276] = 16'h7FFE;
    char_rom[277] = 16'h7FFE;
    char_rom[278] = 16'h6006;
    char_rom[279] = 16'h6006;
    char_rom[280] = 16'h6006;
    char_rom[281] = 16'h6006;
    char_rom[282] = 16'h6006;
    char_rom[283] = 16'h6006;
    char_rom[284] = 16'h6006;
    char_rom[285] = 16'h0000;
    char_rom[286] = 16'h0000;
    char_rom[287] = 16'h0000;

    // ---- 'I' (idx 18) ----
    char_rom[288] = 16'h3FFC;
    char_rom[289] = 16'h3FFC;
    char_rom[290] = 16'h0300;
    char_rom[291] = 16'h0300;
    char_rom[292] = 16'h0300;
    char_rom[293] = 16'h0300;
    char_rom[294] = 16'h0300;
    char_rom[295] = 16'h0300;
    char_rom[296] = 16'h0300;
    char_rom[297] = 16'h0300;
    char_rom[298] = 16'h0300;
    char_rom[299] = 16'h3FFC;
    char_rom[300] = 16'h3FFC;
    char_rom[301] = 16'h0000;
    char_rom[302] = 16'h0000;
    char_rom[303] = 16'h0000;

    // ---- 'J' (idx 19) ----
    char_rom[304] = 16'h000C;
    char_rom[305] = 16'h000C;
    char_rom[306] = 16'h000C;
    char_rom[307] = 16'h000C;
    char_rom[308] = 16'h000C;
    char_rom[309] = 16'h000C;
    char_rom[310] = 16'h000C;
    char_rom[311] = 16'h000C;
    char_rom[312] = 16'h000C;
    char_rom[313] = 16'h6018;
    char_rom[314] = 16'h6018;
    char_rom[315] = 16'h3030;
    char_rom[316] = 16'h0FC0;
    char_rom[317] = 16'h0000;
    char_rom[318] = 16'h0000;
    char_rom[319] = 16'h0000;

    // ---- 'K' (idx 20) ----
    char_rom[320] = 16'h6018;
    char_rom[321] = 16'h6060;
    char_rom[322] = 16'h6180;
    char_rom[323] = 16'h6600;
    char_rom[324] = 16'h7E00;
    char_rom[325] = 16'h7E00;
    char_rom[326] = 16'h6600;
    char_rom[327] = 16'h6180;
    char_rom[328] = 16'h6060;
    char_rom[329] = 16'h6018;
    char_rom[330] = 16'h6018;
    char_rom[331] = 16'h6006;
    char_rom[332] = 16'h6006;
    char_rom[333] = 16'h0000;
    char_rom[334] = 16'h0000;
    char_rom[335] = 16'h0000;

    // ---- 'L' (idx 21) ----
    char_rom[336] = 16'h6000;
    char_rom[337] = 16'h6000;
    char_rom[338] = 16'h6000;
    char_rom[339] = 16'h6000;
    char_rom[340] = 16'h6000;
    char_rom[341] = 16'h6000;
    char_rom[342] = 16'h6000;
    char_rom[343] = 16'h6000;
    char_rom[344] = 16'h6000;
    char_rom[345] = 16'h6000;
    char_rom[346] = 16'h6000;
    char_rom[347] = 16'h7FFE;
    char_rom[348] = 16'h7FFE;
    char_rom[349] = 16'h0000;
    char_rom[350] = 16'h0000;
    char_rom[351] = 16'h0000;

    // ---- 'M' (idx 22) ----
    char_rom[352] = 16'h6006;
    char_rom[353] = 16'h700E;
    char_rom[354] = 16'h7C3E;
    char_rom[355] = 16'h67E6;
    char_rom[356] = 16'h63C6;
    char_rom[357] = 16'h6186;
    char_rom[358] = 16'h6006;
    char_rom[359] = 16'h6006;
    char_rom[360] = 16'h6006;
    char_rom[361] = 16'h6006;
    char_rom[362] = 16'h6006;
    char_rom[363] = 16'h6006;
    char_rom[364] = 16'h6006;
    char_rom[365] = 16'h0000;
    char_rom[366] = 16'h0000;
    char_rom[367] = 16'h0000;

    // ---- 'N' (idx 23) ----
    char_rom[368] = 16'h6006;
    char_rom[369] = 16'h7006;
    char_rom[370] = 16'h7806;
    char_rom[371] = 16'h6C06;
    char_rom[372] = 16'h6606;
    char_rom[373] = 16'h6306;
    char_rom[374] = 16'h6186;
    char_rom[375] = 16'h60C6;
    char_rom[376] = 16'h6066;
    char_rom[377] = 16'h6036;
    char_rom[378] = 16'h601E;
    char_rom[379] = 16'h600E;
    char_rom[380] = 16'h6006;
    char_rom[381] = 16'h0000;
    char_rom[382] = 16'h0000;
    char_rom[383] = 16'h0000;

    // ---- 'O' (idx 24) ----
    char_rom[384] = 16'h0FFC;
    char_rom[385] = 16'h3003;
    char_rom[386] = 16'h6001;
    char_rom[387] = 16'h6001;
    char_rom[388] = 16'hC001;
    char_rom[389] = 16'hC001;
    char_rom[390] = 16'hC001;
    char_rom[391] = 16'hC001;
    char_rom[392] = 16'hC001;
    char_rom[393] = 16'h6001;
    char_rom[394] = 16'h6001;
    char_rom[395] = 16'h3003;
    char_rom[396] = 16'h0FFC;
    char_rom[397] = 16'h0000;
    char_rom[398] = 16'h0000;
    char_rom[399] = 16'h0000;

    // ---- 'P' (idx 25) ----
    char_rom[400] = 16'h7FF0;
    char_rom[401] = 16'h6018;
    char_rom[402] = 16'h6018;
    char_rom[403] = 16'h6018;
    char_rom[404] = 16'h6018;
    char_rom[405] = 16'h7FF0;
    char_rom[406] = 16'h7FF0;
    char_rom[407] = 16'h6000;
    char_rom[408] = 16'h6000;
    char_rom[409] = 16'h6000;
    char_rom[410] = 16'h6000;
    char_rom[411] = 16'h6000;
    char_rom[412] = 16'h6000;
    char_rom[413] = 16'h0000;
    char_rom[414] = 16'h0000;
    char_rom[415] = 16'h0000;

    // ---- 'Q' (idx 26) ----
    char_rom[416] = 16'h0FFC;
    char_rom[417] = 16'h3003;
    char_rom[418] = 16'h6001;
    char_rom[419] = 16'h6001;
    char_rom[420] = 16'hC000;
    char_rom[421] = 16'hC000;
    char_rom[422] = 16'hC000;
    char_rom[423] = 16'hC000;
    char_rom[424] = 16'hC030;
    char_rom[425] = 16'h601E;
    char_rom[426] = 16'h600C;
    char_rom[427] = 16'h300E;
    char_rom[428] = 16'h0FFD;
    char_rom[429] = 16'h0000;
    char_rom[430] = 16'h0000;
    char_rom[431] = 16'h0000;

    // ---- 'R' (idx 27) ----
    char_rom[432] = 16'h7FF0;
    char_rom[433] = 16'h6018;
    char_rom[434] = 16'h6018;
    char_rom[435] = 16'h6018;
    char_rom[436] = 16'h7FF0;
    char_rom[437] = 16'h7FF0;
    char_rom[438] = 16'h60C0;
    char_rom[439] = 16'h6060;
    char_rom[440] = 16'h6030;
    char_rom[441] = 16'h6018;
    char_rom[442] = 16'h6018;
    char_rom[443] = 16'h600C;
    char_rom[444] = 16'h6006;
    char_rom[445] = 16'h0000;
    char_rom[446] = 16'h0000;
    char_rom[447] = 16'h0000;

    // ---- 'S' (idx 28) ----
    char_rom[448] = 16'h0FFC;
    char_rom[449] = 16'h3003;
    char_rom[450] = 16'h6000;
    char_rom[451] = 16'h6000;
    char_rom[452] = 16'h3000;
    char_rom[453] = 16'h0E00;
    char_rom[454] = 16'h03C0;
    char_rom[455] = 16'h0070;
    char_rom[456] = 16'h000C;
    char_rom[457] = 16'h0006;
    char_rom[458] = 16'h6006;
    char_rom[459] = 16'h300C;
    char_rom[460] = 16'h0FF0;
    char_rom[461] = 16'h0000;
    char_rom[462] = 16'h0000;
    char_rom[463] = 16'h0000;

    // ---- 'T' (idx 29) ----
    char_rom[464] = 16'h7FFE;
    char_rom[465] = 16'h7FFE;
    char_rom[466] = 16'h0300;
    char_rom[467] = 16'h0300;
    char_rom[468] = 16'h0300;
    char_rom[469] = 16'h0300;
    char_rom[470] = 16'h0300;
    char_rom[471] = 16'h0300;
    char_rom[472] = 16'h0300;
    char_rom[473] = 16'h0300;
    char_rom[474] = 16'h0300;
    char_rom[475] = 16'h0300;
    char_rom[476] = 16'h0300;
    char_rom[477] = 16'h0000;
    char_rom[478] = 16'h0000;
    char_rom[479] = 16'h0000;

    // ---- 'U' (idx 30) ----
    char_rom[480] = 16'h6006;
    char_rom[481] = 16'h6006;
    char_rom[482] = 16'h6006;
    char_rom[483] = 16'h6006;
    char_rom[484] = 16'h6006;
    char_rom[485] = 16'h6006;
    char_rom[486] = 16'h6006;
    char_rom[487] = 16'h6006;
    char_rom[488] = 16'h6006;
    char_rom[489] = 16'h6006;
    char_rom[490] = 16'h300C;
    char_rom[491] = 16'h1818;
    char_rom[492] = 16'h07E0;
    char_rom[493] = 16'h0000;
    char_rom[494] = 16'h0000;
    char_rom[495] = 16'h0000;

    // ---- 'V' (idx 31) ----
    char_rom[496] = 16'hC003;
    char_rom[497] = 16'h6006;
    char_rom[498] = 16'h6006;
    char_rom[499] = 16'h300C;
    char_rom[500] = 16'h300C;
    char_rom[501] = 16'h1818;
    char_rom[502] = 16'h1818;
    char_rom[503] = 16'h0C30;
    char_rom[504] = 16'h0C30;
    char_rom[505] = 16'h0660;
    char_rom[506] = 16'h0660;
    char_rom[507] = 16'h03C0;
    char_rom[508] = 16'h03C0;
    char_rom[509] = 16'h0000;
    char_rom[510] = 16'h0000;
    char_rom[511] = 16'h0000;

    // ---- 'W' (idx 32) ----
    char_rom[512] = 16'hC003;
    char_rom[513] = 16'hC003;
    char_rom[514] = 16'h6006;
    char_rom[515] = 16'h6006;
    char_rom[516] = 16'h6186;
    char_rom[517] = 16'h63C6;
    char_rom[518] = 16'h67E6;
    char_rom[519] = 16'h7C3E;
    char_rom[520] = 16'h700E;
    char_rom[521] = 16'h6006;
    char_rom[522] = 16'h6006;
    char_rom[523] = 16'h6006;
    char_rom[524] = 16'h6006;
    char_rom[525] = 16'h0000;
    char_rom[526] = 16'h0000;
    char_rom[527] = 16'h0000;

    // ---- 'X' (idx 33) ----
    char_rom[528] = 16'hC003;
    char_rom[529] = 16'h6006;
    char_rom[530] = 16'h300C;
    char_rom[531] = 16'h1818;
    char_rom[532] = 16'h0C30;
    char_rom[533] = 16'h0660;
    char_rom[534] = 16'h03C0;
    char_rom[535] = 16'h03C0;
    char_rom[536] = 16'h0660;
    char_rom[537] = 16'h0C30;
    char_rom[538] = 16'h1818;
    char_rom[539] = 16'h300C;
    char_rom[540] = 16'h6006;
    char_rom[541] = 16'h0000;
    char_rom[542] = 16'h0000;
    char_rom[543] = 16'h0000;

    // ---- 'Y' (idx 34) ----
    char_rom[544] = 16'hC003;
    char_rom[545] = 16'h6006;
    char_rom[546] = 16'h300C;
    char_rom[547] = 16'h1818;
    char_rom[548] = 16'h0C30;
    char_rom[549] = 16'h0660;
    char_rom[550] = 16'h03C0;
    char_rom[551] = 16'h0300;
    char_rom[552] = 16'h0300;
    char_rom[553] = 16'h0300;
    char_rom[554] = 16'h0300;
    char_rom[555] = 16'h0300;
    char_rom[556] = 16'h0300;
    char_rom[557] = 16'h0000;
    char_rom[558] = 16'h0000;
    char_rom[559] = 16'h0000;

    // ---- 'Z' (idx 35) ----
    char_rom[560] = 16'h7FFE;
    char_rom[561] = 16'h7FFE;
    char_rom[562] = 16'h0018;
    char_rom[563] = 16'h0030;
    char_rom[564] = 16'h0060;
    char_rom[565] = 16'h00C0;
    char_rom[566] = 16'h0180;
    char_rom[567] = 16'h0300;
    char_rom[568] = 16'h0600;
    char_rom[569] = 16'h0C00;
    char_rom[570] = 16'h1800;
    char_rom[571] = 16'h3000;
    char_rom[572] = 16'h7FFE;
    char_rom[573] = 16'h7FFE;
    char_rom[574] = 16'h0000;
    char_rom[575] = 16'h0000;

    // ---- ':' (idx 36) ----
    char_rom[576] = 16'h0000;
    char_rom[577] = 16'h0000;
    char_rom[578] = 16'h03C0;
    char_rom[579] = 16'h03C0;
    char_rom[580] = 16'h03C0;
    char_rom[581] = 16'h03C0;
    char_rom[582] = 16'h0000;
    char_rom[583] = 16'h0000;
    char_rom[584] = 16'h0000;
    char_rom[585] = 16'h0000;
    char_rom[586] = 16'h03C0;
    char_rom[587] = 16'h03C0;
    char_rom[588] = 16'h03C0;
    char_rom[589] = 16'h03C0;
    char_rom[590] = 16'h0000;
    char_rom[591] = 16'h0000;

    // ---- '.' (idx 37) ----
    char_rom[592] = 16'h0000;
    char_rom[593] = 16'h0000;
    char_rom[594] = 16'h0000;
    char_rom[595] = 16'h0000;
    char_rom[596] = 16'h0000;
    char_rom[597] = 16'h0000;
    char_rom[598] = 16'h0000;
    char_rom[599] = 16'h0000;
    char_rom[600] = 16'h0000;
    char_rom[601] = 16'h0000;
    char_rom[602] = 16'h0000;
    char_rom[603] = 16'h03C0;
    char_rom[604] = 16'h03C0;
    char_rom[605] = 16'h03C0;
    char_rom[606] = 16'h03C0;
    char_rom[607] = 16'h0000;

    // ---- '/' (idx 38) ----
    char_rom[608] = 16'h0003;
    char_rom[609] = 16'h0006;
    char_rom[610] = 16'h000C;
    char_rom[611] = 16'h0018;
    char_rom[612] = 16'h0030;
    char_rom[613] = 16'h0060;
    char_rom[614] = 16'h00C0;
    char_rom[615] = 16'h0180;
    char_rom[616] = 16'h0300;
    char_rom[617] = 16'h0600;
    char_rom[618] = 16'h0C00;
    char_rom[619] = 16'h1800;
    char_rom[620] = 16'h3000;
    char_rom[621] = 16'h6000;
    char_rom[622] = 16'hC000;
    char_rom[623] = 16'h0000;

    // ---- 'SPACE' (idx 39) ----
    char_rom[624] = 16'h0000;
    char_rom[625] = 16'h0000;
    char_rom[626] = 16'h0000;
    char_rom[627] = 16'h0000;
    char_rom[628] = 16'h0000;
    char_rom[629] = 16'h0000;
    char_rom[630] = 16'h0000;
    char_rom[631] = 16'h0000;
    char_rom[632] = 16'h0000;
    char_rom[633] = 16'h0000;
    char_rom[634] = 16'h0000;
    char_rom[635] = 16'h0000;
    char_rom[636] = 16'h0000;
    char_rom[637] = 16'h0000;
    char_rom[638] = 16'h0000;
    char_rom[639] = 16'h0000;

    // ---- '安' (idx 40) ----
    char_rom[640] = 16'h03C0;
    char_rom[641] = 16'h03C0;
    char_rom[642] = 16'h3FFC;
    char_rom[643] = 16'h3FFC;
    char_rom[644] = 16'h0660;
    char_rom[645] = 16'h0C30;
    char_rom[646] = 16'h1818;
    char_rom[647] = 16'h3FF0;
    char_rom[648] = 16'h3FF0;
    char_rom[649] = 16'h0C30;
    char_rom[650] = 16'h0C30;
    char_rom[651] = 16'h1818;
    char_rom[652] = 16'h300C;
    char_rom[653] = 16'h3FF0;
    char_rom[654] = 16'h0000;
    char_rom[655] = 16'h0000;

    // ---- '路' (idx 41) ----
    char_rom[656] = 16'h03C0;
    char_rom[657] = 16'h0F00;
    char_rom[658] = 16'h3C00;
    char_rom[659] = 16'h3F00;
    char_rom[660] = 16'h0C00;
    char_rom[661] = 16'h3F00;
    char_rom[662] = 16'h0C00;
    char_rom[663] = 16'h3FF0;
    char_rom[664] = 16'h3FF0;
    char_rom[665] = 16'h0C30;
    char_rom[666] = 16'h1C30;
    char_rom[667] = 16'h1818;
    char_rom[668] = 16'h300C;
    char_rom[669] = 16'h3FFC;
    char_rom[670] = 16'h0000;
    char_rom[671] = 16'h0000;
end

//------------------------------------------------------------------------------
// 2. 同步读：地址进 → 下一拍数据出（这就是新增的 1 拍延迟）
//    ⚠ 硬规则②：r_bits 直连阵列，不许写成 r_bits <= (cond ? rom[..] : 0) 之类
//------------------------------------------------------------------------------
wire [AW-1:0] w_rom_addr = {I_index[5:0], I_row};   // 10 位，恰好 $clog2(672)

reg [15:0] r_bits;
always @ (posedge I_clk) begin
    r_bits <= char_rom[w_rom_addr];
end

//------------------------------------------------------------------------------
// 3. 索引合法性掩蔽（= 旧版 case 的 default: O_bits = 16'h0000）
//    与 r_bits **同沿寄存** ⇒ 掩蔽与数据永远同拍，不会错位。
//    放在读寄存器之外（不是数据通路的一部分），所以不影响 ERAM 推断。
//------------------------------------------------------------------------------
reg r_idx_ok;

initial begin
    r_idx_ok = 1'b0;
end

always @ (posedge I_clk) begin
    r_idx_ok <= (I_index < CHAR_N);          // 0..41 ⇒ 1
end

assign O_bits = r_idx_ok ? r_bits : 16'h0000;

endmodule
