//==============================================================================
// _probe_taps_rf.v -- 一次性诊断 TB（非交付物，不参与集成）。
//
// 目的：把 alg_region_fill_96 的 **9 个窗口抽头的绝对坐标（行, 列）** 用数字读出来。
//
// 为什么不用"坐标编码法"（前任 _probe_win.v 的 R=0xFF/G=row/B=col）：
//   本模块的行缓存**每像素只存 1 bit**（w_masks 是"是不是白"的 1 bit），
//   所以任何颜色都退化成一个 bit —— 编码法必然全 0（实测：_probe_win.txt 全 0）。
//
// 本探针改用 **7 轮位平面扫描**（bit-plane sweep）：
//   第 k 轮激励：像素 (y,x) 为白  <=>  ((y*IMG_WIDTH + x) + 1) 的第 k 位 == 1
//   7 轮（k=0..6，索引 1..96 需要 7 bit）之后，把同一个抽头在 7 轮里的 0/1
//   拼成一个 7 bit 数，减 1 就是它采样的那个像素的线性索引 => 行、列唯一确定。
//   "+1" 偏移的作用：全 0 位型（7 轮都读到黑）只可能来自"从没写过的地址 / 图外
//   补零"，不会和真实像素 (0,0) 撞车。
//
// 用法（每个 k 跑一次，输出都写 taps_probe.txt，由 runner 每轮收走）：
//   vsim -c -lib work _probe_taps_rf -do "run -all; quit -f" +k=0
//==============================================================================
`timescale 1ns / 1ps

module _probe_taps_rf;

    localparam IMG_WIDTH  = 16;             // 4 拍/行
    localparam IMG_HEIGHT = 6;
    localparam BPL        = IMG_WIDTH / 4;
    localparam BPF        = BPL * IMG_HEIGHT;
    localparam NBEAT      = BPF * 2;        // 2 帧，够走满两行窗口

    integer K;                              // 位平面号（plusarg +k=）

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [31:0] tb_cyc, tb_beat;
    reg        rst_n;
    reg [95:0] I_tdata;
    reg        I_tvalid, I_tlast, I_tuser;
    wire       I_tready;
    wire [95:0] O_tdata;
    wire        O_tvalid, O_tlast, O_tuser, O_tready;

    alg_region_fill_96 #(.IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tready(I_tready),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tready(O_tready)
    );
    assign I_tready = 1'b1;

    function [23:0] pix_of;
        input integer row;
        input integer col;
        integer ii;
        begin
            ii = row * IMG_WIDTH + col + 1;
            pix_of = (((ii >> K) & 1) != 0) ? 24'hFFFFFF : 24'h000000;
        end
    endfunction

    wire [31:0] w_row = (tb_beat / BPL) % IMG_HEIGHT;
    wire [31:0] w_grp = tb_beat % BPL;

    always @ (*) begin
        I_tdata  = { pix_of(w_row, 4 * w_grp + 0), pix_of(w_row, 4 * w_grp + 1),
                     pix_of(w_row, 4 * w_grp + 2), pix_of(w_row, 4 * w_grp + 3) };
        I_tvalid = rst_n && (tb_beat < NBEAT) && (tb_cyc >= 32'd6);
        I_tlast  = I_tvalid && (w_grp == (BPL - 1));
        I_tuser  = I_tvalid && ((tb_beat % BPF) == 0);
    end

    integer fd;

    initial begin
        rst_n = 1'b0; tb_cyc = 32'd0; tb_beat = 32'd0;
        if (!$value$plusargs("k=%d", K)) K = 0;
        fd = $fopen("taps_probe.txt", "w");
        if (fd == 0) begin $display("FATAL: cannot open taps_probe.txt"); $finish; end
        $display("PROBE k=%0d start", K);
        #1; repeat (4) @(posedge clk); rst_n = 1'b1;
    end

    // 第 1 级拍（r_vld1）出现时，把 15 个抽头 + 行缓存读链全部打出来（纯 0/1）
    always @(posedge clk) begin
        if (dut.r_vld1) begin
            $fwrite(fd, "c=%0d beat=%0d rx=%0d ry=%0d wv=%b | T=%b,%b,%b,%b,%b,%b | M=%b,%b,%b,%b,%b,%b | B=%b,%b,%b,%b,%b,%b | R=%b,%b,%b,%b,%b,%b,%b,%b\n",
                tb_cyc, tb_beat, dut.r_x, dut.r_y, dut.w_win_valid,
                dut.w_top_m1, dut.w_top_0, dut.w_top_1, dut.w_top_2, dut.w_top_3, dut.w_top_4,
                dut.w_mid_m1, dut.w_mid_0, dut.w_mid_1, dut.w_mid_2, dut.w_mid_3, dut.w_mid_4,
                dut.w_bot_m1, dut.w_bot_0, dut.w_bot_1, dut.w_bot_2, dut.w_bot_3, dut.w_bot_4,
                dut.r_word, dut.r_rd1, dut.r_rd1_s1, dut.r_rd1_s2,
                dut.r_rd2, dut.r_rd2_s1, dut.r_rd2_s2,
                dut.r_bl1);
        end
        tb_cyc  <= tb_cyc + 32'd1;
        if (I_tvalid) tb_beat <= tb_beat + 32'd1;
        if ((tb_beat >= NBEAT) && (tb_cyc >= 32'd150)) begin
            $fclose(fd);
            $display("PROBE DONE k=%0d", K);
            $finish;
        end
    end

endmodule
