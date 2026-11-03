//==============================================================================
// tb_isp_top.v —— `isp_top` **整层**集成仿真测试平台（2026-09-28 建）
//
// 为什么需要它：
//   57 个既有 TB 里**没有一个**例化过 isp_top。零件（alg_top / osd_mixer / histeq）
//   都各自全尺寸验过 4135 万条断言，但"**把它们装成一整台跑一遍**"从没做过。
//   而集成接线 bug 恰恰是仿真最好抓、上板最难抓的一类
//   （上板只能看到"画面不对"，反推不出哪两根线接错）。
//
// 本 TB 的验证策略（关键：**不要求**知道 demosaic/awb 算得对不对）：
//   厂商模块（demosaic / awb / BILINEAR 等）**没有金标准模型**，所以不能逐像素比。
//   改为四条**结构性判据 + 一条交叉验证**（判据在 check_isp_top.py 里实现）：
//
//     J1  流结构：输入有效拍数 == 输出有效拍数（每帧 1 个 tuser、每行 1 个 tlast）
//     J2  无 X 传播：O_tvalid 为 1 时 O_tdata 不含 X/Z
//     J3  帧/行计数：tuser 数 == 帧数、tlast 数 == 帧数×720
//     J4  延迟口径：lat_measure 报出的 LAT 应等于文档值（M0..M6 = 7，M7 = 10）
//     J5  ★交叉验证：把 isp_top **内部 alg_top 的输入流** dump 出来，
//         喂给**已经全尺寸验过的** alg_top 单体测试台，输出须逐位相同。
//         —— 这条绕开了"没有厂商金标准"的困难：不需要知道 demosaic 算得对不对，
//            只需要证明"经过整串之后，喂给 alg_top 的数据和它单独测时一致"。
//
// 数据来源：
//   输入侧用 `stim_top_full.hex`（与 tb_alg_top_full 同一份激励）**降级**成 RAW10：
//   本 TB 的输入端口是 40 位 I_tdata（MIPI 侧），而 stim 是 96 位（算法侧）。
//   ⇒ 见 tb 里的 `raw10_of()`：把 96 位拍流按"每拍 4 像素取第 0 像素的 R 通道"
//     之外的做法**不可行**（demosaic 需要完整 Bayer 图案）。
//   ⇒ 改用**合成 Bayer**：直接造 BGGR 图案喂进去，只验结构（J1~J3）与延迟（J4），
//     不做像素级比对。像素级正确性由 J5 的交叉验证负责。
//
// ⚠ 全部 $display / 注释用英文：ModelSim 10.3c 的 transcript 显示不了中文。
//==============================================================================
`timescale 1ns/1ps

module tb_isp_top;

    //--------------------------------------------------------------------------
    // 参数（必须与 isp_top 例化及文档一致）
    //--------------------------------------------------------------------------
    localparam IMG_W      = 1280;
    localparam IMG_H      = 720;
    localparam FRAMES     = 2;             // 先跑 2 帧（整层很慢，先证明通）
    localparam CLK_HALF   = 8;             // 60MHz -> 16.668ns 周期

    localparam RAW_BEATS  = IMG_W / 2;     // RAW10 2 像素/拍 = 640 拍/行
    localparam LINE_GAP   = 20;            // 行消隐
    localparam FRAME_GAP  = 100;           // 帧消隐
    localparam TAIL_CYC   = 2000;          // 收尾拍数（等输出流走完）

    //--------------------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    reg rst_n = 1'b0;
    reg [31:0] cyc = 32'd0;

    //--------------------------------------------------------------------------
    // 输入侧：合成 BGGR Bayer 图
    //   demosaic 的参数是 BAYER_MODE("BGGR")、IMG_WIDTH(1280)、IMG_HEIGHT(720)
    //   每拍送 2 个 RAW10 像素（I_tdata[19:0] 和 [39:20] 各 10 位）
    //   图案：B G / G R 循环（BGGR 的 2x2 单元）
    //--------------------------------------------------------------------------
    wire [39:0] drv_tdata;
    wire        drv_tvalid;
    wire        drv_tlast;
    wire        drv_tuser;

    reg [31:0]  beat_in_line;
    reg [31:0]  line_idx;
    reg [31:0]  frame_idx;
    reg [31:0]  gap_left;
    reg         run_en;

    wire last_beat_of_frame = (frame_idx == FRAMES - 1) &&
                              (line_idx  == IMG_H - 1) &&
                              (beat_in_line == RAW_BEATS - 1);

    // Bayer 像素值：用坐标函数造，保证相邻像素有梯度（便于观察边缘）
    function [9:0] bayer_pix(input [10:0] x, input [9:0] y);
        begin
            // BGGR: (x+y) even -> B 或 R 取决于行；简单起见用亮度梯度+色彩偏移
            bayer_pix = ( (y[2:0] == 3'd0) ? 10'd64  :        // 每 8 行一条暗带
                          (x[3:0] <  4'd8) ? 10'd768 :        // 每 16 列一条亮带
                                             (10'd128 + {x[3:0], 6'd0}) );
        end
    endfunction

    wire [10:0] pix_x0 = {beat_in_line[8:0], 1'b0};        // 拍内第 0 像素的列号
    wire [10:0] pix_x1 = pix_x0 + 11'd1;
    wire [9:0]  pix_y  = line_idx[9:0];

    assign drv_tdata[19:0]  = {22'd0, bayer_pix(pix_x0, pix_y)};
    assign drv_tdata[39:20] = {22'd0, bayer_pix(pix_x1, pix_y)};

    wire drv_run   = run_en && (gap_left == 32'd0);
    assign drv_tvalid = drv_run;
    assign drv_tlast  = drv_run && (beat_in_line == RAW_BEATS - 1);
    assign drv_tuser  = drv_run && (beat_in_line == 32'd0) && (line_idx == 32'd0);

    always @ (posedge clk) begin
        if (!rst_n) begin
            cyc          <= 32'd0;
            beat_in_line <= 32'd0;
            line_idx     <= 32'd0;
            frame_idx    <= 32'd0;
            gap_left     <= 32'd0;
            run_en       <= 1'b0;
        end else begin
            cyc <= cyc + 32'd1;

            if (!run_en) begin
                if (cyc == 32'd20) run_en <= 1'b1;      // 复位释放后开跑
            end else if (gap_left != 32'd0) begin
                gap_left <= gap_left - 32'd1;
            end else if (frame_idx < FRAMES) begin
                if (beat_in_line == RAW_BEATS - 1) begin
                    beat_in_line <= 32'd0;
                    if (line_idx == IMG_H - 1) begin
                        line_idx  <= 32'd0;
                        frame_idx <= frame_idx + 32'd1;
                        gap_left  <= (last_beat_of_frame && (frame_idx == FRAMES-1))
                                     ? (LINE_GAP + FRAME_GAP) : LINE_GAP;
                    end else begin
                        line_idx <= line_idx + 32'd1;
                        gap_left <= LINE_GAP;
                    end
                end else begin
                    beat_in_line <= beat_in_line + 32'd1;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 复位：前 3 拍低
    //--------------------------------------------------------------------------
    always @ (posedge clk) begin
        if (cyc >= 32'd3) rst_n <= 1'b1;
    end

    //--------------------------------------------------------------------------
    // 按键：本跑不做按键循环（mode 用默认），两个 key 都保持"松开"（高）
    //--------------------------------------------------------------------------
    wire I_mode_key = 1'b1;
    wire I_he_key   = 1'b1;
    wire O_tready   = 1'b1;             // 无反压（与 tb_alg_top_full 同口径）

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    wire [127:0] O_tdata;
    wire         O_tlast, O_tuser, O_tvalid, I_tready;
    wire [10:0]  O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1;
    wire         O_bbox_valid;
    wire [31:0]  O_pix_count;
    wire [2:0]   O_mode;

    isp_top u_dut (
        .axi4s_video_aclk (clk        ),
        .I_rst_n          (rst_n      ),
        .I_tlast          (drv_tlast  ),
        .I_tuser          (drv_tuser  ),
        .I_tdata          (drv_tdata  ),
        .I_tvalid         (drv_tvalid ),
        .I_tdest          (10'd0      ),
        .O_tready         (O_tready   ),
        .O_tdata          (O_tdata    ),
        .O_tlast          (O_tlast    ),
        .O_tuser          (O_tuser    ),
        .O_tvalid         (O_tvalid   ),
        .I_tready         (I_tready   ),
        .O_bbox_x0        (O_bbox_x0  ),
        .O_bbox_x1        (O_bbox_x1  ),
        .O_bbox_y0        (O_bbox_y0  ),
        .O_bbox_y1        (O_bbox_y1  ),
        .O_bbox_valid     (O_bbox_valid),
        .O_pix_count      (O_pix_count),
        .O_mode           (O_mode     ),
        .I_mode_key       (I_mode_key ),
        .I_he_key         (I_he_key   )
    );

    //--------------------------------------------------------------------------
    // 计数与 dump（每拍一行，只记需要的字段）
    //--------------------------------------------------------------------------
    integer fd;
    integer n_in_beat, n_out_beat, n_out_last, n_out_user;
    integer n_x_leak;
    integer tail_cnt;
    reg     finished;

    initial begin
        fd = $fopen("dump_isp_top.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_isp_top.txt");
            $finish;
        end
        n_in_beat = 0; n_out_beat = 0; n_out_last = 0; n_out_user = 0;
        n_x_leak = 0; tail_cnt = 0; finished = 1'b0;
    end

    always @ (posedge clk) begin
        if (rst_n && !finished) begin
            // 字段：cyc | in(tvalid,tlast,tuser) | out(tvalid,tlast,tuser,mode,tdata)
            //       | bbox_valid,pix_count,x0,x1,y0,y1 | n_in_beat      = 15 项
            $fwrite(fd, "%0d %b %b %b %b %b %b %b %h %d %d %d %d %d %d %d\n",
                    cyc,
                    drv_tvalid, drv_tlast, drv_tuser,
                    O_tvalid, O_tlast, O_tuser, O_mode,
                    O_tdata,
                    O_bbox_valid, O_pix_count,
                    O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1,
                    n_in_beat);

            if (drv_tvalid)  n_in_beat  = n_in_beat  + 1;
            if (O_tvalid)    n_out_beat = n_out_beat + 1;
            if (O_tvalid && O_tlast) n_out_last = n_out_last + 1;
            if (O_tvalid && O_tuser) n_out_user = n_out_user + 1;
            if (O_tvalid && (^O_tdata === 1'bx)) n_x_leak = n_x_leak + 1;

            // 收尾：输入流结束后再等 TAIL_CYC 拍
            if (frame_idx >= FRAMES) tail_cnt = tail_cnt + 1;
            else                     tail_cnt = 0;

            if (tail_cnt >= TAIL_CYC) begin
                finished = 1'b1;
                $fclose(fd);
                $display("TB: done, cyc=%0d in_beats=%0d out_beats=%0d out_tlast=%0d out_tuser=%0d x_leak=%0d",
                         cyc, n_in_beat, n_out_beat, n_out_last, n_out_user, n_x_leak);
                $display("TB: expect in_beats=%0d (2*%0d*%0d)", FRAMES*IMG_H*RAW_BEATS, FRAMES*IMG_H, RAW_BEATS);
                $display("TB: expect out_tlast=%0d out_tuser=%0d", FRAMES*IMG_H, FRAMES);
                if (n_in_beat == n_out_beat && n_out_user == FRAMES && n_x_leak == 0)
                    $display("TB: selfcheck RESULT=PASS");
                else
                    $display("TB: selfcheck RESULT=FAIL");
                $finish;
            end
        end
    end

    // 超时保护
    initial begin
        #(CLK_HALF * 2 * 40000000);
        $display("TB: TIMEOUT at cyc=%0d", cyc);
        $fclose(fd);
        $finish;
    end

endmodule
