//==============================================================================
// tb_ext_ctrl.v —— ext_ctrl 的 ModelSim 测试平台（激励 + 变化点 dump）
//
// 【本 TB 只做两件事】
//   1) 按 stim_ext.hex 逐帧喂 bbox / bbox_valid / pix_count，并在每帧的
//      "建立窗口"第一拍给出一拍宽的帧同步脉冲 I_frame；
//   2) 把 (rst_n, I_frame, 输入 bbox 组, O_led, O_buzzer) 的**每一个变化点**
//      连同周期号 dump 到 dump_ext.txt。
//
// 【为什么可以只在变化点 dump】
//   这些信号在每一拍之内都是恒定的（时序寄存器 + 由 cyc 组合译码出来的激励），
//   所以"上一个变化点到下一个变化点之间"的值就是上一个变化点的值 —— 变化点 dump
//   对逐拍比对是**无损**的。dut 的 O_led/O_buzzer 也在监视集合里，它们一变就会
//   产生新的 dump 行，因此不会漏掉"输入没变、输出变了"的拍（例如 beep 包络到期）。
//
// 【DUT 一律用 RTL 默认参数例化，不覆盖任何 parameter】
//   这样"默认参数被改错"的变异才会真正打到仿真里（checker 侧硬编码同一组期望值）。
//
// 【周期口径】
//   dump 行在 posedge 上写出，此时非阻塞赋值尚未生效 —— 该行的 cyc 与各信号
//   都是"刚刚结束的那一拍"的值。checker 按同一口径逐拍回放。
//
// 用法（在 sim 目录下）：
//   vlib work_ext
//   vlog -work work_ext tb_ext_ctrl.v ../src/ext_ctrl.v
//   vsim -c -do "run -all; quit -f" -work work_ext tb_ext_ctrl
//==============================================================================
`timescale 1ns / 1ps

module tb_ext_ctrl;

    // ---- 必须与 gen_stim_ext_ctrl.py 保持一致 ----
    localparam NF    = 80;          // 帧数
    localparam P     = 24000;       // 每帧周期数
                                    //   约束：P * (BEEP_GAP_FRAMES-1) 要大于 BEEP_ON_CYCLES，
                                    //   否则第 2 次 beep 会撞上第 1 次的包络。
                                    //   24000*19 = 456000 > 400000 ✓
    localparam SETUP = 8;           // 帧同步脉冲前，真实 bbox 提前建立的拍数
    localparam MID_RST_FRAME = 56;  // 中途复位所在帧
    localparam MID_RST_P0    = 100; // 中途复位在帧内的起始拍
    localparam MID_RST_LEN   = 4;   // 中途复位持续拍数
    localparam RST0_LEN      = 4;   // 上电复位拍数
    localparam END_CYC = NF*P + 40;

    // 干扰值：非建立窗口期间一直挂在输入上（合法、有目标、左上象限）
    localparam [10:0] D_X0 = 11'd100, D_X1 = 11'd300;
    localparam [10:0] D_Y0 = 11'd50,  D_Y1 = 11'd150;
    localparam [31:0] D_PC = 32'd5000;

    //------------------------------------------------------------------
    // 时钟
    //------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    //------------------------------------------------------------------
    // 激励
    //------------------------------------------------------------------
    reg [95:0] stim [0:NF-1];
    reg [31:0] cyc;
    integer    i;

    initial begin
        for (i = 0; i < NF; i = i + 1) stim[i] = 96'd0;
        $readmemh("stim_ext.hex", stim);
        $display("TB: stim_ext.hex loaded, NF=%0d", NF);
    end

    wire [31:0] fidx = cyc / P;
    wire [31:0] pos  = cyc % P;
    wire        w_win  = (fidx < NF) && (pos >= (P - SETUP));   // 建立窗口
    wire [95:0] w_rec  = (fidx < NF) ? stim[fidx] : 96'd0;

    reg  [31:0] I_pc;
    reg  [10:0] I_x0, I_x1, I_y0, I_y1;
    reg         I_valid;
    reg         I_frame;
    reg         rst_n;

    wire w_rst_mid = (fidx == MID_RST_FRAME) && (pos >= MID_RST_P0)
                   && (pos < (MID_RST_P0 + MID_RST_LEN));

    always @ (*) begin
        if (w_win) begin
            I_pc    = w_rec[95:64];
            I_x0    = w_rec[63:53];
            I_x1    = w_rec[52:42];
            I_y0    = w_rec[41:31];
            I_y1    = w_rec[30:20];
            I_valid = w_rec[19];
        end else begin
            I_pc    = D_PC;
            I_x0    = D_X0;
            I_x1    = D_X1;
            I_y0    = D_Y0;
            I_y1    = D_Y1;
            I_valid = 1'b1;
        end
        I_frame = (fidx < NF) && (pos == (P - SETUP));
        rst_n   = ~((cyc < RST0_LEN) || w_rst_mid);
    end

    //------------------------------------------------------------------
    // DUT（不覆盖任何 parameter）
    //------------------------------------------------------------------
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
        .I_bbox_valid (I_valid),
        .I_pix_count  (I_pc),
        .O_led        (O_led),
        .O_buzzer     (O_buzzer)
    );

    //------------------------------------------------------------------
    // 变化点 dump
    //------------------------------------------------------------------
    reg [127:0] mon;        // 当前拍监视向量
    reg [127:0] mon_q;      // 上一拍监视向量
    integer     fd;

    always @ (*) begin
        mon = {rst_n, I_frame, I_valid, I_pc, I_x0, I_x1, I_y0, I_y1, O_led, O_buzzer};
    end

    initial begin
        mon_q = 128'hx;     // 保证第 0 拍一定会被 dump
        fd    = $fopen("dump_ext.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_ext.txt");
            $finish;
        end
    end

    always @ (posedge clk) begin
        // 变化点 dump；最后一拍强制补一行，checker 用它确认仿真跑满
        if ((mon !== mon_q) || (cyc == END_CYC)) begin
            $fwrite(fd, "%0d %b %b %b %0d %0d %0d %0d %0d %b %b\n",
                    cyc, rst_n, I_frame, I_valid, I_pc,
                    I_x0, I_x1, I_y0, I_y1, O_led, O_buzzer);
        end
        mon_q <= mon;
        cyc   <= cyc + 32'd1;
        if (cyc >= END_CYC) begin
            $fclose(fd);
            $display("TB: done, %0d cycles", cyc + 32'd1);
            $finish;
        end
    end

    initial begin
        cyc = 32'd0;
    end

endmodule
