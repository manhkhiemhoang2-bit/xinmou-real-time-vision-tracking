//==============================================================================
// tb_gim_top.v —— gim_top（三轴云台子系统）集成级测试
//
// 和模块级测试的分工：
//   模块级（run_gim_pwm3 / run_gim_vis / run_gim_imu / run_gim_roll）已经把每个
//   模块的**内部行为**验透了。这一层只验**接起来之后还对**，具体三件事：
//     G1 视觉链路仍然通：帧过域 → 控制律 → pan/tilt 脉宽（Stage 1 不能被破坏）
//     G2 roll 现在真的由 IMU 驱动：喂 ay 之后 roll 从 0 走开、roll 脉宽离开中位
//     G3 **IMU 失效回退**：IMU 不回应时 roll 回中位，而 pan/tilt 完全不受影响
//        —— 这条最重要：它保证"拆掉 IMU 也能演示视觉伺服"
//
// 激励：
//   · 像素域每 FRAME_PIX 拍发一帧 bbox，共 NFRAME 帧（和 Stage 1 同一组）
//   · IMU 用**已被厂商已知good主机反证过**的 mpu6050_slave_bfm，
//     全程给 ay = +2000（约 2.7°；Q16 里是 458366）、gy = 300（零偏）
//   · `+imufail`：从机不回 ACK ⇒ 走失效回退分支
//
// ⚠ 时序参数在本 TB 里**按比例缩小**（真实值已由各自的模块级回归用真实参数验过）：
//     IMU_CLK_DIV 498 → 18   （SCL 100kHz → 2.5MHz；只为跑得快）
//     IMU_CYC_DLY 195312 → 4000（必须 > 一次 14 字节读的事务时间 ≈ 3120 拍）
//     PWR/RST/CFG_DLY 缩到几百拍
//   缩小的值全部写进 dump 头，判据从 dump 读参数。
//
// dump（写到 dump_gim_top.txt / dump_gim_top_imufail.txt）：
//   # 参数头
//   R <cyc> <roll_q16> <imu_ok> <imu_err>   roll 角度变化时记一条
//   W <wpan> <wtilt> <wroll>                实测三路脉宽（各数满一个 PWM 周期）
//   # 末行汇总
//==============================================================================
`timescale 1ns / 1ps

module tb_gim_top;

    // ---- 几何与舵机参数（与设计一致）----
    localparam IMG_W     = 1280;
    localparam IMG_H     = 720;
    localparam DEADZONE  = 40;
    localparam KP_NUM    = 13;
    localparam KP_SH     = 2;
    localparam SLEW_MAX  = 60;           // 真实 300 的 1/5（配合缩小的脉宽范围）
    localparam PULSE_MIN = 10000;        // 真实 50000 的 1/5
    localparam PULSE_MID = 15000;
    localparam PULSE_MAX = 20000;
    localparam PWM_PER   = 200000;       // 真实 1000000 的 1/5
    localparam BOOT_MUTE = 2000;
    localparam SIGN_PAN  = 1;
    localparam SIGN_TILT = 1;
    localparam LOCK_N    = 15;

    // ---- IMU 时序（缩小，理由见文件头）----
    localparam IMU_CLK_DIV = 18;
    localparam IMU_PWR_DLY = 200;
    localparam IMU_RST_DLY = 200;
    localparam IMU_CFG_DLY = 100;
    localparam IMU_CYC_DLY = 4000;       // > 一次事务 ≈3120 拍

    // ---- roll 解算 ----
    localparam IMU_COMP_SH  = 8;
    localparam IMU_CAL_N    = 256;
    localparam IMU_CAL_SH   = 8;
    localparam IMU_ACC_K    = 229;
    localparam IMU_ACC_SH   = 0;
    localparam ROLL_LIM_Q16 = 1638400;   // ±25°
    localparam ROLL_PPD     = 1200;      // 和模块级 TB 一致（这样限幅会咬住）

    localparam NFRAME    = 12;
    localparam FRAME_PIX = 1000;
    localparam NWAIT_MS  = 40;           // 帧喂完后等 40ms，让 roll 走起来

    reg pix_clk = 1'b0;
    reg clk     = 1'b0;
    always #8.334 pix_clk = ~pix_clk;    // 16.668ns -> 59.995MHz
    always #10    clk     = ~clk;        // 20ns     -> 50MHz

    reg pix_rst_n = 1'b0;
    reg rst_n     = 1'b0;
    reg en        = 1'b1;

    reg        pix_frame = 1'b0;
    reg [10:0] bx0, bx1, by0, by1;
    reg        bv;

    wire o_pwm_pan, o_pwm_tilt, o_pwm_roll;
    wire o_scl, o_sda;
    wire o_locked, o_tgt_present, o_boot_done, o_upd_dbg;
    wire o_imu_ok, o_imu_err;
    wire signed [23:0] o_roll;

    integer    i, f, fd, cyc;
    reg        en_imufail;
    reg signed [23:0] last_roll;

    reg [45:0] stim [0:NFRAME-1];

    // ---- IMU 注入：ay = +2000（≈2.7° 倾角）、gy = 300（零偏）----
    localparam [15:0] IMU_AY = 16'd2000;
    localparam [15:0] IMU_GY = 16'd300;

    gim_top #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .DEADZONE(DEADZONE),
        .KP_NUM(KP_NUM), .KP_SH(KP_SH), .SLEW_MAX(SLEW_MAX),
        .SIGN_PAN(SIGN_PAN), .SIGN_TILT(SIGN_TILT), .LOCK_N(LOCK_N),
        .PULSE_MIN(PULSE_MIN), .PULSE_MID(PULSE_MID), .PULSE_MAX(PULSE_MAX),
        .BOOT_MUTE(BOOT_MUTE),
        .IMU_CLK_DIV(IMU_CLK_DIV), .IMU_PWR_DLY(IMU_PWR_DLY),
        .IMU_RST_DLY(IMU_RST_DLY), .IMU_CFG_DLY(IMU_CFG_DLY),
        .IMU_CYC_DLY(IMU_CYC_DLY),
        .IMU_COMP_SH(IMU_COMP_SH), .IMU_CAL_N(IMU_CAL_N), .IMU_CAL_SH(IMU_CAL_SH),
        .IMU_ACC_K(IMU_ACC_K), .IMU_ACC_SH(IMU_ACC_SH),
        .ROLL_LIM_Q16(ROLL_LIM_Q16), .ROLL_PPD(ROLL_PPD)
    ) u_dut (
        .I_pix_clk   (pix_clk),
        .I_pix_rst_n (pix_rst_n),
        .I_pix_frame (pix_frame),
        .I_bbox_x0   (bx0), .I_bbox_x1(bx1),
        .I_bbox_y0   (by0), .I_bbox_y1(by1),
        .I_bbox_valid(bv),
        .I_clk(clk), .I_rst_n(rst_n), .I_en(en),
        .O_pwm_pan(o_pwm_pan), .O_pwm_tilt(o_pwm_tilt), .O_pwm_roll(o_pwm_roll),
        .O_gim_scl(o_scl), .IO_gim_sda(o_sda),
        .O_locked(o_locked), .O_tgt_present(o_tgt_present),
        .O_boot_done(o_boot_done), .O_upd_dbg(o_upd_dbg),
        .O_imu_ok(o_imu_ok), .O_imu_err(o_imu_err), .O_roll_q16(o_roll)
    );

    // ---- 已验证过的 MPU6050 从机模型 ----
    //   ⚠ 陀螺激励放在 **gx**（不是 gy）：gim_imu_roll 默认 GYRO_AXIS=0 取 gx，
    //     因为"横滚 = 绕光轴转"，而 IMU 平放、+X 顺着镜头时绕光轴就是绕 X。
    //     （第一版写死读 gy 是错的 —— gy 是俯仰角速度。见 gim_imu_roll.v 参数区。）
    mpu6050_slave_bfm #(.DEV_ADDR(7'h68)) u_slv (
        .I_clk(clk), .I_rst_n(rst_n),
        .SCL(o_scl), .SDA(o_sda),
        .I_ax(16'd0), .I_ay(IMU_AY), .I_az(16'h4000), .I_temp(16'd0),
        .I_gx(IMU_GY), .I_gy(16'd0), .I_gz(16'd0),
        .I_no_ack(en_imufail),
        .O_wr_bytes(), .O_rd_bytes(), .O_last_regaddr(),
        .O_cfg_cnt(), .O_cfg_wr(), .O_cfg_addr(), .O_cfg_data(),
        .O_last_rd_reg(), .O_ack_err_cnt()
    );

    pullup(o_scl);
    pullup(o_sda);

    always @ (posedge clk) cyc = cyc + 1;

    // ---- roll 或状态位变化就记一条（压小 dump）----
    //   ⚠ 只按 roll 变化记是不够的：失效注入那一跑里 roll **恒为 0**，
    //     全程只会写出一条（复位后第一拍、那时 imu_err 还没置起来），
    //     于是"imu_err 置位"这条判据在 R 行里永远找不到它。
    //     所以状态位（imu_ok/imu_err）变化时也必须记。
    reg last_ok, last_err;
    always @ (posedge clk) begin
        if (rst_n && (o_roll !== last_roll || o_imu_ok !== last_ok || o_imu_err !== last_err)) begin
            $fwrite(fd, "R %0d %0d %0d %0d\n", cyc, o_roll, o_imu_ok, o_imu_err);
            last_roll = o_roll;
            last_ok   = o_imu_ok;
            last_err  = o_imu_err;
        end
    end

    // ---- bbox 激励表（和 Stage 1 同一组）----
    initial begin
        stim[0]  = {1'b1, 11'd560, 11'd720, 11'd300, 11'd420};   // 正中
        stim[1]  = {1'b1, 11'd100, 11'd300, 11'd300, 11'd420};   // 偏左
        stim[2]  = {1'b1, 11'd1000,11'd1200,11'd300, 11'd420};   // 偏右
        stim[3]  = {1'b1, 11'd560, 11'd720, 11'd100, 11'd200};   // 偏上
        stim[4]  = {1'b1, 11'd560, 11'd720, 11'd500, 11'd640};   // 偏下
        stim[5]  = {1'b0, 11'd0,   11'd0,   11'd0,   11'd0  };   // 丢失
        stim[6]  = {1'b0, 11'd1,   11'd2,   11'd3,   11'd4  };
        stim[7]  = {1'b1, 11'd0,   11'd0,   11'd0,   11'd0  };   // 左上角
        stim[8]  = {1'b1, 11'd1279,11'd1279,11'd719, 11'd719};   // 右下角
        stim[9]  = {1'b1, 11'd0,   11'd1,   11'd0,   11'd1  };
        stim[10] = {1'b1, 11'd1,   11'd2,   11'd1,   11'd2  };
        stim[11] = {1'b1, 11'd1000,11'd1200,11'd300, 11'd420};   // 末帧：pan 偏右、tilt 居中
    end

    //--------------------------------------------------------------------------
    // 激励进程
    //--------------------------------------------------------------------------
    initial begin
        en_imufail = $test$plusargs("imufail") ? 1'b1 : 1'b0;
        fd = $fopen(en_imufail ? "dump_gim_top_imufail.txt" : "dump_gim_top.txt", "w");
        if (fd == 0) begin $display("TB: FATAL 打不开 dump"); $finish; end
        $fwrite(fd, "# tb_gim_top IMU_CLK_DIV=%0d IMU_CYC_DLY=%0d IMU_ACC_K=%0d ROLL_PPD=%0d ROLL_LIM_Q16=%0d PULSE_MIN=%0d PULSE_MID=%0d PULSE_MAX=%0d PWM_PER=%0d NFRAME=%0d IMUFAIL=%0d NWAIT_MS=%0d\n",
                IMU_CLK_DIV, IMU_CYC_DLY, IMU_ACC_K, ROLL_PPD, ROLL_LIM_Q16,
                PULSE_MIN, PULSE_MID, PULSE_MAX, PWM_PER, NFRAME, en_imufail, NWAIT_MS);

        cyc = 0; last_roll = -24'sd1;      // 先给不可能的值，保证第一条 R 一定写出来
        last_ok = 1'b0; last_err = 1'b0;
        pix_rst_n = 1'b0; rst_n = 1'b0; en = 1'b1;
        pix_frame = 1'b0;
        bx0 = 11'd560; bx1 = 11'd720; by0 = 11'd300; by1 = 11'd420; bv = 1'b1;

        repeat (20) @(posedge pix_clk);
        repeat (20) @(posedge clk);
        pix_rst_n = 1'b1; rst_n = 1'b1;
        repeat (20) @(posedge pix_clk);

        // 等上电静默结束再喂帧
        wait (o_boot_done == 1'b1);
        repeat (20) @(posedge pix_clk);

        // 视觉帧
        for (f = 0; f < NFRAME; f = f + 1) begin
            {bv, bx0, bx1, by0, by1} = stim[f];
            repeat (FRAME_PIX) @(posedge pix_clk);
            @(negedge pix_clk);  pix_frame = 1'b1;
            @(negedge pix_clk);  pix_frame = 1'b0;
        end
    end

    //--------------------------------------------------------------------------
    // 收尾进程：等够 → 量三路脉宽 → 落盘 → 结束
    //   刻意用**固定等待**而不是"等 roll 变了再走"：
    //   后者在失效注入那一跑里永远等不到，会把仿真挂死。
    //--------------------------------------------------------------------------
    integer wp, wt, wr, n;

    task measure_pwm(input integer which, output integer width);
        integer m;
        begin
            width = 0;
            case (which)
                0:       wait (o_pwm_pan  === 1'b1);
                1:       wait (o_pwm_tilt === 1'b1);
                default: wait (o_pwm_roll === 1'b1);
            endcase
            for (m = 0; m < PWM_PER - 1; m = m + 1) begin
                @(posedge clk);
                case (which)
                    0:       if (o_pwm_pan  === 1'b1) width = width + 1;
                    1:       if (o_pwm_tilt === 1'b1) width = width + 1;
                    default: if (o_pwm_roll === 1'b1) width = width + 1;
                endcase
            end
        end
    endtask

    initial begin
        #(NWAIT_MS * 1000000);            // 帧喂完后再等 NWAIT_MS 毫秒
        measure_pwm(0, wp);
        measure_pwm(1, wt);
        measure_pwm(2, wr);
        $fwrite(fd, "W %0d %0d %0d\n", wp, wt, wr);
        $fwrite(fd, "# final roll=%0d imu_ok=%0d imu_err=%0d locked=%0d tgt=%0d\n",
                o_roll, o_imu_ok, o_imu_err, o_locked, o_tgt_present);
        $fclose(fd);
        $display("TB: done. roll=%0d imu_ok=%0d imu_err=%0d  PWM pan=%0d tilt=%0d roll=%0d",
                 o_roll, o_imu_ok, o_imu_err, wp, wt, wr);
        $finish;
    end

endmodule
