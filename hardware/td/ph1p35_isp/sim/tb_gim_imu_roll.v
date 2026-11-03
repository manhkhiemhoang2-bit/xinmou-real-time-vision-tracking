//==============================================================================
// tb_gim_imu_roll.v —— gim_imu_roll（零偏标定 + 互补滤波）的测试平台
//
// 最重要的一条：**TB 自己不判任何东西**，只把激励和实测值 dump 出来。
//   判据在 check_gim_imu_roll.py，而那个脚本里有一份**独立的 Python 浮点金标准**，
//   按同一个差分方程重算一遍。这样才量得出"定点实现 vs 浮点理想"差多少。
//
// 场景（一条连续的时间线，共 1390 个样本，前 256 个是标定）：
//   样本  0..255   静止，但陀螺有零偏（+300）—— 标定期，这一段的陀螺**必须**参与标定
//   样本 256..355 静止，陀螺仍给 +300 —— 标定完成后，零偏应被减掉，
//                 roll 应该**基本不动**（这条专门验零偏真的被减了）
//   样本 356..415 陀螺给 −5000（往一个方向转）0.234 秒
//   样本 416..473 陀螺回 +300（停）
//   样本 474..533 陀螺给 +5000（反方向转）
//   样本 534..601 陀螺回 +300（停），让互补项把角度拉回加速度倾角
//   样本 602..1359 陀螺回 +300，ay 缓慢变小 —— 让加速度计主导，
//                 连带验"角度限幅到 ±25°"（ay 给到 −8192，倾角会超 25°）
//   最后一段：en=0，输出必须回中位
//
// ⚠ 这里给的是**陀螺**和**加速度计分开的、被刻意做得不一致的**激励 ——
//   因为互补滤波的全部意义就是"短时间信陀螺、长时间信加速度计"，
//   如果两者给一样，就验不出哪一半在起作用。
//
// CLI 波形（每行一条，值变化时才写）：
//   # 头
//   C <sample_idx> <sum_or_val>   标定阶段的累加过程（可选，这里只记结束）
//   S <k> <ay> <gy>               第 k 个样本的输入
//   O <k> <roll_q16> <pulse> <calib_done> <calib_busy>  该样本之后的输出
//==============================================================================
`timescale 1ns / 1ps

module tb_gim_imu_roll;

    localparam COMP_SH    = 8;
    localparam CAL_N      = 256;
    localparam CAL_SH     = 8;
    localparam ACC_K      = 229;
    localparam ACC_SH     = 0;   // 见 gim_imu_roll.v：229 已含 /16384，不再移位
    localparam PULSE_MIN  = 50000;
    localparam PULSE_MID  = 75000;
    localparam PULSE_MAX  = 100000;
    // ★ 2026-09-28：`localparam` → `parameter`，让 -gPULSE_PER_DEG=278 能覆盖。
    //   为什么要能覆盖：原来两个 TB 都写死 1200（故意取大，让限幅咬住），
    //   于是 **gim_top.v 里的生产值从来没被测过** —— 生产值曾是 1000（错 3.6 倍、
    //   会让舵机转 ±90°、可能拧断排线），却一路全绿漏到了 09-28。
    //   ⇒ 现在跑三遍：
    //       ① 默认 1200  —— 测限幅路径"真的会咬住"（R5 的 n_clip>0）
    //       ② +wrongaxis —— 测轴选择参数真接到了逻辑上
    //       ③ +prodppd -gPULSE_PER_DEG=278 —— **测生产值**：脉宽偏移必须落在
    //          排线安全预算内（25°×278 = 6950 counts ≈ ±25° 物理角），
    //          且此时**不允许**再碰到 [PULSE_MIN,PULSE_MAX] 边界。
    parameter PULSE_PER_DEG = 1200;    // 故意取大：±25°×1200 = ±30000 > 中位可用的 ±25000
                                       //   ⇒ 限幅**真的会咬住**。
                                       //   取 1000 时 ±25° 正好填满 [50000,100000]，
                                       //   限幅形同虚设，"去掉限幅"这个变异根本测不出来。
    localparam ROLL_LIM_Q16  = 1638400;      // 25° × 65536

    localparam NSAMP     = 3651;             // A~H 八段，见激励段注释
    localparam GYRO_BIAS = 300;              // 零偏：全程不变（物理自洽）

    reg clk = 1'b0;
    always #10 clk = ~clk;                   // 50MHz

    reg  rst_n = 1'b0;
    reg  en = 1'b1;
    reg  data_rdy = 1'b0;
    reg  [15:0] ay, gy;
    reg  imu_ok = 1'b0;

    wire [19:0] o_pulse;
    wire signed [23:0] o_roll;
    wire o_cdone, o_cbusy;

    integer fd, k;

    // 负数常量：**直接写 16 位补码十六进制**，不给任何歧义留口子
    //   踩过的三个坑，按顺序：
    //     ① `16'sd(-5000)`          → based literal 里不许括号，编译报错
    //     ② `-16'sd5000`            → 语法合法但结果错，得到 60536（= 65536−5000）
    //     ③ `wire signed [15:0] x = -16'sd5000;` 再用 x
    //        → **time-0 竞态**：initial 块在时刻 0 读 x 时连续赋值还没传播，读到 0，
    //          于是"这一段和上一段一样"，dump 里那几行直接消失，
    //          看起来像"TB 没生成激励"，白查半天。
    //   所以最稳的就是 localparam + 手算补码，值是死的、无竞态、无符号歧义。
    localparam [15:0] GY_NEG5000  = 16'hEC78;   // −5000
    localparam [15:0] AY_NEG8192  = 16'hE000;   // −8192
    localparam [15:0] AY_NEG16384 = 16'hC000;   // −16384
    localparam [15:0] AY_NEG32768 = 16'h8000;   // −32768

    // 激励表：{ay, gy}
    reg [31:0] stim [0:NSAMP-1];
    reg [15:0] s_ay, s_gy;

    //--------------------------------------------------------------------------
    // 轴选择的验证（+wrongaxis）：
    //   默认参数是 GYRO_AXIS=0（取 gx）、ACC_AXIS=1（取 ay）。
    //   正常跑：陀螺激励放在 **gx** 上（模块该读的那根）。
    //   +wrongaxis：故意放在 **gy** 上（模块不该读的那根）⇒ 模块看到的陀螺恒为 0，
    //               陀螺段的 excursion 应当**消失**。
    //   这样才证明"轴选择参数真接到了逻辑上"，而不是声明了一个没人用的参数。
    //--------------------------------------------------------------------------
    reg en_wrongaxis;
    reg en_prod;                     // +prodppd：生产值跑（配合 -gPULSE_PER_DEG=278）
    wire [15:0] drv_gx = en_wrongaxis ? 16'd0 : gy;
    wire [15:0] drv_gy = en_wrongaxis ? gy     : 16'd0;

    gim_imu_roll #(
        .COMP_SH(COMP_SH), .CAL_N(CAL_N), .CAL_SH(CAL_SH),
        .ACC_K(ACC_K), .ACC_SH(ACC_SH),
        .PULSE_MIN(PULSE_MIN), .PULSE_MID(PULSE_MID), .PULSE_MAX(PULSE_MAX),
        .ROLL_LIMIT_Q16(ROLL_LIM_Q16), .PULSE_PER_DEG(PULSE_PER_DEG),
        .GYRO_SIGN(1), .ACC_SIGN(1), .OUT_SIGN(1),
        .GYRO_AXIS(0), .ACC_AXIS(1)          // 默认：陀螺取 gx、加速度取 ay
    ) u_dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_en(en),
        .I_data_rdy(data_rdy),
        .I_ax(16'd0), .I_ay(ay), .I_az(16'd0),
        .I_gx(drv_gx), .I_gy(drv_gy), .I_gz(16'd0),
        .I_imu_ok(imu_ok),
        .O_pulse_roll(o_pulse), .O_roll_q16(o_roll),
        .O_calib_done(o_cdone), .O_calib_busy(o_cbusy)
    );

    //--------------------------------------------------------------------------
    // 激励生成
    //--------------------------------------------------------------------------
    task set_seg(input integer lo, input integer hi, input [15:0] vay, input integer rate);
        integer   j;
        reg [15:0] g16;          // ⚠ 必须先收成 16 位再拼，见下面注释
        begin
            // 读数 = 零偏 + 真实角速度（物理自洽，见下）
            g16 = GYRO_BIAS + rate;
            // ⚠⚠ 这里踩过坑：原来写成 `stim[j] = {vay, (GYRO_BIAS + rate)}`。
            //   后半段是 **32 位** 整数表达式，拼起来是 48 位，
            //   赋给 32 位的 stim[j] 时只留低 32 位 ⇒ **ay 被整个截掉，永远是 0**。
            //   症状：dump 里 `S 896 0 300`（ay 本该是 2000）。
            //   更隐蔽的是：金标准是**从 dump 读激励**的，dump 说 ay=0 它也用 0，
            //   于是逐样本比对"完全吻合"、R2 全绿 —— 又一个"两边一起错"。
            //   是 R3b-F / R4 这两条**锚点判据**（它们编码"我本来想给什么激励"）
            //   把它揪出来的。⇒ 锚点判据不能省。
            for (j = lo; j <= hi; j = j + 1)
                stim[j] = {vay, g16};
        end
    endtask

    // 激励必须**物理自洽** —— 这是踩过大坑的地方：
    //   陀螺读到的值 = **真实角速度 + 零偏**。零偏是器件的固定特性，标定前后**不会变**。
    //   第一版写成：标定段(0..255)读 300、标定后静止段(256..355)读 0 ——
    //   那等于说"器件明明静止，零偏却从 300 突变到 0"。减完零偏还剩 -300，
    //   滤波自然一路漂（R1 报"静止段 roll 从 -586 漂到 -48551"）。
    //   看着像"RTL 没减零偏"，其实**是激励不成立**。
    //
    // 各段设计（tau = 2^COMP_SH / 256 = 256 拍；每段必须远长于 tau 才能谈"收敛"）：
    //    A  0..255      0 / 0         标定
    //    B  256..455    0 / 0         R1：静止，roll 必须不动
    //    C  456..575  -5000 / 0       R3a：短时跟随陀螺
    //    D  576..775    0 / 0         停
    //    E  776..895  +5000 / 0       反向
    //    F  896..1400   0 / 2000      收敛到倾角 -2000*229.18 = -6.99 度
    //    G  1401..1900  0 / -32768    2g => 倾角 +114 度 => 必须撞 +25 度限幅
    //    H  1901..3400  0 / 0         回零；1500 拍 = 5.9*tau，足够收敛
    //   （第一版 H 段只给 100 拍 = 0.4*tau 就要求"收敛"，等于要求它 0.4 个时间常数
    //     内到位 —— 判据的时间尺度定错了，不是 RTL 的问题。）
    initial begin
        set_seg(0,    255,  16'd0,        0);          // A 标定
        set_seg(256,  455,  16'd0,        0);          // B 静止
        set_seg(456,  575,  16'd0,    -5000);          // C 跟陀螺
        set_seg(576,  775,  16'd0,        0);          // D 停
        set_seg(776,  895,  16'd0,     5000);          // E 反向
        set_seg(896,  1650, 16'd2000,     0);          // F 收敛到倾角（755 拍 ≈ 2.95τ）
        set_seg(1651, 2150, AY_NEG32768,  0);          // G 2g => 撞限幅
        set_seg(2151, 3650, 16'd0,        0);          // H 回零（1500 拍 ≈ 5.9τ）

        // 标定段覆盖成**零均值噪声**：均值仍是 300，但**每个样本不同**。
        //   为什么必须这么做：标定段若是常数，那么"取 256 个的平均"和
        //   "取 255 个的平均"和"直接取第一个样本"**结果完全一样**，
        //   "标定少一个样本"这个变异就成了空操作、测不出来（第一版就是这样漏掉的）。
        //   加 ±80 的交替噪声后：正确均值 = 300；
        //   "直接取第一个"会得到 380 或 220，偏 80 ⇒ 逐样本比对必然报红。
        for (k = 0; k < 256; k = k + 1)
            stim[k] = {16'd0, ((k % 2) == 0) ? (GYRO_BIAS + 80) : (GYRO_BIAS - 80)};
    end

    //--------------------------------------------------------------------------
    // 跑
    //--------------------------------------------------------------------------
    initial begin
        en_wrongaxis = $test$plusargs("wrongaxis") ? 1'b1 : 1'b0;
        en_prod      = $test$plusargs("prodppd")   ? 1'b1 : 1'b0;
        // 三个跑各写各的 dump，互不覆盖（③ 是 2026-09-28 新增的生产值跑）
        fd = $fopen(en_wrongaxis ? "dump_gim_roll_wrongaxis.txt" :
                    en_prod      ? "dump_gim_roll_prod.txt"      :
                                   "dump_gim_roll.txt", "w");
        if (fd == 0) begin $display("TB: FATAL 打不开 dump"); $finish; end
        $fwrite(fd, "# tb_gim_imu_roll COMP_SH=%0d CAL_N=%0d CAL_SH=%0d ACC_K=%0d ACC_SH=%0d PULSE_MIN=%0d PULSE_MID=%0d PULSE_MAX=%0d PULSE_PER_DEG=%0d ROLL_LIMIT_Q16=%0d NSAMP=%0d\n",
                COMP_SH, CAL_N, CAL_SH, ACC_K, ACC_SH,
                PULSE_MIN, PULSE_MID, PULSE_MAX, PULSE_PER_DEG, ROLL_LIM_Q16, NSAMP);

        rst_n = 1'b0; en = 1'b1; data_rdy = 1'b0; imu_ok = 1'b0;
        ay = 16'd0; gy = 16'sd300;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        imu_ok = 1'b1;                    // WHO_AM_I 已确认
        repeat (20) @(posedge clk);

        for (k = 0; k < NSAMP; k = k + 1) begin
            {s_ay, s_gy} = stim[k];
            @(negedge clk);
            ay = s_ay;  gy = s_gy;
            en = (k < NSAMP - 20) ? 1'b1 : 1'b0;   // 最后 20 个样本拉低 en
            data_rdy = 1'b1;
            @(posedge clk);
            @(negedge clk);
            data_rdy = 1'b0;
            // 记输入（只在变化时写，压小 dump）
            //   ⚠ 必须用 $signed() 再打印：`reg [15:0]` 是无符号的，
            //     直接 %0d 会把 −5000 打印成 60536，害得判据以为激励是正的
            //     （这个"看起来像 RTL bug"的假象就是这么来的）。
            if (k == 0 || stim[k] != stim[k-1])
                $fwrite(fd, "S %0d %0d %0d\n", k, $signed(s_ay), $signed(s_gy));
            // 记输出
            $fwrite(fd, "O %0d %0d %0d %0d %0d\n", k, o_roll, o_pulse, o_cdone, o_cbusy);
        end

        $fwrite(fd, "# final roll=%0d pulse=%0d calib_done=%0d\n", o_roll, o_pulse, o_cdone);
        $fclose(fd);
        $display("TB: done, %0d samples, calib_done=%0d", NSAMP, o_cdone);
        $finish;
    end

endmodule
