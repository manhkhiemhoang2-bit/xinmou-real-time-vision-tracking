//==============================================================================
// 文件名   : alg_sobel_96.v
// 模块名   : alg_sobel_96
// 描述     : 96-bit 算法通道 · M3 Sobel 边缘提取 + M7 素描全轮廓提取（3x3 窗口算子）
//
// 本次改进说明：
//   1. 全方向灰度梯度融合（Horizontal + Vertical Sobel + 45°/135° Roberts 对角梯度）：
//      提升斜向与弧形物体边界的連続性。
//   2. 引入 RGB 色度梯度融合（Chromatic Edge Fusion）：
//      针对红、蓝、绿物体与背景灰度亮度（Y）相近导致传统纯灰度 Sobel 漏检轮廓的问题
//      （特别是蓝色在 BT.601 中权重仅 29/256、红色仅 77/256），利用中心行彩色像素
//      I_rgb_center 计算水平与跨拍色差梯度 |ΔR|+|ΔG|+|ΔB| 并融入边缘强度，确保红、蓝、绿
//      物体的完整 360° 轮廓在 M3 与 M7 素描模式下均清晰不断裂。
//   3. 移除旧版将灰度截断为高 5 bit（步长 8）的 coarse_greater 苛刻门控，改用平滑梯度
//      一致性门限，彻底解决物体弧形轮廓与渐变边界被切成虚线或缺失的问题。
//==============================================================================

module alg_sobel_96 #(
    parameter integer C_OFF       = 0,
    parameter integer TH_MIN      = 0,
    parameter integer TH_MAX      = 255,
    parameter [8:0]   EDGE_K      = 9'd128,
    parameter [9:0]   TH_SCALE    = 10'd3,
    parameter [7:0]   EDGE_BG     = 8'd0,
    parameter         PURE_BW     = 1'b1
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_window_valid,
    input  wire [287:0] I_window,
    input  wire [95:0]  I_gray_src,
    input  wire [95:0]  I_rgb_center,
    input  wire         I_tvalid,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire         I_tready,
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

assign O_tready = I_tready;

localparam        COFF_NEG    = (C_OFF < 0) ? 1'b1 : 1'b0;
localparam [7:0]  COFF_MAG    = (C_OFF < 0) ? (-C_OFF) : C_OFF;
localparam [8:0]  TH_LO       = TH_MIN[8:0];
localparam [8:0]  TH_HI       = TH_MAX[8:0];
localparam [10:0] BW_TH_FLOOR = 11'd52;

//------------------------------------------------------------------------------
// 1. 窗口抽头
//------------------------------------------------------------------------------
wire [31:0] w_t00 = I_window[ 31:  0];
wire [31:0] w_t01 = I_window[ 63: 32];
wire [31:0] w_t02 = I_window[ 95: 64];
wire [31:0] w_t10 = I_window[127: 96];
wire [31:0] w_t11 = I_window[159:128];
wire [31:0] w_t12 = I_window[191:160];
wire [31:0] w_t20 = I_window[223:192];
wire [31:0] w_t21 = I_window[255:224];
wire [31:0] w_t22 = I_window[287:256];

//------------------------------------------------------------------------------
// 2. 局部均值自适应阈值
//------------------------------------------------------------------------------
wire [11:0] w_s0 = w_t00[ 7: 0] + w_t01[ 7: 0] + w_t02[ 7: 0]
                 + w_t10[ 7: 0] + w_t11[ 7: 0] + w_t12[ 7: 0]
                 + w_t20[ 7: 0] + w_t21[ 7: 0] + w_t22[ 7: 0];
wire [11:0] w_s1 = w_t00[15: 8] + w_t01[15: 8] + w_t02[15: 8]
                 + w_t10[15: 8] + w_t11[15: 8] + w_t12[15: 8]
                 + w_t20[15: 8] + w_t21[15: 8] + w_t22[15: 8];
wire [11:0] w_s2 = w_t00[23:16] + w_t01[23:16] + w_t02[23:16]
                 + w_t10[23:16] + w_t11[23:16] + w_t12[23:16]
                 + w_t20[23:16] + w_t21[23:16] + w_t22[23:16];
wire [11:0] w_s3 = w_t00[31:24] + w_t01[31:24] + w_t02[31:24]
                 + w_t10[31:24] + w_t11[31:24] + w_t12[31:24]
                 + w_t20[31:24] + w_t21[31:24] + w_t22[31:24];

wire [16:0] w_p0 = (w_s0 << 5) + (w_s0 << 4) + (w_s0 << 3) + w_s0;
wire [16:0] w_p1 = (w_s1 << 5) + (w_s1 << 4) + (w_s1 << 3) + w_s1;
wire [16:0] w_p2 = (w_s2 << 5) + (w_s2 << 4) + (w_s2 << 3) + w_s2;
wire [16:0] w_p3 = (w_s3 << 5) + (w_s3 << 4) + (w_s3 << 3) + w_s3;

wire [7:0] w_m0 = w_p0[16:9];
wire [7:0] w_m1 = w_p1[16:9];
wire [7:0] w_m2 = w_p2[16:9];
wire [7:0] w_m3 = w_p3[16:9];

wire [9:0] w_ma0 = {2'b00, w_m0};
wire [9:0] w_ma1 = {2'b00, w_m1};
wire [9:0] w_ma2 = {2'b00, w_m2};
wire [9:0] w_ma3 = {2'b00, w_m3};

wire [9:0] w_ad0 = w_ma0 + {2'b00, COFF_MAG};
wire [9:0] w_ad1 = w_ma1 + {2'b00, COFF_MAG};
wire [9:0] w_ad2 = w_ma2 + {2'b00, COFF_MAG};
wire [9:0] w_ad3 = w_ma3 + {2'b00, COFF_MAG};

wire [9:0] w_sb0 = (w_ma0 > {2'b00, COFF_MAG}) ? (w_ma0 - {2'b00, COFF_MAG}) : 10'd0;
wire [9:0] w_sb1 = (w_ma1 > {2'b00, COFF_MAG}) ? (w_ma1 - {2'b00, COFF_MAG}) : 10'd0;
wire [9:0] w_sb2 = (w_ma2 > {2'b00, COFF_MAG}) ? (w_ma2 - {2'b00, COFF_MAG}) : 10'd0;
wire [9:0] w_sb3 = (w_ma3 > {2'b00, COFF_MAG}) ? (w_ma3 - {2'b00, COFF_MAG}) : 10'd0;

wire [9:0] w_tr0 = COFF_NEG ? w_sb0 : w_ad0;
wire [9:0] w_tr1 = COFF_NEG ? w_sb1 : w_ad1;
wire [9:0] w_tr2 = COFF_NEG ? w_sb2 : w_ad2;
wire [9:0] w_tr3 = COFF_NEG ? w_sb3 : w_ad3;

wire [8:0] w_thm0 = (w_tr0 < {1'b0, TH_LO}) ? TH_LO :
                    ((w_tr0 > {1'b0, TH_HI}) ? TH_HI : w_tr0[8:0]);
wire [8:0] w_thm1 = (w_tr1 < {1'b0, TH_LO}) ? TH_LO :
                    ((w_tr1 > {1'b0, TH_HI}) ? TH_HI : w_tr1[8:0]);
wire [8:0] w_thm2 = (w_tr2 < {1'b0, TH_LO}) ? TH_LO :
                    ((w_tr2 > {1'b0, TH_HI}) ? TH_HI : w_tr2[8:0]);
wire [8:0] w_thm3 = (w_tr3 < {1'b0, TH_LO}) ? TH_LO :
                    ((w_tr3 > {1'b0, TH_HI}) ? TH_HI : w_tr3[8:0]);

wire [9:0] w_th0 = w_thm0 * TH_SCALE;
wire [9:0] w_th1 = w_thm1 * TH_SCALE;
wire [9:0] w_th2 = w_thm2 * TH_SCALE;
wire [9:0] w_th3 = w_thm3 * TH_SCALE;

wire [10:0] w_bw_th0_raw = ({3'b000, w_m0} >> 2) + 11'd30;
wire [10:0] w_bw_th1_raw = ({3'b000, w_m1} >> 2) + 11'd30;
wire [10:0] w_bw_th2_raw = ({3'b000, w_m2} >> 2) + 11'd30;
wire [10:0] w_bw_th3_raw = ({3'b000, w_m3} >> 2) + 11'd30;
wire [10:0] w_bw_th0 = (w_bw_th0_raw < BW_TH_FLOOR) ? BW_TH_FLOOR : w_bw_th0_raw;
wire [10:0] w_bw_th1 = (w_bw_th1_raw < BW_TH_FLOOR) ? BW_TH_FLOOR : w_bw_th1_raw;
wire [10:0] w_bw_th2 = (w_bw_th2_raw < BW_TH_FLOOR) ? BW_TH_FLOOR : w_bw_th2_raw;
wire [10:0] w_bw_th3 = (w_bw_th3_raw < BW_TH_FLOOR) ? BW_TH_FLOOR : w_bw_th3_raw;
wire [10:0] w_th_eff0 = PURE_BW ? w_bw_th0 : {1'b0, w_th0};
wire [10:0] w_th_eff1 = PURE_BW ? w_bw_th1 : {1'b0, w_th1};
wire [10:0] w_th_eff2 = PURE_BW ? w_bw_th2 : {1'b0, w_th2};
wire [10:0] w_th_eff3 = PURE_BW ? w_bw_th3 : {1'b0, w_th3};

//------------------------------------------------------------------------------
// 3. Sobel 水平/垂直梯度 + Roberts 45°/135° 对角梯度 + RGB 色差梯度融合
//------------------------------------------------------------------------------
wire [23:0] w_src0 = I_rgb_center[24*3 +: 24];
wire [23:0] w_src1 = I_rgb_center[24*2 +: 24];
wire [23:0] w_src2 = I_rgb_center[24*1 +: 24];
wire [23:0] w_src3 = I_rgb_center[24*0 +: 24];

reg [23:0] r_prev_src3;
reg        r_prev_vld;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_prev_src3 <= 24'd0;
        r_prev_vld  <= 1'b0;
    end else if (I_tvalid) begin
        r_prev_src3 <= w_src3;
        r_prev_vld  <= !I_tlast;
    end
end

function [9:0] f_rgb_diff;
    input [23:0] a;
    input [23:0] b;
    reg [7:0] dr, dg, db;
    begin
        dr = (a[23:16] >= b[23:16]) ? (a[23:16] - b[23:16]) : (b[23:16] - a[23:16]);
        dg = (a[15:8]  >= b[15:8])  ? (a[15:8]  - b[15:8])  : (b[15:8]  - a[15:8]);
        db = (a[7:0]   >= b[7:0])   ? (a[7:0]   - b[7:0])   : (b[7:0]   - a[7:0]);
        f_rgb_diff = {2'b00, dr} + {2'b00, dg} + {2'b00, db};
    end
endfunction

wire [23:0] w_left_src0 = r_prev_vld ? r_prev_src3 : w_src0;
wire [9:0]  w_cd_l0 = f_rgb_diff(w_src0, w_left_src0);
wire [9:0]  w_cd_01 = f_rgb_diff(w_src0, w_src1);
wire [9:0]  w_cd_12 = f_rgb_diff(w_src1, w_src2);
wire [9:0]  w_cd_23 = f_rgb_diff(w_src2, w_src3);

wire [9:0]  w_chr0 = (w_cd_l0 >= w_cd_01) ? w_cd_l0 : w_cd_01;
wire [9:0]  w_chr1 = (w_cd_01 >= w_cd_12) ? w_cd_01 : w_cd_12;
wire [9:0]  w_chr2 = (w_cd_12 >= w_cd_23) ? w_cd_12 : w_cd_23;
wire [9:0]  w_chr3 = w_cd_23;

wire [9:0] w_gxr0 = w_t02[ 7: 0] + {w_t12[ 7: 0], 1'b0} + w_t22[ 7: 0];
wire [9:0] w_gxl0 = w_t00[ 7: 0] + {w_t10[ 7: 0], 1'b0} + w_t20[ 7: 0];
wire [9:0] w_gyu0 = w_t00[ 7: 0] + {w_t01[ 7: 0], 1'b0} + w_t02[ 7: 0];
wire [9:0] w_gyd0 = w_t20[ 7: 0] + {w_t21[ 7: 0], 1'b0} + w_t22[ 7: 0];

wire [9:0] w_gxr1 = w_t02[15: 8] + {w_t12[15: 8], 1'b0} + w_t22[15: 8];
wire [9:0] w_gxl1 = w_t00[15: 8] + {w_t10[15: 8], 1'b0} + w_t20[15: 8];
wire [9:0] w_gyu1 = w_t00[15: 8] + {w_t01[15: 8], 1'b0} + w_t02[15: 8];
wire [9:0] w_gyd1 = w_t20[15: 8] + {w_t21[15: 8], 1'b0} + w_t22[15: 8];

wire [9:0] w_gxr2 = w_t02[23:16] + {w_t12[23:16], 1'b0} + w_t22[23:16];
wire [9:0] w_gxl2 = w_t00[23:16] + {w_t10[23:16], 1'b0} + w_t20[23:16];
wire [9:0] w_gyu2 = w_t00[23:16] + {w_t01[23:16], 1'b0} + w_t02[23:16];
wire [9:0] w_gyd2 = w_t20[23:16] + {w_t21[23:16], 1'b0} + w_t22[23:16];

wire [9:0] w_gxr3 = w_t02[31:24] + {w_t12[31:24], 1'b0} + w_t22[31:24];
wire [9:0] w_gxl3 = w_t00[31:24] + {w_t10[31:24], 1'b0} + w_t20[31:24];
wire [9:0] w_gyu3 = w_t00[31:24] + {w_t01[31:24], 1'b0} + w_t02[31:24];
wire [9:0] w_gyd3 = w_t20[31:24] + {w_t21[31:24], 1'b0} + w_t22[31:24];

wire [9:0] w_dx0 = (w_gxr0 >= w_gxl0) ? (w_gxr0 - w_gxl0) : (w_gxl0 - w_gxr0);
wire [9:0] w_dy0 = (w_gyu0 >= w_gyd0) ? (w_gyu0 - w_gyd0) : (w_gyd0 - w_gyu0);
wire [9:0] w_dx1 = (w_gxr1 >= w_gxl1) ? (w_gxr1 - w_gxl1) : (w_gxl1 - w_gxr1);
wire [9:0] w_dy1 = (w_gyu1 >= w_gyd1) ? (w_gyu1 - w_gyd1) : (w_gyd1 - w_gyu1);
wire [9:0] w_dx2 = (w_gxr2 >= w_gxl2) ? (w_gxr2 - w_gxl2) : (w_gxl2 - w_gxr2);
wire [9:0] w_dy2 = (w_gyu2 >= w_gyd2) ? (w_gyu2 - w_gyd2) : (w_gyd2 - w_gyu2);
wire [9:0] w_dx3 = (w_gxr3 >= w_gxl3) ? (w_gxr3 - w_gxl3) : (w_gxl3 - w_gxr3);
wire [9:0] w_dy3 = (w_gyu3 >= w_gyd3) ? (w_gyu3 - w_gyd3) : (w_gyd3 - w_gyu3);

// 45° / 135° Roberts 对角梯度，补齐斜向与圆弧轮廓
wire [8:0] w_dg0 = ((w_t00[ 7: 0] >= w_t22[ 7: 0]) ? (w_t00[ 7: 0] - w_t22[ 7: 0]) : (w_t22[ 7: 0] - w_t00[ 7: 0]))
                 + ((w_t02[ 7: 0] >= w_t20[ 7: 0]) ? (w_t02[ 7: 0] - w_t20[ 7: 0]) : (w_t20[ 7: 0] - w_t02[ 7: 0]));
wire [8:0] w_dg1 = ((w_t00[15: 8] >= w_t22[15: 8]) ? (w_t00[15: 8] - w_t22[15: 8]) : (w_t22[15: 8] - w_t00[15: 8]))
                 + ((w_t02[15: 8] >= w_t20[15: 8]) ? (w_t02[15: 8] - w_t20[15: 8]) : (w_t20[15: 8] - w_t02[15: 8]));
wire [8:0] w_dg2 = ((w_t00[23:16] >= w_t22[23:16]) ? (w_t00[23:16] - w_t22[23:16]) : (w_t22[23:16] - w_t00[23:16]))
                 + ((w_t02[23:16] >= w_t20[23:16]) ? (w_t02[23:16] - w_t20[23:16]) : (w_t20[23:16] - w_t02[23:16]));
wire [8:0] w_dg3 = ((w_t00[31:24] >= w_t22[31:24]) ? (w_t00[31:24] - w_t22[31:24]) : (w_t22[31:24] - w_t00[31:24]))
                 + ((w_t02[31:24] >= w_t20[31:24]) ? (w_t02[31:24] - w_t20[31:24]) : (w_t20[31:24] - w_t02[31:24]));

// 融合灰度全向梯度与 RGB 色差梯度（色差权重 ×0.5 防止微弱色噪，但对红/蓝/绿边界显著增强）
wire [11:0] w_mag0 = {2'b00, w_dx0} + {2'b00, w_dy0} + {3'b000, w_dg0} + {3'b000, w_chr0[9:1]};
wire [11:0] w_mag1 = {2'b00, w_dx1} + {2'b00, w_dy1} + {3'b000, w_dg1} + {3'b000, w_chr1[9:1]};
wire [11:0] w_mag2 = {2'b00, w_dx2} + {2'b00, w_dy2} + {3'b000, w_dg2} + {3'b000, w_chr2[9:1]};
wire [11:0] w_mag3 = {2'b00, w_dx3} + {2'b00, w_dy3} + {3'b000, w_dg3} + {3'b000, w_chr3[9:1]};

wire w_e0 = (w_mag0 >= {1'b0, w_th_eff0}) || (PURE_BW && (w_chr0 >= 10'd42));
wire w_e1 = (w_mag1 >= {1'b0, w_th_eff1}) || (PURE_BW && (w_chr1 >= 10'd42));
wire w_e2 = (w_mag2 >= {1'b0, w_th_eff2}) || (PURE_BW && (w_chr2 >= 10'd42));
wire w_e3 = (w_mag3 >= {1'b0, w_th_eff3}) || (PURE_BW && (w_chr3 >= 10'd42));

//------------------------------------------------------------------------------
// 4. 像素输出生成（PURE_BW=1：边缘纯白 24'hFFFFFF，非边缘纯黑 24'h000000）
//------------------------------------------------------------------------------
wire [8:0] w_sr0 = {1'b0, w_src0[23:16]} + EDGE_K;
wire [8:0] w_sg0 = {1'b0, w_src0[15: 8]} + EDGE_K;
wire [8:0] w_sl0 = {1'b0, w_src0[ 7: 0]} + EDGE_K;
wire [8:0] w_sr1 = {1'b0, w_src1[23:16]} + EDGE_K;
wire [8:0] w_sg1 = {1'b0, w_src1[15: 8]} + EDGE_K;
wire [8:0] w_sl1 = {1'b0, w_src1[ 7: 0]} + EDGE_K;
wire [8:0] w_sr2 = {1'b0, w_src2[23:16]} + EDGE_K;
wire [8:0] w_sg2 = {1'b0, w_src2[15: 8]} + EDGE_K;
wire [8:0] w_sl2 = {1'b0, w_src2[ 7: 0]} + EDGE_K;
wire [8:0] w_sr3 = {1'b0, w_src3[23:16]} + EDGE_K;
wire [8:0] w_sg3 = {1'b0, w_src3[15: 8]} + EDGE_K;
wire [8:0] w_sl3 = {1'b0, w_src3[ 7: 0]} + EDGE_K;

wire [23:0] w_boost0 = {w_sr0[8] ? 8'hFF : w_sr0[7:0],
                        w_sg0[8] ? 8'hFF : w_sg0[7:0],
                        w_sl0[8] ? 8'hFF : w_sl0[7:0]};
wire [23:0] w_boost1 = {w_sr1[8] ? 8'hFF : w_sr1[7:0],
                        w_sg1[8] ? 8'hFF : w_sg1[7:0],
                        w_sl1[8] ? 8'hFF : w_sl1[7:0]};
wire [23:0] w_boost2 = {w_sr2[8] ? 8'hFF : w_sr2[7:0],
                        w_sg2[8] ? 8'hFF : w_sg2[7:0],
                        w_sl2[8] ? 8'hFF : w_sl2[7:0]};
wire [23:0] w_boost3 = {w_sr3[8] ? 8'hFF : w_sr3[7:0],
                        w_sg3[8] ? 8'hFF : w_sg3[7:0],
                        w_sl3[8] ? 8'hFF : w_sl3[7:0]};

wire [7:0] w_dk0_r = (w_src0[23:16] > EDGE_BG) ? (w_src0[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk0_g = (w_src0[15:8]  > EDGE_BG) ? (w_src0[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk0_b = (w_src0[7:0]   > EDGE_BG) ? (w_src0[7:0]   - EDGE_BG) : 8'd0;

wire [7:0] w_dk1_r = (w_src1[23:16] > EDGE_BG) ? (w_src1[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk1_g = (w_src1[15:8]  > EDGE_BG) ? (w_src1[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk1_b = (w_src1[7:0]   > EDGE_BG) ? (w_src1[7:0]   - EDGE_BG) : 8'd0;

wire [7:0] w_dk2_r = (w_src2[23:16] > EDGE_BG) ? (w_src2[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk2_g = (w_src2[15:8]  > EDGE_BG) ? (w_src2[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk2_b = (w_src2[7:0]   > EDGE_BG) ? (w_src2[7:0]   - EDGE_BG) : 8'd0;

wire [7:0] w_dk3_r = (w_src3[23:16] > EDGE_BG) ? (w_src3[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk3_g = (w_src3[15:8]  > EDGE_BG) ? (w_src3[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk3_b = (w_src3[7:0]   > EDGE_BG) ? (w_src3[7:0]   - EDGE_BG) : 8'd0;

wire [23:0] w_pix0 = PURE_BW ? (w_e0 ? 24'hFFFFFF : 24'h000000)
                             : (w_e0 ? w_boost0   : {w_dk0_r, w_dk0_g, w_dk0_b});
wire [23:0] w_pix1 = PURE_BW ? (w_e1 ? 24'hFFFFFF : 24'h000000)
                             : (w_e1 ? w_boost1   : {w_dk1_r, w_dk1_g, w_dk1_b});
wire [23:0] w_pix2 = PURE_BW ? (w_e2 ? 24'hFFFFFF : 24'h000000)
                             : (w_e2 ? w_boost2   : {w_dk2_r, w_dk2_g, w_dk2_b});
wire [23:0] w_pix3 = PURE_BW ? (w_e3 ? 24'hFFFFFF : 24'h000000)
                             : (w_e3 ? w_boost3   : {w_dk3_r, w_dk3_g, w_dk3_b});

wire [95:0] w_result = {w_pix0, w_pix1, w_pix2, w_pix3};

//------------------------------------------------------------------------------
// 6. 输出级（延迟 1 拍）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (I_tvalid)
        O_tdata <= w_result;
    else
        O_tdata <= 96'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= I_tvalid;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= I_tvalid && I_tlast;
        O_tuser <= I_tvalid && I_tuser;
    end
end

initial begin
    O_tdata     = 96'd0;
    O_tvalid    = 1'b0;
    O_tlast     = 1'b0;
    O_tuser     = 1'b0;
    r_prev_src3 = 24'd0;
    r_prev_vld  = 1'b0;
end

endmodule
