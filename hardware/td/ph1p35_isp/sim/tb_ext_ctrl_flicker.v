//==============================================================================
// tb_ext_ctrl_flicker.v —— ext_ctrl v2 的"抖动 + 包络不可重触发"专项 TB
//
// 目的（针对对抗性审查 P3/P4 与 v2 修法）：
//   ① 检测抖动（valid 时有时无）下**必须响**，且"无 → 有"那一帧就要响
//      （不是等 20 个连续有效帧）。旧版 v1 在 1:1 抖动下 beep 数 = 0。
//   ② beep 包络进行中再来请求 ⇒ 包络长度仍是 400000 拍（真·不可重触发）。
//      旧版 v1 会重装计数器，帧周期小的时候退化成常鸣（单段 2497999 拍）。
//   ③ 倒置 bbox（x0>x1 / y0>y1）且 valid=1 ⇒ LED = 0000、不触发 beep。
//
// 帧号 f 的激励模式（与 P 无关）：
//   f  0..3   : 无目标（哨兵 bbox + valid=0）
//   f  4..43  : 1:1 抖动（f 为偶数 → valid=1）
//   f 44..63  : 1:3 抖动（f % 3 == 0 → valid=1）
//   f 64..69  : 连续有目标（右下象限）
//   f 70..73  : **倒置框** + valid=1（x0=300>x1=100，y0=600>y1=500）
//   f 74..    : 连续有目标（右下象限，一直持续到仿真结束）
//
// 两个 run（同一份 TB，用 -gP / -gNCYC 覆盖）：
//   抖动 run  : -gP=600    -gNCYC=72100     （120 帧；包络跑不完，只看"响没响"）
//   重触发 run: -gP=100    -gNCYC=2500000   （25000 帧；看每段鸣叫是否恒为 400000 拍）
//
// DUT 用 **默认参数**例化，不覆盖任何 parameter（BUZZ_ACT_LOW 默认 0 = 高有效，
// 与两个 TB 的观测口径一致）。
//
// dump（只写变化点，无损）：cyc rst_n I_frame valid pc x0 x1 y0 y1 O_led O_buzzer
//   —— 这些信号每拍之内恒定，所以"变化点 + 保持"对逐拍比对是无损的。
//
// 用法（在 sim 目录下）：
//   vlib work_flk
//   vlog -work work_flk tb_ext_ctrl_flicker.v ../src/ext_ctrl.v
//   vsim -c -lib work_flk -do "run -all; quit -f" tb_ext_ctrl_flicker
//   vsim -c -lib work_flk -gP=100 -gNCYC=2500000 -do "run -all; quit -f" tb_ext_ctrl_flicker
//==============================================================================
`timescale 1ns / 1ps

module tb_ext_ctrl_flicker;

    parameter P    = 600;        // 每帧拍数（-gP 覆盖）
    parameter NCYC = 72100;      // 总拍数（-gNCYC 覆盖）

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [10:0] I_x0, I_x1, I_y0, I_y1;
    reg [31:0] I_pc;
    reg        I_v;
    reg        I_frame;
    reg        rst_n;

    wire [3:0] O_led;
    wire       O_buzzer;

    ext_ctrl u_dut (
        .I_clk        (clk),
        .I_rst_n      (rst_n),
        .I_frame      (I_frame),
        .I_bbox_x0    (I_x0),
        .I_bbox_x1    (I_x1),
        .I_bbox_y0    (I_y0),
        .I_bbox_y1    (I_y1),
        .I_bbox_valid (I_v),
        .I_pix_count  (I_pc),
        .O_led        (O_led),
        .O_buzzer     (O_buzzer)
    );

    reg [31:0] cyc;
    wire [31:0] fidx = cyc / P;
    wire [31:0] pos  = cyc % P;

    wire w_inv    = (fidx >= 32'd70) && (fidx <= 32'd73);
    wire w_flick1 = (fidx >= 32'd4)  && (fidx <= 32'd43) && ((fidx % 32'd2) == 32'd0);
    wire w_flick3 = (fidx >= 32'd44) && (fidx <= 32'd63) && ((fidx % 32'd3) == 32'd0);
    wire w_cont   = (fidx >= 32'd64) && (fidx <= 32'd69);
    wire w_cont2  = (fidx >= 32'd74);
    wire w_tgt    = w_flick1 | w_flick3 | w_cont | w_cont2;

    always @ (*) begin
        if (w_inv) begin
            I_x0 = 11'd300; I_x1 = 11'd100;     // x0 > x1（倒置）
            I_y0 = 11'd600; I_y1 = 11'd500;     // y0 > y1（倒置）
            I_v  = 1'b1;    I_pc = 32'd5000;    // valid 有效也没用，倒置一律按无目标
        end else if (w_tgt) begin
            I_x0 = 11'd900; I_x1 = 11'd1100;    // 右下象限
            I_y0 = 11'd500; I_y1 = 11'd600;
            I_v  = 1'b1;    I_pc = 32'd5000;
        end else begin
            I_x0 = 11'd2047; I_x1 = 11'd0;      // 哨兵 + 无目标
            I_y0 = 11'd2047; I_y1 = 11'd0;
            I_v  = 1'b0;    I_pc = 32'd0;
        end
        I_frame = (pos == 32'd0);               // 每帧第 0 拍，宽 1 拍
        rst_n   = (cyc >= 32'd4);
    end

    //------------------------------------------------------------------
    // 变化点 dump
    //------------------------------------------------------------------
    reg [127:0] mon, mon_q;
    integer     fd;

    always @ (*) begin
        mon = {rst_n, I_frame, I_v, I_pc, I_x0, I_x1, I_y0, I_y1, O_led, O_buzzer};
    end

    initial begin
        cyc   = 32'd0;
        mon_q = 128'hx;
        fd    = $fopen("dump_flk.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_flk.txt");
            $finish;
        end
        $display("FLK TB: P=%0d NCYC=%0d", P, NCYC);
    end

    always @ (posedge clk) begin
        if ((mon !== mon_q) || (cyc == NCYC)) begin
            $fwrite(fd, "%0d %b %b %b %0d %0d %0d %0d %0d %b %b\n",
                    cyc, rst_n, I_frame, I_v, I_pc,
                    I_x0, I_x1, I_y0, I_y1, O_led, O_buzzer);
        end
        mon_q <= mon;
        cyc   <= cyc + 32'd1;
        if (cyc >= NCYC) begin
            $fclose(fd);
            $display("FLK DONE cyc=%0d P=%0d", cyc, P);
            $finish;
        end
    end

endmodule
