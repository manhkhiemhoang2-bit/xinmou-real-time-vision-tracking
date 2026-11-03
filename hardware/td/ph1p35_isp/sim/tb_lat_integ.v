//==============================================================================
// tb_lat_integ.v —— lat_measure 真集成 TB（alg_top + osd_mixer + lat_measure）
//------------------------------------------------------------------------------
// 【一、为什么要有这个 TB】
//   单元 TB（tb_lat_measure.v）只证明"喂进去什么周期、就输出什么 BCD/延迟"。
//   但屏上那个 LAT 数字到底是多少，取决于**接入点**与 alg_top/osd_mixer 的真实
//   流水线深度：M0（直通）与 M3（边缘）走的是不同的数据通路，win3x3 行缓冲会按
//   "行"延迟控制信号。所以这里按真实拓扑串起来实测一遍，把接入点的风险测掉。
//
// 【二、拓扑（与 isp_top_alg.v 的串法一致，区别只是输入侧 tap 在 alg_top 的输入）】
//     input stream ─┬─→ alg_top ──→ osd_mixer ──→ O_tuser/O_tvalid
//                   │                   ↑
//                   └─→ lat_measure ────┘（I_info_lat / I_info_fps）
//   · lat_measure.I_in_tuser  = TB 送进 alg_top 的帧首（同一个信号，不过任何延迟）
//   · lat_measure.I_out_tuser = osd_mixer 的输出帧首（= 送 DDR 那条流的帧首）
//   · lat_measure.O_lat_clk → osd_mixer.I_info_lat；O_fps_bcd → I_info_fps 低字节
//
// 【三、判据（期望值全部由 TB 自己独立算，不拿 DUT 内部信号当期望）】
//   · LAT：TB 只看顶层信号，自己数 in_tuser → osd_O_tuser 之间的拍数，与 O_lat_clk
//     比；另外再比一次 osd_mixer **内部真正寄存下来的** r_info_lat（证明 OSD 确实
//     拿到了这个数，而不只是 lat_measure 自己算对了）。
//   · FPS：TB 自己数两次输入帧首之间的实际拍数 C，用 (CLK_HZ + C/2)/C（四舍五入）
//     独立算期望 BCD，与 O_fps_bcd 比。
//   · 帧计数：TB 自己数输入帧首个数，与 O_frame_cnt 比。
//   · 4 个配置 = {M0, M3} × {周期 1,000,000 拍, 周期 999,917 拍}，每档 3 帧。
//     两个周期分别对应"60.000fps@60MHz"与"59.94fps@59.995MHz"两种传感时序。
//   · 每条断言以 [CHK] 行打印检查次数/失配数；[RPT] 行打印实测 LAT 与 O_fps_bcd。
//
// 【四、注意】
//   · 本 TB 引用 osd_mixer 内部寄存器 u_osd.r_info_lat。端口没变、只改内部实现时，
//     若这个名字被改掉，只需同步改这里（其余不用动）。
//   · 几何 320x180（4 像素/拍 → 80 拍/行），行末 20 拍行消隐（与 tb_alg_top 的真实
//     链路工况一致）；帧周期靠帧间空档凑到 1,000,000 / 999,917 拍。
//   · TB 时钟 100MHz：lat_measure 只数拍，FPS 绝对值由 CLK_HZ=60e6 参数决定。
//==============================================================================
`timescale 1ns / 1ps

module tb_lat_integ;

//------------------------------------------------------------------------------
// 几何与常量
//------------------------------------------------------------------------------
localparam IMG_WIDTH  = 320;
localparam IMG_HEIGHT = 180;
localparam BPL        = IMG_WIDTH / 4;              // 80 拍/行
localparam BLANK      = 20;                         // 行末消隐拍数（真实链路工况）
localparam LINE_TOT   = BPL + BLANK;                // 100 拍/行
localparam ACTIVE     = IMG_HEIGHT * LINE_TOT;      // 18000 拍有效窗口
localparam FRAMES     = 3;                          // 每档 3 帧

reg clk;
initial clk = 1'b0;
always #5 clk = ~clk;                               // 100MHz

//------------------------------------------------------------------------------
// 激励：帧首发生器 + 帧间空档（把相邻两个帧首凑到 period 拍）
//------------------------------------------------------------------------------
reg         rst_n;
reg  [24:0] period;             // 本档帧周期（拍）
reg  [24:0] idle_cnt;           // 帧间空档剩余拍数
reg  [7:0]  line;               // 帧内行号
reg  [7:0]  within;             // 行内拍号 0..LINE_TOT-1
reg  [2:0]  mode_sel;           // alg_top 档位（I_mode_set=1 强制）
reg  [1:0]  fidx;               // 已发帧号

wire w_in_valid = (fidx < FRAMES) && (idle_cnt == 25'd0) && (within < BPL);
wire w_in_tuser = w_in_valid && (line == 8'd0) && (within == 8'd0);
wire w_in_tlast = w_in_valid && (within == (BPL - 1));
wire [95:0] w_in_tdata = w_in_valid ? {12{line}} : 96'd0;

always @(posedge clk) begin
    if (!rst_n) begin
        idle_cnt <= period - ACTIVE;
        line     <= 8'd0;
        within   <= 8'd0;
        fidx     <= 2'd0;
    end else if (fidx < FRAMES) begin
        if (idle_cnt != 25'd0) begin
            idle_cnt <= idle_cnt - 25'd1;
        end else if (within == (LINE_TOT - 1)) begin
            within <= 8'd0;
            if (line == (IMG_HEIGHT - 1)) begin
                line     <= 8'd0;
                fidx     <= fidx + 2'd1;
                idle_cnt <= period - ACTIVE;        // 帧间空档
            end else begin
                line <= line + 8'd1;
            end
        end else begin
            within <= within + 8'd1;
        end
    end
end

//------------------------------------------------------------------------------
// DUT 互连线（先声明，后面的参考模型要看这些顶层信号）
//------------------------------------------------------------------------------
wire [95:0] alg_tdata;
wire        alg_tvalid, alg_tlast, alg_tuser;
wire [2:0]  alg_mode;
wire [31:0] alg_cnt;
wire [10:0] alg_x0, alg_x1, alg_y0, alg_y1;

wire [95:0] osd_tdata;
wire        osd_tvalid, osd_tlast, osd_tuser;

wire [31:0] lat_fcnt;
wire [7:0]  lat_fps;
wire [10:0] lat_val;

//------------------------------------------------------------------------------
// TB 参考模型：帧首计数 / 帧周期 / 输入→输出延迟（全部只看顶层信号）
//------------------------------------------------------------------------------
reg  [31:0] tb_frm;             // 输入帧首个数
reg  [24:0] tb_cnt;             // 距上一个输入帧首的拍数
reg  [24:0] tb_gap;             // 最近一个实测帧周期
reg  [15:0] tb_lat_cnt;         // 帧内延迟计数
reg  [15:0] tb_lat_val;         // 最近一次实测延迟（拍）
reg         tb_lat_arm;

always @(posedge clk) begin
    if (!rst_n) begin
        tb_frm <= 32'd0;
        tb_cnt <= 25'd0;
        tb_gap <= 25'd0;
    end else if (w_in_tuser) begin
        tb_gap <= tb_cnt + 25'd1;
        tb_cnt <= 25'd0;
        tb_frm <= tb_frm + 32'd1;
    end else begin
        tb_cnt <= tb_cnt + 25'd1;
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        tb_lat_cnt <= 16'd0;
        tb_lat_val <= 16'd0;
        tb_lat_arm <= 1'b0;
    end else if (w_in_tuser) begin
        tb_lat_cnt <= 16'd0;
        tb_lat_arm <= 1'b1;
    end else if (tb_lat_arm) begin
        if (osd_tuser) begin
            tb_lat_val <= tb_lat_cnt + 16'd1;
            tb_lat_arm <= 1'b0;
        end else begin
            tb_lat_cnt <= tb_lat_cnt + 16'd1;
        end
    end
end

//------------------------------------------------------------------------------
// DUT：alg_top → osd_mixer；lat_measure 挂输入/输出两侧
//------------------------------------------------------------------------------
alg_top #(
    .IMG_WIDTH  (IMG_WIDTH),
    .IMG_HEIGHT (IMG_HEIGHT),
    .KEY_DIV    (32)
) u_alg (
    .I_clk      (clk),
    .I_rst_n    (rst_n),
    .I_tlast    (w_in_tlast),
    .I_tuser    (w_in_tuser),
    .I_tdata    (w_in_tdata),
    .I_tvalid   (w_in_valid),
    .I_tready   (1'b1),
    .I_key      (1'b1),
    .I_mode_set (1'b1),
    .I_mode_sel (mode_sel),
    .O_mode     (alg_mode),
    .O_pix_count(alg_cnt),
    .O_bbox_x0  (alg_x0),
    .O_bbox_x1  (alg_x1),
    .O_bbox_y0  (alg_y0),
    .O_bbox_y1  (alg_y1),
    .O_bbox_valid(),
    .O_tlast    (alg_tlast),
    .O_tuser    (alg_tuser),
    .O_tdata    (alg_tdata),
    .O_tvalid   (alg_tvalid),
    .O_tready   ()
);

lat_measure #(
    .CLK_HZ (60000000)
) u_lat (
    .I_clk        (clk),
    .I_rst_n      (rst_n),
    .I_in_tvalid  (w_in_valid),
    .I_in_tuser   (w_in_tuser),
    .I_out_tvalid (osd_tvalid),
    .I_out_tuser  (osd_tuser),
    .O_frame_cnt  (lat_fcnt),
    .O_fps_bcd    (lat_fps),
    .O_lat_clk    (lat_val)
);

osd_mixer #(
    .IMG_WIDTH  (IMG_WIDTH),
    .IMG_HEIGHT (IMG_HEIGHT)
) u_osd (
    .I_clk       (clk),
    .I_rst_n     (rst_n),
    .I_tdata     (alg_tdata),
    .I_tvalid    (alg_tvalid),
    .I_tlast     (alg_tlast),
    .I_tuser     (alg_tuser),
    .I_tready    (1'b1),
    .I_info_mode ({8'd0, alg_mode}),
    .I_info_fps  ({24'd0, lat_fps}),
    .I_info_lat  (lat_val),
    .I_info_x    (alg_x0),
    .I_info_y    (alg_y0),
    .I_info_cnt  (alg_cnt),
    .O_tdata     (osd_tdata),
    .O_tvalid    (osd_tvalid),
    .O_tlast     (osd_tlast),
    .O_tuser     (osd_tuser),
    .O_tready    ()
);

//------------------------------------------------------------------------------
// 检查计数器（必须给初值，否则 4 值整型上电是 x）
//------------------------------------------------------------------------------
integer n_lat_m0_1m = 0, e_lat_m0_1m = 0;
integer n_osd_m0_1m = 0, e_osd_m0_1m = 0;
integer n_fps_m0_1m = 0, e_fps_m0_1m = 0;
integer n_cnt_m0_1m = 0, e_cnt_m0_1m = 0;
integer n_lat_m3_1m = 0, e_lat_m3_1m = 0;
integer n_osd_m3_1m = 0, e_osd_m3_1m = 0;
integer n_fps_m3_1m = 0, e_fps_m3_1m = 0;
integer n_cnt_m3_1m = 0, e_cnt_m3_1m = 0;
integer n_lat_m0_59 = 0, e_lat_m0_59 = 0;
integer n_osd_m0_59 = 0, e_osd_m0_59 = 0;
integer n_fps_m0_59 = 0, e_fps_m0_59 = 0;
integer n_cnt_m0_59 = 0, e_cnt_m0_59 = 0;
integer n_lat_m3_59 = 0, e_lat_m3_59 = 0;
integer n_osd_m3_59 = 0, e_osd_m3_59 = 0;
integer n_fps_m3_59 = 0, e_fps_m3_59 = 0;
integer n_cnt_m3_59 = 0, e_cnt_m3_59 = 0;
integer n_ref = 0, e_ref = 0;
// 档位是否真的生效（否则"M3 档 LAT"会退化成"M0 档 LAT"，结论就空了）
integer n_mode_m0_1m = 0, e_mode_m0_1m = 0;
integer n_mode_m3_1m = 0, e_mode_m3_1m = 0;
integer n_mode_m0_59 = 0, e_mode_m0_59 = 0;
integer n_mode_m3_59 = 0, e_mode_m3_59 = 0;
// 第 5 档：真实 59.94fps 源（59.995MHz 下周期 1,000,917 拍）—— 这一档才区分
// "截断显示 59" 与 "四舍五入显示 60"，是任务 A 的动机档
integer n_lat_1m917 = 0, e_lat_1m917 = 0;
integer n_osd_1m917 = 0, e_osd_1m917 = 0;
integer n_fps_1m917 = 0, e_fps_1m917 = 0;
integer n_cnt_1m917 = 0, e_cnt_1m917 = 0;
integer n_mode_1m917 = 0, e_mode_1m917 = 0;

integer   ex_fps;
reg [7:0] ex_bcd;

//------------------------------------------------------------------------------
// 收尾
//------------------------------------------------------------------------------
reg done_all;
initial done_all = 1'b0;

always @(posedge clk) begin
    if (done_all) begin
        $display("[TB] ALL DONE");
        $finish;
    end
end

initial begin
    #500000000;
    $display("[TB] TIMEOUT 看门狗触发（500ms 仿真时间）");
    $finish;
end

//------------------------------------------------------------------------------
// 配置 1：M0 + 周期 1,000,000 拍
//------------------------------------------------------------------------------
initial begin
    rst_n    = 1'b0;
    mode_sel = 3'd0;
    period   = 25'd1000000;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3*1000000 + 3000) @(posedge clk);

    ex_fps = (60000000 + tb_gap / 2) / tb_gap;
    if ((ex_fps < 1) || (ex_fps > 99)) ex_bcd = 8'h00;
    else ex_bcd = (ex_fps / 10) * 16 + (ex_fps % 10);
    $display("[RPT] cfg M0/1e6: mode=%0d LAT=%0d osd_r_info_lat=%0d O_fps_bcd=0x%02x 期望0x%02x (C=%0d)",
             alg_mode, lat_val, u_osd.r_info_lat, lat_fps, ex_bcd, tb_gap);

    if (alg_mode !== 3'd0) begin
        e_mode_m0_1m = e_mode_m0_1m + 1;
        $display("  [ERR] I.mode_m0_1m alg_top O_mode=%0d 期望 0（档位没生效，本档结论无效）", alg_mode);
    end
    n_mode_m0_1m = n_mode_m0_1m + 1;

    if (lat_val !== tb_lat_val[10:0]) begin
        e_lat_m0_1m = e_lat_m0_1m + 1;
        $display("  [ERR] I.lat_m0_1m O_lat_clk=%0d TB独立实测=%0d", lat_val, tb_lat_val);
    end
    n_lat_m0_1m = n_lat_m0_1m + 1;
    if (u_osd.r_info_lat !== lat_val) begin
        e_osd_m0_1m = e_osd_m0_1m + 1;
        $display("  [ERR] I.osd_m0_1m OSD 内部 r_info_lat=%0d 与 O_lat_clk=%0d 不符",
                 u_osd.r_info_lat, lat_val);
    end
    n_osd_m0_1m = n_osd_m0_1m + 1;
    if (lat_fps !== ex_bcd) begin
        e_fps_m0_1m = e_fps_m0_1m + 1;
        $display("  [ERR] I.fps_m0_1m O_fps_bcd=0x%02x 期望 0x%02x", lat_fps, ex_bcd);
    end
    n_fps_m0_1m = n_fps_m0_1m + 1;
    if (lat_fcnt !== tb_frm) begin
        e_cnt_m0_1m = e_cnt_m0_1m + 1;
        $display("  [ERR] I.cnt_m0_1m O_frame_cnt=%0d 期望 %0d", lat_fcnt, tb_frm);
    end
    n_cnt_m0_1m = n_cnt_m0_1m + 1;
    if ((tb_lat_val == 16'd0) || (tb_gap < 25'd999000) || (tb_frm !== 32'd3)) begin
        e_ref = e_ref + 1;
        $display("  [ERR] I.ref M0/1e6 前置条件不成立：tb_lat=%0d tb_gap=%0d tb_frm=%0d",
                 tb_lat_val, tb_gap, tb_frm);
    end
    n_ref = n_ref + 1;
    $display("[CHK] I_lat_m0_1m cnt=%0d err=%0d", n_lat_m0_1m, e_lat_m0_1m);
    $display("[CHK] I_osd_lat_m0_1m cnt=%0d err=%0d", n_osd_m0_1m, e_osd_m0_1m);
    $display("[CHK] I_fps_m0_1m cnt=%0d err=%0d", n_fps_m0_1m, e_fps_m0_1m);
    $display("[CHK] I_cnt_m0_1m cnt=%0d err=%0d", n_cnt_m0_1m, e_cnt_m0_1m);
    $display("[CHK] I_mode_m0_1m cnt=%0d err=%0d", n_mode_m0_1m, e_mode_m0_1m);
end

//------------------------------------------------------------------------------
// 配置 2：M3 + 周期 1,000,000 拍
//------------------------------------------------------------------------------
initial begin
    repeat (3*1000000 + 6000) @(posedge clk);       // 等配置 1 的检查做完
    rst_n    = 1'b0;
    mode_sel = 3'd3;
    period   = 25'd1000000;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3*1000000 + 3000) @(posedge clk);

    ex_fps = (60000000 + tb_gap / 2) / tb_gap;
    if ((ex_fps < 1) || (ex_fps > 99)) ex_bcd = 8'h00;
    else ex_bcd = (ex_fps / 10) * 16 + (ex_fps % 10);
    $display("[RPT] cfg M3/1e6: mode=%0d LAT=%0d osd_r_info_lat=%0d O_fps_bcd=0x%02x 期望0x%02x (C=%0d)",
             alg_mode, lat_val, u_osd.r_info_lat, lat_fps, ex_bcd, tb_gap);

    if (alg_mode !== 3'd3) begin
        e_mode_m3_1m = e_mode_m3_1m + 1;
        $display("  [ERR] I.mode_m3_1m alg_top O_mode=%0d 期望 3（档位没生效，本档结论无效）", alg_mode);
    end
    n_mode_m3_1m = n_mode_m3_1m + 1;

    if (lat_val !== tb_lat_val[10:0]) begin
        e_lat_m3_1m = e_lat_m3_1m + 1;
        $display("  [ERR] I.lat_m3_1m O_lat_clk=%0d TB独立实测=%0d", lat_val, tb_lat_val);
    end
    n_lat_m3_1m = n_lat_m3_1m + 1;
    if (u_osd.r_info_lat !== lat_val) begin
        e_osd_m3_1m = e_osd_m3_1m + 1;
        $display("  [ERR] I.osd_m3_1m OSD 内部 r_info_lat=%0d 与 O_lat_clk=%0d 不符",
                 u_osd.r_info_lat, lat_val);
    end
    n_osd_m3_1m = n_osd_m3_1m + 1;
    if (lat_fps !== ex_bcd) begin
        e_fps_m3_1m = e_fps_m3_1m + 1;
        $display("  [ERR] I.fps_m3_1m O_fps_bcd=0x%02x 期望 0x%02x", lat_fps, ex_bcd);
    end
    n_fps_m3_1m = n_fps_m3_1m + 1;
    if (lat_fcnt !== tb_frm) begin
        e_cnt_m3_1m = e_cnt_m3_1m + 1;
        $display("  [ERR] I.cnt_m3_1m O_frame_cnt=%0d 期望 %0d", lat_fcnt, tb_frm);
    end
    n_cnt_m3_1m = n_cnt_m3_1m + 1;
    $display("[CHK] I_lat_m3_1m cnt=%0d err=%0d", n_lat_m3_1m, e_lat_m3_1m);
    $display("[CHK] I_osd_lat_m3_1m cnt=%0d err=%0d", n_osd_m3_1m, e_osd_m3_1m);
    $display("[CHK] I_fps_m3_1m cnt=%0d err=%0d", n_fps_m3_1m, e_fps_m3_1m);
    $display("[CHK] I_cnt_m3_1m cnt=%0d err=%0d", n_cnt_m3_1m, e_cnt_m3_1m);
    $display("[CHK] I_mode_m3_1m cnt=%0d err=%0d", n_mode_m3_1m, e_mode_m3_1m);
end

//------------------------------------------------------------------------------
// 配置 3：M0 + 周期 999,917 拍（59.94fps @59.995MHz 的等效周期）
//------------------------------------------------------------------------------
initial begin
    repeat (2*(3*1000000 + 6000)) @(posedge clk);   // 等配置 2 的检查做完
    rst_n    = 1'b0;
    mode_sel = 3'd0;
    period   = 25'd999917;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3*1000000 + 3000) @(posedge clk);

    ex_fps = (60000000 + tb_gap / 2) / tb_gap;
    if ((ex_fps < 1) || (ex_fps > 99)) ex_bcd = 8'h00;
    else ex_bcd = (ex_fps / 10) * 16 + (ex_fps % 10);
    $display("[RPT] cfg M0/999917: mode=%0d LAT=%0d osd_r_info_lat=%0d O_fps_bcd=0x%02x 期望0x%02x (C=%0d)",
             alg_mode, lat_val, u_osd.r_info_lat, lat_fps, ex_bcd, tb_gap);

    if (alg_mode !== 3'd0) begin
        e_mode_m0_59 = e_mode_m0_59 + 1;
        $display("  [ERR] I.mode_m0_59 alg_top O_mode=%0d 期望 0（档位没生效，本档结论无效）", alg_mode);
    end
    n_mode_m0_59 = n_mode_m0_59 + 1;

    if (lat_val !== tb_lat_val[10:0]) begin
        e_lat_m0_59 = e_lat_m0_59 + 1;
        $display("  [ERR] I.lat_m0_59 O_lat_clk=%0d TB独立实测=%0d", lat_val, tb_lat_val);
    end
    n_lat_m0_59 = n_lat_m0_59 + 1;
    if (u_osd.r_info_lat !== lat_val) begin
        e_osd_m0_59 = e_osd_m0_59 + 1;
        $display("  [ERR] I.osd_m0_59 OSD 内部 r_info_lat=%0d 与 O_lat_clk=%0d 不符",
                 u_osd.r_info_lat, lat_val);
    end
    n_osd_m0_59 = n_osd_m0_59 + 1;
    if (lat_fps !== ex_bcd) begin
        e_fps_m0_59 = e_fps_m0_59 + 1;
        $display("  [ERR] I.fps_m0_59 O_fps_bcd=0x%02x 期望 0x%02x", lat_fps, ex_bcd);
    end
    n_fps_m0_59 = n_fps_m0_59 + 1;
    if (lat_fcnt !== tb_frm) begin
        e_cnt_m0_59 = e_cnt_m0_59 + 1;
        $display("  [ERR] I.cnt_m0_59 O_frame_cnt=%0d 期望 %0d", lat_fcnt, tb_frm);
    end
    n_cnt_m0_59 = n_cnt_m0_59 + 1;
    if ((tb_lat_val == 16'd0) || (tb_gap < 25'd999000) || (tb_frm !== 32'd3)) begin
        e_ref = e_ref + 1;
        $display("  [ERR] I.ref M0/999917 前置条件不成立：tb_lat=%0d tb_gap=%0d tb_frm=%0d",
                 tb_lat_val, tb_gap, tb_frm);
    end
    n_ref = n_ref + 1;
    $display("[CHK] I_lat_m0_59 cnt=%0d err=%0d", n_lat_m0_59, e_lat_m0_59);
    $display("[CHK] I_osd_lat_m0_59 cnt=%0d err=%0d", n_osd_m0_59, e_osd_m0_59);
    $display("[CHK] I_fps_m0_59 cnt=%0d err=%0d", n_fps_m0_59, e_fps_m0_59);
    $display("[CHK] I_cnt_m0_59 cnt=%0d err=%0d", n_cnt_m0_59, e_cnt_m0_59);
    $display("[CHK] I_mode_m0_59 cnt=%0d err=%0d", n_mode_m0_59, e_mode_m0_59);
end

//------------------------------------------------------------------------------
// 配置 4：M3 + 周期 999,917 拍
//------------------------------------------------------------------------------
initial begin
    repeat (3*(3*1000000 + 6000)) @(posedge clk);   // 等配置 3 的检查做完
    rst_n    = 1'b0;
    mode_sel = 3'd3;
    period   = 25'd999917;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3*1000000 + 3000) @(posedge clk);

    ex_fps = (60000000 + tb_gap / 2) / tb_gap;
    if ((ex_fps < 1) || (ex_fps > 99)) ex_bcd = 8'h00;
    else ex_bcd = (ex_fps / 10) * 16 + (ex_fps % 10);
    $display("[RPT] cfg M3/999917: mode=%0d LAT=%0d osd_r_info_lat=%0d O_fps_bcd=0x%02x 期望0x%02x (C=%0d)",
             alg_mode, lat_val, u_osd.r_info_lat, lat_fps, ex_bcd, tb_gap);

    if (alg_mode !== 3'd3) begin
        e_mode_m3_59 = e_mode_m3_59 + 1;
        $display("  [ERR] I.mode_m3_59 alg_top O_mode=%0d 期望 3（档位没生效，本档结论无效）", alg_mode);
    end
    n_mode_m3_59 = n_mode_m3_59 + 1;

    if (lat_val !== tb_lat_val[10:0]) begin
        e_lat_m3_59 = e_lat_m3_59 + 1;
        $display("  [ERR] I.lat_m3_59 O_lat_clk=%0d TB独立实测=%0d", lat_val, tb_lat_val);
    end
    n_lat_m3_59 = n_lat_m3_59 + 1;
    if (u_osd.r_info_lat !== lat_val) begin
        e_osd_m3_59 = e_osd_m3_59 + 1;
        $display("  [ERR] I.osd_m3_59 OSD 内部 r_info_lat=%0d 与 O_lat_clk=%0d 不符",
                 u_osd.r_info_lat, lat_val);
    end
    n_osd_m3_59 = n_osd_m3_59 + 1;
    if (lat_fps !== ex_bcd) begin
        e_fps_m3_59 = e_fps_m3_59 + 1;
        $display("  [ERR] I.fps_m3_59 O_fps_bcd=0x%02x 期望 0x%02x", lat_fps, ex_bcd);
    end
    n_fps_m3_59 = n_fps_m3_59 + 1;
    if (lat_fcnt !== tb_frm) begin
        e_cnt_m3_59 = e_cnt_m3_59 + 1;
        $display("  [ERR] I.cnt_m3_59 O_frame_cnt=%0d 期望 %0d", lat_fcnt, tb_frm);
    end
    n_cnt_m3_59 = n_cnt_m3_59 + 1;
    $display("[CHK] I_lat_m3_59 cnt=%0d err=%0d", n_lat_m3_59, e_lat_m3_59);
    $display("[CHK] I_osd_lat_m3_59 cnt=%0d err=%0d", n_osd_m3_59, e_osd_m3_59);
    $display("[CHK] I_fps_m3_59 cnt=%0d err=%0d", n_fps_m3_59, e_fps_m3_59);
    $display("[CHK] I_cnt_m3_59 cnt=%0d err=%0d", n_cnt_m3_59, e_cnt_m3_59);
    $display("[CHK] I_mode_m3_59 cnt=%0d err=%0d", n_mode_m3_59, e_mode_m3_59);
end

//------------------------------------------------------------------------------
// 配置 5：M0 + 周期 1,000,917 拍（真实 59.94fps 源 @59.995MHz 的等效周期）
//   60e6/1000917 = 59.945 → 截断会显示 59；四舍五入显示 60。这一档是任务 A 的动机。
//------------------------------------------------------------------------------
initial begin
    repeat (4*(3*1000000 + 6000)) @(posedge clk);   // 等配置 4 的检查做完
    rst_n    = 1'b0;
    mode_sel = 3'd0;
    period   = 25'd1000917;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (3*1000917 + 3000) @(posedge clk);

    ex_fps = (60000000 + tb_gap / 2) / tb_gap;
    if ((ex_fps < 1) || (ex_fps > 99)) ex_bcd = 8'h00;
    else ex_bcd = (ex_fps / 10) * 16 + (ex_fps % 10);
    $display("[RPT] cfg M0/1000917: mode=%0d LAT=%0d osd_r_info_lat=%0d O_fps_bcd=0x%02x 期望0x%02x (C=%0d)",
             alg_mode, lat_val, u_osd.r_info_lat, lat_fps, ex_bcd, tb_gap);

    if (alg_mode !== 3'd0) begin
        e_mode_1m917 = e_mode_1m917 + 1;
        $display("  [ERR] I.mode_1m917 alg_top O_mode=%0d 期望 0", alg_mode);
    end
    n_mode_1m917 = n_mode_1m917 + 1;
    if (lat_val !== tb_lat_val[10:0]) begin
        e_lat_1m917 = e_lat_1m917 + 1;
        $display("  [ERR] I.lat_1m917 O_lat_clk=%0d TB独立实测=%0d", lat_val, tb_lat_val);
    end
    n_lat_1m917 = n_lat_1m917 + 1;
    if (u_osd.r_info_lat !== lat_val) begin
        e_osd_1m917 = e_osd_1m917 + 1;
        $display("  [ERR] I.osd_1m917 OSD 内部 r_info_lat=%0d 与 O_lat_clk=%0d 不符",
                 u_osd.r_info_lat, lat_val);
    end
    n_osd_1m917 = n_osd_1m917 + 1;
    if (lat_fps !== ex_bcd) begin
        e_fps_1m917 = e_fps_1m917 + 1;
        $display("  [ERR] I.fps_1m917 O_fps_bcd=0x%02x 期望 0x%02x（截断写法会是 0x59）",
                 lat_fps, ex_bcd);
    end
    n_fps_1m917 = n_fps_1m917 + 1;
    if (lat_fcnt !== tb_frm) begin
        e_cnt_1m917 = e_cnt_1m917 + 1;
        $display("  [ERR] I.cnt_1m917 O_frame_cnt=%0d 期望 %0d", lat_fcnt, tb_frm);
    end
    n_cnt_1m917 = n_cnt_1m917 + 1;
    if ((tb_lat_val == 16'd0) || (tb_gap < 25'd999000) || (tb_frm !== 32'd3)) begin
        e_ref = e_ref + 1;
        $display("  [ERR] I.ref M0/1000917 前置条件不成立：tb_lat=%0d tb_gap=%0d tb_frm=%0d",
                 tb_lat_val, tb_gap, tb_frm);
    end
    n_ref = n_ref + 1;
    $display("[CHK] I_lat_1m917 cnt=%0d err=%0d", n_lat_1m917, e_lat_1m917);
    $display("[CHK] I_osd_lat_1m917 cnt=%0d err=%0d", n_osd_1m917, e_osd_1m917);
    $display("[CHK] I_fps_1m917 cnt=%0d err=%0d", n_fps_1m917, e_fps_1m917);
    $display("[CHK] I_cnt_1m917 cnt=%0d err=%0d", n_cnt_1m917, e_cnt_1m917);
    $display("[CHK] I_mode_1m917 cnt=%0d err=%0d", n_mode_1m917, e_mode_1m917);
    $display("[CHK] I_ref cnt=%0d err=%0d", n_ref, e_ref);
    done_all = 1'b1;
end

endmodule
