//==============================================================================
// tb_cd_cls.v —— alg_color_detect_96 的**颜色类别 + 跟踪编号**专项测试平台
//
// 为什么单独一个 TB（而不是并进 tb_alg_color_detect_96.v）：
//   全尺寸回归的激励里命中像素恒为红色主导，类别期望值恒为 RED ⇒ 对分类器零鉴别力；
//   而且全尺寸里目标每一帧都在，**跟踪编号一次都不会递增** ⇒ 对编号逻辑也是零鉴别力。
//   本 TB 用 gen_stim_cd_cls.py 造的小图，一次跑完两件事：
//     · 类别逐帧变化（1/2/0/0/1/0/1/0/0/0/0/0/0）；
//     · 编号走完"短间隔重现（不动）→ 长间隔重现（+1）"两侧边界。
//   原有那个 TB 与它的判据一个字都不动。
//
// 只从**规格**推导观测，不读实现内部：
//   契约 1：O_color_class = **上一帧**统计出的命中像素主导通道（0=R / 1=G / 2=B），
//           与 O_bbox_valid / O_pix_count 在**同一拍**（帧首有效拍）换值。
//   契约 2：O_track_id = 目标连续丢失 >= LOST_N 帧后再捕获就 +1，否则不变；
//           与上面两个信号**同一拍**换值。
//
// 激励：stim_cd_cls.hex（832 拍 = 32x8 x 13 帧）
//       cd_cls_tgt.txt（每行 "<RRGGBB> <TOL>"，逐帧目标色/容差）
//         —— TB 与判据**共用同一份表**，不各写一遍常数。
//
// 输出：dump_cd_cls.txt（每周期一行）
//   cyc Iv Iu beat fidx TgtColor Itol | Ov Ocls Ovalid Ocnt Otid
//   fIdx 是 TB 自己算的"当前输入拍属于第几帧"，判据用它对齐，不靠猜 START_CYC。
//==============================================================================
`timescale 1ns / 1ps

module tb_cd_cls;

    localparam IMG_WIDTH  = 32;
    localparam IMG_HEIGHT = 8;
    localparam BPL        = IMG_WIDTH / 4;              // 8 拍/行
    localparam FRAMES     = 13;
    localparam BPF        = BPL * IMG_HEIGHT;           // 64 拍/帧
    localparam NBEAT      = BPF * FRAMES;               // 832 拍
    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;
    localparam TAIL_CYC   = 20;

    //--------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------
    // 激励
    //--------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];
    reg [23:0] tgt_arr [0:FRAMES-1];
    reg [7:0]  tol_arr [0:FRAMES-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg        rst_n;

    wire drv_valid = (cyc >= START_CYC) && (beat_idx < NBEAT);

    // 当前输入拍属于第几帧（激励驱动与 dump 都用它，保证两边同一口径）
    wire [31:0] fidx = (beat_idx < NBEAT) ? (beat_idx / BPF) : 32'd0;

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    reg  [23:0] I_tgt_color;
    reg  [7:0]  I_tgt_tol;
    wire        I_tready;

    always @(*) begin
        I_tdata     = drv_valid ? stim[beat_idx] : 96'd0;
        I_tvalid    = drv_valid;
        I_tlast     = drv_valid && ((beat_idx % BPL) == (BPL - 1));
        I_tuser     = drv_valid && ((beat_idx % BPF) == 0);
        // 目标色/容差按**当前输入拍**的帧号取（判色是组合逻辑，吃的就是本拍端口）
        I_tgt_color = drv_valid ? tgt_arr[fidx] : 24'd0;
        I_tgt_tol   = drv_valid ? tol_arr[fidx] : 8'd0;
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
    wire [1:0]  O_color_class;
    wire [7:0]  O_track_id;

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
        .I_tgt_color  (I_tgt_color),
        .I_tgt_tol    (I_tgt_tol),
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
        .O_bbox_valid (O_bbox_valid),
        .O_color_class(O_color_class),
        .O_track_id   (O_track_id)
    );

    assign I_tready = 1'b1;                             // C-3：全链路不反压

    //--------------------------------------------------------------------
    // 逐周期 dump
    //--------------------------------------------------------------------
    integer fd;
    integer ft;
    integer i;
    integer rcscan;

    initial begin
        fd = $fopen("dump_cd_cls.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_cd_cls.txt");
            $finish;
        end
        $readmemh("stim_cd_cls.hex", stim);

        ft = $fopen("cd_cls_tgt.txt", "r");
        if (ft == 0) begin
            $display("FATAL: cannot open cd_cls_tgt.txt");
            $finish;
        end
        for (i = 0; i < FRAMES; i = i + 1) begin
            rcscan = $fscanf(ft, "%h %d\n", tgt_arr[i], tol_arr[i]);
            if (rcscan != 2) begin
                $display("FATAL: cd_cls_tgt.txt line %0d unreadable (rc=%0d)", i, rcscan);
                $finish;
            end
            $display("TB: F%0d target=%06h tol=%0d", i, tgt_arr[i], tol_arr[i]);
        end
        $fclose(ft);

        $display("TB: loaded %0d beats, BPL=%0d BPF=%0d FRAMES=%0d", NBEAT, BPL, BPF, FRAMES);
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
        $fwrite(fd, "%0d %b %b %0d %0d %h %0d %b %b %b %0d %0d\n",
                cyc,
                I_tvalid, I_tuser, beat_idx, fidx, I_tgt_color, I_tgt_tol,
                O_tvalid, O_color_class, O_bbox_valid, O_pix_count,
                O_track_id);
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
