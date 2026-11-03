//==============================================================================
// alg_runlen_bbox.v —— 二维连通带游程滤波包围盒（水平最长连续段 + 垂直连通簇优选）
//
// 解决的核心问题：
//   1. 修复原版行切换（I_y != r_row_y）时未结算行尾活跃段（r_run_on）导致靠右目标丢失的 bug；
//   2. 增加【垂直连通带聚类（2D Connected Band）】：
//      原版把全画面任意一行满足 >= MIN_RUN 的水平段无条件并入全局 min/max，
//      导致背景中哪怕只有 1 行出现水平条纹反光，就会把整个目标框拉大到全屏。
//      新版要求：相邻合格行的间距 <= VGAP_MAX（4 行）且水平区间存在重叠，
//      才归入同一连通目标簇；一帧内若有多个连通簇，自动优选包含合格行数最多（面积最大）
//      的主目标簇输出包围盒，彻底杜绝背景条纹/孤立杂斑拉大颜色框！
//==============================================================================
module alg_runlen_bbox #(
    parameter [10:0] MIN_RUN  = 11'd32,   // 合格段最短水平长度（像素）
    parameter [7:0]  GAP_MAX  = 8'd2,     // 允许跳过的空拍数（每拍4px）
    parameter [15:0] MIN_ROWS = 16'd6     // 合格连通簇最少行数
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_valid,
    input  wire         I_frame_start,
    input  wire         I_hit,
    input  wire [10:0]  I_x_lo,
    input  wire [10:0]  I_x_hi,
    input  wire [10:0]  I_y,
    input  wire         I_roi_en,
    input  wire [10:0]  I_roi_x0,
    input  wire [10:0]  I_roi_x1,
    input  wire [10:0]  I_roi_y0,
    input  wire [10:0]  I_roi_y1,

    output reg  [10:0]  O_x0,
    output reg  [10:0]  O_x1,
    output reg  [10:0]  O_y0,
    output reg  [10:0]  O_y1,
    output reg          O_valid,
    output reg  [15:0]  O_rows
);

    localparam [10:0] SENT     = 11'h7FF;
    localparam [10:0] VGAP_MAX = 11'd6;   // 允许垂直断裂的最大行数

    // ---- 当前行内状态 ----
    reg [10:0] r_row_y;
    reg        r_run_on;
    reg [10:0] r_run_s, r_run_e;
    reg [7:0]  r_gap;
    reg [10:0] r_best_len, r_best_s, r_best_e;

    // ---- 当前垂直连通簇（2D Band）状态 ----
    reg        b_active;
    reg [10:0] b_minx, b_maxx, b_miny, b_maxy;
    reg [15:0] b_rows;

    // ---- 帧内最佳连通簇（Winning Cluster）----
    reg [10:0] a_minx, a_maxx, a_miny, a_maxy;
    reg [15:0] a_rows;

    // ---- 本拍水平段计算 ----
    wire [10:0] w_run_len = (r_run_e >= r_run_s) ? (r_run_e - r_run_s + 11'd1) : 11'd0;
    wire        w_roi_in  = (!I_roi_en)
                         || ((I_x_hi >= I_roi_x0) && (I_x_lo <= I_roi_x1)
                          && (I_y    >= I_roi_y0) && (I_y    <= I_roi_y1));
    wire        w_hit     = I_hit && w_roi_in;
    wire        w_gap_out = (r_gap >= GAP_MAX);
    wire        w_upd_best = r_run_on && (w_run_len > r_best_len) && (r_run_e >= r_run_s);

    // ---- 行结束/帧结束时的完整本行最佳段（含仍在延续的 r_run_on）----
    wire [10:0] w_last_len  = (r_run_on && (r_run_e >= r_run_s)) ? w_run_len : 11'd0;
    wire        w_last_best = (w_last_len > r_best_len);
    wire [10:0] w_fin_len   = w_last_best ? w_last_len : r_best_len;
    wire [10:0] w_fin_s     = w_last_best ? r_run_s    : r_best_s;
    wire [10:0] w_fin_e     = w_last_best ? r_run_e    : r_best_e;
    wire        w_fin_ok    = (r_row_y != SENT) && (w_fin_len >= MIN_RUN) && (w_fin_e >= w_fin_s);

    // ---- 判断本行合格段是否与当前连通簇 b_* 连通（垂直距离 <= VGAP_MAX 且水平重叠）----
    wire        w_v_close   = b_active && (r_row_y >= b_maxy) && ((r_row_y - b_maxy) <= VGAP_MAX);
    wire        w_h_overlap = b_active && ((w_fin_e + 11'd8) >= b_minx) && (w_fin_s <= (b_maxx + 11'd8));
    wire        w_band_cont = w_v_close && w_h_overlap;

    // ---- 若本行延续当前簇，更新后的簇范围 ----
    wire [10:0] w_b_minx_nx = (w_fin_s < b_minx) ? w_fin_s : b_minx;
    wire [10:0] w_b_maxx_nx = (w_fin_e > b_maxx) ? w_fin_e : b_maxx;
    wire [10:0] w_b_miny_nx = (r_row_y < b_miny) ? r_row_y : b_miny;
    wire [10:0] w_b_maxy_nx = (r_row_y > b_maxy) ? r_row_y : b_maxy;
    wire [15:0] w_b_rows_nx = b_rows + 16'd1;

    // ---- 帧末综合结算：比较 b_*（叠加最后一行后）与历史最佳 a_* ----
    wire [10:0] w_end_b_minx = w_fin_ok ? (w_band_cont ? w_b_minx_nx : w_fin_s) : b_minx;
    wire [10:0] w_end_b_maxx = w_fin_ok ? (w_band_cont ? w_b_maxx_nx : w_fin_e) : b_maxx;
    wire [10:0] w_end_b_miny = w_fin_ok ? (w_band_cont ? w_b_miny_nx : r_row_y) : b_miny;
    wire [10:0] w_end_b_maxy = w_fin_ok ? (w_band_cont ? w_b_maxy_nx : r_row_y) : b_maxy;
    wire [15:0] w_end_b_rows = w_fin_ok ? (w_band_cont ? w_b_rows_nx : 16'd1)   : (b_active ? b_rows : 16'd0);

    // 若 w_fin_ok 开启了新簇，旧簇 b_* 可能本身比 a_* 更好
    wire        w_prev_b_wins = b_active && (b_rows >= a_rows) && (b_maxx >= b_minx);
    wire [10:0] w_mid_a_minx  = w_prev_b_wins ? b_minx : a_minx;
    wire [10:0] w_mid_a_maxx  = w_prev_b_wins ? b_maxx : a_maxx;
    wire [10:0] w_mid_a_miny  = w_prev_b_wins ? b_miny : a_miny;
    wire [10:0] w_mid_a_maxy  = w_prev_b_wins ? b_maxy : a_maxy;
    wire [15:0] w_mid_a_rows  = w_prev_b_wins ? b_rows : a_rows;

    wire        w_end_b_wins  = (w_end_b_rows >= w_mid_a_rows) && (w_end_b_rows > 16'd0) && (w_end_b_maxx >= w_end_b_minx);
    wire [10:0] w_out_minx    = w_end_b_wins ? w_end_b_minx : w_mid_a_minx;
    wire [10:0] w_out_maxx    = w_end_b_wins ? w_end_b_maxx : w_mid_a_maxx;
    wire [10:0] w_out_miny    = w_end_b_wins ? w_end_b_miny : w_mid_a_miny;
    wire [10:0] w_out_maxy    = w_end_b_wins ? w_end_b_maxy : w_mid_a_maxy;
    wire [15:0] w_out_rows    = w_end_b_wins ? w_end_b_rows : w_mid_a_rows;
    wire        w_out_valid   = (w_out_rows >= MIN_ROWS) && (w_out_maxx >= w_out_minx);

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_row_y    <= SENT;
            r_run_on   <= 1'b0;
            r_run_s    <= 11'd0;
            r_run_e    <= 11'd0;
            r_gap      <= 8'd0;
            r_best_len <= 11'd0;
            r_best_s   <= 11'd0;
            r_best_e   <= 11'd0;
            b_active   <= 1'b0;
            b_minx     <= SENT;
            b_maxx     <= 11'd0;
            b_miny     <= SENT;
            b_maxy     <= 11'd0;
            b_rows     <= 16'd0;
            a_minx     <= SENT;
            a_maxx     <= 11'd0;
            a_miny     <= SENT;
            a_maxy     <= 11'd0;
            a_rows     <= 16'd0;
            O_x0       <= SENT;
            O_x1       <= 11'd0;
            O_y0       <= SENT;
            O_y1       <= 11'd0;
            O_valid    <= 1'b0;
            O_rows     <= 16'd0;
        end else if (I_frame_start) begin
            O_x0    <= w_out_valid ? w_out_minx : SENT;
            O_x1    <= w_out_valid ? w_out_maxx : 11'd0;
            O_y0    <= w_out_valid ? w_out_miny : SENT;
            O_y1    <= w_out_valid ? w_out_maxy : 11'd0;
            O_rows  <= w_out_rows;
            O_valid <= w_out_valid;

            r_row_y    <= SENT;
            r_run_on   <= 1'b0;
            r_gap      <= 8'd0;
            r_best_len <= 11'd0;
            r_best_s   <= 11'd0;
            r_best_e   <= 11'd0;
            b_active   <= 1'b0;
            b_minx     <= SENT;
            b_maxx     <= 11'd0;
            b_miny     <= SENT;
            b_maxy     <= 11'd0;
            b_rows     <= 16'd0;
            a_minx     <= SENT;
            a_maxx     <= 11'd0;
            a_miny     <= SENT;
            a_maxy     <= 11'd0;
            a_rows     <= 16'd0;
        end else if (I_valid) begin
            if (I_y != r_row_y) begin
                // ---- 行切换：用 w_fin_ok 完整结算上一行（含行尾未关段）----
                if (w_fin_ok) begin
                    if (w_band_cont) begin
                        b_minx <= w_b_minx_nx;
                        b_maxx <= w_b_maxx_nx;
                        b_miny <= w_b_miny_nx;
                        b_maxy <= w_b_maxy_nx;
                        b_rows <= w_b_rows_nx;
                    end else begin
                        if (w_prev_b_wins) begin
                            a_minx <= b_minx;
                            a_maxx <= b_maxx;
                            a_miny <= b_miny;
                            a_maxy <= b_maxy;
                            a_rows <= b_rows;
                        end
                        b_active <= 1'b1;
                        b_minx   <= w_fin_s;
                        b_maxx   <= w_fin_e;
                        b_miny   <= r_row_y;
                        b_maxy   <= r_row_y;
                        b_rows   <= 16'd1;
                    end
                end else if (b_active && (I_y > b_maxy) && ((I_y - b_maxy) > VGAP_MAX)) begin
                    // 垂直空隙超出上限：关闭当前连通簇，若优于最佳簇则晋升
                    if (w_prev_b_wins) begin
                        a_minx <= b_minx;
                        a_maxx <= b_maxx;
                        a_miny <= b_miny;
                        a_maxy <= b_maxy;
                        a_rows <= b_rows;
                    end
                    b_active <= 1'b0;
                end

                // 开启新一行扫描
                r_row_y    <= I_y;
                r_run_on   <= w_hit;
                r_run_s    <= I_x_lo;
                r_run_e    <= I_x_hi;
                r_gap      <= 8'd0;
                r_best_len <= 11'd0;
                r_best_s   <= 11'd0;
                r_best_e   <= 11'd0;
            end else begin
                // ---- 同一行内推进 ----
                if (w_hit) begin
                    if (!r_run_on) begin
                        r_run_on <= 1'b1;
                        r_run_s  <= I_x_lo;
                        r_run_e  <= I_x_hi;
                        r_gap    <= 8'd0;
                    end else begin
                        r_run_e <= I_x_hi;
                        r_gap   <= 8'd0;
                    end
                end else if (r_run_on) begin
                    if (w_gap_out) begin
                        if (w_upd_best) begin
                            r_best_len <= w_run_len;
                            r_best_s   <= r_run_s;
                            r_best_e   <= r_run_e;
                        end
                        r_run_on <= 1'b0;
                        r_gap    <= 8'd0;
                    end else begin
                        r_gap <= r_gap + 8'd1;
                    end
                end
            end
        end
    end

endmodule
