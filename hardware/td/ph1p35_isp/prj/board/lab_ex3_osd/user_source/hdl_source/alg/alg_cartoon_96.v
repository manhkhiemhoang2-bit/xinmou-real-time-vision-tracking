//==============================================================================
// 文件名  : alg_cartoon_96.v
// 功能    : M8 深度赛璐璐动漫渲染引擎（Cel-Shading + 2倍高饱和色彩 + 双层浓淡漫画墨线）
//
// 核心升级与根因修复：
//   1. 修复原版像素左右镜像错位 bug：
//      96-bit 总线约定 pix0（最左像素，对应窗口 k=0）在 [95:72]，pix3（最右，k=3）在 [23:0]；
//      原版将 I_tdata[95:72] 与 r_yc3/r_edge3 配对，导致每 4 像素内部墨线与底色左右颠倒锯齿！
//   2. 接入 3×3 平滑底座（由 alg_top 传入 w_m_dat）：
//      消除传感器颗粒感，且与 3×3 窗口中心行（y-1）在空间行号与 4 拍时序上 100% 严格对齐。
//   3. 赛璐璐（Cel-Shading）四段光影质感 + 2.0× 高饱和色彩提亮：
//      - 对每个像素先做 2.0 倍色度张力增强：c_vivid = clamp(Y + 2*(c - Y), 0, 255)；
//      - 按平滑亮度 Y 划分为【冷调动漫暗部影（Y<56，带蓝紫冷调偏移）】、【赛璐璐次暗面（56..111）】、
//        【主受光亮面（112..184，暖调提亮）】、【动漫高光反光带（Y>=185，高光泛白）】四段，
//        并结合平滑色阶量化，既保留自然肤色/景物色相，又呈现浓郁的日系动画赛璐璐平涂质感！
//   4. 双层浓淡漫画墨线（Multi-Weight Manga Ink）：
//      - 强边缘（|Gx|+|Gy|+diag >= EDGE_TH）：纯黑重墨勾线（24'h06040A）；
//      - 次强边缘（>= EDGE_TH*5/8）：深炭色半透明笔锋过渡（色块亮度压至 1/4），消除锯齿感。
//==============================================================================
`timescale 1ns / 1ps

module alg_cartoon_96 #(
    parameter integer EDGE_TH = 115      // 主墨线梯度阈值（大幅强化轮廓线条表现力）
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [287:0] I_window,        // 3×3 灰度窗口（3 拍域）
    input  wire         I_window_valid,
    input  wire [95:0]  I_tdata,         // 3×3 平滑后的 RGB888（4 拍域，行 y-1）
    output wire [95:0]  O_tdata          // 赛璐璐卡通化结果（4 拍域）
);

    localparam integer SOFT_TH = (EDGE_TH * 5) / 8;   // 次级笔锋描边阈值（约 72）

    //--------------------------------------------------------------------------
    // 1. 逐像素全向梯度强度（Sobel + 对角交叉）+ 3×3 平滑中心亮度（3 拍域）
    //--------------------------------------------------------------------------
    wire [11:0] w_edge [0:3];
    wire [7:0]  w_ycen [0:3];

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_sobel
            wire [7:0] w_tl = I_window[8*(4*(3*0+0)+k) +: 8];
            wire [7:0] w_tc = I_window[8*(4*(3*0+1)+k) +: 8];
            wire [7:0] w_tr = I_window[8*(4*(3*0+2)+k) +: 8];
            wire [7:0] w_ml = I_window[8*(4*(3*1+0)+k) +: 8];
            wire [7:0] w_mc = I_window[8*(4*(3*1+1)+k) +: 8];
            wire [7:0] w_mr = I_window[8*(4*(3*1+2)+k) +: 8];
            wire [7:0] w_bl = I_window[8*(4*(3*2+0)+k) +: 8];
            wire [7:0] w_bc = I_window[8*(4*(3*2+1)+k) +: 8];
            wire [7:0] w_br = I_window[8*(4*(3*2+2)+k) +: 8];

            wire [10:0] w_gx_p = {1'b0, w_tr} + {1'b0, w_mr, 1'b0} + {1'b0, w_br};
            wire [10:0] w_gx_n = {1'b0, w_tl} + {1'b0, w_ml, 1'b0} + {1'b0, w_bl};
            wire [10:0] w_gy_p = {1'b0, w_bl} + {1'b0, w_bc, 1'b0} + {1'b0, w_br};
            wire [10:0] w_gy_n = {1'b0, w_tl} + {1'b0, w_tc, 1'b0} + {1'b0, w_tr};

            wire [10:0] w_dx = (w_gx_p >= w_gx_n) ? (w_gx_p - w_gx_n) : (w_gx_n - w_gx_p);
            wire [10:0] w_dy = (w_gy_p >= w_gy_n) ? (w_gy_p - w_gy_n) : (w_gy_n - w_gy_p);

            wire [8:0]  w_d1 = (w_tl >= w_br) ? (w_tl - w_br) : (w_br - w_tl);
            wire [8:0]  w_d2 = (w_tr >= w_bl) ? (w_tr - w_bl) : (w_bl - w_tr);

            // 3×3 加权平滑亮度：(4*mc + tc + bc + ml + mr) >> 3，使色阶分界线如丝般顺滑
            wire [10:0] w_ysum = ({1'b0, w_mc, 2'b00}) + {3'b0, w_tc} + {3'b0, w_bc}
                               + {3'b0, w_ml} + {3'b0, w_mr} + 11'd4;

            assign w_edge[k] = {1'b0, w_dx} + {1'b0, w_dy} + {3'b0, w_d1} + {3'b0, w_d2};
            assign w_ycen[k] = w_ysum[10:3];
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 2. 边缘强度与平滑亮度打 1 拍：3 拍窗 → 4 拍（与 I_tdata 严格同拍对齐）
    //--------------------------------------------------------------------------
    reg [11:0] r_edge [0:3];
    reg [7:0]  r_yc   [0:3];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_edge[0] <= 12'd0; r_edge[1] <= 12'd0; r_edge[2] <= 12'd0; r_edge[3] <= 12'd0;
            r_yc[0]   <= 8'd0;  r_yc[1]   <= 8'd0;  r_yc[2]   <= 8'd0;  r_yc[3]   <= 8'd0;
        end else begin
            r_edge[0] <= w_edge[0]; r_edge[1] <= w_edge[1];
            r_edge[2] <= w_edge[2]; r_edge[3] <= w_edge[3];
            r_yc[0]   <= w_ycen[0]; r_yc[1]   <= w_ycen[1];
            r_yc[2]   <= w_ycen[2]; r_yc[3]   <= w_ycen[3];
        end
    end

    //--------------------------------------------------------------------------
    // 3. 4 像素并行赛璐璐（Cel-Shading）色彩重塑 + 双层浓淡漫画墨线合成
    //    ⚠ 严格遵守位序：k=0 对应 [95:72]，k=1 对应 [71:48]，k=2 对应 [47:24]，k=3 对应 [23:0]
    //--------------------------------------------------------------------------
    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : g_cel
            wire [23:0] w_rgb = I_tdata[24*(3-p) +: 24];
            wire [7:0]  w_r   = w_rgb[23:16];
            wire [7:0]  w_g   = w_rgb[15:8];
            wire [7:0]  w_b   = w_rgb[7:0];
            wire [7:0]  w_y   = r_yc[p];
            wire [11:0] w_e   = r_edge[p];

            // Step A: 2.0 倍高饱和色度拉伸：c_sat = clamp(Y + 2*(c - Y), 0, 255)
            //         等价于 c_sat = clamp(2*c - Y, 0, 255)
            wire signed [10:0] w_sr = $signed({2'b00, w_r, 1'b0}) - $signed({3'b000, w_y});
            wire signed [10:0] w_sg = $signed({2'b00, w_g, 1'b0}) - $signed({3'b000, w_y});
            wire signed [10:0] w_sb = $signed({2'b00, w_b, 1'b0}) - $signed({3'b000, w_y});

            wire [7:0] w_vr = (w_sr < 11'sd0) ? 8'd0 : ((w_sr > 11'sd255) ? 8'd255 : w_sr[7:0]);
            wire [7:0] w_vg = (w_sg < 11'sd0) ? 8'd0 : ((w_sg > 11'sd255) ? 8'd255 : w_sg[7:0]);
            wire [7:0] w_vb = (w_sb < 11'sd0) ? 8'd0 : ((w_sb > 11'sd255) ? 8'd255 : w_sb[7:0]);

            // Step B: 8 级丝滑色阶量化（取高 3 bit 并填入明快动漫偏置）
            wire [7:0] w_qr = {w_vr[7:5], w_vr[7:5], 2'b10};
            wire [7:0] w_qg = {w_vg[7:5], w_vg[7:5], 2'b10};
            wire [7:0] w_qb = {w_vb[7:5], w_vb[7:5], 2'b10};

            // Step C: 四段赛璐璐光影分层（Shadow / Midtone / Lit / Specular Highlight）
            //   - 暗部影（Y < 56）：压暗至 50% 并注入日系动漫标志性的冷蓝紫环境光 (+20 B)
            wire [7:0] w_sh_r = (w_qr >> 1);
            wire [7:0] w_sh_g = (w_qg >> 1) + 8'd4;
            wire [7:0] w_sh_b = (w_qb >> 1) + ((w_qb < 8'd210) ? 8'd22 : 8'd8);

            //   - 次暗面（56 <= Y < 112）：平涂 75% 浓郁色块
            wire [7:0] w_md_r = (w_qr >> 1) + (w_qr >> 2);
            wire [7:0] w_md_g = (w_qg >> 1) + (w_qg >> 2);
            wire [7:0] w_md_b = (w_qb >> 1) + (w_qb >> 2);

            //   - 主受光面（112 <= Y < 185）：通透亮丽平涂 (+14 暖调提亮)
            wire [8:0] w_lt_r9 = {1'b0, w_qr} + 9'd16;
            wire [8:0] w_lt_g9 = {1'b0, w_qg} + 9'd14;
            wire [8:0] w_lt_b9 = {1'b0, w_qb} + 9'd10;
            wire [7:0] w_lt_r  = w_lt_r9[8] ? 8'hFF : w_lt_r9[7:0];
            wire [7:0] w_lt_g  = w_lt_g9[8] ? 8'hFF : w_lt_g9[7:0];
            wire [7:0] w_lt_b  = w_lt_b9[8] ? 8'hFF : w_lt_b9[7:0];

            //   - 赛璐璐高光带（Y >= 185）：强烈动漫高光提亮 (+48)
            wire [8:0] w_hi_r9 = {1'b0, w_qr} + 9'd48;
            wire [8:0] w_hi_g9 = {1'b0, w_qg} + 9'd48;
            wire [8:0] w_hi_b9 = {1'b0, w_qb} + 9'd44;
            wire [7:0] w_hi_r  = w_hi_r9[8] ? 8'hFF : w_hi_r9[7:0];
            wire [7:0] w_hi_g  = w_hi_g9[8] ? 8'hFF : w_hi_g9[7:0];
            wire [7:0] w_hi_b  = w_hi_b9[8] ? 8'hFF : w_hi_b9[7:0];

            wire [23:0] w_cel_rgb = (w_y < 8'd56)  ? {w_sh_r, w_sh_g, w_sh_b} :
                                    (w_y < 8'd112) ? {w_md_r, w_md_g, w_md_b} :
                                    (w_y < 8'd185) ? {w_lt_r, w_lt_g, w_lt_b} :
                                                     {w_hi_r, w_hi_g, w_hi_b};

            // Step D: 双层浓淡漫画墨线（强边缘重墨勾线 + 次强边缘深炭笔锋抗锯齿过渡）
            wire        w_ink_hard = (w_e >= EDGE_TH);
            wire        w_ink_soft = (w_e >= SOFT_TH);
            wire [23:0] w_soft_rgb = { (w_cel_rgb[23:16] >> 2),
                                       (w_cel_rgb[15:8]  >> 2),
                                       (w_cel_rgb[7:0]   >> 2) };

            assign O_tdata[24*(3-p) +: 24] = w_ink_hard ? 24'h06040A :
                                             (w_ink_soft ? w_soft_rgb : w_cel_rgb);
        end
    endgenerate

endmodule
