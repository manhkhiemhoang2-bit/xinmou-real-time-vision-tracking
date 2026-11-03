//==============================================================================
// tb_alg_color_detect_96.v —— alg_color_detect_96（M5）的 ModelSim 测试平台
//
// 只从**规格**推导激励与观测，不读实现：
//   契约：O_tdata/O_tvalid/O_tlast/O_tuser = 输入延迟 1 拍；
//         O_bbox_* / O_pix_count / O_bbox_valid = 上一帧的统计（帧首更新）；
//         输出图像 = 在命中像素上画标记色、其余原图（画的是**上一帧**的 bbox 边框）。
//
// 判定全部交给 check_color_detect.py —— 它直接 import alg_ref.py，用金标准的
// target_hit / hit_vote / bbox_stats / draw_bbox 当期望值（不重写一遍算法）。
//
// 激励：stim_cd.hex（由 gen_stim_color_detect.py 用 alg_ref.frame_to_beats 打包）。
//
// 输出：dump_cd.txt
//   cyc Iv Il Iu Id | Ov Ol Ou Od | Ox0 Ox1 Oy0 Oy1 Ocnt Ovalid
//==============================================================================
`timescale 1ns / 1ps

module tb_alg_color_detect;

    localparam IMG_WIDTH  = 32;
    localparam IMG_HEIGHT = 8;
    localparam BPL        = IMG_WIDTH / 4;              // 8 拍/行
    localparam FRAMES     = 5;
    localparam BPF        = BPL * IMG_HEIGHT;           // 64 拍/帧
    localparam NBEAT      = BPF * FRAMES;               // 320 拍
    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;
    localparam TAIL_CYC   = 20;

    localparam [23:0] TGT_COLOR = 24'hC8283C;           // R=200 G=40 B=60
    localparam [7:0]  TGT_TOL   = 8'd40;                // 必须与 gen_stim_color_detect.py 一致

    //--------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------
    // 激励
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
        I_tdata  = drv_valid ? stim[beat_idx] : 96'd0;
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
    wire [10:0] O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1;
    wire [31:0] O_pix_count;
    wire        O_bbox_valid;

    alg_color_detect_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) dut (
        .I_clk        (clk),
        .I_rst_n      (rst_n),
        .I_tdata      (I_tdata),
        .I_tvalid     (I_tvalid),
        .I_tlast      (I_tlast),
        .I_tuser      (I_tuser),
        .I_tready     (I_tready),
        .I_tgt_color  (TGT_COLOR),
        .I_tgt_tol    (TGT_TOL),
        .O_tdata      (O_tdata),
        .O_tvalid     (O_tvalid),
        .O_tlast      (O_tlast),
        .O_tuser      (O_tuser),
        .O_tready     (O_tready),
        .O_bbox_x0    (O_bbox_x0),
        .O_bbox_x1    (O_bbox_x1),
        .O_bbox_y0    (O_bbox_y0),
        .O_bbox_y1    (O_bbox_y1),
        .O_pix_count  (O_pix_count),
        .O_bbox_valid (O_bbox_valid)
    );

    assign I_tready = 1'b1;                             // C-3：全链路不反压

    //--------------------------------------------------------------------
    // 逐周期 dump
    //--------------------------------------------------------------------
    integer fd;

    initial begin
        fd = $fopen("dump_cd.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_cd.txt");
            $finish;
        end
        $readmemh("stim_cd.hex", stim);
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
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %h %h %h %h %0d %b\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata,
                O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1,
                O_pix_count, O_bbox_valid);
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
