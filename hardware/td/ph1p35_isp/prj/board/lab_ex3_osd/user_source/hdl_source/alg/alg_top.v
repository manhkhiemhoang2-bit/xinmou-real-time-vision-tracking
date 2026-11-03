//==============================================================================
// 文件名   : alg_top.v
// 模块名   : alg_top
// 描述     : 96-bit 算法通道 · M0~M8，M7 智能聚色（2026-10-29 晚 R5 版）/ M8 赛璐璐动漫
//
// 当前版本要点（2026-10-30 合入专家优化后，M7 已回退 R5 版）：
//   1. M7（智能聚色，MODE_FOCUS）：**已回退到 2026-10-29 晚上 R5 版**——检测框内且命中掩码的像素
//      保留原 RGB，其余像素转灰阶铅笔素描（亮度底 + 深色边缘线）；不使用 color_delta ROM。
//      M7 下 u_det 使用 SW1 当前档位模式（不再强制多色识别）。
//   2. 资源利用率优化：
//      · 移除原 M7 的 6 个 64K×1bit ROM（color_delta_rom_2p），直接释放 24 块 ERAM20K
//        （占全芯片 ERAM 的 22.2%），且不再依赖外部 color_delta_ge12.hex；
//      · 复用 r_m0_dat[0:2] 与 r_m0_ctl[0:2] 驱动 u_rowdly，消除冗余的 r_rgb3_dat/ctl（省 297 FF）；
//      · 将 M1 灰度延迟链 r_m1_dat[0:2] 从 3×96 bit 压缩为 3×32 bit 单通道灰度延迟（省 192 FF）。
//==============================================================================

module alg_top #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter [23:0] TGT_COLOR = 24'hFF0000,
    parameter [7:0]  TGT_TOL   = 8'd40,
    parameter [7:0]  M6_DIFF_TH = 8'd24,
    parameter        DOM_MODE   = 1'b0,
    parameter [7:0]  DOM_MIN    = 8'd80,
    parameter [7:0]  DOM_MARGIN = 8'd30,
    parameter [23:0] BBOX_COLOR = 24'hFFFFFF,
    parameter [7:0]  SAT_TH     = 8'd40,
    parameter        REL_MODE      = 1'b0,
    parameter [7:0]  REL_ABS_MIN   = 8'd12,
    parameter [7:0]  REL_SAT_MIN   = 8'd12,
    parameter [7:0]  REL_MARGIN    = 8'd4,
    parameter        RL_EN         = 1'b0,
    parameter [10:0] RL_MIN_RUN    = 11'd32,
    parameter [7:0]  RL_GAP_MAX    = 8'd2,
    parameter [15:0] RL_MIN_ROWS   = 16'd6,
    parameter [7:0]  SAT_MIN    = 8'd0,
    parameter [8:0]  COLOR_GAP  = 9'd255,
    parameter        RED_B_RATIO = 1'b1,
    parameter [31:0] MIN_PIX     = 32'd0,
    parameter [7:0]  Y_MARGIN   = 8'd40,
    parameter        M6_NORM    = 1'b0,
    parameter integer C_OFF    = 0,
    parameter [8:0]   EDGE_K   = 9'd128,
    parameter [7:0]   RF_TH    = 8'd128,
    parameter integer TH_SCALE = 3,
    parameter         AUTO_Y   = 1'b1,
    parameter [7:0]   SAT_TH_B = SAT_TH,
    parameter [7:0]   DOM_MIN_B= DOM_MIN,
    parameter [7:0]   GREEN_M  = 8'd0,
    parameter [31:0]  FAM_MIN  = 32'd1,
    parameter [7:0]   EDGE_BG  = 8'd0,
    parameter         SMOOTH_BOX = 1'b0,
    parameter         BIN_GLOBAL = 1'b0,
    parameter [7:0]   SAT_TH_G   = SAT_TH,
    parameter [7:0]   SAT_TH_R   = SAT_TH,
    parameter [7:0]   DOM_MIN_R  = DOM_MIN,
    parameter [7:0]   DOM_MIN_G  = DOM_MIN,
    parameter         PURE_BW    = 1'b1,
    parameter         MORPH_FILL = 1'b1,
    parameter integer KEY_DIV  = 50000
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tready,
    input  wire         I_key,
    input  wire         I_mode_set,
    input  wire [3:0]   I_mode_sel,
    input  wire [1:0]   I_color_mode,
    output wire [3:0]   O_mode,
    output wire [31:0]  O_pix_count,
    input  wire         I_roi_en,
    input  wire [10:0]  I_roi_x0,
    input  wire [10:0]  I_roi_x1,
    input  wire [10:0]  I_roi_y0,
    input  wire [10:0]  I_roi_y1,
    output wire [10:0]  O_bbox_x0,
    output wire [10:0]  O_bbox_x1,
    output wire [10:0]  O_bbox_y0,
    output wire [10:0]  O_bbox_y1,
    output wire         O_bbox_valid,
    output wire [1:0]   O_color_class,
    output wire [7:0]   O_track_id,
    output wire [2:0]   O_fam_valid,
    output wire [32:0]  O_fam_cx,
    output wire [32:0]  O_fam_cy,
    output reg          O_tlast,
    output reg          O_tuser,
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output wire         O_tready
);

    wire [95:0] w_clean_dat;
    wire w_clean_val, w_clean_lst, w_clean_usr;
    rgb_denoise_96 u_denoise(
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_tdata(I_tdata),
        .I_tvalid(I_tvalid), .I_tlast(I_tlast), .I_tuser(I_tuser),
        .O_tdata(w_clean_dat), .O_tvalid(w_clean_val),
        .O_tlast(w_clean_lst), .O_tuser(w_clean_usr));

    assign O_tready = I_tready;

    localparam [3:0] MODE_RAW        = 4'd0;
    localparam [3:0] MODE_GRAY       = 4'd1;
    localparam [3:0] MODE_BIN        = 4'd2;
    localparam [3:0] MODE_EDGE       = 4'd3;
    localparam [3:0] MODE_SMOOTH     = 4'd4;
    localparam [3:0] MODE_TARGET     = 4'd5;
    localparam [3:0] MODE_MOTION     = 4'd6;
    localparam [3:0] MODE_FOCUS      = 4'd7;
    localparam [3:0] MODE_ANIM       = 4'd8;

    localparam [15:0] KEY_TOP = KEY_DIV[15:0] - 16'd1;

    localparam M6_BPL  = IMG_WIDTH >> 2;
    localparam M6_XW   = $clog2(M6_BPL);
    localparam [M6_XW-1:0] M6_LAST_BEAT = M6_BPL - 1;
    localparam [10:0]      M6_LAST_ROW  = IMG_HEIGHT - 1;

    integer i;
    reg [3:0] r_mode;

//------------------------------------------------------------------------------
// 1. u_gray：原始彩色 → 灰度（+1 拍）
//------------------------------------------------------------------------------
    wire [95:0] w_g_dat;
    wire        w_g_val, w_g_lst, w_g_usr;

    gray_bt601_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_gray (
        .I_clk    (I_clk),       .I_rst_n  (I_rst_n),
        .I_tlast  (w_clean_lst), .I_tuser  (w_clean_usr), .I_tdata (w_clean_dat),
        .I_tvalid (w_clean_val), .I_tready (I_tready),
        .O_tlast  (w_g_lst),     .O_tuser  (w_g_usr),     .O_tdata (w_g_dat),
        .O_tvalid (w_g_val),     .O_tready ()
    );

//------------------------------------------------------------------------------
// 2. u_win：灰度 → 3x3 窗口（再 +2 拍，累计 +3）
//------------------------------------------------------------------------------
    wire [287:0] w_window;
    wire         w_wvalid;
    wire [95:0]  w_w_dat;
    wire         w_w_val, w_w_lst, w_w_usr;

    win3x3_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_win (
        .I_clk          (I_clk),    .I_rst_n  (I_rst_n),
        .I_tlast        (w_g_lst),  .I_tuser  (w_g_usr), .I_tdata (w_g_dat),
        .I_tvalid       (w_g_val),  .I_tready (I_tready),
        .O_tlast        (w_w_lst),  .O_tuser  (w_w_usr), .O_tdata (w_w_dat),
        .O_tvalid       (w_w_val),  .O_tready (),
        .O_window       (w_window), .O_window_valid (w_wvalid)
    );

//------------------------------------------------------------------------------
// 3. 共享 4 拍彩色延迟链 r_m0_dat[0:3] + 行延迟 u_rowdly（省去重复的 r_rgb3_dat[0:2]）
//------------------------------------------------------------------------------
    reg [95:0] r_m0_dat [0:3];
    reg  [2:0] r_m0_ctl [0:3];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                r_m0_dat[i] <= 96'd0;
                r_m0_ctl[i] <= 3'd0;
            end
        end else begin
            r_m0_dat[0] <= w_clean_dat;
            r_m0_ctl[0] <= {w_clean_val, w_clean_lst, w_clean_usr};
            for (i = 1; i < 4; i = i + 1) begin
                r_m0_dat[i] <= r_m0_dat[i-1];
                r_m0_ctl[i] <= r_m0_ctl[i-1];
            end
        end
    end

    wire [95:0] w_a0_dat = r_m0_dat[3];
    wire [2:0]  w_a0_ctl = r_m0_ctl[3];

    wire [95:0] w_c_rgb;

    rgb_row_delay_96 #(
        .IMG_WIDTH (IMG_WIDTH)
    ) u_rowdly (
        .I_clk    (I_clk),            .I_rst_n  (I_rst_n),
        .I_tlast  (r_m0_ctl[2][1]),   .I_tuser  (r_m0_ctl[2][0]),
        .I_tdata  (r_m0_dat[2]),
        .I_tvalid (r_m0_ctl[2][2]),   .I_tready (I_tready),
        .O_tlast  (),                 .O_tuser  (), .O_tdata (w_c_rgb),
        .O_tvalid (),                 .O_tready ()
    );

//------------------------------------------------------------------------------
// 4. 三个窗口算子（各自再 +1 拍，累计 +4）
//------------------------------------------------------------------------------
    wire [95:0] w_b_dat, w_s_dat, w_m_dat;
    wire        w_b_val, w_b_lst, w_b_usr;
    wire        w_s_val, w_s_lst, w_s_usr;
    wire        w_m_val, w_m_lst, w_m_usr;

    alg_binarize_96 #(
        .C_OFF (C_OFF), .TH_MIN (0), .TH_MAX (255), .BIN_GLOBAL (BIN_GLOBAL)
    ) u_bin (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_b_dat), .O_tvalid (w_b_val), .O_tlast (w_b_lst), .O_tuser (w_b_usr),
        .O_tready ()
    );

    alg_sobel_96 #(
        .C_OFF (C_OFF), .TH_MIN (0), .TH_MAX (255), .EDGE_K (EDGE_K),
        .TH_SCALE (TH_SCALE), .EDGE_BG (EDGE_BG), .PURE_BW (PURE_BW)
    ) u_sob (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_s_dat), .O_tvalid (w_s_val), .O_tlast (w_s_lst), .O_tuser (w_s_usr),
        .O_tready ()
    );

    alg_smooth_96 #(
        .UNUSED (0),
        .SMOOTH_BOX (SMOOTH_BOX)
    ) u_smo (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_m_dat), .O_tvalid (w_m_val), .O_tlast (w_m_lst), .O_tuser (w_m_usr),
        .O_tready ()
    );

//------------------------------------------------------------------------------
// 5. u_det：M5/M7 目标检测（M7 回退 R5 版：使用 SW1 当前档位模式）
//------------------------------------------------------------------------------
    wire [95:0] w_d_dat;
    wire        w_d_val, w_d_lst, w_d_usr;
    wire [10:0] w_det_x0, w_det_x1, w_det_y0, w_det_y1;
    wire [31:0] w_det_pc;
    wire        w_det_bbv;
    wire [1:0]  w_det_cls;
    wire [7:0]  w_det_id;
    wire [3:0]  w_det_mask;
    reg  [3:0]  r_det_mask0, r_det_mask1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_det_mask0 <= 4'd0;
            r_det_mask1 <= 4'd0;
        end else begin
            r_det_mask0 <= w_det_mask;
            r_det_mask1 <= r_det_mask0;
        end
    end
    wire [3:0]         w_det_fv;
    wire [4*11-1:0]    w_det_fx0, w_det_fx1, w_det_fy0, w_det_fy1;

    alg_color_detect_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .REL_MODE    (REL_MODE    ),
        .REL_ABS_MIN (REL_ABS_MIN ),
        .REL_SAT_MIN (REL_SAT_MIN ),
        .REL_MARGIN  (REL_MARGIN  ),
        .RL_EN       (RL_EN       ),
        .RL_MIN_RUN  (RL_MIN_RUN  ),
        .RL_GAP_MAX  (RL_GAP_MAX  ),
        .RL_MIN_ROWS (RL_MIN_ROWS ),
        .IMG_HEIGHT (IMG_HEIGHT),
        .DOM_MODE   (DOM_MODE  ),
        .DOM_MIN    (DOM_MIN   ),
        .DOM_MARGIN (DOM_MARGIN),
        .BBOX_COLOR (BBOX_COLOR),
        .SAT_TH     (SAT_TH    ),
        .SAT_MIN    (SAT_MIN   ),
        .COLOR_GAP  (COLOR_GAP ),
        .RED_B_RATIO(RED_B_RATIO),
        .MIN_PIX    (MIN_PIX    ),
        .Y_MARGIN   (Y_MARGIN  ),
        .AUTO_Y     (AUTO_Y    ),
        .SAT_TH_B   (SAT_TH_B  ),
        .DOM_MIN_B  (DOM_MIN_B ),
        .SAT_TH_G   (SAT_TH_G  ),
        .SAT_TH_R   (SAT_TH_R  ),
        .DOM_MIN_R  (DOM_MIN_R ),
        .DOM_MIN_G  (DOM_MIN_G ),
        .GREEN_M    (GREEN_M   ),
        .FAM_MIN    (FAM_MIN   )
    ) u_det (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_tdata (w_clean_dat), .I_tvalid (w_clean_val), .I_tlast (w_clean_lst), .I_tuser (w_clean_usr),
        .I_roi_en (I_roi_en), .I_roi_x0 (I_roi_x0), .I_roi_x1 (I_roi_x1),
        .I_roi_y0 (I_roi_y0), .I_roi_y1 (I_roi_y1),
        .I_tready (I_tready),
        .I_tgt_color (TGT_COLOR), .I_tgt_tol (TGT_TOL),
        .I_color_mode (I_color_mode),
        .I_auto_green_en((r_mode == MODE_TARGET) || (r_mode == MODE_FOCUS)),
        .O_tdata (w_d_dat), .O_tvalid (w_d_val), .O_tlast (w_d_lst), .O_tuser (w_d_usr),
        .O_tready (),
        .O_bbox_x0 (w_det_x0), .O_bbox_x1 (w_det_x1),
        .O_bbox_y0 (w_det_y0), .O_bbox_y1 (w_det_y1),
        .O_pix_count (w_det_pc), .O_bbox_valid (w_det_bbv),
        .O_color_class (w_det_cls),
        .O_track_id (w_det_id),
        .O_hit_mask (w_det_mask),
        .O_fam_valid (w_det_fv),
        .O_fam_x0 (w_det_fx0), .O_fam_x1 (w_det_fx1),
        .O_fam_y0 (w_det_fy0), .O_fam_y1 (w_det_fy1)
    );

//------------------------------------------------------------------------------
// 5b. u_mot：M6 帧差运动检测
//------------------------------------------------------------------------------
    wire        w_mot_pix0;
    wire [31:0] w_mot_fcnt, w_mot_cnt;
    wire [10:0] w_mot_x0, w_mot_x1, w_mot_y0, w_mot_y1;
    wire        w_mot_v;

    alg_framediff_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT),
        .DIFF_TH    (M6_DIFF_TH),
        .NORM       (M6_NORM)
    ) u_mot (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_tdata (w_g_dat), .I_tvalid (w_g_val), .I_tuser (w_g_usr), .I_tready (I_tready),
        .O_tready (),
        .O_motion_pix0 (w_mot_pix0),
        .O_frame_motion_cnt (w_mot_fcnt),
        .O_motion_cnt (w_mot_cnt),
        .O_motion_bbox_x0 (w_mot_x0), .O_motion_bbox_x1 (w_mot_x1),
        .O_motion_bbox_y0 (w_mot_y0), .O_motion_bbox_y1 (w_mot_y1),
        .O_motion_valid (w_mot_v)
    );

//------------------------------------------------------------------------------
// 5c. M6 运动点补 1 拍（3 → 4），与 w_a0_dat 同拍
//------------------------------------------------------------------------------
    reg r_m6_mot;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_m6_mot <= 1'b0;
        else
            r_m6_mot <= w_mot_pix0;
    end

    reg r_mask_d;

//------------------------------------------------------------------------------
// 5e. M8 动漫风格
//------------------------------------------------------------------------------
    wire [95:0] w_ct_dat;

    alg_cartoon_96 #(
        .EDGE_TH (115)
    ) u_cartoon (
        .I_clk          (I_clk),
        .I_rst_n        (I_rst_n),
        .I_window       (w_window),
        .I_window_valid (w_wvalid),
        .I_tdata        (w_m_dat),
        .O_tdata        (w_ct_dat)
    );

//------------------------------------------------------------------------------
//    7.2 M1 灰度：将 3×96bit 压缩为 3×32bit 灰度字节延迟（省 192 个触发器）
//------------------------------------------------------------------------------
    reg [31:0] r_m1_g   [0:2];
    reg  [2:0] r_m1_ctl [0:2];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (i = 0; i < 3; i = i + 1) begin
                r_m1_g[i]   <= 32'd0;
                r_m1_ctl[i] <= 3'd0;
            end
        end else begin
            r_m1_g[0]   <= {w_g_dat[95:88], w_g_dat[71:64], w_g_dat[47:40], w_g_dat[23:16]};
            r_m1_ctl[0] <= {w_g_val, w_g_lst, w_g_usr};
            for (i = 1; i < 3; i = i + 1) begin
                r_m1_g[i]   <= r_m1_g[i-1];
                r_m1_ctl[i] <= r_m1_ctl[i-1];
            end
        end
    end

    wire [7:0]  w_a1_g0  = r_m1_g[2][31:24];
    wire [7:0]  w_a1_g1  = r_m1_g[2][23:16];
    wire [7:0]  w_a1_g2  = r_m1_g[2][15:8];
    wire [7:0]  w_a1_g3  = r_m1_g[2][7:0];
    wire [95:0] w_a1_dat = {w_a1_g0, w_a1_g0, w_a1_g0,
                            w_a1_g1, w_a1_g1, w_a1_g1,
                            w_a1_g2, w_a1_g2, w_a1_g2,
                            w_a1_g3, w_a1_g3, w_a1_g3};
    wire [2:0]  w_a1_ctl = r_m1_ctl[2];

//------------------------------------------------------------------------------
//    7.3 M5：已在 2 拍，再打 2 拍
//------------------------------------------------------------------------------
    reg [95:0] r_m5_dat [0:1];
    reg  [2:0] r_m5_ctl [0:1];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_m5_dat[0] <= 96'd0; r_m5_dat[1] <= 96'd0;
            r_m5_ctl[0] <= 3'd0;  r_m5_ctl[1] <= 3'd0;
        end else begin
            r_m5_dat[0] <= w_d_dat;
            r_m5_ctl[0] <= {w_d_val, w_d_lst, w_d_usr};
            r_m5_dat[1] <= r_m5_dat[0];
            r_m5_ctl[1] <= r_m5_ctl[0];
        end
    end

    wire [95:0] w_a5_dat = r_m5_dat[1];
    wire [2:0]  w_a5_ctl = r_m5_ctl[1];

//------------------------------------------------------------------------------
//    7.5 掩蔽：window_valid 在 3 拍，再打 1 拍
//------------------------------------------------------------------------------
    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mask_d <= 1'b0;
        else
            r_mask_d <= w_wvalid;
    end

//------------------------------------------------------------------------------
//    7.5b M6 画框坐标：计数器 + 4 拍时钟延迟
//------------------------------------------------------------------------------
    reg [M6_XW-1:0] r_m6_xg;
    reg [10:0]      r_m6_y;
    reg [M6_XW-1:0] r_m6_xg_d [0:3];
    reg [10:0]      r_m6_y_d  [0:3];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_m6_xg <= {M6_XW{1'b0}};
            r_m6_y  <= 11'd0;
            for (i = 0; i < 4; i = i + 1) begin
                r_m6_xg_d[i] <= {M6_XW{1'b0}};
                r_m6_y_d[i]  <= 11'd0;
            end
        end else begin
            if (w_clean_val) begin
                if (w_clean_usr) begin
                    r_m6_xg <= {{(M6_XW-1){1'b0}}, 1'b1};
                    r_m6_y  <= 11'd0;
                end else if (r_m6_xg == M6_LAST_BEAT) begin
                    r_m6_xg <= {M6_XW{1'b0}};
                    r_m6_y  <= (r_m6_y == M6_LAST_ROW) ? 11'd0 : (r_m6_y + 11'd1);
                end else begin
                    r_m6_xg <= r_m6_xg + 1'b1;
                end
            end
            r_m6_xg_d[0] <= r_m6_xg;
            r_m6_y_d[0]  <= r_m6_y;
            for (i = 1; i < 4; i = i + 1) begin
                r_m6_xg_d[i] <= r_m6_xg_d[i-1];
                r_m6_y_d[i]  <= r_m6_y_d[i-1];
            end
        end
    end

//------------------------------------------------------------------------------
//    7.6 帧级统计锁存（w_sof_a0 采样）
//------------------------------------------------------------------------------
    reg [10:0] r_bb_x0, r_bb_x1, r_bb_y0, r_bb_y1;
    reg [31:0] r_bb_pc;
    reg        r_bb_v;
    reg [1:0]  r_bb_cls;
    reg [7:0]  r_bb_id;
    reg [3:0]          r_bb_fv;
    reg [4*11-1:0]     r_bb_fx0, r_bb_fx1, r_bb_fy0, r_bb_fy1;

    wire w_sof_a0 = w_a0_ctl[2] & w_a0_ctl[0];

    reg [3:0] r_mode_hold;

    wire [3:0] w_requested_mode = I_mode_set ? I_mode_sel : r_mode_hold;
    wire [3:0] w_mode_nx = w_requested_mode;
    wire w_mode_sw = w_sof_a0;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_bb_x0  <= 11'h7FF;  r_bb_x1 <= 11'd0;
            r_bb_y0  <= 11'h7FF;  r_bb_y1 <= 11'd0;
            r_bb_pc  <= 32'd0;    r_bb_v  <= 1'b0;
            r_bb_cls <= 2'd0;
            r_bb_id  <= 8'd0;
            r_bb_fv  <= 4'd0;
            r_bb_fx0 <= {4{11'h7FF}};  r_bb_fx1 <= 44'd0;
            r_bb_fy0 <= {4{11'h7FF}};  r_bb_fy1 <= 44'd0;
        end else if (w_sof_a0) begin
            r_bb_cls <= w_det_cls;
            r_bb_id  <= w_det_id;
            r_bb_fv  <= w_det_fv;
            r_bb_fx0 <= w_det_fx0;  r_bb_fx1 <= w_det_fx1;
            r_bb_fy0 <= w_det_fy0;  r_bb_fy1 <= w_det_fy1;
            if (w_mode_nx == MODE_MOTION) begin
                r_bb_x0 <= w_mot_x0;  r_bb_x1 <= w_mot_x1;
                r_bb_y0 <= w_mot_y0;  r_bb_y1 <= w_mot_y1;
                r_bb_pc <= w_mot_cnt; r_bb_v  <= w_mot_v;
            end else begin
                r_bb_x0 <= w_det_x0;  r_bb_x1 <= w_det_x1;
                r_bb_y0 <= w_det_y0;  r_bb_y1 <= w_det_y1;
                r_bb_pc <= w_det_pc;  r_bb_v  <= w_det_bbv;
            end
        end
    end

    assign O_bbox_x0     = r_bb_x0;
    assign O_bbox_x1     = r_bb_x1;
    assign O_bbox_y0     = r_bb_y0;
    assign O_bbox_y1     = r_bb_y1;
    assign O_pix_count   = r_bb_pc;
    assign O_bbox_valid  = r_bb_v;
    assign O_color_class = r_bb_cls;
    assign O_track_id    = r_bb_id;
    assign O_fam_valid   = r_bb_fv[2:0];
    genvar fc;
    generate for(fc=0;fc<3;fc=fc+1) begin:g_centers
        wire [11:0] sx={1'b0,r_bb_fx0[fc*11+:11]}+{1'b0,r_bb_fx1[fc*11+:11]};
        wire [11:0] sy={1'b0,r_bb_fy0[fc*11+:11]}+{1'b0,r_bb_fy1[fc*11+:11]};
        assign O_fam_cx[fc*11+:11]=sx[11:1];
        assign O_fam_cy[fc*11+:11]=sy[11:1];
    end endgenerate

//------------------------------------------------------------------------------
//    7.7 M6 像素叠加（8×8 整块鲜绿高亮 + 3 像素粗红框）
//------------------------------------------------------------------------------
    wire [10:0] w_m6_xbase = {r_m6_xg_d[3], 2'b00};
    wire        w_m6_bb_ok = (r_bb_x0 <= r_bb_x1) && (r_bb_y0 <= r_bb_y1);

    wire [95:0] w_m6_dat;

    genvar g6;
    generate
        for (g6 = 0; g6 < 4; g6 = g6 + 1) begin : g_m6
            wire [10:0] w_m6_xk  = w_m6_xbase + g6;
            wire w_m6_row_1px = ((r_m6_y_d[3] == r_bb_y0) || (r_m6_y_d[3] == r_bb_y1))
                             && (w_m6_xk >= r_bb_x0) && (w_m6_xk <= r_bb_x1);
            wire w_m6_col_1px = ((w_m6_xk == r_bb_x0) || (w_m6_xk == r_bb_x1))
                             && (r_m6_y_d[3] >= r_bb_y0) && (r_m6_y_d[3] <= r_bb_y1);

            wire w_m6_row_3px = (((r_m6_y_d[3] >= r_bb_y0) && (r_m6_y_d[3] <= r_bb_y0 + 11'd2))
                              || ((r_m6_y_d[3] + 11'd2 >= r_bb_y1) && (r_m6_y_d[3] <= r_bb_y1)))
                             && (w_m6_xk >= r_bb_x0) && (w_m6_xk <= r_bb_x1);
            wire w_m6_col_3px = (((w_m6_xk >= r_bb_x0) && (w_m6_xk <= r_bb_x0 + 11'd2))
                              || ((w_m6_xk + 11'd2 >= r_bb_x1) && (w_m6_xk <= r_bb_x1)))
                             && (r_m6_y_d[3] >= r_bb_y0) && (r_m6_y_d[3] <= r_bb_y1);

            wire w_m6_red = w_m6_bb_ok && (M6_NORM ? (w_m6_row_3px || w_m6_col_3px)
                                                   : (w_m6_row_1px || w_m6_col_1px));
            wire w_m6_wht = M6_NORM ? (r_m6_mot && r_mask_d) : (r_m6_mot && (g6 == 0));
            assign w_m6_dat[24*(3-g6) +: 24] =
                   w_m6_red ? 24'hFF0000 :
                   (w_m6_wht ? 24'h00FF00 : w_a0_dat[24*(3-g6) +: 24]);
        end
    endgenerate

//------------------------------------------------------------------------------
//    7.7c M5/M7 AUTO 多色框叠加（3 像素粗彩色框 + 目标框保护区）
//------------------------------------------------------------------------------
    wire w_m5fam = DOM_MODE && ((I_color_mode == 2'd3) || (r_mode == MODE_FOCUS));
    wire [10:0] w_m5_xbase = {r_m6_xg_d[3], 2'b00};

    wire [3:0] w_m5_edge   [0:3];
    wire [3:0] w_m5_inside [0:3];

    genvar g5f, g5p;
    generate
        for (g5f = 0; g5f < 4; g5f = g5f + 1) begin : g_m5fam
            wire [10:0] w_f5x0 = r_bb_fx0[g5f*11 +: 11];
            wire [10:0] w_f5x1 = r_bb_fx1[g5f*11 +: 11];
            wire [10:0] w_f5y0 = r_bb_fy0[g5f*11 +: 11];
            wire [10:0] w_f5y1 = r_bb_fy1[g5f*11 +: 11];
            wire        w_f5ok = (w_f5x0 <= w_f5x1) && (w_f5y0 <= w_f5y1);
            // 外扩 6 像素的轮廓保护区，避免 1 帧框滞后或边缘微缩切掉物体外轮廓
            wire [10:0] w_f5x0_pad = (w_f5x0 > 11'd6) ? (w_f5x0 - 11'd6) : 11'd0;
            wire [10:0] w_f5x1_pad = w_f5x1 + 11'd6;
            wire [10:0] w_f5y0_pad = (w_f5y0 > 11'd6) ? (w_f5y0 - 11'd6) : 11'd0;
            wire [10:0] w_f5y1_pad = w_f5y1 + 11'd6;
            for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_m5px
                wire [10:0] w_m5_xk = w_m5_xbase + g5p;
                wire w_m5_on_row = (((r_m6_y_d[3] >= w_f5y0) && (r_m6_y_d[3] <= w_f5y0 + 11'd2))
                                 || ((r_m6_y_d[3] + 11'd2 >= w_f5y1) && (r_m6_y_d[3] <= w_f5y1)))
                                && (w_m5_xk >= w_f5x0) && (w_m5_xk <= w_f5x1);
                wire w_m5_on_col = (((w_m5_xk >= w_f5x0) && (w_m5_xk <= w_f5x0 + 11'd2))
                                 || ((w_m5_xk + 11'd2 >= w_f5x1) && (w_m5_xk <= w_f5x1)))
                                && (r_m6_y_d[3] >= w_f5y0) && (r_m6_y_d[3] <= w_f5y1);
                assign w_m5_edge[g5f][g5p] = r_bb_fv[g5f] && w_f5ok
                                          && (w_m5_on_row || w_m5_on_col);
                assign w_m5_inside[g5f][g5p] = r_bb_fv[g5f] && w_f5ok
                                            && (w_m5_xk >= w_f5x0_pad) && (w_m5_xk <= w_f5x1_pad)
                                            && (r_m6_y_d[3] >= w_f5y0_pad) && (r_m6_y_d[3] <= w_f5y1_pad);
            end
        end
    endgenerate

    wire [95:0] w_m5_dat;

    generate
        for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_m5out
            assign w_m5_dat[24*(3-g5p) +: 24] =
                   w_m5_edge[0][g5p] ? 24'hFF0000 :
                   (w_m5_edge[1][g5p] ? 24'h00FF00 :
                   (w_m5_edge[2][g5p] ? 24'h0000FF :
                   (w_m5_edge[3][g5p] ? 24'hFFFF00 :
                    w_a5_dat[24*(3-g5p) +: 24])));
        end
    endgenerate

//------------------------------------------------------------------------------
//    7.7d M7（MODE_FOCUS）智能聚色：目标框内保留原色，其余转铅笔素描
//         —— 2026-10-30 按要求回退到 2026-10-29 晚上 R5 版实现
//         （检测框内且命中掩码的像素保留原 RGB；其余出灰阶素描 + 边缘深线）
//------------------------------------------------------------------------------
    wire [95:0] w_focus_dat;
    genvar fp;
    generate for (fp = 0; fp < 4; fp = fp + 1) begin : g_focus
        wire keep = r_det_mask1[fp] &&
                    (w_m5_inside[0][fp] || w_m5_inside[1][fp] || w_m5_inside[2][fp]);
        wire [7:0] shade   = 8'd192 + {2'b00, w_a1_dat[24*(3-fp)+18 +: 6]};
        wire       edge_hit = w_s_dat[24*(3-fp) + 23];
        assign w_focus_dat[24*(3-fp) +: 24] =
               keep      ? w_a0_dat[24*(3-fp) +: 24] :
               edge_hit  ? 24'h202028 : {shade, shade, shade};
    end endgenerate

    // AUTO markers use independent R/G/B centers and four short history samples.
    reg [7:0] trail_x[0:11];
    reg [6:0] trail_y[0:11];
    reg [3:0] trail_valid[0:2];
    integer tf,ti;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            for(tf=0;tf<3;tf=tf+1) trail_valid[tf]<=0;
            for(ti=0;ti<12;ti=ti+1) begin trail_x[ti]<=0;trail_y[ti]<=0;end
        end else if(w_sof_a0) begin
            for(tf=0;tf<3;tf=tf+1) begin
                if(!w_m5fam || !r_bb_fv[tf]) trail_valid[tf]<=0;
                else begin
                    trail_valid[tf]<={trail_valid[tf][2:0],1'b1};
                    for(ti=3;ti>0;ti=ti-1) begin
                        trail_x[tf*4+ti]<=trail_x[tf*4+ti-1];
                        trail_y[tf*4+ti]<=trail_y[tf*4+ti-1];
                    end
                    trail_x[tf*4]<=O_fam_cx[tf*11+3+:8];
                    trail_y[tf*4]<=O_fam_cy[tf*11+3+:7];
                end
            end
        end
    end
    wire [3:0] family_trail[0:2];
    wire [3:0] family_dot[0:2],family_cross[0:2];
    function [11:0] marker_x_masks;
        input [9:0] beat_delta;
        input [1:0] phase;
        begin
            case({beat_delta,phase})
                12'hff4: marker_x_masks=12'hf00;
                12'hff5: marker_x_masks=12'he00;
                12'hff6: marker_x_masks=12'hc00;
                12'hff7: marker_x_masks=12'h800;
                12'hff8: marker_x_masks=12'hf00;
                12'hff9: marker_x_masks=12'hf00;
                12'hffa: marker_x_masks=12'hf00;
                12'hffb: marker_x_masks=12'hf00;
                12'hffc: marker_x_masks=12'h18c;
                12'hffd: marker_x_masks=12'h308;
                12'hffe: marker_x_masks=12'h700;
                12'hfff: marker_x_masks=12'hf00;
                12'h000: marker_x_masks=12'h037;
                12'h001: marker_x_masks=12'h07f;
                12'h002: marker_x_masks=12'h0ef;
                12'h003: marker_x_masks=12'h0ce;
                12'h004: marker_x_masks=12'hf00;
                12'h005: marker_x_masks=12'he00;
                12'h006: marker_x_masks=12'hc01;
                12'h007: marker_x_masks=12'h813;
                12'h008: marker_x_masks=12'hf00;
                12'h009: marker_x_masks=12'hf00;
                12'h00a: marker_x_masks=12'hf00;
                12'h00b: marker_x_masks=12'hf00;
                12'h00c: marker_x_masks=12'h100;
                12'h00d: marker_x_masks=12'h300;
                12'h00e: marker_x_masks=12'h700;
                12'h00f: marker_x_masks=12'hf00;
                default:marker_x_masks=0;
            endcase
        end
    endfunction
    function [2:0] marker_y_masks;
        input [11:0] delta;
        begin
            case(delta)
                12'd0,12'd1,12'd4095:marker_y_masks=3'b011;
                12'd2,12'd4094:marker_y_masks=3'b001;
                12'd4,12'd5,12'd6,12'd7,12'd8,12'd9,12'd10,12'd11,12'd12,
                12'd4092,12'd4091,12'd4090,12'd4089,12'd4088,12'd4087,12'd4086,12'd4085,12'd4084:marker_y_masks=3'b100;
                default:marker_y_masks=0;
            endcase
        end
    endfunction
    genvar mf,mp,mt;
    generate for(mf=0;mf<3;mf=mf+1) begin:g_multi
        wire [9:0] beat_delta={1'b0,w_m5_xbase[10:2]}-{1'b0,O_fam_cx[mf*11+2+:9]};
        wire [11:0] ydelta={1'b0,r_m6_y_d[3]}-{1'b0,O_fam_cy[mf*11+:11]};
        wire [11:0] x_masks=marker_x_masks(beat_delta,O_fam_cx[mf*11+:2]);
        wire [2:0] y_masks=marker_y_masks(ydelta);
        for(mt=0;mt<4;mt=mt+1) begin:g_trail
            assign family_trail[mf][mt]=trail_valid[mf][mt]
                && w_m5_xbase[10:3]==trail_x[mf*4+mt]
                && r_m6_y_d[3][9:3]==trail_y[mf*4+mt];
        end
        for(mp=0;mp<4;mp=mp+1) begin:g_mark
            assign family_dot[mf][mp]=r_bb_fv[mf] && ((x_masks[mp]&&y_masks[0])||(|family_trail[mf]));
            assign family_cross[mf][mp]=r_bb_fv[mf]
                && ((x_masks[mp+8]&&y_masks[1])||(x_masks[mp+4]&&y_masks[2]));
        end
    end endgenerate

//------------------------------------------------------------------------------
// 8. 档位累计 + 锁存
//------------------------------------------------------------------------------
    reg  [15:0] r_div;
    reg         r_key_d;
    reg         r_key_pulse;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_div       <= 16'd0;
            r_key_d     <= 1'b0;
            r_key_pulse <= 1'b0;
        end else begin
            r_key_d     <= I_key;
            r_key_pulse <= 1'b0;
            if (I_key != r_key_d)
                r_div <= 16'd0;
            else if (r_div != KEY_TOP) begin
                r_div <= r_div + 16'd1;
                if (r_div == KEY_TOP - 16'd1)
                    r_key_pulse <= ~I_key;
            end
        end
    end

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mode_hold <= MODE_RAW;
        else if (r_key_pulse)
            r_mode_hold <= (r_mode_hold == MODE_ANIM) ? MODE_RAW : (r_mode_hold + 4'd1);
    end

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mode <= MODE_RAW;
        else if (w_mode_sw)
            r_mode <= w_mode_nx;
    end

    assign O_mode = r_mode;

//------------------------------------------------------------------------------
// 9. 9 选 1 MUX + 掩蔽 + 输出寄存器
//------------------------------------------------------------------------------
    reg [95:0] w_mux_dat;
    reg  [2:0] w_mux_ctl;

    always @ (*) begin
        case (r_mode)
            MODE_RAW        : begin w_mux_dat = w_a0_dat;    w_mux_ctl = w_a0_ctl; end
            MODE_GRAY       : begin w_mux_dat = w_a1_dat;    w_mux_ctl = w_a1_ctl; end
            MODE_BIN        : begin w_mux_dat = w_b_dat;     w_mux_ctl = {w_b_val, w_b_lst, w_b_usr}; end
            MODE_EDGE       : begin w_mux_dat = w_s_dat;     w_mux_ctl = {w_s_val, w_s_lst, w_s_usr}; end
            MODE_SMOOTH     : begin w_mux_dat = w_m_dat;     w_mux_ctl = {w_m_val, w_m_lst, w_m_usr}; end
            MODE_TARGET     : begin w_mux_dat = w_m5fam ? w_m5_dat : w_a5_dat;
                                    w_mux_ctl = w_a5_ctl; end
            MODE_MOTION     : begin w_mux_dat = w_m6_dat;    w_mux_ctl = w_a0_ctl; end
            MODE_FOCUS      : begin w_mux_dat = w_focus_dat; w_mux_ctl = w_a0_ctl; end
            MODE_ANIM       : begin w_mux_dat = w_ct_dat;    w_mux_ctl = w_a0_ctl; end
            default         : begin w_mux_dat = w_a0_dat;    w_mux_ctl = w_a0_ctl; end
        endcase
    end

    wire [95:0] w_masked_dat = (r_mask_d ? w_mux_dat
                             : (((r_mode == MODE_EDGE) && PURE_BW) ? 96'd0 : w_a0_dat));

//------------------------------------------------------------------------------
// 7.7e XY 十字准星（中心加粗 3 像素，清晰标定主目标中心）
//------------------------------------------------------------------------------
wire        w_xh_en = r_bb_v && (((r_mode == MODE_TARGET) && !w_m5fam) || (r_mode == MODE_MOTION))
                   && (r_bb_x0 <= r_bb_x1) && (r_bb_y0 <= r_bb_y1);
wire [11:0] w_xh_cx = ({1'b0, r_bb_x0} + {1'b0, r_bb_x1}) >> 1;
wire [11:0] w_xh_cy = ({1'b0, r_bb_y0} + {1'b0, r_bb_y1}) >> 1;
wire [3:0]  w_xh_hit;
generate
    for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_xh
        wire [11:0] w_xh_px = {1'b0, w_m5_xbase} + g5p;
        wire [11:0] w_xh_py = {1'b0, r_m6_y_d[3]};
        wire [11:0] w_xh_dx = (w_xh_px >= w_xh_cx) ? (w_xh_px - w_xh_cx) : (w_xh_cx - w_xh_px);
        wire [11:0] w_xh_dy = (w_xh_py >= w_xh_cy) ? (w_xh_py - w_xh_cy) : (w_xh_cy - w_xh_py);
        wire        w_xh_1px = ((w_xh_py == w_xh_cy) && (w_xh_dx <= 12'd8))
                            || ((w_xh_px == w_xh_cx) && (w_xh_dy <= 12'd8));
        wire        w_xh_3px = ((w_xh_dy <= 12'd1) && (w_xh_dx <= 12'd10))
                            || ((w_xh_dx <= 12'd1) && (w_xh_dy <= 12'd10));
        assign w_xh_hit[g5p] = w_xh_en && (DOM_MODE ? w_xh_3px : w_xh_1px);
    end
endgenerate
wire [95:0] w_xh_dat;
generate
    for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_xhmix
        wire multi=((r_mode==MODE_TARGET)&&w_m5fam)||(r_mode==MODE_FOCUS);
        wire dot=family_dot[0][g5p]||family_dot[1][g5p]||family_dot[2][g5p];
        wire cross_hit=family_cross[0][g5p]||family_cross[1][g5p]||family_cross[2][g5p];
        wire [23:0] bbox_pixel=w_m5_edge[0][g5p] ? 24'hff0000
                         : (w_m5_edge[1][g5p] ? 24'h00ff00
                         : (w_m5_edge[2][g5p] ? 24'h0000ff : w_masked_dat[24*(3-g5p)+:24]));
        assign w_xh_dat[24*(3-g5p) +: 24] =
               multi ? (dot ? 24'hff8000 : (cross_hit ? 24'hffff00 : bbox_pixel))
               : (w_xh_hit[g5p] ? 24'hFFFF00 : w_masked_dat[24*(3-g5p) +: 24]);
    end
endgenerate

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
        end else begin
            O_tdata  <= w_xh_dat;
            O_tvalid <= w_mux_ctl[2];
            O_tlast  <= w_mux_ctl[1];
            O_tuser  <= w_mux_ctl[0];
        end
    end

endmodule

module rgb_denoise_96(
 input wire I_clk,I_rst_n,
 input wire [95:0] I_tdata,
 input wire I_tvalid,I_tlast,I_tuser,
 output wire [95:0] O_tdata,
 output wire O_tvalid,O_tlast,O_tuser
);
 function near_rgb;
  input [23:0] a,b;
  reg [5:0] dr,dg,db;
  begin
   dr={1'b0,a[23:19]}+6'd1-{1'b0,b[23:19]};
   dg={1'b0,a[15:11]}+6'd1-{1'b0,b[15:11]};
   db={1'b0,a[7:3]}+6'd1-{1'b0,b[7:3]};
   near_rgb=(dr<=2)&&(dg<=2)&&(db<=2);
  end
 endfunction
 wire [95:0] filtered;
 genvar p,c;
 generate for(p=0;p<2;p=p+1)begin:g_pair
  wire [23:0] a=I_tdata[24*(3-2*p)+:24];
  wire [23:0] b=I_tdata[24*(2-2*p)+:24];
  wire mix_pair=near_rgb(a,b);
  for(c=0;c<3;c=c+1)begin:g_ch
   wire [8:0] sum={1'b0,a[8*c+:8]}+{1'b0,b[8*c+:8]}+9'd1;
   assign filtered[24*(3-2*p)+8*c+:8]=mix_pair?sum[8:1]:a[8*c+:8];
   assign filtered[24*(2-2*p)+8*c+:8]=mix_pair?sum[8:1]:b[8*c+:8];
  end
 end endgenerate
 reg [95:0] r_data;
 reg r_valid,r_last,r_user;
 always @(posedge I_clk or negedge I_rst_n)begin
  if(!I_rst_n)begin
   r_data<=0;r_valid<=0;r_last<=0;r_user<=0;
  end else begin
   r_data<=I_tvalid?filtered:96'd0;
   r_valid<=I_tvalid;r_last<=I_tvalid&&I_tlast;r_user<=I_tvalid&&I_tuser;
  end
 end
 assign O_tdata=r_data;
 assign O_tvalid=r_valid;assign O_tlast=r_last;assign O_tuser=r_user;
endmodule
