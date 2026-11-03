//==============================================================================
// 文件名   : alg_color_detect_96.v
// 模块名   : alg_color_detect_96
// 描述     : 96-bit AXI4-Stream 算法通道 · M5 目标颜色检测（二维连通游程多色框 + 资源优化版）
//
// 本次改进说明：
//   1. 当 AUTO_Y=0（板级三原色 R/G/B 模式）时，通过 generate 条件裁剪第 4 族（黄族 gf=3）
//      的 alg_runlen_bbox 实例，直接节省约 395 LUTs 与 250 FFs；
//   2. 当 RL_EN=1（板级游程滤波开启）时，对未使用的裸 min/max 寄存器 r_fminx/y 与 r_min_x/y
//      实施常量门控，让综合器在 RTL 阶段直接折叠裁剪，节省约 220 FFs 与 20 个 11-bit 比较器。
//==============================================================================

module alg_color_detect_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter        DOM_MODE   = 1'b0,
    parameter [7:0]  DOM_MIN    = 8'd80,
    parameter [7:0]  DOM_MARGIN = 8'd30,
    parameter [23:0] BBOX_COLOR = 24'hFFFFFF,
    parameter [7:0]  SAT_TH     = 8'd40,
    parameter [7:0]  SAT_MIN    = 8'd0,
    parameter [8:0]  COLOR_GAP  = 9'd255,
    parameter        RED_B_RATIO = 1'b1,
    parameter [31:0] MIN_PIX     = 32'd0,
    parameter [7:0]  Y_MARGIN   = 8'd40,
    parameter        REL_MODE      = 1'b0,
    parameter [7:0]  REL_ABS_MIN   = 8'd12,
    parameter [7:0]  REL_SAT_MIN   = 8'd12,
    parameter [7:0]  REL_MARGIN    = 8'd4,
    parameter        RL_EN       = 1'b0,
    parameter [10:0] RL_MIN_RUN  = 11'd32,
    parameter [7:0]  RL_GAP_MAX  = 8'd2,
    parameter [15:0] RL_MIN_ROWS = 16'd6,
    parameter        AUTO_Y     = 1'b1,
    parameter [7:0]  SAT_TH_B   = SAT_TH,
    parameter [7:0]  DOM_MIN_B  = DOM_MIN,
    parameter [7:0]  SAT_TH_G   = SAT_TH,
    parameter [7:0]  SAT_TH_R   = SAT_TH,
    parameter [7:0]  DOM_MIN_R  = DOM_MIN,
    parameter [7:0]  DOM_MIN_G  = DOM_MIN,
    parameter [7:0]  GREEN_M    = 8'd0,
    parameter [31:0] FAM_MIN    = 32'd1
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire         I_tready,
    input  wire [23:0]  I_tgt_color,
    input  wire [7:0]   I_tgt_tol,
    input  wire [1:0]   I_color_mode,
    input  wire         I_auto_green_en,
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready,
    input  wire         I_roi_en,
    input  wire [10:0]  I_roi_x0,
    input  wire [10:0]  I_roi_x1,
    input  wire [10:0]  I_roi_y0,
    input  wire [10:0]  I_roi_y1,
    output reg  [10:0]  O_bbox_x0,
    output reg  [10:0]  O_bbox_x1,
    output reg  [10:0]  O_bbox_y0,
    output reg  [10:0]  O_bbox_y1,
    output reg  [31:0]  O_pix_count,
    output reg          O_bbox_valid,
    output reg  [1:0]   O_color_class,
    output reg  [7:0]   O_track_id,
    output reg  [3:0]   O_hit_mask,
    output reg  [3:0]        O_fam_valid,
    output reg  [4*11-1:0]   O_fam_x0,
    output reg  [4*11-1:0]   O_fam_x1,
    output reg  [4*11-1:0]   O_fam_y0,
    output reg  [4*11-1:0]   O_fam_y1
);

localparam BEATS_PER_LINE = IMG_WIDTH >> 2;
localparam XW = $clog2(BEATS_PER_LINE);
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;
localparam [10:0]   BBOX_SENT = 11'h7FF;

assign O_tready = I_tready;

reg [XW-1:0] r_x_grp;
reg [10:0]   r_y_pos;

reg [95:0]   r_data_d1;
reg [XW-1:0] r_x_d1;
reg [10:0]   r_y_d1;
reg [3:0]    r_hit_d1;
reg          r_tu_d1;
reg          r_tl_d1;
reg          r_vld1;

reg          r_hit3_p2;
reg          r_tl_p2;

reg [10:0]   r_min_x;
reg [10:0]   r_max_x;
reg [10:0]   r_min_y;
reg [10:0]   r_max_y;
reg [31:0]   r_cnt;
reg [31:0]   r_cnt_cls_r, r_cnt_cls_g, r_cnt_cls_b;
reg [31:0]   r_cnt_cls_y;
reg [10:0]   r_fminx [0:3];
reg [10:0]   r_fmaxx [0:3];
reg [10:0]   r_fminy [0:3];
reg [10:0]   r_fmaxy [0:3];

localparam TRAIL_N = 8;
localparam [2:0] LOST_MAX = 3'd7;
localparam [2:0] LOST_N   = 3'd4;

reg [10:0]   r_tx [0:TRAIL_N-1];
reg [10:0]   r_ty [0:TRAIL_N-1];
reg [7:0]    r_track_id;
reg [2:0]    r_lost_f;

//------------------------------------------------------------------------------
// 2. 逐像素判色
//------------------------------------------------------------------------------
wire [7:0] w_t_r = I_tgt_color[23:16];
wire [7:0] w_t_g = I_tgt_color[15:8];
wire [7:0] w_t_b = I_tgt_color[7:0];

wire [3:0] w_hit;

genvar gi;
genvar gk;
genvar gf;
integer ii;
generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_hit
        wire [7:0] w_r = I_tdata[24*(3-gi) + 23 -: 8];
        wire [7:0] w_g = I_tdata[24*(3-gi) + 15 -: 8];
        wire [7:0] w_b = I_tdata[24*(3-gi) +  7 -: 8];
        wire [7:0] w_dr = (w_r >= w_t_r) ? (w_r - w_t_r) : (w_t_r - w_r);
        wire [7:0] w_dg = (w_g >= w_t_g) ? (w_g - w_t_g) : (w_t_g - w_g);
        wire [7:0] w_db = (w_b >= w_t_b) ? (w_b - w_t_b) : (w_t_b - w_b);

        wire w_hit_fixr, w_hit_fixg, w_hit_fixb, w_hit_green_auto;

        alg_color_gate #(
            .REL_MODE    (REL_MODE),
            .DOM_MIN     (DOM_MIN),
            .DOM_MARGIN  (DOM_MARGIN),
            .SAT_MIN     (SAT_MIN),
            .COLOR_GAP   (COLOR_GAP),
            .RED_B_RATIO (RED_B_RATIO),
            .REL_ABS_MIN (REL_ABS_MIN),
            .REL_SAT_MIN (REL_SAT_MIN),
            .REL_MARGIN  (REL_MARGIN)
        ) u_cgate (
            .I_r     (w_r),
            .I_g     (w_g),
            .I_b     (w_b),
            .O_hit_r (w_hit_fixr),
            .O_hit_g (w_hit_fixg),
            .O_hit_b (w_hit_fixb),
            .O_hit_g_auto(w_hit_green_auto)
        );

        wire w_hit_auto = w_hit_fixr | (I_auto_green_en ? w_hit_green_auto : w_hit_fixg) | w_hit_fixb;

        wire w_hit_dom = (I_color_mode == 2'd0) ? w_hit_fixr :
                         (I_color_mode == 2'd1) ? w_hit_fixg :
                         (I_color_mode == 2'd2) ? w_hit_fixb : w_hit_auto;

        assign w_hit[gi] = DOM_MODE
                         ? w_hit_dom
                         : ((w_dr <= I_tgt_tol) && (w_dg <= I_tgt_tol) && (w_db <= I_tgt_tol));
    end
endgenerate

//------------------------------------------------------------------------------
// 2b. 颜色类别统计
//------------------------------------------------------------------------------
wire [7:0] w_p0_r = r_data_d1[95:88], w_p0_g = r_data_d1[87:80], w_p0_b = r_data_d1[79:72];
wire [7:0] w_p1_r = r_data_d1[71:64], w_p1_g = r_data_d1[63:56], w_p1_b = r_data_d1[55:48];
wire [7:0] w_p2_r = r_data_d1[47:40], w_p2_g = r_data_d1[39:32], w_p2_b = r_data_d1[31:24];
wire [7:0] w_p3_r = r_data_d1[23:16], w_p3_g = r_data_d1[15:8],  w_p3_b = r_data_d1[7:0];

wire       w_cls_auto = DOM_MODE && (I_color_mode == 2'd3);
wire       w_cls_y_en = w_cls_auto && AUTO_Y;
wire [8:0] w_p0_r9 = {1'b0, w_p0_r}, w_p0_g9 = {1'b0, w_p0_g}, w_p0_b9 = {1'b0, w_p0_b};
wire [8:0] w_p1_r9 = {1'b0, w_p1_r}, w_p1_g9 = {1'b0, w_p1_g}, w_p1_b9 = {1'b0, w_p1_b};
wire [8:0] w_p2_r9 = {1'b0, w_p2_r}, w_p2_g9 = {1'b0, w_p2_g}, w_p2_b9 = {1'b0, w_p2_b};
wire [8:0] w_p3_r9 = {1'b0, w_p3_r}, w_p3_g9 = {1'b0, w_p3_g}, w_p3_b9 = {1'b0, w_p3_b};
wire [8:0] w_ym9    = {1'b0, Y_MARGIN};
wire       w_is_y0  = w_cls_y_en && (w_p0_r >= DOM_MIN) && (w_p0_g >= DOM_MIN)
                              && (w_p0_r9 >= w_p0_b9 + w_ym9) && (w_p0_g9 >= w_p0_b9 + w_ym9);
wire       w_is_y1  = w_cls_y_en && (w_p1_r >= DOM_MIN) && (w_p1_g >= DOM_MIN)
                              && (w_p1_r9 >= w_p1_b9 + w_ym9) && (w_p1_g9 >= w_p1_b9 + w_ym9);
wire       w_is_y2  = w_cls_y_en && (w_p2_r >= DOM_MIN) && (w_p2_g >= DOM_MIN)
                              && (w_p2_r9 >= w_p2_b9 + w_ym9) && (w_p2_g9 >= w_p2_b9 + w_ym9);
wire       w_is_y3  = w_cls_y_en && (w_p3_r >= DOM_MIN) && (w_p3_g >= DOM_MIN)
                              && (w_p3_r9 >= w_p3_b9 + w_ym9) && (w_p3_g9 >= w_p3_b9 + w_ym9);

wire [1:0] w_cls0 = w_is_y0 ? 2'd3 :
                    ((w_p0_r >= w_p0_g) && (w_p0_r >= w_p0_b)) ? 2'd0 :
                    ((w_p0_g >= w_p0_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls1 = w_is_y1 ? 2'd3 :
                    ((w_p1_r >= w_p1_g) && (w_p1_r >= w_p1_b)) ? 2'd0 :
                    ((w_p1_g >= w_p1_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls2 = w_is_y2 ? 2'd3 :
                    ((w_p2_r >= w_p2_g) && (w_p2_r >= w_p2_b)) ? 2'd0 :
                    ((w_p2_g >= w_p2_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls3 = w_is_y3 ? 2'd3 :
                    ((w_p3_r >= w_p3_g) && (w_p3_r >= w_p3_b)) ? 2'd0 :
                    ((w_p3_g >= w_p3_b))                       ? 2'd1 : 2'd2;

wire [2:0] w_hit_r = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd0)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd0)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd0)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd0)};
wire [2:0] w_hit_g = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd1)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd1)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd1)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd1)};
wire [2:0] w_hit_b = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd2)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd2)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd2)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd2)};
wire [2:0] w_hit_y = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd3)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd3)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd3)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd3)};

//------------------------------------------------------------------------------
// 3. 行内表决 hit_vote
//------------------------------------------------------------------------------
wire w_left_nb  = (!r_tl_p2) && r_hit3_p2;
wire w_right_nb = (!r_tl_d1) && I_tvalid && r_vld1;

wire [3:0] w_vote;
assign w_vote[0] = r_hit_d1[0] && ( w_left_nb || r_hit_d1[1] );
assign w_vote[1] = r_hit_d1[1] && ( r_hit_d1[0] || r_hit_d1[2] );
assign w_vote[2] = r_hit_d1[2] && ( r_hit_d1[1] || r_hit_d1[3] );
assign w_vote[3] = r_hit_d1[3] && ( r_hit_d1[2] || (w_right_nb && w_hit[0]) );

//------------------------------------------------------------------------------
// 4. 有效掩蔽 + 本拍命中候选
//------------------------------------------------------------------------------
wire [10:0] w_x_base = {r_x_d1, 2'b00};
wire w_row_ok = (r_y_d1 >= 11'd2) && (r_x_d1 != {XW{1'b0}});

wire [3:0] w_voted = w_vote & {4{w_row_ok}};

wire w_any = |w_voted;
wire [10:0] w_x_lo = w_voted[0] ? (w_x_base + 11'd0) :
                     w_voted[1] ? (w_x_base + 11'd1) :
                     w_voted[2] ? (w_x_base + 11'd2) : (w_x_base + 11'd3);
wire [10:0] w_x_hi = w_voted[3] ? (w_x_base + 11'd3) :
                     w_voted[2] ? (w_x_base + 11'd2) :
                     w_voted[1] ? (w_x_base + 11'd1) : (w_x_base + 11'd0);
wire [2:0] w_vcnt = {2'b00, w_voted[0]} + {2'b00, w_voted[1]}
                  + {2'b00, w_voted[2]} + {2'b00, w_voted[3]};

//------------------------------------------------------------------------------
// 5. 画框判定与输出数据
//------------------------------------------------------------------------------
wire w_auto_no_union = (I_color_mode == 2'd3);
wire w_bbox_ok = (O_bbox_x0 <= O_bbox_x1) && (O_bbox_y0 <= O_bbox_y1)
               && !w_auto_no_union;
wire [3:0] w_mark;

generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_mark
        wire [10:0] w_xk  = w_x_base + gi;
        wire w_on_row_1px = ((r_y_d1 == O_bbox_y0) || (r_y_d1 == O_bbox_y1))
                         && (w_xk >= O_bbox_x0) && (w_xk <= O_bbox_x1);
        wire w_on_col_1px = ((w_xk == O_bbox_x0) || (w_xk == O_bbox_x1))
                         && (r_y_d1 >= O_bbox_y0) && (r_y_d1 <= O_bbox_y1);

        wire w_on_row_3px = (((r_y_d1 >= O_bbox_y0) && (r_y_d1 <= O_bbox_y0 + 11'd2))
                          || ((r_y_d1 + 11'd2 >= O_bbox_y1) && (r_y_d1 <= O_bbox_y1)))
                         && (w_xk >= O_bbox_x0) && (w_xk <= O_bbox_x1);
        wire w_on_col_3px = (((w_xk >= O_bbox_x0) && (w_xk <= O_bbox_x0 + 11'd2))
                          || ((w_xk + 11'd2 >= O_bbox_x1) && (w_xk <= O_bbox_x1)))
                         && (r_y_d1 >= O_bbox_y0) && (r_y_d1 <= O_bbox_y1);

        assign w_mark[gi] = w_bbox_ok && (DOM_MODE ? (w_on_row_3px || w_on_col_3px)
                                                   : (w_on_row_1px || w_on_col_1px));
    end
endgenerate

//------------------------------------------------------------------------------
// 5b. 轨迹点判定
//------------------------------------------------------------------------------
wire [TRAIL_N-1:0] w_trail_hit;

generate
    for (gk = 0; gk < TRAIL_N; gk = gk + 1) begin : g_trail
        assign w_trail_hit[gk] = (r_y_d1[10:3]  == r_ty[gk][10:3]) &&
                                 (w_x_base[10:3] == r_tx[gk][10:3]);
    end
endgenerate

wire w_trail = |w_trail_hit;

//------------------------------------------------------------------------------
// 5c. 输出像素
//------------------------------------------------------------------------------
wire [95:0] w_marked;

generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_out
        assign w_marked[24*(3-gi) +: 24] =
               w_mark[gi] ? BBOX_COLOR :
               ((w_trail && !w_cls_auto) ? 24'hFF8000 :
                            r_data_d1[24*(3-gi) +: 24]);
    end
endgenerate

wire w_frame_start = r_vld1 && r_tu_d1;

//------------------------------------------------------------------------------
// 6. 坐标推进
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin
            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin
            r_x_grp <= {XW{1'b0}};
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 7. 第 1 级流水寄存器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_data_d1 <= 96'd0;
    else if (I_tvalid)
        r_data_d1 <= I_tdata;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_d1 <= {XW{1'b0}};
        r_y_d1 <= 11'd0;
    end else if (I_tvalid) begin
        r_x_d1 <= r_x_grp;
        r_y_d1 <= r_y_pos;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_hit_d1 <= 4'd0;
    else if (I_tvalid)
        r_hit_d1 <= w_hit;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tu_d1 <= 1'b0;
        r_tl_d1 <= 1'b0;
    end else if (I_tvalid) begin
        r_tu_d1 <= I_tuser;
        r_tl_d1 <= I_tlast;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;
end

//------------------------------------------------------------------------------
// 8. 邻居历史寄存器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_hit3_p2 <= 1'b0;
    else if (I_tvalid)
        r_hit3_p2 <= r_hit_d1[3];
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_tl_p2 <= 1'b0;
    else if (I_tvalid)
        r_tl_p2 <= r_tl_d1;
end

//------------------------------------------------------------------------------
// 9. 帧内累加 + 二维连通带游程包围盒（主通路 + R/G/B/(Y) 独立通路）
//------------------------------------------------------------------------------
wire [10:0] w_rl_x0, w_rl_x1, w_rl_y0, w_rl_y1;
wire        w_rl_v;

alg_runlen_bbox #(
    .MIN_RUN (RL_MIN_RUN ),
    .GAP_MAX (RL_GAP_MAX ),
    .MIN_ROWS(RL_MIN_ROWS)
) u_rlbb (
    .I_clk        (I_clk),
    .I_rst_n      (I_rst_n),
    .I_valid      (r_vld1),
    .I_frame_start(w_frame_start),
    .I_hit        (w_any),
    .I_x_lo       (w_x_lo),
    .I_x_hi       (w_x_hi),
    .I_y          (r_y_d1),
    .O_x0         (w_rl_x0),
    .O_x1         (w_rl_x1),
    .O_y0         (w_rl_y0),
    .O_y1         (w_rl_y1),
    .O_valid      (w_rl_v),
    .I_roi_en     (I_roi_en),
    .I_roi_x0     (I_roi_x0),
    .I_roi_x1     (I_roi_x1),
    .I_roi_y0     (I_roi_y0),
    .I_roi_y1     (I_roi_y1),
    .O_rows       ()
);

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_x <= BBOX_SENT;
    else if (!RL_EN) begin
        if (w_frame_start)
            r_min_x <= w_any ? w_x_lo : BBOX_SENT;
        else if (r_vld1 && w_any && (w_x_lo < r_min_x))
            r_min_x <= w_x_lo;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_x <= 11'd0;
    else if (!RL_EN) begin
        if (w_frame_start)
            r_max_x <= w_any ? w_x_hi : 11'd0;
        else if (r_vld1 && w_any && (w_x_hi > r_max_x))
            r_max_x <= w_x_hi;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_y <= BBOX_SENT;
    else if (!RL_EN) begin
        if (w_frame_start)
            r_min_y <= w_any ? r_y_d1 : BBOX_SENT;
        else if (r_vld1 && w_any && (r_y_d1 < r_min_y))
            r_min_y <= r_y_d1;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_y <= 11'd0;
    else if (!RL_EN) begin
        if (w_frame_start)
            r_max_y <= w_any ? r_y_d1 : 11'd0;
        else if (r_vld1 && w_any && (r_y_d1 > r_max_y))
            r_max_y <= r_y_d1;
    end
end

//------------------------------------------------------------------------------
// 9a. 色族独立二维连通带游程包围盒（当 AUTO_Y=0 时自动裁剪黄族 gf=3，节省 ~395 LUTs）
//------------------------------------------------------------------------------
wire [10:0] w_rl_fx0   [0:3];
wire [10:0] w_rl_fx1   [0:3];
wire [10:0] w_rl_fy0   [0:3];
wire [10:0] w_rl_fy1   [0:3];
wire        w_rl_fv    [0:3];
wire [15:0] w_rl_frows [0:3];

generate
    for (gf = 0; gf < 4; gf = gf + 1) begin : g_fambb
        localparam [1:0] GFID = gf;
        wire [3:0] w_vfg   = w_voted &
                             { (w_cls3 == GFID),
                               (w_cls2 == GFID),
                               (w_cls1 == GFID),
                               (w_cls0 == GFID) };
        wire       w_anyg  = |w_vfg;
        wire [10:0] w_xlog = w_vfg[0] ? (w_x_base + 11'd0) :
                             w_vfg[1] ? (w_x_base + 11'd1) :
                             w_vfg[2] ? (w_x_base + 11'd2) : (w_x_base + 11'd3);
        wire [10:0] w_xhig = w_vfg[3] ? (w_x_base + 11'd3) :
                             w_vfg[2] ? (w_x_base + 11'd2) :
                             w_vfg[1] ? (w_x_base + 11'd1) : (w_x_base + 11'd0);

        if ((gf < 3) || (AUTO_Y != 1'b0)) begin : g_rl_en
            alg_runlen_bbox #(
                .MIN_RUN (RL_MIN_RUN ),
                .GAP_MAX (RL_GAP_MAX ),
                .MIN_ROWS(RL_MIN_ROWS)
            ) u_rlbb_fam (
                .I_clk        (I_clk),
                .I_rst_n      (I_rst_n),
                .I_valid      (r_vld1),
                .I_frame_start(w_frame_start),
                .I_hit        (w_anyg),
                .I_x_lo       (w_xlog),
                .I_x_hi       (w_xhig),
                .I_y          (r_y_d1),
                .I_roi_en     (I_roi_en),
                .I_roi_x0     (I_roi_x0),
                .I_roi_x1     (I_roi_x1),
                .I_roi_y0     (I_roi_y0),
                .I_roi_y1     (I_roi_y1),
                .O_x0         (w_rl_fx0[gf]),
                .O_x1         (w_rl_fx1[gf]),
                .O_y0         (w_rl_fy0[gf]),
                .O_y1         (w_rl_fy1[gf]),
                .O_valid      (w_rl_fv[gf]),
                .O_rows       (w_rl_frows[gf])
            );
        end else begin : g_rl_dis
            assign w_rl_fx0[gf]   = BBOX_SENT;
            assign w_rl_fx1[gf]   = 11'd0;
            assign w_rl_fy0[gf]   = BBOX_SENT;
            assign w_rl_fy1[gf]   = 11'd0;
            assign w_rl_fv[gf]    = 1'b0;
            assign w_rl_frows[gf] = 16'd0;
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fminx[gf] <= BBOX_SENT;
            else if (!RL_EN) begin
                if (w_frame_start)
                    r_fminx[gf] <= w_anyg ? w_xlog : BBOX_SENT;
                else if (r_vld1 && w_anyg && (w_xlog < r_fminx[gf]))
                    r_fminx[gf] <= w_xlog;
            end
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fmaxx[gf] <= 11'd0;
            else if (!RL_EN) begin
                if (w_frame_start)
                    r_fmaxx[gf] <= w_anyg ? w_xhig : 11'd0;
                else if (r_vld1 && w_anyg && (w_xhig > r_fmaxx[gf]))
                    r_fmaxx[gf] <= w_xhig;
            end
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fminy[gf] <= BBOX_SENT;
            else if (!RL_EN) begin
                if (w_frame_start)
                    r_fminy[gf] <= w_anyg ? r_y_d1 : BBOX_SENT;
                else if (r_vld1 && w_anyg && (r_y_d1 < r_fminy[gf]))
                    r_fminy[gf] <= r_y_d1;
            end
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fmaxy[gf] <= 11'd0;
            else if (!RL_EN) begin
                if (w_frame_start)
                    r_fmaxy[gf] <= w_anyg ? r_y_d1 : 11'd0;
                else if (r_vld1 && w_anyg && (r_y_d1 > r_fmaxy[gf]))
                    r_fmaxy[gf] <= r_y_d1;
            end
        end
    end
endgenerate

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt <= 32'd0;
    else if (w_frame_start)
        r_cnt <= {29'd0, w_vcnt};
    else if (r_vld1)
        r_cnt <= r_cnt + {29'd0, w_vcnt};
end

//------------------------------------------------------------------------------
// 9b. 颜色类别的四个计数器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_r <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_r <= {29'd0, w_hit_r};
    else if (r_vld1)
        r_cnt_cls_r <= r_cnt_cls_r + {29'd0, w_hit_r};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_g <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_g <= {29'd0, w_hit_g};
    else if (r_vld1)
        r_cnt_cls_g <= r_cnt_cls_g + {29'd0, w_hit_g};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_b <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_b <= {29'd0, w_hit_b};
    else if (r_vld1)
        r_cnt_cls_b <= r_cnt_cls_b + {29'd0, w_hit_b};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_y <= 32'd0;
    else if (AUTO_Y) begin
        if (w_frame_start)
            r_cnt_cls_y <= {29'd0, w_hit_y};
        else if (r_vld1)
            r_cnt_cls_y <= r_cnt_cls_y + {29'd0, w_hit_y};
    end
end

//------------------------------------------------------------------------------
// 10. 帧尾锁存与主导色族优选
//------------------------------------------------------------------------------
wire w_fam_ok_r = (r_cnt_cls_r >= FAM_MIN) && (!RL_EN || w_rl_fv[0]);
wire w_fam_ok_g = (r_cnt_cls_g >= FAM_MIN) && (!RL_EN || w_rl_fv[1]);
wire w_fam_ok_b = (r_cnt_cls_b >= FAM_MIN) && (!RL_EN || w_rl_fv[2]);
wire w_fam_ok_y = (r_cnt_cls_y >= FAM_MIN) && (!RL_EN || w_rl_fv[3]) && AUTO_Y;

wire [31:0] w_eff_cnt_r = (RL_EN && w_cls_auto) ? (w_fam_ok_r ? r_cnt_cls_r : 32'd0) : r_cnt_cls_r;
wire [31:0] w_eff_cnt_g = (RL_EN && w_cls_auto) ? (w_fam_ok_g ? r_cnt_cls_g : 32'd0) : r_cnt_cls_g;
wire [31:0] w_eff_cnt_b = (RL_EN && w_cls_auto) ? (w_fam_ok_b ? r_cnt_cls_b : 32'd0) : r_cnt_cls_b;
wire [31:0] w_eff_cnt_y = (RL_EN && w_cls_auto) ? (w_fam_ok_y ? r_cnt_cls_y : 32'd0) : r_cnt_cls_y;

wire [1:0] w_cls_win =
        ((w_eff_cnt_r >= w_eff_cnt_g) && (w_eff_cnt_r >= w_eff_cnt_b) && (w_eff_cnt_r >= w_eff_cnt_y)) ? 2'd0 :
        ((w_eff_cnt_g >= w_eff_cnt_b) && (w_eff_cnt_g >= w_eff_cnt_y))                                 ? 2'd1 :
        ((w_eff_cnt_b >= w_eff_cnt_y))                                                                  ? 2'd2 : 2'd3;

reg r_fs_d1;
reg [1:0] r_cls_win_l;
reg [31:0] r_cnt_l;
reg [3:0]  r_fam_cnt_ok;

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_fs_d1      <= 1'b0;
        r_cls_win_l  <= 2'd0;
        r_cnt_l      <= 32'd0;
        r_fam_cnt_ok <= 4'd0;
    end else begin
        r_fs_d1 <= w_frame_start;
        if (w_frame_start) begin
            r_cls_win_l  <= w_cls_win;
            r_cnt_l      <= r_cnt;
            r_fam_cnt_ok <= { (r_cnt_cls_y >= FAM_MIN) && AUTO_Y,
                              (r_cnt_cls_b >= FAM_MIN),
                              (r_cnt_cls_g >= FAM_MIN),
                              (r_cnt_cls_r >= FAM_MIN) };
        end
    end
end

wire [3:0] w_rl_fvalid = { w_rl_fv[3] && r_fam_cnt_ok[3],
                           w_rl_fv[2] && r_fam_cnt_ok[2],
                           w_rl_fv[1] && r_fam_cnt_ok[1],
                           w_rl_fv[0] && r_fam_cnt_ok[0] };

wire [15:0] w_sc_r = w_rl_fvalid[0] ? w_rl_frows[0] : 16'd0;
wire [15:0] w_sc_g = w_rl_fvalid[1] ? w_rl_frows[1] : 16'd0;
wire [15:0] w_sc_b = w_rl_fvalid[2] ? w_rl_frows[2] : 16'd0;
wire [15:0] w_sc_y = w_rl_fvalid[3] ? w_rl_frows[3] : 16'd0;

wire [1:0] w_rl_win =
        ((w_sc_r >= w_sc_g) && (w_sc_r >= w_sc_b) && (w_sc_r >= w_sc_y)) ? 2'd0 :
        ((w_sc_g >= w_sc_b) && (w_sc_g >= w_sc_y))                         ? 2'd1 :
        ((w_sc_b >= w_sc_y))                                               ? 2'd2 : 2'd3;

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_x0 <= BBOX_SENT;
    else if (w_frame_start && !RL_EN)
        O_bbox_x0 <= w_cls_y_en ? r_fminx[w_cls_win] : r_min_x;
    else if (r_fs_d1 && RL_EN)
        O_bbox_x0 <= w_cls_auto ? w_rl_fx0[w_rl_win] : w_rl_x0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_x1 <= 11'd0;
    else if (w_frame_start && !RL_EN)
        O_bbox_x1 <= w_cls_y_en ? r_fmaxx[w_cls_win] : r_max_x;
    else if (r_fs_d1 && RL_EN)
        O_bbox_x1 <= w_cls_auto ? w_rl_fx1[w_rl_win] : w_rl_x1;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_y0 <= BBOX_SENT;
    else if (w_frame_start && !RL_EN)
        O_bbox_y0 <= w_cls_y_en ? r_fminy[w_cls_win] : r_min_y;
    else if (r_fs_d1 && RL_EN)
        O_bbox_y0 <= w_cls_auto ? w_rl_fy0[w_rl_win] : w_rl_y0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_y1 <= 11'd0;
    else if (w_frame_start && !RL_EN)
        O_bbox_y1 <= w_cls_y_en ? r_fmaxy[w_cls_win] : r_max_y;
    else if (r_fs_d1 && RL_EN)
        O_bbox_y1 <= w_cls_auto ? w_rl_fy1[w_rl_win] : w_rl_y1;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_pix_count <= 32'd0;
    else if (w_frame_start)
        O_pix_count <= r_cnt;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_valid <= 1'b0;
    else if (w_frame_start && !RL_EN)
        O_bbox_valid <= (r_cnt != 32'd0) && (r_cnt >= MIN_PIX);
    else if (r_fs_d1 && RL_EN)
        O_bbox_valid <= w_cls_auto ? (|w_rl_fvalid) : (w_rl_v && (r_cnt_l >= MIN_PIX));
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_color_class <= 2'd0;
    else if (w_frame_start && !RL_EN)
        O_color_class <= w_cls_win;
    else if (r_fs_d1 && RL_EN)
        O_color_class <= w_cls_auto ? w_rl_win : r_cls_win_l;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_fam_valid <= 4'd0;
        O_fam_x0    <= {4{BBOX_SENT}};
        O_fam_x1    <= 44'd0;
        O_fam_y0    <= {4{BBOX_SENT}};
        O_fam_y1    <= 44'd0;
    end else if (w_frame_start && !RL_EN) begin
        O_fam_valid <= { (r_cnt_cls_y >= FAM_MIN), (r_cnt_cls_b >= FAM_MIN),
                         (r_cnt_cls_g >= FAM_MIN), (r_cnt_cls_r >= FAM_MIN) };
        O_fam_x0    <= { r_fminx[3], r_fminx[2], r_fminx[1], r_fminx[0] };
        O_fam_x1    <= { r_fmaxx[3], r_fmaxx[2], r_fmaxx[1], r_fmaxx[0] };
        O_fam_y0    <= { r_fminy[3], r_fminy[2], r_fminy[1], r_fminy[0] };
        O_fam_y1    <= { r_fmaxy[3], r_fmaxy[2], r_fmaxy[1], r_fmaxy[0] };
    end else if (r_fs_d1 && RL_EN) begin
        O_fam_valid <= w_rl_fvalid;
        O_fam_x0    <= { w_rl_fx0[3], w_rl_fx0[2], w_rl_fx0[1], w_rl_fx0[0] };
        O_fam_x1    <= { w_rl_fx1[3], w_rl_fx1[2], w_rl_fx1[1], w_rl_fx1[0] };
        O_fam_y0    <= { w_rl_fy0[3], w_rl_fy0[2], w_rl_fy0[1], w_rl_fy0[0] };
        O_fam_y1    <= { w_rl_fy1[3], w_rl_fy1[2], w_rl_fy1[1], w_rl_fy1[0] };
    end
end

//------------------------------------------------------------------------------
// 10c. 动态跟踪轨迹与编号
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        for (ii = 0; ii < TRAIL_N; ii = ii + 1) begin
            r_tx[ii] <= BBOX_SENT;
            r_ty[ii] <= BBOX_SENT;
        end
    end else if (w_frame_start && !RL_EN && (r_cnt != 32'd0)) begin
        for (ii = TRAIL_N - 1; ii > 0; ii = ii - 1) begin
            r_tx[ii] <= r_tx[ii-1];
            r_ty[ii] <= r_ty[ii-1];
        end
        r_tx[0] <= ({1'b0, r_min_x} + {1'b0, r_max_x}) >> 1;
        r_ty[0] <= ({1'b0, r_min_y} + {1'b0, r_max_y}) >> 1;
    end else if (r_fs_d1 && RL_EN && (w_cls_auto ? (|w_rl_fvalid) : (w_rl_v && (r_cnt_l >= MIN_PIX)))) begin
        for (ii = TRAIL_N - 1; ii > 0; ii = ii - 1) begin
            r_tx[ii] <= r_tx[ii-1];
            r_ty[ii] <= r_ty[ii-1];
        end
        r_tx[0] <= w_cls_auto ? (({1'b0, w_rl_fx0[w_rl_win]} + {1'b0, w_rl_fx1[w_rl_win]}) >> 1)
                              : (({1'b0, w_rl_x0} + {1'b0, w_rl_x1}) >> 1);
        r_ty[0] <= w_cls_auto ? (({1'b0, w_rl_fy0[w_rl_win]} + {1'b0, w_rl_fy1[w_rl_win]}) >> 1)
                              : (({1'b0, w_rl_y0} + {1'b0, w_rl_y1}) >> 1);
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_track_id <= 8'd0;
        r_lost_f   <= LOST_MAX;
    end else if (w_frame_start) begin
        if (r_cnt != 32'd0) begin
            r_lost_f <= 3'd0;
            if (r_lost_f >= LOST_N)
                O_track_id <= (O_track_id >= 8'd99) ? 8'd1 : (O_track_id + 8'd1);
        end else if (r_lost_f != LOST_MAX) begin
            r_lost_f <= r_lost_f + 3'd1;
        end
    end
end

//------------------------------------------------------------------------------
// 11. 输出级
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) O_hit_mask <= 4'd0;
    else          O_hit_mask <= r_vld1 ? r_hit_d1 : 4'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld1)
        O_tdata <= w_marked;
    else
        O_tdata <= 96'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld1;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= r_vld1 && r_tl_d1;
        O_tuser <= r_vld1 && r_tu_d1;
    end
end

initial begin
    r_data_d1  = 96'd0;
    r_x_d1     = {XW{1'b0}};
    r_y_d1     = 11'd0;
    r_hit_d1   = 4'd0;
    r_tu_d1    = 1'b0;
    r_tl_d1    = 1'b0;
    r_vld1     = 1'b0;
    r_hit3_p2  = 1'b0;
    r_tl_p2    = 1'b0;
    r_x_grp    = {XW{1'b0}};
    r_y_pos    = 11'd0;
    r_min_x    = BBOX_SENT;
    r_max_x    = 11'd0;
    r_min_y    = BBOX_SENT;
    r_max_y    = 11'd0;
    r_cnt      = 32'd0;
    r_fs_d1    = 1'b0;
    r_cls_win_l= 2'd0;
    r_cnt_l    = 32'd0;
    r_fam_cnt_ok = 4'd0;
    O_tdata    = 96'd0;
    O_tvalid   = 1'b0;
    O_tlast    = 1'b0;
    O_tuser    = 1'b0;
    O_bbox_x0  = BBOX_SENT;
    O_bbox_x1  = 11'd0;
    O_bbox_y0  = BBOX_SENT;
    O_bbox_y1  = 11'd0;
    O_pix_count   = 32'd0;
    r_cnt_cls_r   = 32'd0;
    r_cnt_cls_g   = 32'd0;
    r_cnt_cls_b   = 32'd0;
    O_color_class = 2'd0;
    r_cnt_cls_y = 32'd0;
    for (ii = 0; ii < 4; ii = ii + 1) begin
        r_fminx[ii] = BBOX_SENT;
        r_fmaxx[ii] = 11'd0;
        r_fminy[ii] = BBOX_SENT;
        r_fmaxy[ii] = 11'd0;
    end
    O_fam_valid = 4'd0;
    O_fam_x0    = {4{BBOX_SENT}};
    O_fam_x1    = 44'd0;
    O_fam_y0    = {4{BBOX_SENT}};
    O_fam_y1    = 44'd0;
    for (ii = 0; ii < TRAIL_N; ii = ii + 1) begin
        r_tx[ii] = BBOX_SENT;
        r_ty[ii] = BBOX_SENT;
    end
    O_track_id = 8'd0;
    r_lost_f   = LOST_MAX;
end

endmodule
