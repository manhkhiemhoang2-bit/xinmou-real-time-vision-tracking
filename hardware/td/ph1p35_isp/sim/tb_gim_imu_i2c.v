//==============================================================================
// tb_gim_imu_i2c.v —— gim_imu_i2c 的测试平台（配置序列 + 256Hz 周期读）
//
// 结构：DUT（gim_imu_i2c，内含厂商 uii2c 主机）+ **已验证过的** MPU6050 从机模型
//   从机模型的正确性由 sim\run_i2c_bfm_chk.ps1 单独反证过（拿厂商已知good主机验的），
//   所以这里可以放心用它的输出来判 DUT。
//
// 三个读周期注入**三组不同的值** ⇒ 能验两件事：
//   ① 每个周期都真的取到了"当前"数据（不是缓存了第一拍）
//   ② 14 字节拆成 7 个 16 位量时的高低字节顺序对
//
// ⚠ 延时参数：
//   PWR_DLY / RST_DLY / CFG_DLY 在本 TB 里**缩小**（真实 100ms/100ms/2ms），
//     因为它们的唯一作用就是"等够时间"，精确值不影响功能；真实值在设计文件里是
//     字面量 + 推导注释，改动一眼可见。
//   **CYC_DLY 用真实值 195312（50MHz/256 = 256Hz）** —— 采样间隔这条判据是真验的。
//
// ⚠ SCL 用真实 CLK_DIV=498（≈100kHz），所以每个 I2C 事务约 0.3~1.6ms，
//   三个读周期合计约 12ms 仿真时间。
//
// dump（写到 dump_gim_imu.txt）：
//   W <regaddr> <data>                          DUT 写进从机的每一次配置
//   D <cyc> <k> <ax> <ay> <az> <tp> <gx> <gy> <gz>   第 k 次 O_data_rdy 的拆包结果
//   # who=<v> imu_ok=<b> imu_err=<b> step=<s> err=<b>
//==============================================================================
`timescale 1ns / 1ps

module tb_gim_imu_i2c;

    localparam CLK_HZ   = 50000000;
    localparam CLK_DIV  = 498;         // SCL ≈ 100kHz（真实值）
    localparam CYC_DLY  = 195312;      // 真实值：50e6/256 = 256Hz

    // 缩小的延时（理由见文件头）
    localparam PWR_DLY  = 200;
    localparam RST_DLY  = 200;
    localparam CFG_DLY  = 100;

    localparam NRD      = 3;           // 只跑 3 个读周期（省仿真时间）

    reg clk = 1'b0;
    always #10 clk = ~clk;             // 50MHz

    reg  rst_n = 1'b0;
    wire d_scl;
    wire d_sda;
    wire [15:0] o_ax, o_ay, o_az, o_tp, o_gx, o_gy, o_gz;
    wire        o_rdy, o_ok, o_err, o_sda_dg;
    wire [3:0]  o_step;
    wire [7:0]  o_who;

    integer fd, cyc, rd_idx;
    reg     en_noack;                  // +noack 故障注入

    // ---- 注入给从机的三组值（每个字节两两不同、半字节也不对称）----
    reg [15:0] t_ax, t_ay, t_az, t_tp, t_gx, t_gy, t_gz;
    always @ (*) begin
        case (rd_idx)
            1: begin t_ax=16'h2B3C; t_ay=16'h4D5E; t_az=16'h6F70; t_tp=16'h8192;
                     t_gx=16'hA3B4; t_gy=16'hC5D6; t_gz=16'hE7F8; end
            2: begin t_ax=16'h3C4D; t_ay=16'h5E6F; t_az=16'h7081; t_tp=16'h92A3;
                     t_gx=16'hB4C5; t_gy=16'hD6E7; t_gz=16'hF8F9; end
            default: begin t_ax=16'h1A2B; t_ay=16'h3C4D; t_az=16'h5E6F; t_tp=16'h7081;
                     t_gx=16'h92A3; t_gy=16'hB4C5; t_gz=16'hD6E7; end
        endcase
    end

    // ---- DUT ----
    gim_imu_i2c #(
        .CLK_HZ  (CLK_HZ ),
        .CLK_DIV (CLK_DIV),
        .PWR_DLY (PWR_DLY),
        .RST_DLY (RST_DLY),
        .CFG_DLY (CFG_DLY),
        .CYC_DLY (CYC_DLY)
    ) u_dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .O_scl(d_scl), .IO_sda(d_sda),
        .O_ax(o_ax), .O_ay(o_ay), .O_az(o_az), .O_temp(o_tp),
        .O_gx(o_gx), .O_gy(o_gy), .O_gz(o_gz),
        .O_data_rdy(o_rdy), .O_imu_ok(o_ok), .O_imu_err(o_err),
        .O_step(o_step), .O_who(o_who), .O_sda_dg(o_sda_dg)
    );

    // ---- 从机模型（已被厂商已知good主机反证通过）----
    wire [15:0] b_wr, b_rd, b_cnt;
    wire [7:0]  b_laddr, b_lrd, b_ae, b_ca, b_cd;
    wire        b_cw;

    mpu6050_slave_bfm #(.DEV_ADDR(7'h68)) u_slv (
        .I_clk(clk), .I_rst_n(rst_n),
        .SCL(d_scl), .SDA(d_sda),
        .I_ax(t_ax), .I_ay(t_ay), .I_az(t_az), .I_temp(t_tp),
        .I_gx(t_gx), .I_gy(t_gy), .I_gz(t_gz),
        .I_no_ack(en_noack),
        .O_wr_bytes(b_wr), .O_rd_bytes(b_rd), .O_last_regaddr(b_laddr),
        .O_cfg_cnt(b_cnt), .O_cfg_wr(b_cw),
        .O_cfg_addr(b_ca), .O_cfg_data(b_cd),
        .O_last_rd_reg(b_lrd), .O_ack_err_cnt(b_ae)
    );

    pullup(d_scl);
    pullup(d_sda);

    // ---- 配置写：从机每写一个就给一拍脉冲，转成一行 ----
    always @ (posedge clk) begin
        if (rst_n && b_cw) $fwrite(fd, "W %0d %0d\n", b_ca, b_cd);
    end

    // ---- 每次 O_data_rdy 记一行 ----
    always @ (posedge clk) begin
        if (rst_n && o_rdy) begin
            $fwrite(fd, "D %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    cyc, rd_idx, o_ax, o_ay, o_az, o_tp, o_gx, o_gy, o_gz);
            rd_idx = rd_idx + 1;
        end
    end

    always @ (posedge clk) cyc = cyc + 1;

    initial begin
        en_noack = $test$plusargs("noack") ? 1'b1 : 1'b0;
        fd = $fopen(en_noack ? "dump_gim_imu_noack.txt" : "dump_gim_imu.txt", "w");
        if (fd == 0) begin $display("TB: FATAL 打不开 dump"); $finish; end
        $fwrite(fd, "# tb_gim_imu_i2c CLK_DIV=%0d CYC_DLY=%0d PWR_DLY=%0d RST_DLY=%0d CFG_DLY=%0d NRD=%0d NOACK=%0d\n",
                CLK_DIV, CYC_DLY, PWR_DLY, RST_DLY, CFG_DLY, NRD, en_noack);
        $fwrite(fd, "# exp k0 %04h %04h %04h %04h %04h %04h %04h\n",
                16'h1A2B, 16'h3C4D, 16'h5E6F, 16'h7081, 16'h92A3, 16'hB4C5, 16'hD6E7);
        $fwrite(fd, "# exp k1 %04h %04h %04h %04h %04h %04h %04h\n",
                16'h2B3C, 16'h4D5E, 16'h6F70, 16'h8192, 16'hA3B4, 16'hC5D6, 16'hE7F8);
        $fwrite(fd, "# exp k2 %04h %04h %04h %04h %04h %04h %04h\n",
                16'h3C4D, 16'h5E6F, 16'h7081, 16'h92A3, 16'hB4C5, 16'hD6E7, 16'hF8F9);

        cyc = 0; rd_idx = 0;
        rst_n = 1'b0;
        repeat (50) @(posedge clk);
        rst_n = 1'b1;

        // 等够（+ 余量）：配置约 2ms（7 个 I2C 事务）+ 3 个读周期 × 3.906ms ≈ 14ms
        //   ⇒ 等 20ms。⛔ 不要写成 100ms（那是 500 万拍，白跑）。
        #20000000;

        $fwrite(fd, "# who=%0d imu_ok=%0d imu_err=%0d step=%0d err=%0d rd_idx=%0d\n",
                o_who, o_ok, o_err, o_step, en_noack, rd_idx);
        $fclose(fd);
        $display("TB: done. rd_idx=%0d who=0x%02h ok=%0d err=%0d", rd_idx, o_who, o_ok, o_err);
        $finish;
    end

endmodule
