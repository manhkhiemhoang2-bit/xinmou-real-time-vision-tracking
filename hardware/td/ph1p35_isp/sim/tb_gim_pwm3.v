//==============================================================================
// tb_gim_pwm3.v —— gim_pwm3（三路舵机 PWM）的测试平台
//
// 干什么：
//   按一张**固定拍数**的时间表驱动 gim_pwm3，把三个输出 + O_boot_done 的
//   **变化沿**逐条 dump 出来，交给 check_gim_pwm3.py 出判据。
//
//   为什么只 dump 变化沿：整个过程约 1950 万拍，逐拍 dump 会写出几百 MB；
//   而变化沿总共只有几十条，脉宽 / 周期 / 静默期这三件事全部能从沿推出来。
//
// 反循环原则：本 TB **只产生激励 + 记录事实**，不做任何判定。
//   所有 PASS/FAIL 由 check_gim_pwm3.py 出，且它只读 dump，不读 DUT 内部信号。
//
// 时间表（拍号 = 第几个 clk 上升沿，从 1 开始数）：
//   1 .. T_RST_END            复位，en=0，三路命令脉宽都给 MID
//   T_RST_END                 释放复位，en=1
//   T_RST_END .. T_SIL_END    上电静默期（= BOOT_MUTE = 1000 万拍）——这一段三路**必须恒 0**
//   T_SIL_END .. T_BASE       静默结束后再等半个周期（+500000 拍），落进"脉冲之外"的安全窗口
//   T_BASE + [0, 3)个周期      稳态测量：脉宽应 = MID，周期应 = PWM_PER
//   T_OVER + [0, 2)个周期      pan 命令给 200000（> MAX）→ 应被限到 PULSE_MAX
//   T_UNDER+ [0, 2)个周期      pan 命令给 1000  （< MIN）→ 应被限到 PULSE_MIN
//   T_OFF  + [0, 1)个周期      en=0 → 三路**必须恒 0**
//   T_ON   + [0, 1)个周期      en=1 恢复
//
//   ⚠ 为什么基准点要 +500000 拍：保证每次改命令脉宽都落在**脉冲之外**。
//     脉冲最宽 PULSE_MAX = 100000 拍 ⇒ +500000 时本周期脉冲早结束了；
//     距下一个周期边界还有 1000000-500000 = 500000 拍 ⇒ 也还没到下一个脉冲。
//     这样"某条脉冲的宽度对应哪个命令值"就没有歧义。
//     （全部改点 = T_BASE + k*PWM_PER，相对 r_cnt 的位置不变 ⇒ 都在安全窗口里。）
//
// dump 格式（每行一条变化沿，写到 dump_gim_pwm3.txt）：
//   cyc step boot_done pan tilt roll cp_pan cp_tilt cp_roll
//     cyc   拍号
//     step  0=复位/静默 1=稳态 2=超上限 3=超下限 4=en关 5=恢复
//     boot_done / pan / tilt / roll   变化后的值
//     cp_*  该拍的命令脉宽（TB 驱动的值，不是 DUT 内部信号）
//   首行是 "# " 开头的参数注释行。
//==============================================================================
`timescale 1ns / 1ps

module tb_gim_pwm3;

    // ---- 与被测模块必须一致的参数（写死成 localparam，改一处要两边一起改）----
    localparam PWM_PER   = 1000000;     // 20ms @50MHz
    localparam PULSE_MIN = 50000;       // 1.0ms
    localparam PULSE_MAX = 100000;      // 2.0ms
    localparam PULSE_MID = 75000;       // 1.5ms
    localparam BOOT_MUTE = 10000000;    // 200ms

    // ---- 时间表关键拍号 ----
    //   ⚠ 2026-09-23 踩过的坑：第一版写成 T_BASE = T_RST_END + 500000，
    //     忘了静默期有 BOOT_MUTE = 1000 万拍 ⇒ 整张表提前跑完（T_END=9500100），
    //     boot_done 还没拉高、一个脉冲都没产生，判据 J4/J5 报红。
    //     基准点必须落在**静默期之后**：T_BASE = T_SIL_END + 500000。
    localparam T_RST_END = 100;
    localparam T_SIL_END = T_RST_END + BOOT_MUTE;     // 静默期结束；boot_done 约在此拉高
    //   再等半个周期（500000 拍）才当基准：此时 r_cnt ≈ 499999，
    //   脉冲最宽 100000 拍 ⇒ 既过了本周期脉冲，又没到下一个周期边界 ⇒ 改命令值没有歧义。
    localparam T_BASE    = T_SIL_END + 500000;
    localparam T_OVER    = T_BASE   + 3*PWM_PER;
    localparam T_UNDER   = T_OVER   + 2*PWM_PER;
    localparam T_OFF     = T_UNDER  + 2*PWM_PER;
    localparam T_ON      = T_OFF    + 1*PWM_PER;
    localparam T_END     = T_ON     + 1*PWM_PER;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg        en = 1'b0;
    reg [19:0] cp_pan, cp_tilt, cp_roll;
    reg [2:0]  step;

    wire w_pan, w_tilt, w_roll, boot_done;

    integer   cyc;
    integer   fd;
    reg [3:0] last_v;
    wire [3:0] now_v = {boot_done, w_pan, w_tilt, w_roll};

    always #10 clk = ~clk;              // 20ns -> 50MHz

    gim_pwm3 #(
        .PWM_PER   (PWM_PER  ),
        .PULSE_MIN (PULSE_MIN),
        .PULSE_MAX (PULSE_MAX),
        .BOOT_MUTE (BOOT_MUTE)
    ) u_dut (
        .I_clk        (clk      ),
        .I_rst_n      (rst_n    ),
        .I_en         (en       ),
        .I_pulse_pan  (cp_pan   ),
        .I_pulse_tilt (cp_tilt  ),
        .I_pulse_roll (cp_roll  ),
        .O_pwm_pan    (w_pan    ),
        .O_pwm_tilt   (w_tilt   ),
        .O_pwm_roll   (w_roll   ),
        .O_boot_done  (boot_done)
    );

    //--------------------------------------------------------------------------
    // 拍号 + 时间表 + 变化沿 dump
    //   本块内一律用**阻塞赋值**（每个信号只有这一个驱动点），
    //   这样 `cyc == T_xxx` 就是"第 T_xxx 个上升沿"，不产生前后拍歧义。
    //   now_v 采到的是本沿**之前**的 DUT 输出（DUT 用的是非阻塞赋值），
    //   所以本 dump 的时间基准整体早 1 拍；判据只比较沿与沿的**差值**，不受影响。
    //--------------------------------------------------------------------------
    initial begin
        cyc     = 0;
        rst_n   = 1'b0;
        en      = 1'b0;
        cp_pan  = PULSE_MID;
        cp_tilt = PULSE_MID;
        cp_roll = PULSE_MID;
        step    = 3'd0;
        last_v  = 4'h0;                 // 与初值相同，靠下面强制 dump 首行
        fd      = $fopen("dump_gim_pwm3.txt", "w");
        if (fd == 0) begin
            $display("TB: FATAL 打不开 dump_gim_pwm3.txt");
            $finish;
        end
        $fwrite(fd, "# tb_gim_pwm3 PWM_PER=%0d PULSE_MIN=%0d PULSE_MAX=%0d PULSE_MID=%0d BOOT_MUTE=%0d T_RST_END=%0d T_BASE=%0d T_OVER=%0d T_UNDER=%0d T_OFF=%0d T_ON=%0d T_END=%0d\n",
                PWM_PER, PULSE_MIN, PULSE_MAX, PULSE_MID, BOOT_MUTE,
                T_RST_END, T_BASE, T_OVER, T_UNDER, T_OFF, T_ON, T_END);
    end

    always @(posedge clk) begin
        cyc = cyc + 1;

        // ---- 时间表 ----
        if (cyc == T_RST_END) begin
            rst_n = 1'b1;
            en    = 1'b1;
        end
        if (cyc == T_BASE)  step = 3'd1;
        if (cyc == T_OVER)  begin cp_pan = 20'd200000; step = 3'd2; end   // > PULSE_MAX
        if (cyc == T_UNDER) begin cp_pan = 20'd1000;   step = 3'd3; end   // < PULSE_MIN
        if (cyc == T_OFF)   begin en     = 1'b0;       step = 3'd4; end
        if (cyc == T_ON)    begin cp_pan = PULSE_MID; en = 1'b1; step = 3'd5; end

        if (cyc == T_END) begin
            $fclose(fd);
            $display("TB: done cyc=%0d boot_done=%0d", cyc, boot_done);
            $finish;
        end

        // ---- 变化沿 dump（含复位段的首行）----
        if (cyc == 1) begin
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    cyc, step, boot_done, w_pan, w_tilt, w_roll, cp_pan, cp_tilt, cp_roll);
            last_v = now_v;
        end else if (now_v !== last_v) begin
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    cyc, step, boot_done, w_pan, w_tilt, w_roll, cp_pan, cp_tilt, cp_roll);
            last_v = now_v;
        end
    end

endmodule
