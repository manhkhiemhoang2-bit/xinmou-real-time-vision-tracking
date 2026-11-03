//==============================================================================
// tb_gim_vis_ctl.v —— gim_vis_ctl（pan/tilt 视觉伺服控制律）的测试平台
//
// 干什么：
//   逐"帧"给 gim_vis_ctl 喂一组 (cx, cy, valid)，并在部分帧上拉低 en，
//   把每帧之后的 (O_pulse_pan, O_pulse_tilt, O_locked, O_tgt_present) dump 出来，
//   交给 check_gim_vis_ctl.py 用**独立写的 Python 参考模型**比对。
//
// 反循环原则：TB 只产生激励 + 记录事实；判据全部由 Python 出。
//
// 激励表（stim[f] = {valid, cx[11:0], cy[11:0]}）为什么这么排：
//   f0 .. f15  目标钉在画面正中，**连续 16 帧**都落在死区内
//              -> 验"锁定在第 15 帧置 1"**并且第 16 帧仍然是 1**
//                 （第 16 帧是 4 位锁定计数器回绕 bug 的唯一暴露点）
//   f16        ex = +60 刚出死区 -> 步进应 = 60*13>>2 = 195，锁定立刻清零
//   f17        ex = +639 大误差 -> 未限幅是 2076，必须被限斜率限到 +300
//   f18        ex = -640 反方向 -> 未限幅是 -2080，必须被限到 -300
//   f19..f26   连续 8 帧把目标推到最右 -> 每帧 +300，用来撞 PULSE_MAX 饱和
//   f27,f28    目标丢失两帧 -> 脉宽**必须保持不变**（不回中）
//   f29        目标回来，落在死区内
//   f30..f45   再连续 16 帧在死区内 -> 锁定应重新在第 15 帧置 1 且保持
//   f46        ey = +340 出死区 -> 锁定立刻清零
//   f47        |ex| 恰好 = DEADZONE(=40) -> 算"在死区内"，本帧不动
//   f48        ex = +41 只超 1 个像素 -> 步进 = 41*13>>2 = 133
//   f49        ex = -41 -> 步进 = -133
//   f50,f51    en=0 -> 两轴回中位 PULSE_MID、锁定清零
//   f52..f55   en=1 恢复，目标在正中
//
// dump 格式（写到 dump_gim_vis.txt）：
//   首行 "# " 参数注释行，之后每帧一行（**含 en**，让判据不用去猜 TB 的时间表）：
//     f cx cy valid en pulse_pan pulse_tilt locked tgt_present
//==============================================================================
`timescale 1ns / 1ps

module tb_gim_vis_ctl;

    // ---- 与被测模块必须一致的参数 ----
    localparam IMG_W     = 1280;
    localparam IMG_H     = 720;
    localparam DEADZONE  = 40;
    localparam KP_NUM    = 13;
    localparam KP_SH     = 2;
    localparam SLEW_MAX  = 300;
    localparam PULSE_MIN = 50000;
    localparam PULSE_MID = 75000;
    localparam PULSE_MAX = 100000;
    localparam SIGN_PAN  = 1;
    localparam SIGN_TILT = 1;
    localparam LOCK_N    = 15;

    localparam NFRAME    = 56;
    localparam OFF_LO    = 50;          // en=0 的帧区间 [50,51]
    localparam OFF_HI    = 52;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         en = 1'b1;
    reg         upd = 1'b0;
    reg  [11:0] cx, cy;
    reg         valid;

    wire [19:0] pp, pt;
    wire        lk, tp;

    integer    i, f, fd;
    reg [24:0] stim [0:NFRAME-1];       // {valid, cx[11:0], cy[11:0]}

    always #10 clk = ~clk;              // 20ns -> 50MHz

    gim_vis_ctl #(
        .IMG_W     (IMG_W    ), .IMG_H     (IMG_H    ),
        .DEADZONE  (DEADZONE ), .KP_NUM    (KP_NUM   ), .KP_SH(KP_SH),
        .SLEW_MAX  (SLEW_MAX ), .PULSE_MIN (PULSE_MIN),
        .PULSE_MID (PULSE_MID), .PULSE_MAX (PULSE_MAX),
        .SIGN_PAN  (SIGN_PAN ), .SIGN_TILT (SIGN_TILT), .LOCK_N(LOCK_N)
    ) u_dut (
        .I_clk        (clk  ),
        .I_rst_n      (rst_n),
        .I_upd        (upd  ),
        .I_cx         (cx   ),
        .I_cy         (cy   ),
        .I_valid      (valid),
        .I_en         (en   ),
        .O_pulse_pan  (pp   ),
        .O_pulse_tilt (pt   ),
        .O_locked     (lk   ),
        .O_tgt_present(tp   )
    );

    //--------------------------------------------------------------------------
    // 激励表
    //--------------------------------------------------------------------------
    initial begin
        for (i = 0; i < NFRAME; i = i + 1)
            stim[i] = {1'b1, 12'd640, 12'd360};                 // 默认：正中、有效

        stim[16] = {1'b1, 12'd700,  12'd360};                   // ex=+60
        stim[17] = {1'b1, 12'd1279, 12'd360};                   // ex=+639
        stim[18] = {1'b1, 12'd0,    12'd360};                   // ex=-640
        for (i = 19; i <= 26; i = i + 1)
            stim[i] = {1'b1, 12'd1279, 12'd360};                // 连续右推
        stim[27] = {1'b0, 12'd640,  12'd360};                   // 丢失
        stim[28] = {1'b0, 12'd0,    12'd0  };                   // 丢失（坐标也乱给，不应影响）
        stim[29] = {1'b1, 12'd640,  12'd360};                   // 回来
        // f30..f45 保持正中（默认值已经是）
        stim[46] = {1'b1, 12'd640,  12'd700};                   // ey=+340
        stim[47] = {1'b1, 12'd680,  12'd360};                   // ex=+40（恰好等于死区）
        stim[48] = {1'b1, 12'd681,  12'd360};                   // ex=+41
        stim[49] = {1'b1, 12'd599,  12'd360};                   // ex=-41
        // f50..f55 用默认值（正中、有效），en 由时间表控制
    end

    //--------------------------------------------------------------------------
    // 时间表：逐帧摆数据 -> 出一个 I_upd 脉冲 -> dump 结果
    //--------------------------------------------------------------------------
    initial begin
        fd    = $fopen("dump_gim_vis.txt", "w");
        if (fd == 0) begin
            $display("TB: FATAL 打不开 dump_gim_vis.txt");
            $finish;
        end
        $fwrite(fd, "# tb_gim_vis_ctl IMG_W=%0d IMG_H=%0d DEADZONE=%0d KP_NUM=%0d KP_SH=%0d SLEW_MAX=%0d PULSE_MIN=%0d PULSE_MID=%0d PULSE_MAX=%0d SIGN_PAN=%0d SIGN_TILT=%0d LOCK_N=%0d NFRAME=%0d OFF_LO=%0d OFF_HI=%0d\n",
                IMG_W, IMG_H, DEADZONE, KP_NUM, KP_SH, SLEW_MAX,
                PULSE_MIN, PULSE_MID, PULSE_MAX, SIGN_PAN, SIGN_TILT,
                LOCK_N, NFRAME, OFF_LO, OFF_HI);

        rst_n = 1'b0;  en = 1'b1;  upd = 1'b0;
        cx = 12'd640;  cy = 12'd360;  valid = 1'b1;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        for (f = 0; f < NFRAME; f = f + 1) begin
            {valid, cx, cy} = stim[f];
            en = ((f >= OFF_LO) && (f < OFF_HI)) ? 1'b0 : 1'b1;

            @(negedge clk);  upd = 1'b1;
            @(posedge clk);                     // DUT 在这一拍按 I_upd 更新
            @(negedge clk);  upd = 1'b0;

            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    f, cx, cy, valid, en, pp, pt, lk, tp);
        end

        $fclose(fd);
        $display("TB: done, %0d frames", NFRAME);
        $finish;
    end

endmodule
