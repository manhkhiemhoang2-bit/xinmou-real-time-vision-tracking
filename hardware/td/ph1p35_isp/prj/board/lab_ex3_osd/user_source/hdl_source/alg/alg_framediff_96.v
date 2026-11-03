//==============================================================================
// 文件名   : alg_framediff_96.v
// 模块名   : alg_framediff_96
// 描述     : 96-bit AXI4-Stream 算法通道 · M6 帧差法运动目标检测（8x8 整块高亮增强版）
//
// 改进说明（解决运动检测不明显、红框易受单格噪点干扰的问题）：
//   1. 原版 O_motion_pix0 仅在采样行（y%8==0）且偶拍（x_grp%2==0）拉高 1 拍，
//      在 alg_top 中又只点亮 pix0（即 8×8=64 像素中仅点亮 1 个像素，占比 1/64，肉眼极难看清）。
//   2. 新版（当 NORM=1 板级模式时）：
//      - 新增 160-bit 行运动状态保持寄存器 r_row_mot[0:CX-1]（仅耗 160 个触发器，0 ERAM），
//        在采样行 y%8==0 将每个 8×8 网格的运动判决锁存并保持整整 8 行（y%8 == 0..7）及奇偶两拍；
//      - 配合 alg_top 4 像素全点亮，使每个运动 8×8 网格完整 64 像素全部高亮为鲜绿色（亮度提升 64 倍！）；
//      - 引入水平相邻格验证（r_prev_mot）：包围盒仅在连续 >=2 个相邻运动格（>=16px）出现时才扩展，
//        彻底滤除孤立单格传感器噪点把运动红框撑大的问题。
//==============================================================================

module alg_framediff_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter [7:0] DIFF_TH = 8'd24,
    parameter        NORM   = 1'b0,
    parameter integer DS    = 8
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tuser,
    input  wire         I_tready,
    output wire         O_tready,
    output reg          O_motion_pix0,
    output wire [31:0]  O_frame_motion_cnt,
    output reg  [31:0]  O_motion_cnt,
    output reg  [10:0]  O_motion_bbox_x0,
    output reg  [10:0]  O_motion_bbox_x1,
    output reg  [10:0]  O_motion_bbox_y0,
    output reg  [10:0]  O_motion_bbox_y1,
    output reg          O_motion_valid
);

localparam BEATS_PER_LINE = IMG_WIDTH >> 2;
localparam XW  = $clog2(BEATS_PER_LINE);
localparam CX  = IMG_WIDTH  / 8;
localparam CY  = IMG_HEIGHT / 8;
localparam DEPTH = CX * CY;
localparam AW  = $clog2(DEPTH);
localparam [XW-1:0] LAST_BEAT    = BEATS_PER_LINE - 1;
localparam [10:0]   LAST_ROW     = IMG_HEIGHT - 1;
localparam [10:0]   LAST_SMP_ROW = (CY - 1) * 8;
localparam [10:0]   LAST_SMP_X   = (CX - 1) * 8;
localparam [10:0]   BBOX_SENT    = 11'h7FF;
localparam [AW-1:0] CX_AW        = CX;

assign O_tready = I_tready;

//------------------------------------------------------------------------------
// 1. 存储阵列（单写口 + 单读口，同钟简单双口）
//------------------------------------------------------------------------------
reg [8:0] r_prev_mem [0:DEPTH-1];   //synthesis ram_style = bram

//------------------------------------------------------------------------------
// 2. 寄存器声明
//------------------------------------------------------------------------------
reg [XW-1:0] r_x_grp;
reg [10:0]   r_y_pos;
reg [AW-1:0] r_row_base;

reg [AW-1:0] r_wr_addr;
reg          r_wr_en;
reg [8:0]    r_cur;
reg [8:0]    r_prev;
reg [7:0]    r_m_run;
reg          r_smp_d1;
reg [10:0]   r_smp_x;
reg [10:0]   r_smp_y;
reg [XW-1:0] r_xg_d1;

reg          r_vld1;
reg          r_tu_d1;
reg          r_mem_full;

// ★8×8 整块高亮保持寄存器与相邻格滤波
reg [CX-1:0] r_row_mot;
reg          r_prev_mot;
reg [10:0]   r_prev_mot_x;

reg [10:0]   r_min_x, r_max_x;
reg [10:0]   r_min_y, r_max_y;
reg [31:0]   r_cnt;

//------------------------------------------------------------------------------
// 3. 采样判定与组合逻辑
//------------------------------------------------------------------------------
wire w_smp = I_tvalid && (r_x_grp[0] == 1'b0) && (r_y_pos[2:0] == 3'd0);

wire w_smp_row_start = w_smp && (r_x_grp == {XW{1'b0}});
wire [AW-1:0] w_row_base = I_tuser ? {AW{1'b0}}
                         : (w_smp_row_start ? (r_row_base + CX_AW) : r_row_base);

wire [AW-1:0] w_smp_cx   = {{(AW-XW+1){1'b0}}, r_x_grp[XW-1:1]};
wire [AW-1:0] w_smp_addr = w_row_base + w_smp_cx;

/* 每个采样拍取 4 个灰度像素均值，单个感光噪点不再代表整个 8x8 网格。 */
wire [9:0] w_gray_sum = {2'b00, I_tdata[95:88]}
                       + {2'b00, I_tdata[71:64]}
                       + {2'b00, I_tdata[47:40]}
                       + {2'b00, I_tdata[23:16]};
wire [10:0] w_gray_round = {1'b0, w_gray_sum} + 11'd2;
wire [7:0] w_gray_p0 = w_gray_round[9:2];

wire [7:0] w_m_err_up = (w_gray_p0 > r_m_run) ? (w_gray_p0 - r_m_run) : 8'd0;
wire [7:0] w_m_err_dn = (r_m_run > w_gray_p0) ? (r_m_run - w_gray_p0) : 8'd0;
wire [8:0] w_m_up9    = {1'b0, w_m_err_up} + 9'd8;
wire [8:0] w_m_dn9    = {1'b0, w_m_err_dn} + 9'd8;
wire [7:0] w_m_stp_up = {3'b0, w_m_up9[8:4]};
wire [7:0] w_m_stp_dn = {3'b0, w_m_dn9[8:4]};
wire [7:0] w_m_run_nx = (w_gray_p0 >= r_m_run) ? (r_m_run + w_m_stp_up)
                                               : (r_m_run - w_m_stp_dn);
wire [8:0] w_gray_nx  = (w_gray_p0 >= r_m_run) ? {1'b0, (w_gray_p0 - r_m_run)}
                                               : (~{1'b0, (r_m_run - w_gray_p0)} + 9'd1);
wire [8:0] w_wr_val   = NORM ? w_gray_nx : {1'b0, w_gray_p0};

wire [9:0] w_d10    = {r_cur[8], r_cur} - {r_prev[8], r_prev};
wire [9:0] w_diff   = w_d10[9] ? (~w_d10 + 10'd1) : w_d10;
wire       w_motion = r_mem_full && (w_diff > {2'b0, DIFF_TH});

// 板级显示要求水平相邻两格同时运动；孤立强噪点也不能直接点亮。
wire       w_mot_pair   = w_motion && r_prev_mot && (r_smp_x > 11'd0);
wire       w_mot_vis    = NORM ? w_mot_pair : w_motion;
wire       w_mot_bb     = NORM ? w_mot_pair                   : w_motion;

wire w_frame_start = r_vld1 && r_tu_d1;
wire w_last_smp_d  = r_smp_d1 && (r_smp_y == LAST_SMP_ROW) && (r_smp_x == LAST_SMP_X);

//------------------------------------------------------------------------------
// 4. 阵列本体
//------------------------------------------------------------------------------
always @ (posedge I_clk) begin
    if (r_wr_en)
        r_prev_mem[r_wr_addr] <= r_cur;
end

always @ (posedge I_clk) begin
    if (w_smp)
        r_prev <= r_prev_mem[w_smp_addr];
end

//------------------------------------------------------------------------------
// 5. 采样/判决流水寄存器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_wr_addr <= {AW{1'b0}};
    else
        r_wr_addr <= w_smp_addr;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_wr_en <= 1'b0;
    else
        r_wr_en <= w_smp;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cur <= 9'd0;
    else
        r_cur <= w_wr_val;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_m_run <= 8'd128;
    else if (w_smp && NORM)
        r_m_run <= w_m_run_nx;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_d1 <= 1'b0;
    else
        r_smp_d1 <= w_smp;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_x <= 11'd0;
    else
        r_smp_x <= {r_x_grp, 2'b00};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_y <= 11'd0;
    else
        r_smp_y <= r_y_pos;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_xg_d1 <= {XW{1'b0}};
    else
        r_xg_d1 <= r_x_grp;
end

// ★记录同行上一格是否运动，以及本采样行 160 个 8×8 网格的运动掩码（保持 8 行）
wire [7:0] w_cur_gx = r_xg_d1[XW-1:1];

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_prev_mot   <= 1'b0;
        r_prev_mot_x <= 11'd0;
        r_row_mot    <= {CX{1'b0}};
    end else if (w_frame_start) begin
        r_prev_mot   <= (r_smp_d1 && w_motion);
        r_prev_mot_x <= r_smp_x;
        r_row_mot    <= {CX{1'b0}};
    end else if (r_smp_d1) begin
        r_prev_mot              <= (r_smp_x == 11'd0) ? w_motion : w_motion;
        r_prev_mot_x            <= r_smp_x;
        r_row_mot[r_smp_x[10:3]]<= w_mot_vis;
        if (w_mot_pair && (r_smp_x >= 11'd8))
            r_row_mot[r_smp_x[10:3] - 8'd1] <= 1'b1;
    end
end

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
// 7. 行基址推进
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_row_base <= {AW{1'b0}};
    else if (w_smp_row_start)
        r_row_base <= w_row_base;
end

//------------------------------------------------------------------------------
// 8. 帧边界寄存器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_tu_d1 <= 1'b0;
    else if (I_tvalid)
        r_tu_d1 <= I_tuser;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_mem_full <= 1'b0;
    else if (w_last_smp_d)
        r_mem_full <= 1'b1;
end

//------------------------------------------------------------------------------
// 9. 帧内累加（运动格子数 + 抗噪运动 bbox）
//------------------------------------------------------------------------------
wire [10:0] w_pair_x0 = (NORM && (r_smp_x >= 11'd8)) ? (r_smp_x - 11'd8) : r_smp_x;

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_x <= BBOX_SENT;
    else if (w_frame_start)
        r_min_x <= (r_smp_d1 && w_mot_bb) ? w_pair_x0 : BBOX_SENT;
    else if (r_smp_d1 && w_mot_bb && (w_pair_x0 < r_min_x))
        r_min_x <= w_pair_x0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_x <= 11'd0;
    else if (w_frame_start)
        r_max_x <= (r_smp_d1 && w_mot_bb) ? (r_smp_x + 11'd7) : 11'd0;
    else if (r_smp_d1 && w_mot_bb && ((r_smp_x + 11'd7) > r_max_x))
        r_max_x <= r_smp_x + 11'd7;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_y <= BBOX_SENT;
    else if (w_frame_start)
        r_min_y <= (r_smp_d1 && w_mot_bb) ? r_smp_y : BBOX_SENT;
    else if (r_smp_d1 && w_mot_bb && (r_smp_y < r_min_y))
        r_min_y <= r_smp_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_y <= 11'd0;
    else if (w_frame_start)
        r_max_y <= (r_smp_d1 && w_mot_bb) ? (r_smp_y + 11'd7) : 11'd0;
    else if (r_smp_d1 && w_mot_bb && ((r_smp_y + 11'd7) > r_max_y))
        r_max_y <= r_smp_y + 11'd7;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt <= 32'd0;
    else if (w_frame_start)
        r_cnt <= (r_smp_d1 && w_motion) ? 32'd1 : 32'd0;
    else if (r_smp_d1 && w_motion)
        r_cnt <= r_cnt + 32'd1;
end

assign O_frame_motion_cnt = r_cnt;

//------------------------------------------------------------------------------
// 10. 输出级
//     ★当 NORM=1（板级模式）时，O_motion_pix0 在整个 8×8 网格的 8 行×2 拍内持续拉高！
//       当 NORM=0（仿真回归模式）时，保持原单拍脉冲语义。
//------------------------------------------------------------------------------
wire w_blk_mot = r_smp_d1 ? w_mot_vis : r_row_mot[w_cur_gx];

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_pix0 <= 1'b0;
    else if (NORM)
        O_motion_pix0 <= r_vld1 && w_blk_mot;
    else
        O_motion_pix0 <= r_smp_d1 && w_motion;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_cnt <= 32'd0;
    else if (w_frame_start)
        O_motion_cnt <= r_cnt;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_x0 <= BBOX_SENT;
    else if (w_frame_start)
        O_motion_bbox_x0 <= r_min_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_x1 <= 11'd0;
    else if (w_frame_start)
        O_motion_bbox_x1 <= r_max_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_y0 <= BBOX_SENT;
    else if (w_frame_start)
        O_motion_bbox_y0 <= r_min_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_y1 <= 11'd0;
    else if (w_frame_start)
        O_motion_bbox_y1 <= r_max_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_valid <= 1'b0;
    else if (w_frame_start)
        O_motion_valid <= NORM ? ((r_cnt >= 32'd3) && (r_max_x >= r_min_x)) : (r_cnt != 32'd0);
end

initial begin
    r_x_grp       = {XW{1'b0}};
    r_y_pos       = 11'd0;
    r_row_base    = {AW{1'b0}};
    r_wr_addr     = {AW{1'b0}};
    r_wr_en       = 1'b0;
    r_cur         = 9'd0;
    r_m_run       = 8'd128;
    r_smp_d1      = 1'b0;
    r_smp_x       = 11'd0;
    r_smp_y       = 11'd0;
    r_xg_d1       = {XW{1'b0}};
    r_vld1        = 1'b0;
    r_tu_d1       = 1'b0;
    r_mem_full    = 1'b0;
    r_row_mot     = {CX{1'b0}};
    r_prev_mot    = 1'b0;
    r_prev_mot_x  = 11'd0;
    r_min_x       = BBOX_SENT;
    r_max_x       = 11'd0;
    r_min_y       = BBOX_SENT;
    r_max_y       = 11'd0;
    r_cnt         = 32'd0;
    O_motion_pix0 = 1'b0;
    O_motion_cnt  = 32'd0;
    O_motion_bbox_x0 = BBOX_SENT;
    O_motion_bbox_x1 = 11'd0;
    O_motion_bbox_y0 = BBOX_SENT;
    O_motion_bbox_y1 = 11'd0;
    O_motion_valid   = 1'b0;
end

endmodule
