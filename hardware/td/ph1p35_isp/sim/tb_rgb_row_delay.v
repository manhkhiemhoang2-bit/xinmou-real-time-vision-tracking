//==============================================================================
// tb_rgb_row_delay.v —— rgb_row_delay_96 的 ModelSim 测试平台
//
// 只从**规格**推导激励与观测，不读实现：
//   契约：O_* 恒等于 I_* 延迟 320 拍（= 一行），O_tdata 在延迟后 tvalid=0 的拍清零。
//
// 关键的时间锚点（校验器依赖它，改这里必须同步改 check_row_delay.py）：
//   RST_CYC = 4，START_CYC = 4 —— 第 1 拍数据必须落在"拍号归零"的那一拍上
//   （复位把 r_x_grp 钉在 0，复位释放后第 1 拍 = 拍号 0），这样拍号 = 行内拍号，
//   320 拍延迟的比对点才能算准。
//
// 空闲期 I_tdata 驱动成**非零垃圾值** IDLE：这样"无效拍 O_tdata 必须为 0"这条
// 才是可观测的（若空闲期送 0，清零与不清零在波形上无法区分）。
//
// 输出：dump_rd.txt
//   cycle I_tvalid I_tlast I_tuser I_tdata O_tvalid O_tlast O_tuser O_tdata mem[0]
//   末列是内部探针（阵列第 0 个字）：它在复位里**故意不清零**，早期应为 X ——
//   这是"阵列没有复位循环 / 没有 initial"的直接证据，Python 转写模型给不出。
//==============================================================================
`timescale 1ns / 1ps

module tb_rgb_row_delay;

    localparam BPL       = 320;                 // 每行 320 拍（IMG_WIDTH=1280）
    localparam ROWS      = 3;                   // 每帧 3 行
    localparam FRAMES    = 2;
    localparam BPF       = BPL * ROWS;          // 960 拍/帧
    localparam NBEAT     = BPF * FRAMES;        // 1920 拍
    localparam RST_CYC   = 4;
    localparam START_CYC = 4;                   // 见文件头"时间锚点"
    localparam TAIL_CYC  = 360;                 // 排空 320 拍 + 余量
    localparam [95:0] IDLE = 96'hA5A5_A5A5_A5A5_A5A5_A5A5_A5A5;

    //--------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                       // 10ns 周期

    //--------------------------------------------------------------------
    // 激励存储
    //--------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg        rst_n;

    wire drv_valid = (cyc >= START_CYC) && (beat_idx < NBEAT);

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    wire        I_tready;

    always @(*) begin
        I_tdata  = drv_valid ? stim[beat_idx] : IDLE;
        I_tvalid = drv_valid;
        I_tlast  = drv_valid && ((beat_idx % BPL) == (BPL - 1));
        I_tuser  = drv_valid && ((beat_idx % BPF) == 0);
    end

    //--------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------
    wire [95:0] O_tdata;
    wire        O_tvalid;
    wire        O_tlast;
    wire        O_tuser;
    wire        O_tready;

    rgb_row_delay_96 #(
        .IMG_WIDTH (1280)
    ) dut (
        .I_clk    (clk),
        .I_rst_n  (rst_n),
        .I_tdata  (I_tdata),
        .I_tvalid (I_tvalid),
        .I_tlast  (I_tlast),
        .I_tuser  (I_tuser),
        .I_tready (I_tready),
        .O_tdata  (O_tdata),
        .O_tvalid (O_tvalid),
        .O_tlast  (O_tlast),
        .O_tuser  (O_tuser),
        .O_tready (O_tready)
    );

    assign I_tready = 1'b1;                     // C-3：全链路不反压

    //--------------------------------------------------------------------
    // 逐周期 dump
    //--------------------------------------------------------------------
    integer fd;

    initial begin
        fd = $fopen("dump_rd.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_rd.txt");
            $finish;
        end
        $readmemh("stim_rd.hex", stim);
        $display("TB: loaded %0d beats, BPL=%0d BPF=%0d", NBEAT, BPL, BPF);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        rst_n    = 1'b0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    always @(posedge clk) begin
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %h\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata,
                dut.r_mem[0]);
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
