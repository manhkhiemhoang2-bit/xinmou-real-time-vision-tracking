//==============================================================================
// 文件名   : tb_fig5_m5_color_bbox.v
// 对应报告 : 图 5 —— M5 相对饱和度比例判色与二维连通带统计 RTL 仿真测试平台
// 仿真对象 : alg_color_gate.v (REL_MODE=1) + alg_runlen_bbox.v (MIN_RUN=32, GAP_MAX=2, MIN_ROWS=6)
// 运行方法 : 在 ModelSim Transcript 窗口执行: do run_fig5_m5.do
//==============================================================================
`timescale 1ns / 1ps

module tb_fig5_m5_color_bbox;

    // 44.996 MHz 像素处理时钟 (周期约 22.22 ns，此处取 22.2 ns)
    reg         clk;
    reg         rst_n;
    initial clk = 1'b0;
    always #11.1 clk = ~clk;

    // 单拍四像素 RGB 输入与坐标信号
    reg         pix_valid;
    reg         frame_start;
    reg  [10:0] row_y;
    reg  [10:0] x_base;       // 当前拍起始像素横坐标 (步进 4)
    reg  [7:0]  in_r, in_g, in_b;

    // 1. 例化增强型相对饱和度与比例判色门 (REL_MODE = 1)
    wire        hit_r, hit_g, hit_b, hit_g_auto;
    alg_color_gate #(
        .REL_MODE    (1'b1),
        .REL_ABS_MIN (8'd45),
        .REL_SAT_MIN (8'd30),
        .REL_MARGIN  (8'd12)
    ) u_color_gate (
        .I_r          (in_r),
        .I_g          (in_g),
        .I_b          (in_b),
        .O_hit_r      (hit_r),
        .O_hit_g      (hit_g),
        .O_hit_b      (hit_b),
        .O_hit_g_auto (hit_g_auto)
    );

    // 单拍四像素命中区间 [x_lo, x_hi]
    wire [10:0] x_lo = x_base;
    wire [10:0] x_hi = x_base + 11'd3;

    // 2. 例化二维垂直连通带游程包围盒模块
    wire [10:0] bbox_x0, bbox_x1, bbox_y0, bbox_y1;
    wire        bbox_valid;
    wire [15:0] bbox_rows;

    alg_runlen_bbox #(
        .MIN_RUN  (11'd32),   // 行内有效连续段最小宽度 32 px (8 拍)
        .GAP_MAX  (8'd2),     // 行内高光反光空洞最大桥接拍数 2 拍 (8 px)
        .MIN_ROWS (16'd6)     // 垂直连通簇最少有效行数 6 行
    ) u_runlen_bbox (
        .I_clk         (clk),
        .I_rst_n       (rst_n),
        .I_valid       (pix_valid),
        .I_frame_start (frame_start),
        .I_hit         (hit_r),
        .I_x_lo        (x_lo),
        .I_x_hi        (x_hi),
        .I_y           (row_y),
        .I_roi_en      (1'b0),
        .I_roi_x0      (11'd0),
        .I_roi_x1      (11'd1279),
        .I_roi_y0      (11'd0),
        .I_roi_y1      (11'd719),
        .O_x0          (bbox_x0),
        .O_x1          (bbox_x1),
        .O_y0          (bbox_y0),
        .O_y1          (bbox_y1),
        .O_valid       (bbox_valid),
        .O_rows        (bbox_rows)
    );

    // 像素扫描辅助任务：扫描一行中的若干拍
    task send_beat(
        input [10:0] y,
        input [10:0] x,
        input [7:0]  r,
        input [7:0]  g,
        input [7:0]  b
    );
    begin
        @(posedge clk);
        pix_valid   <= 1'b1;
        frame_start <= 1'b0;
        row_y       <= y;
        x_base      <= x;
        in_r        <= r;
        in_g        <= g;
        in_b        <= b;
    end
    endtask

    integer r_idx, b_idx;

    initial begin
        rst_n       = 1'b0;
        pix_valid   = 1'b0;
        frame_start = 1'b0;
        row_y       = 11'd0;
        x_base      = 11'd0;
        in_r        = 8'd0;
        in_g        = 8'd0;
        in_b        = 8'd0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 发出帧首同步脉冲
        @(posedge clk);
        pix_valid   <= 1'b1;
        frame_start <= 1'b1;
        @(posedge clk);
        frame_start <= 1'b0;
        pix_valid   <= 1'b0;

        //======================================================================
        // 阶段 1 (Row 2)：背景高亮度白墙 (210,205,200) + 孤立 2 拍(8px)红杂点
        //   预期：白墙因 3*(max-min)<max 被 hit_r=0 滤除；8px 红杂点在间隔 3 拍后
        //         触发 w_gap_out 关段，且因 w_run_len=8 < MIN_RUN(32) 被直接丢弃
        //======================================================================
        send_beat(11'd2, 11'd100, 8'd210, 8'd205, 8'd200); // 白墙反光 -> 不命中
        send_beat(11'd2, 11'd104, 8'd210, 8'd205, 8'd200);
        send_beat(11'd2, 11'd108, 8'd200, 8'd45,  8'd40);  // 孤立红杂点 1 (4px)
        send_beat(11'd2, 11'd112, 8'd200, 8'd45,  8'd40);  // 孤立红杂点 2 (累计8px)
        send_beat(11'd2, 11'd116, 8'd80,  8'd80,  8'd80);  // r_gap = 1
        send_beat(11'd2, 11'd120, 8'd80,  8'd80,  8'd80);  // r_gap = 2
        send_beat(11'd2, 11'd124, 8'd80,  8'd80,  8'd80);  // w_gap_out=1 -> 关段(8px<32px 滤除)

        //======================================================================
        // 阶段 2 (Row 10 ~ Row 15，共 6 行)：扫描真实红色目标物块 (X = 460 .. 503, 宽 44px)
        //   其中在 X=476 处插入 1 拍表面反光白点 (230,225,220)，验证 r_gap=1 <= GAP_MAX(2)
        //   高光空洞自动桥接，段长连续累加至 44 px >= MIN_RUN(32)，且 b_rows 累加至 6 行
        //======================================================================
        for (r_idx = 10; r_idx <= 15; r_idx = r_idx + 1) begin
            send_beat(r_idx[10:0], 11'd452, 8'd70,  8'd72,  8'd70); // 左侧背景
            send_beat(r_idx[10:0], 11'd456, 8'd70,  8'd72,  8'd70);
            for (b_idx = 0; b_idx < 11; b_idx = b_idx + 1) begin
                if (b_idx == 4) begin
                    // 物块表面高光反光空洞 (1 拍 4px 未命中，被 r_gap=1 桥接)
                    send_beat(r_idx[10:0], 11'd460 + b_idx*4, 8'd235, 8'd230, 8'd228);
                end else begin
                    // 红色物块有效像素 (R=210, G=42, B=38 -> 满足 3*sat>=mx & 5R>=8G+12)
                    send_beat(r_idx[10:0], 11'd460 + b_idx*4, 8'd210, 8'd42,  8'd38);
                end
            end
            send_beat(r_idx[10:0], 11'd504, 8'd70,  8'd72,  8'd70); // 右侧背景
            send_beat(r_idx[10:0], 11'd508, 8'd70,  8'd72,  8'd70);
        end

        // 切换到 Row 25 (超出 VGAP_MAX=6) 触发当前簇结算并晋升至帧内最佳簇 a_*
        send_beat(11'd25, 11'd100, 8'd60, 8'd60, 8'd60);
        send_beat(11'd25, 11'd104, 8'd60, 8'd60, 8'd60);

        // 发出下一帧帧首脉冲，锁存输出 O_x0, O_x1, O_y0, O_y1, O_valid, O_rows
        @(posedge clk);
        pix_valid   <= 1'b1;
        frame_start <= 1'b1;
        @(posedge clk);
        frame_start <= 1'b0;
        pix_valid   <= 1'b0;

        repeat (6) @(posedge clk);
        $display("================================================================");
        $display("[PASS] M5 BBox Simulation Result: valid=%b, rows=%0d, X=[%0d..%0d], Y=[%0d..%0d]",
                 bbox_valid, bbox_rows, bbox_x0, bbox_x1, bbox_y0, bbox_y1);
        $display("================================================================");
        $stop;
    end

endmodule
