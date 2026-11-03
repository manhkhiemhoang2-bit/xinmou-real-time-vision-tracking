//==============================================================================
// tb_osd_anlogo.v —— 安路官方 Logo 接入（G1）专项测试平台
//
// 目标：把「安路 Logo 是真的按量化位图逐像素画出来的」这件事单独证死。
//
// 四个 DUT 实例共用同一份激励，分工如下：
//   dut_a（真实版面）：ANLOGO_X/Y = (0,0)，160x160
//       自研 Logo 放 (176,176)、文字放 (16,224) —— 都在安路区**外**。
//       ⇒ 校正窗口 x∈[0,320), y∈[0,176) 里**只可能**有安路面命中，
//         "命中 ⇒ 逐 bit 等于期望色 / 未命中 ⇒ 原像素" 才是干净的。
//   dut_b（错位摆放）：ANLOGO_X = 8
//       验证列偏移确实被减掉了（忘了减 ANLOGO_X ⇒ 整个 Logo 右移 8 像素）。
//       ⚠ 2026-09-17（ERAM 返工）：改成"一拍读 4 像素"的 ERAM 位图后，字地址 =
//         (x_base-ANLOGO_X)/4，**ANLOGO_X 必须是 4 的倍数** ⇒ 原来那个 ANLOGO_X=2
//         的跨拍边界用例不再合法（改为 8）。跨拍边界问题在新方案里结构上不存在：
//         一拍 4 像素要么整拍在区内、要么整拍在区外。
//   dut_c（三层优先级）：自研 Logo (16,16)、文字 (16,32) 都塞进安路区内部
//       ⇒ 文字/安路/自研 三个面互相重叠，"文字 > 安路Logo > 自研Logo > 原像素"
//         这条真值表才有被证伪的机会（互不重叠时优先级写反也测不出来）。
//   dut_d（非法配置）：ANLOGO_X = 6（不是 4 的倍数）—— **不比对像素**，
//       只证明配置护栏真的会响：它的 r_an_cfg_err 必须为 1，而 a/b/c 必须为 0。
//       四个标志写进 dump_anlogo_cfg.txt，由 check_anlogo.py 断言（4 次检查）。
//
// ⚠ dump 里**只记录 TB 自己产生的激励与 DUT 的端口**（外加四个配置护栏标志），
//   一个内部像素信号都不探 —— 期望值必须由 Python 侧独立解析 logo_64c.hex +
//   alg_logo_eram.v 里那 4 份调色板算出来。探内部信号等于循环论证（本工程历史上
//   踩过：模型把 RTL 的相位缺陷一起吸收，测出假 0 错）。
//
// 像素值图（严格单射，每像素自带拍号，与 tb_osd_mixer.v 同式）：
//   pix(beat,ch) = (beat << 7) | ((beat % 32) << 2) | ch      ch = 0..3
//   ⇒ beat = pix >> 7 可反解；beat 最大 20479 ⇒ 值 < 2^24，不溢出。
//
// dump 格式（每个 DUT 一个文件）：
//   首行 H <W> <H> <AN_X> <AN_Y> <AN_W> <AN_H> <MY_X> <MY_Y> <TX> <TY>
//          <MODE> <FPS> <LAT> <INF_X>
//   其后每拍：cyc Iv Il Iu Id Ov Ol Ou Od beat
//
// 编译开关：
//   +define+G1_NO_RESET —— DUT 的 I_rst_n 恒 1（**不做复位**），只靠 RTL 的
//     initial 初值。用来验证"新增的 initial 与复位分支逐一相同"：
//     该模式下三个 dump 必须与正常复位模式下**逐字节相同**。
//==============================================================================
`timescale 1ns / 1ps

module tb_osd_anlogo;

    localparam IMG_WIDTH  = 320;
    localparam IMG_HEIGHT = 256;
    localparam BPL        = IMG_WIDTH / 4;                 // 80 拍/行
    localparam NBEAT      = BPL * IMG_HEIGHT;              // 20480 拍
    localparam BPF        = NBEAT;                         // 一帧
    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;
    localparam TAIL_CYC   = 16;

    localparam AN_X  = 0;
    localparam AN_Y  = 0;
    localparam AN_W  = 160;                                // 与 alg_logo_eram 一致
    localparam AN_H  = 160;
    localparam ANB_X = 8;                                  // 故意错位（4 的倍数，合法）
    localparam AND_X = 6;                                  // **非法**：不是 4 的倍数

    localparam MY_X  = 176, MY_Y  = 176;                   // A/B 的自研 Logo（安路区外）
    localparam TX_X  = 16,  TX_Y  = 224;                   // A/B 的文字（安路区外）
    localparam MYC_X = 16,  MYC_Y = 16;                    // C 的自研 Logo（安路区内）
    localparam TXC_X = 16,  TXC_Y = 32;                    // C 的文字（安路区内）

    localparam INFO_MODE = 3;
    localparam INFO_FPS  = 32'h0000_0042;
    localparam INFO_LAT  = 11'd137;
    localparam INFO_X    = 11'd2047;
    localparam INFO_Y    = 11'd600;
    localparam INFO_CNT  = 32'h0000_0007;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] cyc;
    reg        rst_n;

`ifdef G1_NO_RESET
    wire dut_rst_n = 1'b1;                    // 不复位：只考 RTL 的 initial 初值
`else
    wire dut_rst_n = rst_n;
`endif

    reg [31:0] r_beat;
    wire drv_valid = (cyc >= START_CYC) && (r_beat < NBEAT);

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    wire        I_tready;

    reg  [10:0] I_info_mode;
    reg  [31:0] I_info_fps;
    reg  [10:0] I_info_lat;
    reg  [10:0] I_info_x;
    reg  [10:0] I_info_y;
    reg  [31:0] I_info_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_beat   <= 32'd0;
            I_tdata  <= 96'd0;
            I_tvalid <= 1'b0;
            I_tlast  <= 1'b0;
            I_tuser  <= 1'b0;
        end else if (drv_valid) begin
            r_beat   <= r_beat + 32'd1;
            I_tdata  <= stim[r_beat];
            I_tvalid <= 1'b1;
            I_tlast  <= ((r_beat % BPL) == (BPL - 1));
            I_tuser  <= ((r_beat % BPF) == 0);
        end else begin
            I_tvalid <= 1'b0;
            I_tlast  <= 1'b0;
            I_tuser  <= 1'b0;
        end
    end

    reg [31:0] beat_idx;
    always @(*) beat_idx = I_tvalid ? r_beat : 32'd0;

    wire [95:0] Oa_d, Ob_d, Oc_d;
    wire        Oa_v, Ob_v, Oc_v;
    wire        Oa_l, Ob_l, Oc_l;
    wire        Oa_u, Ob_u, Oc_u;
    wire        Oa_r, Ob_r, Oc_r;

    //-------------------------------------------------------------------- dut_a
    osd_mixer #(
        .IMG_WIDTH  (IMG_WIDTH),  .IMG_HEIGHT (IMG_HEIGHT),
        .ANLOGO_X   (AN_X),       .ANLOGO_Y   (AN_Y),
        .LOGO_X     (MY_X),       .LOGO_Y     (MY_Y),
        .TEXT_X     (TX_X),       .TEXT_Y     (TX_Y)
    ) dut_a (
        .I_clk (clk), .I_rst_n (dut_rst_n),
        .I_tdata (I_tdata), .I_tvalid (I_tvalid), .I_tlast (I_tlast),
        .I_tuser (I_tuser), .I_tready (I_tready),
        .I_info_mode (I_info_mode), .I_info_fps (I_info_fps),
        .I_info_lat (I_info_lat), .I_info_x (I_info_x),
        .I_info_y (I_info_y), .I_info_cnt (I_info_cnt),
        .O_tdata (Oa_d), .O_tvalid (Oa_v), .O_tlast (Oa_l),
        .O_tuser (Oa_u), .O_tready (Oa_r)
    );

    //-------------------------------------------------------------------- dut_b
    osd_mixer #(
        .IMG_WIDTH  (IMG_WIDTH),  .IMG_HEIGHT (IMG_HEIGHT),
        .ANLOGO_X   (ANB_X),      .ANLOGO_Y   (AN_Y),
        .LOGO_X     (MY_X),       .LOGO_Y     (MY_Y),
        .TEXT_X     (TX_X),       .TEXT_Y     (TX_Y)
    ) dut_b (
        .I_clk (clk), .I_rst_n (dut_rst_n),
        .I_tdata (I_tdata), .I_tvalid (I_tvalid), .I_tlast (I_tlast),
        .I_tuser (I_tuser), .I_tready (I_tready),
        .I_info_mode (I_info_mode), .I_info_fps (I_info_fps),
        .I_info_lat (I_info_lat), .I_info_x (I_info_x),
        .I_info_y (I_info_y), .I_info_cnt (I_info_cnt),
        .O_tdata (Ob_d), .O_tvalid (Ob_v), .O_tlast (Ob_l),
        .O_tuser (Ob_u), .O_tready (Ob_r)
    );

    //-------------------------------------------------------------------- dut_c
    osd_mixer #(
        .IMG_WIDTH  (IMG_WIDTH),  .IMG_HEIGHT (IMG_HEIGHT),
        .ANLOGO_X   (AN_X),       .ANLOGO_Y   (AN_Y),
        .LOGO_X     (MYC_X),      .LOGO_Y     (MYC_Y),
        .TEXT_X     (TXC_X),      .TEXT_Y     (TXC_Y)
    ) dut_c (
        .I_clk (clk), .I_rst_n (dut_rst_n),
        .I_tdata (I_tdata), .I_tvalid (I_tvalid), .I_tlast (I_tlast),
        .I_tuser (I_tuser), .I_tready (I_tready),
        .I_info_mode (I_info_mode), .I_info_fps (I_info_fps),
        .I_info_lat (I_info_lat), .I_info_x (I_info_x),
        .I_info_y (I_info_y), .I_info_cnt (I_info_cnt),
        .O_tdata (Oc_d), .O_tvalid (Oc_v), .O_tlast (Oc_l),
        .O_tuser (Oc_u), .O_tready (Oc_r)
    );

    assign I_tready = 1'b1;                    // 全链路不反压

    //-------------------------------------------------------------------- dut_d
    // 非法配置用例：ANLOGO_X = 6（不是 4 的倍数）⇒ 配置护栏必须响。
    // 它的像素输出**不比对**（配置本身非法，行为无意义），只取 r_an_cfg_err。
    wire        Od_d, Od_v, Od_l, Od_u, Od_r;

    osd_mixer #(
        .IMG_WIDTH  (IMG_WIDTH),  .IMG_HEIGHT (IMG_HEIGHT),
        .ANLOGO_X   (AND_X),      .ANLOGO_Y   (AN_Y),
        .LOGO_X     (MY_X),       .LOGO_Y     (MY_Y),
        .TEXT_X     (TX_X),       .TEXT_Y     (TX_Y)
    ) dut_d (
        .I_clk (clk), .I_rst_n (dut_rst_n),
        .I_tdata (I_tdata), .I_tvalid (I_tvalid), .I_tlast (I_tlast),
        .I_tuser (I_tuser), .I_tready (I_tready),
        .I_info_mode (I_info_mode), .I_info_fps (I_info_fps),
        .I_info_lat (I_info_lat), .I_info_x (I_info_x),
        .I_info_y (I_info_y), .I_info_cnt (I_info_cnt),
        .O_tdata (Od_d), .O_tvalid (Od_v), .O_tlast (Od_l),
        .O_tuser (Od_u), .O_tready (Od_r)
    );

    // 配置护栏标志（只取这一个"配置"信号，不碰任何像素内部量）
    wire cfg_a = dut_a.r_an_cfg_err;
    wire cfg_b = dut_b.r_an_cfg_err;
    wire cfg_c = dut_c.r_an_cfg_err;
    wire cfg_d = dut_d.r_an_cfg_err;

    integer fd_a, fd_b, fd_c, fd_cfg;
    integer i;
    // ⚠ 必须用定宽中间量拼装：ModelSim 10.3c 对"含非 2 的幂宽度操作数的拼接/大位移"
    //   会静默算错（tb_osd_mixer.v 踩过：{8'h40,8'h00,10'h000,4'h0} 求值成 0）。
    //   这里照抄那边的写法：先算 4 个 24 bit 像素，再拼成 96 bit。
    reg [23:0] p0, p1, p2, p3;
    reg [95:0] pw;

    initial begin
        fd_a = $fopen("dump_anlogo_a.txt", "w");
        fd_b = $fopen("dump_anlogo_b.txt", "w");
        fd_c = $fopen("dump_anlogo_c.txt", "w");
        fd_cfg = $fopen("dump_anlogo_cfg.txt", "w");
        if (fd_a == 0 || fd_b == 0 || fd_c == 0 || fd_cfg == 0) begin
            $display("FATAL: cannot open dump files");
            $finish;
        end
        for (i = 0; i < NBEAT; i = i + 1) begin
            p0 = (i << 7) + ((i % 32) << 2) + 24'd0;
            p1 = (i << 7) + ((i % 32) << 2) + 24'd1;
            p2 = (i << 7) + ((i % 32) << 2) + 24'd2;
            p3 = (i << 7) + ((i % 32) << 2) + 24'd3;
            pw = {p0, p1, p2, p3};
            stim[i] = pw;
        end
        $display("TB: stim[0]=%h stim[1]=%h stim[NBEAT-1]=%h",
                 stim[0], stim[1], stim[NBEAT-1]);
        // 首行：几何 + 信息量（校验器只从这里取版面参数，不从 RTL 取）
        $fwrite(fd_a, "H %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                IMG_WIDTH, IMG_HEIGHT, AN_X, AN_Y, AN_W, AN_H, MY_X, MY_Y,
                TX_X, TX_Y, INFO_MODE, INFO_FPS, INFO_LAT, INFO_X);
        $fwrite(fd_b, "H %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                IMG_WIDTH, IMG_HEIGHT, ANB_X, AN_Y, AN_W, AN_H, MY_X, MY_Y,
                TX_X, TX_Y, INFO_MODE, INFO_FPS, INFO_LAT, INFO_X);
        $fwrite(fd_c, "H %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                IMG_WIDTH, IMG_HEIGHT, AN_X, AN_Y, AN_W, AN_H, MYC_X, MYC_Y,
                TXC_X, TXC_Y, INFO_MODE, INFO_FPS, INFO_LAT, INFO_X);
        $display("TB: loaded %0d beats, BPL=%0d", NBEAT, BPL);
    end

    initial begin
        cyc         = 32'd0;
        rst_n       = 1'b0;
        I_info_mode = INFO_MODE[10:0];
        I_info_fps  = INFO_FPS;
        I_info_lat  = INFO_LAT;
        I_info_x    = INFO_X;
        I_info_y    = INFO_Y;
        I_info_cnt  = INFO_CNT;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d (dut_rst_n=%b)", cyc, dut_rst_n);
    end

    always @(posedge clk) begin
        $fwrite(fd_a, "%0d %b %b %b %h %b %b %b %h %0d\n",
                cyc, I_tvalid, I_tlast, I_tuser, I_tdata,
                Oa_v, Oa_l, Oa_u, Oa_d, beat_idx);
        $fwrite(fd_b, "%0d %b %b %b %h %b %b %b %h %0d\n",
                cyc, I_tvalid, I_tlast, I_tuser, I_tdata,
                Ob_v, Ob_l, Ob_u, Ob_d, beat_idx);
        $fwrite(fd_c, "%0d %b %b %b %h %b %b %b %h %0d\n",
                cyc, I_tvalid, I_tlast, I_tuser, I_tdata,
                Oc_v, Oc_l, Oc_u, Oc_d, beat_idx);
        // 配置护栏标志：在 cyc==16 落盘（此时四个 DUT 的 initial 早跑完、复位也放了，
        // 不会与 time-0 的 initial 竞争）。合法 a/b/c 必须 0，非法 d（ANLOGO_X=6）必须 1。
        if (cyc == 32'd16)
            $fwrite(fd_cfg, "CFG %b %b %b %b\n", cfg_a, cfg_b, cfg_c, cfg_d);
        cyc <= cyc + 32'd1;
        if (cyc >= (START_CYC + NBEAT + TAIL_CYC)) begin
            $fclose(fd_a);
            $fclose(fd_b);
            $fclose(fd_c);
            $fclose(fd_cfg);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
