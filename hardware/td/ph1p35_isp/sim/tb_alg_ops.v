//==============================================================================
// tb_alg_ops.v —— M2/M3/M4 三个窗口算子（alg_binarize_96 / alg_sobel_96 /
//                alg_smooth_96）的 ModelSim 测试平台
//
// 级联结构（与 S1第二批_接口冻结.md §1 的架构一致）：
//     stim_alg.hex ─► win3x3_96 ─┬─► alg_binarize_96 ─► O_bin
//                                 ├─► alg_sobel_96    ─► O_sob
//                                 └─► alg_smooth_96   ─► O_smo
//     原始彩色拍流 ─► TB 自己做 1 行延迟 ─► I_rgb_center（96bit = 第 y-1 行的 4 个 RGB888）
//
// 本 TB 只产生激励 + 逐周期记录，**不做任何判定**；判定全部在 check_alg_ops.py。
// 这样"期望值"只依赖规格（alg_ref.py 金标准 + 冻结文档 §3 的位序），
// 不依赖这份 RTL 的任何实现细节。
//
// 记录格式 dump_alg.txt（每行一拍，空格分隔）：
//   cyc beat_idx bix2 drv_valid
//   I_tvalid I_tlast I_tuser I_window_valid I_window I_rgb_center
//   bin  bin_v bin_l bin_u
//   sob  sob_v sob_l sob_u
//   smo  smo_v smo_l smo_u
// %h 打印会把 X/Z 原样显示成 x/z —— 这是 X 传播检查的依据。
//
// ⚠ 全部 $display / 注释用英文，因为 ModelSim 10.3c 的 transcript 显示不了中文。
//==============================================================================
`timescale 1ns / 1ps

module tb_alg_ops;

    localparam IMG_WIDTH  = 32;
    localparam IMG_HEIGHT = 8;
    localparam BPL        = IMG_WIDTH / 4;                // 8 拍/行
    localparam FRAMES     = 3;                            // 跑 3 帧（行缓存稳态纪律）
    localparam BPF        = BPL * IMG_HEIGHT;             // 64 拍/帧
    localparam NBEAT      = BPF * FRAMES;                 // 192 拍
    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;
    localparam TAIL_CYC   = 24;
    localparam GAP_AT     = 41;                           // 在这里插气泡（测 C-4）
    localparam GAP_LEN    = 3;

    //------------------------------------------------------------------
    // 时钟
    //------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                                 // 10ns

    //------------------------------------------------------------------
    // 激励
    //------------------------------------------------------------------
    reg [95:0] stim_g [0:NBEAT-1];                        // 灰度拍（喂 win3x3_96）
    reg [95:0] stim_r [0:NBEAT-1];                        // 原始 RGB 拍（喂行延迟）

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg        rst_n;

    // 气泡：按拍插入（不能用 beat_idx 判，否则 beat_idx 冻住后再也走不出来）
    wire in_gap    = (cyc >= (START_CYC + GAP_AT)) && (cyc < (START_CYC + GAP_AT + GAP_LEN));
    wire drv_valid = (cyc >= START_CYC) && (beat_idx < NBEAT) && !in_gap;

    wire [95:0] I_tdata = drv_valid ? stim_g[beat_idx] : 96'd0;
    wire        I_tvalid = drv_valid;
    wire        I_tlast  = drv_valid && ((beat_idx % BPL) == (BPL - 1));
    wire        I_tuser  = drv_valid && ((beat_idx % BPF) == 0);
    wire        I_tready = 1'b1;                          // C-3：全链路不反压

    //------------------------------------------------------------------
    // 原始 RGB 通路的 1 行 / 2 行延迟（行为级移位，只用于造 I_rgb_center）
    //   上电清 0（与安路 ERAM 上电一致），否则未初始化值会以 X 形式漏进 src
    //------------------------------------------------------------------
    reg [95:0] dly [0:BPL-1];
    integer    k;
    always @ (posedge clk) begin
        if (drv_valid) begin
            dly[0] <= stim_r[beat_idx];
            for (k = 1; k < BPL; k = k + 1)
                dly[k] <= dly[k-1];
        end
    end

    wire [95:0] w_rgb_d1 = dly[BPL-1];                    // 第 y-1 行（窗口中心行）的 RGB 拍

    // I_rgb_center = 图像第 y-1 行的 96bit RGB 拍。冻结文档 §2 已更正为 [95:0]
    // （位序同 I_tdata：pix0 = 列 4x+0 在 [95:72]），**不做任何扩展**。
    // 打两级与 win3x3_96 的输出级对齐（第 2 级不门控，与 win3x3 同构）。
    reg [95:0] r_rgb_s1;
    reg [95:0] r_rgb_s2;
    always @ (posedge clk) begin
        if (drv_valid)
            r_rgb_s1 <= w_rgb_d1;
        r_rgb_s2 <= r_rgb_s1;
    end

    // 窗口所属拍号：与 win3x3_96 的入口级同构（drv_valid 门控的第 1 级 + 不门控的第 2 级）
    reg [31:0] bix1, bix2;
    always @ (posedge clk) begin
        if (drv_valid)
            bix1 <= beat_idx;
        bix2 <= bix1;
    end

    //------------------------------------------------------------------
    // DUT：3x3 窗口（已被 S2 验证过，这里当作"给定条件"）
    //------------------------------------------------------------------
    wire [287:0] W_window;
    wire         W_wvalid;
    wire [95:0]  W_tdata;
    wire         W_tvalid, W_tlast, W_tuser, W_tready;

    win3x3_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_win (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_tlast        (I_tlast),
        .I_tuser        (I_tuser),
        .I_tdata        (I_tdata),
        .I_tvalid       (I_tvalid),
        .I_tready       (I_tready),
        .O_tlast        (W_tlast),
        .O_tuser        (W_tuser),
        .O_tdata        (W_tdata),
        .O_tvalid       (W_tvalid),
        .O_tready       (W_tready),
        .O_window       (W_window),
        .O_window_valid (W_wvalid)
    );

    //------------------------------------------------------------------
    // DUT：三个窗口算子（接口逐字相同）
    //------------------------------------------------------------------
    wire [95:0] O_bin, O_sob, O_smo;
    wire        B_v, B_l, B_u;
    wire        S_v, S_l, S_u;
    wire        M_v, M_l, M_u;

    alg_binarize_96 u_bin (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_window_valid (W_wvalid),
        .I_window       (W_window),
        .I_gray_src     (W_tdata),
        .I_rgb_center   (r_rgb_s2),
        .I_tvalid       (W_tvalid),
        .I_tlast        (W_tlast),
        .I_tuser        (W_tuser),
        .I_tready       (W_tready),
        .O_tdata        (O_bin),
        .O_tvalid       (B_v),
        .O_tlast        (B_l),
        .O_tuser        (B_u),
        .O_tready       ()
    );

    alg_sobel_96 u_sob (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_window_valid (W_wvalid),
        .I_window       (W_window),
        .I_gray_src     (W_tdata),
        .I_rgb_center   (r_rgb_s2),
        .I_tvalid       (W_tvalid),
        .I_tlast        (W_tlast),
        .I_tuser        (W_tuser),
        .I_tready       (W_tready),
        .O_tdata        (O_sob),
        .O_tvalid       (S_v),
        .O_tlast        (S_l),
        .O_tuser        (S_u),
        .O_tready       ()
    );

    alg_smooth_96 u_smo (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_window_valid (W_wvalid),
        .I_window       (W_window),
        .I_gray_src     (W_tdata),
        .I_rgb_center   (r_rgb_s2),
        .I_tvalid       (W_tvalid),
        .I_tlast        (W_tlast),
        .I_tuser        (W_tuser),
        .I_tready       (W_tready),
        .O_tdata        (O_smo),
        .O_tvalid       (M_v),
        .O_tlast        (M_l),
        .O_tuser        (M_u),
        .O_tready       ()
    );

    //------------------------------------------------------------------
    // 逐周期 dump（posedge 上阻塞式 $fwrite ⇒ 取到本拍稳定值）
    //------------------------------------------------------------------
    integer fd;
    integer ii;

    initial begin
        fd = $fopen("dump_alg.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_alg.txt");
            $finish;
        end
        $readmemh("stim_alg.hex", stim_g);
        $readmemh("rgb_alg.hex", stim_r);
        for (ii = 0; ii < BPL; ii = ii + 1)
            dly[ii] = 96'd0;                              // 上电 0（ERAM 语义）
        $display("TB: %0d beats loaded, BPL=%0d BPF=%0d FRAMES=%0d",
                 NBEAT, BPL, BPF, FRAMES);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        bix1     = 32'd0;
        bix2     = 32'd0;
        rst_n    = 1'b0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    always @ (posedge clk) begin
        $fwrite(fd, "%0d %0d %0d %b %b %b %b %b %h %h %h %b %b %b %h %b %b %b %h %b %b %b\n",
                cyc, beat_idx, bix2, drv_valid,
                W_tvalid, W_tlast, W_tuser, W_wvalid, W_window, r_rgb_s2,
                O_bin, B_v, B_l, B_u,
                O_sob, S_v, S_l, S_u,
                O_smo, M_v, M_l, M_u);
        cyc <= cyc + 32'd1;
        if (drv_valid)
            beat_idx <= beat_idx + 32'd1;
        if (cyc >= (START_CYC + NBEAT + GAP_LEN + TAIL_CYC)) begin
            $fclose(fd);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
