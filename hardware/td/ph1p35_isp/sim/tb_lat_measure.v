//==============================================================================
// tb_lat_measure.v —— lat_measure 独立自检 TB（不接 osd_mixer，先把这个模块验干净）
//------------------------------------------------------------------------------
// 【一、三个 DUT 的职责（每个 DUT 一个参数档，用不同的 CLK_HZ/量程覆盖边界）】
//   dut_a：CLK_HZ=60_000_000，周期 1,000,000 拍 → FPS 必须正好 60 → 8'h60
//          （需求点名的"真实频率"档；同时覆盖"只来一帧"和"中途复位"）
//   dut_b：CLK_HZ=1000，PERIOD_MAX=255 → 用小周期覆盖 1 位数(4/5)、两位数(91/83)、
//          FPS=100 超范围、周期=1 极小、周期=255 量程上限、周期=256 超量程、
//          超量程后恢复、延迟 7→13 切换（证明延迟是实测不是常数）
//   dut_c：CLK_HZ=99_000，PERIOD_MAX=4095 → FPS=99 上边界、50（半整数进位）、超量程，
//          以及"除法器正在跑时中途复位"（专抓复位没清干净）
//
// 【二、激励与判据口径】
//   · 时钟 100MHz（周期 10ns）。lat_measure 只"数拍"，FPS 绝对值由 DUT 的 CLK_HZ
//     参数决定，与 TB 时钟频率无关 —— 用快时钟纯粹为了缩短仿真时间。
//   · tuser 发生器：每 gap 拍一个宽 1 拍的帧首；gap=1 时 tuser 恒 1（每拍一个帧首），
//     这是"极小周期"边界。
//   · 输出侧 tuser = 输入 tuser 打 7 拍或 13 拍（sel13 切换），验证 O_lat_clk 是
//     "测出来的"：注入 7 就得 7，切到 13 就得 13。
//   · 参考模型：TB 自己数两次 tuser 之间的实际拍数（refgap）和帧首个数（reffrm），
//     用**整数除法 (CLK_HZ + C/2)/C**（= 四舍五入）独立算期望 BCD 再和 DUT 比。
//     只在本周期与上一周期都 >=150 拍、且距上一个帧首 >=100 拍时比对
//     （保证 DUT 除法器一定算完、帧首请求不会被丢）。
//   · 每条断言都用 [CHK] 行打印检查次数与失配数，由 check_lat_measure.py 统计；
//     任何一条断言 0 次检查即判失败（禁止"空跑也算绿"）。
//==============================================================================
`timescale 1ns / 1ps

module tb_lat_measure;

//------------------------------------------------------------------------------
// 全局时钟（100MHz）
//------------------------------------------------------------------------------
reg clk;
initial clk = 1'b0;
always #5 clk = ~clk;

//------------------------------------------------------------------------------
// 检查计数器（n_ = 检查次数，e_ = 失配数）
// ※ 必须给初值：4 值整型上电是 x，x+1 永远是 x，会让 [CHK] 打印成 cnt=x（吃过这个亏）
integer na_first = 0, ea_first = 0;   // A：1e6 周期窗口内只来一帧 → fps 必须是 0
integer na_lat7  = 0, ea_lat7  = 0;   // A：延迟 = 7
integer na_cnt   = 0, ea_cnt   = 0;   // A：帧计数 = 参考模型帧数
integer na_fps60 = 0, ea_fps60 = 0;   // A：1e6 周期 @60MHz → 8'h60
integer na_rstclr= 0, ea_rstclr= 0;   // A：中途复位 → cnt/fps/lat 全 0
integer na_aftcnt= 0, ea_aftcnt= 0;   // A：复位后帧计数重新与参考一致
integer na_aftlat= 0, ea_aftlat= 0;   // A：复位后延迟重测
integer na_aftfps= 0, ea_aftfps= 0;   // A：复位后 60e6/200 超范围 → 安全值 0
integer nref_a   = 0, eref_a   = 0;   // A：参考模型比对

integer nb_cnt1  = 0, eb_cnt1  = 0;   // B：只来一帧
integer nb_lat7  = 0, eb_lat7  = 0;   // B：延迟 = 7
integer nb_fps04 = 0, eb_fps04 = 0;   // B：round(1000/250) = 4 → 8'h04
integer nb_fps05 = 0, eb_fps05 = 0;   // B：round(1000/200) = 5 → 8'h05（1 位数）
integer nb_fps91 = 0, eb_fps91 = 0;   // B：round(1000/11) = 91 → 8'h91（四舍五入生效）
integer nb_fps83 = 0, eb_fps83 = 0;   // B：round(1000/12) = 83 → 8'h83（两位、个位非 0）
integer nb_inv100= 0, eb_inv100= 0;   // B：round(1000/10) = 100 → 超范围 → 8'h00
integer nb_inv250= 0, eb_inv250= 0;   // B：round(1000/4) = 250 → 超范围 → 8'h00
integer nb_inv1k = 0, eb_inv1k = 0;   // B：round(1000/1) = 1000 → 超范围（极小周期）→ 8'h00
integer nb_maxg  = 0, eb_maxg  = 0;   // B：周期=255=量程上限 → round(1000/255)=4 → 8'h04
integer nb_over  = 0, eb_over  = 0;   // B：周期=256 超量程 → 无效 → 8'h00
integer nb_recov = 0, eb_recov = 0;   // B：超量程后恢复 → 8'h05
integer nb_rstclr= 0, eb_rstclr= 0;   // B：中途复位清零
integer nb_rstfps= 0, eb_rstfps= 0;   // B：复位后重新测到 8'h05
integer nb_rstcnt= 0, eb_rstcnt= 0;   // B：复位后帧计数与参考一致
integer nb_lat13 = 0, eb_lat13 = 0;   // B：延迟切成 13 拍 → 13
integer nref_b   = 0, eref_b   = 0;   // B：参考模型比对

integer nc_fps99 = 0, ec_fps99 = 0;   // C：round(99000/1000) = 99 → 8'h99（上边界）
integer nc_fps50 = 0, ec_fps50 = 0;   // C：round(99000/2000) = round(49.5) = 50 → 8'h50
integer nc_over  = 0, ec_over  = 0;   // C：周期 5000 > 4095 → 无效 → 8'h00
integer nc_recov = 0, ec_recov = 0;   // C：超量程后恢复 → 8'h99
integer nc_rstdv = 0, ec_rstdv = 0;   // C：除法器正在跑时复位 → 立即清零
integer nc_rstfp = 0, ec_rstfp = 0;   // C：上述复位后仍能测出 8'h99
integer nref_c   = 0, eref_c   = 0;   // C：参考模型比对

//------------------------------------------------------------------------------
// dut_a：真实频率档
//------------------------------------------------------------------------------
reg         rst_a;
reg  [24:0] gap_a;
reg  [24:0] cnt_a;
reg         inu_a;
reg  [18:0] sh_a;                                   // 延迟链：bit6=7 拍，bit12=13 拍
reg         sel13_a;
wire        outu_a = sel13_a ? sh_a[12] : sh_a[6];
wire [31:0] fcnt_a;
wire [7:0]  fps_a;
wire [10:0] lat_a;
reg  [24:0] refcnt_a, refgap_a, refgap_p_a;
reg  [31:0] reffrm_a;
integer     tick_a, exfps_a;
reg  [7:0]  exbcd_a;

lat_measure #(.CLK_HZ(60000000), .PERIOD_MAX(24'hFFFFFF)) dut_a (
    .I_clk(clk), .I_rst_n(rst_a),
    .I_in_tvalid(1'b1), .I_in_tuser(inu_a),
    .I_out_tvalid(1'b1), .I_out_tuser(outu_a),
    .O_frame_cnt(fcnt_a), .O_fps_bcd(fps_a), .O_lat_clk(lat_a)
);

always @(posedge clk) begin
    if (!rst_a) begin cnt_a <= 25'd0; inu_a <= 1'b0; end
    else if (cnt_a >= (gap_a - 25'd1)) begin cnt_a <= 25'd0; inu_a <= 1'b1; end
    else begin cnt_a <= cnt_a + 25'd1; inu_a <= 1'b0; end
end

always @(posedge clk) begin
    if (!rst_a) sh_a <= 19'd0;
    else        sh_a <= {sh_a[17:0], inu_a};
end

always @(posedge clk) begin
    if (!rst_a) begin
        refcnt_a <= 25'd0; refgap_a <= 25'd0; refgap_p_a <= 25'd0; reffrm_a <= 32'd0;
    end else if (inu_a) begin
        refgap_p_a <= refgap_a;
        refgap_a   <= refcnt_a + 25'd1;
        refcnt_a   <= 25'd0;
        reffrm_a   <= reffrm_a + 32'd1;
    end else begin
        refcnt_a <= refcnt_a + 25'd1;
    end
end

always @(posedge clk) begin
    if (!rst_a) begin
        tick_a <= 0;
    end else if (tick_a >= 127) begin
        tick_a <= 0;
        if ((refcnt_a >= 25'd100) && (refgap_a >= 25'd150) && (refgap_p_a >= 25'd150)) begin
            exfps_a = (60000000 + refgap_a / 2) / refgap_a;   // 四舍五入（与 DUT 同口径）
            if ((refgap_a > 25'd16777215) || (exfps_a < 1) || (exfps_a > 99)) exbcd_a = 8'h00;
            else exbcd_a = (exfps_a / 10) * 16 + (exfps_a % 10);
            if (fps_a !== exbcd_a) begin
                eref_a = eref_a + 1;
                $display("  [ERR] A.ref gap=%0d 期望 0x%02x 实测 0x%02x", refgap_a, exbcd_a, fps_a);
            end
            nref_a = nref_a + 1;
        end
    end else begin
        tick_a <= tick_a + 1;
    end
end

//------------------------------------------------------------------------------
// dut_b：小周期档
//------------------------------------------------------------------------------
reg         rst_b;
reg  [24:0] gap_b;
reg  [24:0] cnt_b;
reg         inu_b;
reg  [12:0] sh7_b;
reg  [18:0] sh13_b;
reg         sel13_b;
wire        outu_b = sel13_b ? sh13_b[12] : sh7_b[6];
wire [31:0] fcnt_b;
wire [7:0]  fps_b;
wire [10:0] lat_b;
reg  [24:0] refcnt_b, refgap_b, refgap_p_b;
reg  [31:0] reffrm_b;
integer     tick_b, exfps_b;
reg  [7:0]  exbcd_b;

lat_measure #(.CLK_HZ(1000), .PERIOD_MAX(24'h0000FF)) dut_b (
    .I_clk(clk), .I_rst_n(rst_b),
    .I_in_tvalid(1'b1), .I_in_tuser(inu_b),
    .I_out_tvalid(1'b1), .I_out_tuser(outu_b),
    .O_frame_cnt(fcnt_b), .O_fps_bcd(fps_b), .O_lat_clk(lat_b)
);

always @(posedge clk) begin
    if (!rst_b) begin cnt_b <= 25'd0; inu_b <= 1'b0; end
    else if (cnt_b >= (gap_b - 25'd1)) begin cnt_b <= 25'd0; inu_b <= 1'b1; end
    else begin cnt_b <= cnt_b + 25'd1; inu_b <= 1'b0; end
end

always @(posedge clk) begin
    if (!rst_b) begin sh7_b <= 13'd0; sh13_b <= 19'd0; end
    else begin
        sh7_b  <= {sh7_b[11:0],  inu_b};
        sh13_b <= {sh13_b[17:0], inu_b};
    end
end

always @(posedge clk) begin
    if (!rst_b) begin
        refcnt_b <= 25'd0; refgap_b <= 25'd0; refgap_p_b <= 25'd0; reffrm_b <= 32'd0;
    end else if (inu_b) begin
        refgap_p_b <= refgap_b;
        refgap_b   <= refcnt_b + 25'd1;
        refcnt_b   <= 25'd0;
        reffrm_b   <= reffrm_b + 32'd1;
    end else begin
        refcnt_b <= refcnt_b + 25'd1;
    end
end

always @(posedge clk) begin
    if (!rst_b) begin
        tick_b <= 0;
    end else if (tick_b >= 127) begin
        tick_b <= 0;
        if ((refcnt_b >= 25'd100) && (refgap_b >= 25'd150) && (refgap_p_b >= 25'd150)) begin
            exfps_b = (1000 + refgap_b / 2) / refgap_b;       // 四舍五入（与 DUT 同口径）
            if ((refgap_b > 25'd255) || (exfps_b < 1) || (exfps_b > 99)) exbcd_b = 8'h00;
            else exbcd_b = (exfps_b / 10) * 16 + (exfps_b % 10);
            if (fps_b !== exbcd_b) begin
                eref_b = eref_b + 1;
                $display("  [ERR] B.ref gap=%0d 期望 0x%02x 实测 0x%02x", refgap_b, exbcd_b, fps_b);
            end
            nref_b = nref_b + 1;
        end
    end else begin
        tick_b <= tick_b + 1;
    end
end

//------------------------------------------------------------------------------
// dut_c：FPS 上边界 + 除法中复位
//------------------------------------------------------------------------------
reg         rst_c;
reg  [24:0] gap_c;
reg  [24:0] cnt_c;
reg         inu_c;
reg  [12:0] sh7_c;
wire        outu_c = sh7_c[6];
wire [31:0] fcnt_c;
wire [7:0]  fps_c;
wire [10:0] lat_c;
reg  [24:0] refcnt_c, refgap_c, refgap_p_c;
reg  [31:0] reffrm_c;
integer     tick_c, exfps_c;
reg  [7:0]  exbcd_c;

lat_measure #(.CLK_HZ(99000), .PERIOD_MAX(24'h000FFF)) dut_c (
    .I_clk(clk), .I_rst_n(rst_c),
    .I_in_tvalid(1'b1), .I_in_tuser(inu_c),
    .I_out_tvalid(1'b1), .I_out_tuser(outu_c),
    .O_frame_cnt(fcnt_c), .O_fps_bcd(fps_c), .O_lat_clk(lat_c)
);

always @(posedge clk) begin
    if (!rst_c) begin cnt_c <= 25'd0; inu_c <= 1'b0; end
    else if (cnt_c >= (gap_c - 25'd1)) begin cnt_c <= 25'd0; inu_c <= 1'b1; end
    else begin cnt_c <= cnt_c + 25'd1; inu_c <= 1'b0; end
end

always @(posedge clk) begin
    if (!rst_c) sh7_c <= 13'd0;
    else        sh7_c <= {sh7_c[11:0], inu_c};
end

always @(posedge clk) begin
    if (!rst_c) begin
        refcnt_c <= 25'd0; refgap_c <= 25'd0; refgap_p_c <= 25'd0; reffrm_c <= 32'd0;
    end else if (inu_c) begin
        refgap_p_c <= refgap_c;
        refgap_c   <= refcnt_c + 25'd1;
        refcnt_c   <= 25'd0;
        reffrm_c   <= reffrm_c + 32'd1;
    end else begin
        refcnt_c <= refcnt_c + 25'd1;
    end
end

always @(posedge clk) begin
    if (!rst_c) begin
        tick_c <= 0;
    end else if (tick_c >= 127) begin
        tick_c <= 0;
        if ((refcnt_c >= 25'd100) && (refgap_c >= 25'd150) && (refgap_p_c >= 25'd150)) begin
            exfps_c = (99000 + refgap_c / 2) / refgap_c;       // 四舍五入（与 DUT 同口径）
            if ((refgap_c > 25'd4095) || (exfps_c < 1) || (exfps_c > 99)) exbcd_c = 8'h00;
            else exbcd_c = (exfps_c / 10) * 16 + (exfps_c % 10);
            if (fps_c !== exbcd_c) begin
                eref_c = eref_c + 1;
                $display("  [ERR] C.ref gap=%0d 期望 0x%02x 实测 0x%02x", refgap_c, exbcd_c, fps_c);
            end
            nref_c = nref_c + 1;
        end
    end else begin
        tick_c <= tick_c + 1;
    end
end

//------------------------------------------------------------------------------
// 收尾：三个 DUT 全跑完 → 打印汇总；另有看门狗防挂死
//------------------------------------------------------------------------------
integer done_cnt;
reg done_a, done_b, done_c;
initial begin done_a = 1'b0; done_b = 1'b0; done_c = 1'b0; end

always @(posedge clk) begin
    done_cnt = (done_a ? 1 : 0) + (done_b ? 1 : 0) + (done_c ? 1 : 0);
    if (done_cnt == 3) begin
        $display("[TB] ALL DONE");
        $finish;
    end
end

initial begin
    #400000000;
    $display("[TB] TIMEOUT 看门狗触发（400ms 仿真时间）");
    $finish;
end

//------------------------------------------------------------------------------
// dut_a 激励：真实频率档 —— 1,000,000 拍周期 @60MHz → FPS=60
//------------------------------------------------------------------------------
initial begin
    rst_a   = 1'b0;
    sel13_a = 1'b0;                 // 输出延迟 7 拍
    gap_a   = 25'd1000000;          // 1e6 拍一个帧首
    repeat (10) @(posedge clk);
    rst_a = 1'b1;

    // 第一个帧首已到、第二个还没到 → FPS 必须是安全值 0（"只来一帧"）
    repeat (1100000) @(posedge clk);
    if (reffrm_a !== 32'd1) begin
        ea_first = ea_first + 1;
        $display("  [ERR] A.first TB 窗口失效：参考帧数应为 1，实测 %0d", reffrm_a);
    end
    if (fps_a !== 8'h00) begin
        ea_first = ea_first + 1;
        $display("  [ERR] A.first 只来一帧时期望 fps=0x00 实测 0x%02x", fps_a);
    end
    na_first = na_first + 1;
    if (fcnt_a !== reffrm_a) begin
        ea_cnt = ea_cnt + 1;
        $display("  [ERR] A.cnt 期望 %0d 实测 %0d", reffrm_a, fcnt_a);
    end
    na_cnt = na_cnt + 1;
    if (lat_a !== 11'd7) begin
        ea_lat7 = ea_lat7 + 1;
        $display("  [ERR] A.lat7 期望 7 实测 %0d", lat_a);
    end
    na_lat7 = na_lat7 + 1;

    // 再等一个完整周期：第二个帧首 → 除法器算出 FPS
    repeat (1100000) @(posedge clk);
    if (fps_a !== 8'h60) begin
        ea_fps60 = ea_fps60 + 1;
        $display("  [ERR] A.fps60 周期 1000000 @60MHz 期望 0x60 实测 0x%02x", fps_a);
    end
    na_fps60 = na_fps60 + 1;
    if (fcnt_a !== reffrm_a) begin
        ea_cnt = ea_cnt + 1;
        $display("  [ERR] A.cnt 期望 %0d 实测 %0d", reffrm_a, fcnt_a);
    end
    na_cnt = na_cnt + 1;
    if (lat_a !== 11'd7) begin
        ea_lat7 = ea_lat7 + 1;
        $display("  [ERR] A.lat7 第二帧后期望 7 实测 %0d", lat_a);
    end
    na_lat7 = na_lat7 + 1;

    // 中途复位：输出必须立刻清零
    rst_a = 1'b0;
    repeat (5) @(posedge clk);
    if ((fcnt_a !== 32'd0) || (fps_a !== 8'h00) || (lat_a !== 11'd0)) begin
        ea_rstclr = ea_rstclr + 1;
        $display("  [ERR] A.rstclr 复位期期望 cnt/fps/lat=0 实测 %0d/0x%02x/%0d",
                 fcnt_a, fps_a, lat_a);
    end
    na_rstclr = na_rstclr + 1;
    rst_a = 1'b1;

    // 复位后：换 200 拍周期（60e6/200 = 300000 > 99 → 安全值 0），验证重新计数与重测
    gap_a = 25'd200;
    repeat (1200) @(posedge clk);
    if (fcnt_a !== reffrm_a) begin
        ea_aftcnt = ea_aftcnt + 1;
        $display("  [ERR] A.aftcnt 复位后期望 %0d 实测 %0d", reffrm_a, fcnt_a);
    end
    na_aftcnt = na_aftcnt + 1;
    if (lat_a !== 11'd7) begin
        ea_aftlat = ea_aftlat + 1;
        $display("  [ERR] A.aftlat 复位后期望延迟 7 实测 %0d", lat_a);
    end
    na_aftlat = na_aftlat + 1;
    if (fps_a !== 8'h00) begin
        ea_aftfps = ea_aftfps + 1;
        $display("  [ERR] A.aftfps 300000fps 超范围期望 0x00 实测 0x%02x", fps_a);
    end
    na_aftfps = na_aftfps + 1;

    $display("[CHK] A_first cnt=%0d err=%0d", na_first, ea_first);
    $display("[CHK] A_cnt cnt=%0d err=%0d", na_cnt, ea_cnt);
    $display("[CHK] A_lat7 cnt=%0d err=%0d", na_lat7, ea_lat7);
    $display("[CHK] A_fps60 cnt=%0d err=%0d", na_fps60, ea_fps60);
    $display("[CHK] A_rstclr cnt=%0d err=%0d", na_rstclr, ea_rstclr);
    $display("[CHK] A_aftcnt cnt=%0d err=%0d", na_aftcnt, ea_aftcnt);
    $display("[CHK] A_aftlat cnt=%0d err=%0d", na_aftlat, ea_aftlat);
    $display("[CHK] A_aftfps cnt=%0d err=%0d", na_aftfps, ea_aftfps);
    $display("[CHK] A_ref cnt=%0d err=%0d", nref_a, eref_a);
    done_a = 1'b1;
end

//------------------------------------------------------------------------------
// dut_b 激励：小周期档 —— FPS 边界、量程饱和、延迟切换、复位
//------------------------------------------------------------------------------
initial begin
    rst_b   = 1'b0;
    sel13_b = 1'b0;                 // 输出延迟 7 拍
    gap_b   = 25'd2000;             // 先来长周期，制造"只来一帧"的窗口
    repeat (10) @(posedge clk);
    rst_b = 1'b1;

    // b1：只来一帧 → cnt=1、fps=0（未测到）；而延迟此时已经测出来了
    repeat (2100) @(posedge clk);
    if (reffrm_b !== 32'd1) begin
        eb_cnt1 = eb_cnt1 + 1;
        $display("  [ERR] B.cnt1 TB 窗口失效：参考帧数应为 1，实测 %0d", reffrm_b);
    end
    if (fps_b !== 8'h00) begin
        eb_cnt1 = eb_cnt1 + 1;
        $display("  [ERR] B.cnt1 只来一帧期望 fps=0x00 实测 0x%02x", fps_b);
    end
    nb_cnt1 = nb_cnt1 + 1;
    if (fcnt_b !== reffrm_b) begin
        eb_cnt1 = eb_cnt1 + 1;
        $display("  [ERR] B.cnt1 期望 %0d 实测 %0d", reffrm_b, fcnt_b);
    end
    nb_cnt1 = nb_cnt1 + 1;
    if (lat_b !== 11'd7) begin
        eb_lat7 = eb_lat7 + 1;
        $display("  [ERR] B.lat7 期望 7 实测 %0d", lat_b);
    end
    nb_lat7 = nb_lat7 + 1;

    // b2：周期 250 → 1000/250 = 4 → 0x04（注意：本档量程 255，周期必须 <=255）
    gap_b = 25'd250;
    repeat (900) @(posedge clk);
    if (fps_b !== 8'h04) begin
        eb_fps04 = eb_fps04 + 1;
        $display("  [ERR] B.fps04 周期250 期望 0x04 实测 0x%02x", fps_b);
    end
    nb_fps04 = nb_fps04 + 1;

    // b3：周期 200 → 5 → 0x05（一位数）
    gap_b = 25'd200;
    repeat (800) @(posedge clk);
    if (fps_b !== 8'h05) begin
        eb_fps05 = eb_fps05 + 1;
        $display("  [ERR] B.fps05 周期200 期望 0x05 实测 0x%02x", fps_b);
    end
    nb_fps05 = nb_fps05 + 1;

    // b4：周期 11 → round(1000/11) = round(90.909) = 91 → 0x91（四舍五入必须生效）
    gap_b = 25'd11;
    repeat (500) @(posedge clk);
    if (fps_b !== 8'h91) begin
        eb_fps91 = eb_fps91 + 1;
        $display("  [ERR] B.fps91 周期11 期望 0x91 实测 0x%02x", fps_b);
    end
    nb_fps91 = nb_fps91 + 1;

    // b5：周期 12 → round(1000/12) = 83.33 → 83 → 0x83（两位、个位非 0，专抓 BCD 错位）
    gap_b = 25'd12;
    repeat (500) @(posedge clk);
    if (fps_b !== 8'h83) begin
        eb_fps83 = eb_fps83 + 1;
        $display("  [ERR] B.fps83 周期12 期望 0x83 实测 0x%02x", fps_b);
    end
    nb_fps83 = nb_fps83 + 1;

    // b6：周期 10 → 100 → 超范围 → 0x00
    gap_b = 25'd10;
    repeat (500) @(posedge clk);
    if (fps_b !== 8'h00) begin
        eb_inv100 = eb_inv100 + 1;
        $display("  [ERR] B.inv100 周期10(100fps) 期望 0x00 实测 0x%02x", fps_b);
    end
    nb_inv100 = nb_inv100 + 1;

    // b7：周期 4 → 250 → 超范围 → 0x00
    gap_b = 25'd4;
    repeat (500) @(posedge clk);
    if (fps_b !== 8'h00) begin
        eb_inv250 = eb_inv250 + 1;
        $display("  [ERR] B.inv250 周期4(250fps) 期望 0x00 实测 0x%02x", fps_b);
    end
    nb_inv250 = nb_inv250 + 1;

    // b8：周期 1 → 1000 → 超范围（极小周期边界）→ 0x00
    gap_b = 25'd1;
    repeat (500) @(posedge clk);
    if (fps_b !== 8'h00) begin
        eb_inv1k = eb_inv1k + 1;
        $display("  [ERR] B.inv1k 周期1(1000fps) 期望 0x00 实测 0x%02x", fps_b);
    end
    nb_inv1k = nb_inv1k + 1;

    // b9：周期 255 = 量程上限 → round(1000/255) = round(3.92) = 4 → 0x04
    //     （恰好不超量程；截断写法会得 3，这条也顺带锁住四舍五入口径）
    gap_b = 25'd255;
    repeat (1000) @(posedge clk);
    if (fps_b !== 8'h04) begin
        eb_maxg = eb_maxg + 1;
        $display("  [ERR] B.maxg 周期255 期望 0x04 实测 0x%02x", fps_b);
    end
    nb_maxg = nb_maxg + 1;

    // b10：周期 256 > 量程 255 → 判无效 → 0x00
    gap_b = 25'd256;
    repeat (1000) @(posedge clk);
    if (fps_b !== 8'h00) begin
        eb_over = eb_over + 1;
        $display("  [ERR] B.over 周期256 超量程期望 0x00 实测 0x%02x", fps_b);
    end
    nb_over = nb_over + 1;

    // b11：周期 200 → 恢复 0x05（证明超量程标志按帧清零）
    gap_b = 25'd200;
    repeat (800) @(posedge clk);
    if (fps_b !== 8'h05) begin
        eb_recov = eb_recov + 1;
        $display("  [ERR] B.recov 超量程后期望 0x05 实测 0x%02x", fps_b);
    end
    nb_recov = nb_recov + 1;

    // b12：延迟切成 13 拍 → O_lat_clk 必须跟着变（证明是实测不是常数）
    sel13_b = 1'b1;
    repeat (800) @(posedge clk);
    if (lat_b !== 11'd13) begin
        eb_lat13 = eb_lat13 + 1;
        $display("  [ERR] B.lat13 注入 13 拍期望 13 实测 %0d", lat_b);
    end
    nb_lat13 = nb_lat13 + 1;

    // b13：中途复位（帧之间）→ 清零，复位后重新计数/重新测到 0x05
    rst_b = 1'b0;
    repeat (5) @(posedge clk);
    if ((fcnt_b !== 32'd0) || (fps_b !== 8'h00) || (lat_b !== 11'd0)) begin
        eb_rstclr = eb_rstclr + 1;
        $display("  [ERR] B.rstclr 复位期期望 cnt/fps/lat=0 实测 %0d/0x%02x/%0d",
                 fcnt_b, fps_b, lat_b);
    end
    nb_rstclr = nb_rstclr + 1;
    rst_b   = 1'b1;
    sel13_b = 1'b0;
    gap_b   = 25'd200;
    repeat (800) @(posedge clk);
    if (fps_b !== 8'h05) begin
        eb_rstfps = eb_rstfps + 1;
        $display("  [ERR] B.rstfps 复位后期望 0x05 实测 0x%02x", fps_b);
    end
    nb_rstfps = nb_rstfps + 1;
    if (fcnt_b !== reffrm_b) begin
        eb_rstcnt = eb_rstcnt + 1;
        $display("  [ERR] B.rstcnt 复位后期望 %0d 实测 %0d", reffrm_b, fcnt_b);
    end
    nb_rstcnt = nb_rstcnt + 1;

    $display("[CHK] B_cnt1 cnt=%0d err=%0d", nb_cnt1, eb_cnt1);
    $display("[CHK] B_lat7 cnt=%0d err=%0d", nb_lat7, eb_lat7);
    $display("[CHK] B_fps04 cnt=%0d err=%0d", nb_fps04, eb_fps04);
    $display("[CHK] B_fps05 cnt=%0d err=%0d", nb_fps05, eb_fps05);
    $display("[CHK] B_fps91 cnt=%0d err=%0d", nb_fps91, eb_fps91);
    $display("[CHK] B_fps83 cnt=%0d err=%0d", nb_fps83, eb_fps83);
    $display("[CHK] B_inv100 cnt=%0d err=%0d", nb_inv100, eb_inv100);
    $display("[CHK] B_inv250 cnt=%0d err=%0d", nb_inv250, eb_inv250);
    $display("[CHK] B_inv1k cnt=%0d err=%0d", nb_inv1k, eb_inv1k);
    $display("[CHK] B_maxg cnt=%0d err=%0d", nb_maxg, eb_maxg);
    $display("[CHK] B_over cnt=%0d err=%0d", nb_over, eb_over);
    $display("[CHK] B_recov cnt=%0d err=%0d", nb_recov, eb_recov);
    $display("[CHK] B_lat13 cnt=%0d err=%0d", nb_lat13, eb_lat13);
    $display("[CHK] B_rstclr cnt=%0d err=%0d", nb_rstclr, eb_rstclr);
    $display("[CHK] B_rstfps cnt=%0d err=%0d", nb_rstfps, eb_rstfps);
    $display("[CHK] B_rstcnt cnt=%0d err=%0d", nb_rstcnt, eb_rstcnt);
    $display("[CHK] B_ref cnt=%0d err=%0d", nref_b, eref_b);
    done_b = 1'b1;
end

//------------------------------------------------------------------------------
// dut_c 激励：FPS=99 上边界、超量程、除法器运行中复位
//------------------------------------------------------------------------------
initial begin
    rst_c = 1'b0;
    gap_c = 25'd1000;
    repeat (10) @(posedge clk);
    rst_c = 1'b1;

    // c1：周期 1000 → 99000/1000 = 99 → 0x99（1..99 上边界）
    repeat (2400) @(posedge clk);
    if (fps_c !== 8'h99) begin
        ec_fps99 = ec_fps99 + 1;
        $display("  [ERR] C.fps99 周期1000 期望 0x99 实测 0x%02x", fps_c);
    end
    nc_fps99 = nc_fps99 + 1;

    // c2：周期 2000 → round(99000/2000) = round(49.5) = 50 → 0x50（半整数进位）
    gap_c = 25'd2000;
    repeat (4400) @(posedge clk);
    if (fps_c !== 8'h50) begin
        ec_fps50 = ec_fps50 + 1;
        $display("  [ERR] C.fps50 周期2000 期望 0x50 实测 0x%02x", fps_c);
    end
    nc_fps50 = nc_fps50 + 1;

    // c3：周期 5000 > 量程 4095 → 无效 → 0x00
    gap_c = 25'd5000;
    repeat (10600) @(posedge clk);
    if (fps_c !== 8'h00) begin
        ec_over = ec_over + 1;
        $display("  [ERR] C.over 周期5000 超量程期望 0x00 实测 0x%02x", fps_c);
    end
    nc_over = nc_over + 1;

    // c4：周期 1000 → 恢复 0x99
    gap_c = 25'd1000;
    repeat (2400) @(posedge clk);
    if (fps_c !== 8'h99) begin
        ec_recov = ec_recov + 1;
        $display("  [ERR] C.recov 超量程后期望 0x99 实测 0x%02x", fps_c);
    end
    nc_recov = nc_recov + 1;

    // c5：除法器正在跑的时候中途复位 —— 专抓"复位没清干净 busy/状态机"
    @(posedge dut_c.r_div_busy);
    repeat (3) @(posedge clk);
    rst_c = 1'b0;
    repeat (5) @(posedge clk);
    if ((fcnt_c !== 32'd0) || (fps_c !== 8'h00) || (lat_c !== 11'd0)) begin
        ec_rstdv = ec_rstdv + 1;
        $display("  [ERR] C.rstdv 除法中复位期望 cnt/fps/lat=0 实测 %0d/0x%02x/%0d",
                 fcnt_c, fps_c, lat_c);
    end
    nc_rstdv = nc_rstdv + 1;
    rst_c = 1'b1;

    // c6：复位后必须还能正常测到 0x99（状态机/除法器真的复位干净了）
    repeat (2400) @(posedge clk);
    if (fps_c !== 8'h99) begin
        ec_rstfp = ec_rstfp + 1;
        $display("  [ERR] C.rstfp 除法中复位后期望 0x99 实测 0x%02x", fps_c);
    end
    nc_rstfp = nc_rstfp + 1;

    $display("[CHK] C_fps99 cnt=%0d err=%0d", nc_fps99, ec_fps99);
    $display("[CHK] C_fps50 cnt=%0d err=%0d", nc_fps50, ec_fps50);
    $display("[CHK] C_over cnt=%0d err=%0d", nc_over, ec_over);
    $display("[CHK] C_recov cnt=%0d err=%0d", nc_recov, ec_recov);
    $display("[CHK] C_rstdv cnt=%0d err=%0d", nc_rstdv, ec_rstdv);
    $display("[CHK] C_rstfp cnt=%0d err=%0d", nc_rstfp, ec_rstfp);
    $display("[CHK] C_ref cnt=%0d err=%0d", nref_c, eref_c);
    done_c = 1'b1;
end

endmodule
