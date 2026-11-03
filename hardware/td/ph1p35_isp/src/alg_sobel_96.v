//==============================================================================
// 文件名   : alg_sobel_96.v
// 模块名   : alg_sobel_96
// 日期     : 2026-09-14
// 版本     : v1.0
// 描述     : 96-bit 算法通道 · M3 Sobel 边缘增强（3x3 窗口算子）
//
//  ---------------------------------------------------------------------------
//  【一、算法：以金标准 alg_ref.py 为准】
//  ---------------------------------------------------------------------------
//  帧级金标准 alg_ref.py:642-649 / 逐拍模型 beat_ref.py:418-425：
//      gx   = -a00 + a02 - 2*a10 + 2*a12 - a20 + a22      （alg_ref.py:427）
//      gy   =  a00 + 2*a01 + a02 - a20 - 2*a21 - a22      （alg_ref.py:428）
//      mag  = |gx| + |gy|                                 （L1 近似，最大 1020）
//      S    = 窗口 9 点灰度和
//      TH   = clamp( (S*57)>>9 + C_off, 0, 255 )          （local_mean）
//      edge = (mag >= TH * 4)                             （alg_ref.py:647，EDGE_TH_SCALE=4）
//      src  = **窗口中心像素的 RGB**（= 窗口中心行 y-1，不是输出行 y）
//      out  = edge ? sat8(src + K) : src                  （alg_ref.py:649）
//
//  ⚠ 三个必须写明的点（详见验证报告 §3）：
//   (1) 阈值要乘 4。冻结文档 §2 只写了"自适应阈值同 M2"和 `mag >= th`，
//       没写量纲换算；金标准 alg_ref.py:106-107 明确 `EDGE_TH_SCALE = 4`
//       （"灰度阈值 → |Gx|+|Gy| 量纲"）并在 :647 使用。本模块照金标准乘 4。
//       不乘 4 的话阈值最大只有 255、而 mag 最大 1020，边缘会大面积误触发。
//   (2) `src` 取窗口中心行（r=1，= 第 y-1 行）的 RGB，不是底行（第 y 行）。
//       见 beat_ref.py:326-332 与 :403-410（那里专门修过一次这个错行），
//       以及 S1_RTL_README.md §8 第 (2) 条：M3 的提亮源必须走**原始 RGB 通路**,
//       3x3 窗口固有的一行延迟同时作用在窗口与源像素上。
//   (3) `|gx|` 的位宽：gx ∈ [-1020, 1020]，12 bit 二补数装得下，所以
//       alg_ref.sign_magnitude_13bit 的 13 bit 掩码不发生截断，等价于数学绝对值。
//       本模块不写有符号运算，改用"正项和 - 负项和取绝对差"（数学等价、无符号、
//       跨工具移植无歧义）。
//
//  ---------------------------------------------------------------------------
//  【二、I_rgb_center 的位序（冻结文档 §2，2026-09-14 更正为 [95:0]）】
//  ---------------------------------------------------------------------------
//  96 bit = 4 中心像素 × RGB888，就是**图像第 y-1 行、列 4x+0..4x+3** 的 RGB，
//  直接接 `rgb_row_delay_96` 的 96 位输出，无需扩展。位序同 I_tdata（S0-02 §2.1）：
//      I_rgb_center[24*(3-k) +: 24] = 第 k 个中心像素的 {R[23:16], G[15:8], B[7:0]}
//      k=0（列 4x+0，最左）→ [95:72]；k=3（列 4x+3，最右）→ [23:0]
//  ⇒ src_k = I_rgb_center[24*(3-k) +: 24]，即 k=0→[95:72] … k=3→[23:0]。
//  ⚠ 端口宽度 2026-09-14 由 287:0 更正为 95:0（原宽度是从 I_window 那行复制时忘改）；
//    同时删掉了当时为兼容错误宽度而留的 RGB_CTR_LSB 参数。
//
//  ---------------------------------------------------------------------------
//  【三、延迟】全部输出相对输入**延迟 1 拍**，5 路同拍（同 alg_binarize_96 §二）
//  【四、屏蔽】本模块不做，由 alg_top 用 I_window_valid 统一做（同 §三 铁律 2）
//  【五、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/
//  force/#delay；组合全 assign/wire ⇒ 无 latch；一个 always 只干一件事。
//==============================================================================

module alg_sobel_96 #(
    parameter integer C_OFF       = 0,      // 阈值偏置；金标准默认 0（-64..+64，步长 8）
    parameter integer TH_MIN      = 0,      // 阈值下限钳位（local_mean th_min）
    parameter integer TH_MAX      = 255,    // 阈值上限钳位（local_mean th_max，须 <= 255）
    parameter [8:0]   EDGE_K      = 9'd128,     // 提亮增量 K；金标准 EDGE_K_DEFAULT = 128（{0,64,128,192}）
    parameter [9:0]   TH_SCALE    = 10'd4,      // ★五修：阈值倍率（金标准 4；板级 2=暗场景多检出）
    parameter [7:0]   EDGE_BG     = 8'd0        // ★十修：非边缘背景下压量（默认0=原图；板级80）
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    // ---- 来自 win3x3_96（同一拍，延迟对齐）----
    input  wire         I_window_valid,   // 窗口是否可信（本模块不用，见 §四）
    input  wire [287:0] I_window,         // 4 中心像素 × 3x3 × 8bit（索引见冻结文档 §3）
    input  wire [95:0]  I_gray_src,       // 灰度已打拍的原图（本档不用）
    input  wire [95:0]  I_rgb_center,     // 4 中心像素的 RGB888 = 图像第 y-1 行（位序见 §二）
    // ---- 控制透传（与上面同拍）----
    input  wire         I_tvalid,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire         I_tready,
    // ---- 输出：纯算法结果，不做屏蔽 ----
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

assign O_tready = I_tready;

//------------------------------------------------------------------------------
// 0. 编译期常量（C_OFF 的符号/幅值拆分理由同 alg_binarize_96 §0）
//------------------------------------------------------------------------------
localparam        COFF_NEG = (C_OFF < 0) ? 1'b1 : 1'b0;
localparam [7:0]  COFF_MAG = (C_OFF < 0) ? (-C_OFF) : C_OFF;
localparam [8:0]  TH_LO    = TH_MIN[8:0];
localparam [8:0]  TH_HI    = TH_MAX[8:0];

//------------------------------------------------------------------------------
// 1. 窗口抽头：w_tRC[8*k +: 8] = 第 k 个中心像素在 (r,c) 处的灰度
//------------------------------------------------------------------------------
wire [31:0] w_t00 = I_window[ 31:  0];   // r=0 c=0  左上（列 4x+k-1）
wire [31:0] w_t01 = I_window[ 63: 32];   // r=0 c=1  正上
wire [31:0] w_t02 = I_window[ 95: 64];   // r=0 c=2  右上
wire [31:0] w_t10 = I_window[127: 96];   // r=1 c=0  左
wire [31:0] w_t11 = I_window[159:128];   // r=1 c=1  中心灰度
wire [31:0] w_t12 = I_window[191:160];   // r=1 c=2  右
wire [31:0] w_t20 = I_window[223:192];   // r=2 c=0  左下
wire [31:0] w_t21 = I_window[255:224];   // r=2 c=1  正下
wire [31:0] w_t22 = I_window[287:256];   // r=2 c=2  右下

//------------------------------------------------------------------------------
// 2. 阈值：S → m=(S*57)>>9 → TH=clamp(m+C_off, TH_MIN, TH_MAX) → th=TH*4
//    与 alg_binarize_96 §2/§3/§4 同构（同一套金标准 local_mean），只是末尾乘 4。
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

// 57 = 32+16+8+1 ⇒ 常数移位加法，零 DSP；最大 2295*57 = 130815 < 2^17
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

// th = TH * TH_SCALE（金标准 4 ⇒ 与旧 {,2'b00} 逐位一致）：<= 1020，10 bit
wire [9:0] w_th0 = w_thm0 * TH_SCALE;
wire [9:0] w_th1 = w_thm1 * TH_SCALE;
wire [9:0] w_th2 = w_thm2 * TH_SCALE;
wire [9:0] w_th3 = w_thm3 * TH_SCALE;

//------------------------------------------------------------------------------
// 3. Sobel 幅值：mag = |gx| + |gy|
//    gx = (a02 + 2a12 + a22) - (a00 + 2a10 + a20)     右列和 - 左列和
//    gy = (a00 + 2a01 + a02) - (a20 + 2a21 + a22)     上行和 - 下行和
//    每个括号 <= 4*255 = 1020（10 bit），差取绝对 <= 1020，mag <= 2040（11 bit）
//------------------------------------------------------------------------------
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

wire [10:0] w_mag0 = ((w_gxr0 >= w_gxl0) ? (w_gxr0 - w_gxl0) : (w_gxl0 - w_gxr0))
                   + ((w_gyu0 >= w_gyd0) ? (w_gyu0 - w_gyd0) : (w_gyd0 - w_gyu0));
wire [10:0] w_mag1 = ((w_gxr1 >= w_gxl1) ? (w_gxr1 - w_gxl1) : (w_gxl1 - w_gxr1))
                   + ((w_gyu1 >= w_gyd1) ? (w_gyu1 - w_gyd1) : (w_gyd1 - w_gyu1));
wire [10:0] w_mag2 = ((w_gxr2 >= w_gxl2) ? (w_gxr2 - w_gxl2) : (w_gxl2 - w_gxr2))
                   + ((w_gyu2 >= w_gyd2) ? (w_gyu2 - w_gyd2) : (w_gyd2 - w_gyu2));
wire [10:0] w_mag3 = ((w_gxr3 >= w_gxl3) ? (w_gxr3 - w_gxl3) : (w_gxl3 - w_gxr3))
                   + ((w_gyu3 >= w_gyd3) ? (w_gyu3 - w_gyd3) : (w_gyd3 - w_gyu3));

// edge = (mag >= TH*4)：mag 11 bit、th 抬成 11 bit 再比（alg_ref.py:647 是 >=，不是 >）
wire w_e0 = (w_mag0 >= {1'b0, w_th0});
wire w_e1 = (w_mag1 >= {1'b0, w_th1});
wire w_e2 = (w_mag2 >= {1'b0, w_th2});
wire w_e3 = (w_mag3 >= {1'b0, w_th3});

//------------------------------------------------------------------------------
// 4. 提亮源 src：图像第 y-1 行（= 窗口中心行）第 k 个中心像素的 RGB888
//    位序同 I_tdata：pix0（列 4x+0）在 [95:72]，pix3（列 4x+3）在 [23:0]（§二）
//------------------------------------------------------------------------------
wire [23:0] w_src0 = I_rgb_center[24*3 +: 24];   // k=0，列 4x+0，在 [95:72]
wire [23:0] w_src1 = I_rgb_center[24*2 +: 24];   // k=1
wire [23:0] w_src2 = I_rgb_center[24*1 +: 24];   // k=2
wire [23:0] w_src3 = I_rgb_center[24*0 +: 24];   // k=3，列 4x+3，在 [23:0]

//------------------------------------------------------------------------------
// 5. out = edge ? sat8(src + K) : src
//    K <= 192、src <= 255 ⇒ 和 <= 447 < 2^9，只需上饱和（金标准 sat8）
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

// ★十修：非边缘三通道各下压 EDGE_BG（饱和减）——背景暗下去，提亮的边缘才跳得出来
wire [7:0] w_dk0_r = (w_src0[23:16] > EDGE_BG) ? (w_src0[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk0_g = (w_src0[15:8]  > EDGE_BG) ? (w_src0[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk0_b = (w_src0[7:0]   > EDGE_BG) ? (w_src0[7:0]   - EDGE_BG) : 8'd0;
wire [23:0] w_pix0 = w_e0 ? w_boost0 : {w_dk0_r, w_dk0_g, w_dk0_b};
// ★十修：非边缘三通道各下压 EDGE_BG（饱和减）——背景暗下去，提亮的边缘才跳得出来
wire [7:0] w_dk1_r = (w_src1[23:16] > EDGE_BG) ? (w_src1[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk1_g = (w_src1[15:8]  > EDGE_BG) ? (w_src1[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk1_b = (w_src1[7:0]   > EDGE_BG) ? (w_src1[7:0]   - EDGE_BG) : 8'd0;
wire [23:0] w_pix1 = w_e1 ? w_boost1 : {w_dk1_r, w_dk1_g, w_dk1_b};
// ★十修：非边缘三通道各下压 EDGE_BG（饱和减）——背景暗下去，提亮的边缘才跳得出来
wire [7:0] w_dk2_r = (w_src2[23:16] > EDGE_BG) ? (w_src2[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk2_g = (w_src2[15:8]  > EDGE_BG) ? (w_src2[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk2_b = (w_src2[7:0]   > EDGE_BG) ? (w_src2[7:0]   - EDGE_BG) : 8'd0;
wire [23:0] w_pix2 = w_e2 ? w_boost2 : {w_dk2_r, w_dk2_g, w_dk2_b};
// ★十修：非边缘三通道各下压 EDGE_BG（饱和减）——背景暗下去，提亮的边缘才跳得出来
wire [7:0] w_dk3_r = (w_src3[23:16] > EDGE_BG) ? (w_src3[23:16] - EDGE_BG) : 8'd0;
wire [7:0] w_dk3_g = (w_src3[15:8]  > EDGE_BG) ? (w_src3[15:8]  - EDGE_BG) : 8'd0;
wire [7:0] w_dk3_b = (w_src3[7:0]   > EDGE_BG) ? (w_src3[7:0]   - EDGE_BG) : 8'd0;
wire [23:0] w_pix3 = w_e3 ? w_boost3 : {w_dk3_r, w_dk3_g, w_dk3_b};

// ⚠ 像素顺序同 alg_binarize_96：S0-02 §2.1 规定 pix0 = [95:72] 是行内最左像素，
//    而窗口 byte k 对应列 4x+k（k 越大越靠右）⇒ k=0 必须放最高位。
wire [95:0] w_result = {w_pix0, w_pix1, w_pix2, w_pix3};

//------------------------------------------------------------------------------
// 6. 输出级：5 路同一个时钟沿装载 ⇒ 延迟 1 拍、彼此严格同拍
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (I_tvalid)
        O_tdata <= w_result;
    else
        O_tdata <= 96'd0;          // C-4
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

//------------------------------------------------------------------------------
// 7. 上电初值（仿真友好；与复位分支逐一相同）
//------------------------------------------------------------------------------
initial begin
    O_tdata  = 96'd0;
    O_tvalid = 1'b0;
    O_tlast  = 1'b0;
    O_tuser  = 1'b0;
end

endmodule
