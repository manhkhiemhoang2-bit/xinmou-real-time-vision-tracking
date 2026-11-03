//==============================================================================
// tb_win3x3.v —— win3x3_96 的 ModelSim 测试平台（S2/S3）
//
// 只从**规格**推导激励与观测，不读实现：
//   规格契约（S0-02 §一）：O_window[8*(4*(3r+c)+k) +: 8] == gray(y-2+r, 4x+k+c-1)
//   6 路输出延迟 = 2 拍
//
// 做法：把每一拍的**全部信号**逐周期 dump 成文本，几何与延迟的判定全部放到
//       Python 校验器里做（见 check_win3x3.py）。这里只负责产生激励和记录。
//
// 输出：dump.txt
//   cycle I_tvalid I_tlast I_tuser I_tdata O_tvalid O_tlast O_tuser O_tdata
//         O_window_valid O_window
//   十六进制用 %h 打印，X/Z 会原样显示成 x/z —— 这是 X 传播检查的依据，
//   Python 转写模型做不到这一点。
//==============================================================================
`timescale 1ns / 1ps

module tb_win3x3;

    localparam IMG_WIDTH  = 32;
    localparam IMG_HEIGHT = 8;
    localparam BPL        = IMG_WIDTH / 4;              // 8 拍/行
    localparam FRAMES     = 2;
    localparam NBEAT      = BPL * IMG_HEIGHT * FRAMES;  // 128 拍
    localparam BPF        = BPL * IMG_HEIGHT;           // 64 拍/帧
    localparam RST_CYC    = 4;                          // 复位保持的时钟数
    localparam START_CYC  = 6;                          // 从第几拍开始送激励
    localparam TAIL_CYC   = 16;                         // 送完后多跑几拍排空

    //--------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                               // 10ns 周期

    //--------------------------------------------------------------------
    // 激励存储
    //--------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg        rst_n;

    wire        drv_valid = (cyc >= START_CYC) && (beat_idx < NBEAT);

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    wire        I_tready;

    always @(*) begin
        I_tdata  = drv_valid ? stim[beat_idx] : 96'd0;
        I_tvalid = drv_valid;
        I_tlast  = drv_valid && ((beat_idx % BPL) == (BPL - 1));
        I_tuser  = drv_valid && ((beat_idx % BPF) == 0);
    end

    //--------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------
    wire [287:0] O_window;
    wire         O_window_valid;
    wire [95:0]  O_tdata;
    wire         O_tvalid;
    wire         O_tlast;
    wire         O_tuser;
    wire         O_tready;

    win3x3_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) dut (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_tlast        (I_tlast),
        .I_tuser        (I_tuser),
        .I_tdata        (I_tdata),
        .I_tvalid       (I_tvalid),
        .I_tready       (I_tready),
        .O_tlast        (O_tlast),
        .O_tuser        (O_tuser),
        .O_tdata        (O_tdata),
        .O_tvalid       (O_tvalid),
        .O_tready       (O_tready),
        .O_window       (O_window),
        .O_window_valid (O_window_valid)
    );

    assign I_tready = 1'b1;                             // C-3：全链路不反压

    //--------------------------------------------------------------------
    // 逐周期 dump
    //   在 posedge 的 always 块里用阻塞式 $fwrite 读取，取到的是**本拍稳定值**
    //   （非阻塞更新在此块结束之后才生效），所以 dump 的就是第 cyc 拍的画面。
    //--------------------------------------------------------------------
    integer fd;

    initial begin
        fd = $fopen("dump.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump.txt");
            $finish;
        end
        $readmemh("stim.hex", stim);
        $display("TB: loaded %0d beats, BPL=%0d BPF=%0d", NBEAT, BPL, BPF);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        rst_n    = 1'b0;
        #1;                                             // 让复位先建立
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    always @(posedge clk) begin
        // 末两列是内部探针：行缓冲的第一个字。它在复位里被**故意不清零**，
        // 所以早期应为 X —— 这一列是"不复位行缓冲"这条设计的直接证据，
        // 也是本测试区别于 Python 转写模型的唯一能力（Python 没有 X 概念）。
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %b %h %h %h\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata,
                O_window_valid, O_window,
                dut.r_line1_mem[0], dut.r_line2_mem[0]);
        cyc <= cyc + 32'd1;
        if (drv_valid)
            beat_idx <= beat_idx + 32'd1;
        if (cyc >= (START_CYC + NBEAT + TAIL_CYC)) begin
            $fclose(fd);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
