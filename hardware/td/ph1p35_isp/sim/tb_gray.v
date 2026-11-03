//==============================================================================
// tb_gray.v —— gray_bt601_96 的 ModelSim 测试平台
//
// 只从规格推导：Y = (77*R + 150*G + 29*B) >> 8，复制到 R/G/B 三通道；
// 五路输出相对输入延迟 1 拍；tlast / tuser 纯透传。
//
// 做法：逐周期 dump，判定全部交给 check_gray.py。
// 十六进制用 %h 打印，X/Z 会原样显示，这是 X 传播检查的依据。
//==============================================================================
`timescale 1ns / 1ps

module tb_gray;

    localparam BPL       = 8;      // 每行拍数
    localparam H         = 36;     // 行数
    localparam NBEAT     = 288;    // 总拍数 = 256 拍扫描 + 32 拍极端值
    localparam START_CYC = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;

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
        I_tdata  = drv_valid ? stim[beat_idx] : 96'd0;
        I_tvalid = drv_valid;
        I_tlast  = drv_valid && ((beat_idx % BPL) == (BPL - 1));
        I_tuser  = drv_valid && ((beat_idx % (BPL * H)) == 0);
    end

    wire [95:0] O_tdata;
    wire        O_tvalid;
    wire        O_tlast;
    wire        O_tuser;
    wire        O_tready;

    gray_bt601_96 #(
        .IMG_WIDTH  (32),
        .IMG_HEIGHT (H)
    ) dut (
        .I_clk    (clk),
        .I_rst_n  (rst_n),
        .I_tlast  (I_tlast),
        .I_tuser  (I_tuser),
        .I_tdata  (I_tdata),
        .I_tvalid (I_tvalid),
        .I_tready (I_tready),
        .O_tlast  (O_tlast),
        .O_tuser  (O_tuser),
        .O_tdata  (O_tdata),
        .O_tvalid (O_tvalid),
        .O_tready (O_tready)
    );

    assign I_tready = 1'b1;

    integer fd;

    initial begin
        fd = $fopen("dump_gray.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_gray.txt");
            $finish;
        end
        $readmemh("stim_gray.hex", stim);
        $display("TB: loaded %0d beats", NBEAT);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        rst_n    = 1'b0;
        #1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    always @(posedge clk) begin
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata);
        cyc <= cyc + 32'd1;
        if (drv_valid)
            beat_idx <= beat_idx + 32'd1;
        if (cyc >= (START_CYC + NBEAT + 12)) begin
            $fclose(fd);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
