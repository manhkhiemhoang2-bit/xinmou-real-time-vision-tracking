//==============================================================================
// tb_i2c_bfm_chk.v —— **验证 mpu6050_slave_bfm 自己是对的**
//
// 为什么要有这一层：
//   手写的从机模型去验手写的主机，最危险的失败是"两个一起错、还互相吻合"。
//   所以先拿一个**已知good的主机**去反证从机模型：
//     uii2c（米联客的 I2C 主机，工程里摄像头配置正在用它，已经在硬件上跑通过）。
//   这条通过之后，mpu6050_slave_bfm 才有资格去验我们自己写的 gim_imu_i2c。
//
// 测什么：
//   1. 写一个寄存器（PWR_MGMT_1 = 0x6B，写 0x00），看从机模型有没有收到 (0x6B, 0x00)
//   2. 随机读 0x3B 起 14 字节，看读回来的字节序对不对
//      —— 这一条同时把"uii2c 的字节序"钉死（我们的 gim_imu_i2c 依赖它）：
//         · 写：I_wr_data[7:0] 先发
//         · 读：O_rd_data[7:0] 是第一个收到的字节
//   3. 总线无错（O_iic_bus_error 全程为 0）
//
// dump（写到 dump_i2c_bfm_chk.txt）：
//     W <regaddr> <data>                  从机记录到的每一次寄存器写
//     R <b0> <b1> ... <b13>               14 字节连读的结果（按收到的顺序）
//     # bus_err=<n> rd_bytes=<n> wr_bytes=<n>
//==============================================================================
`timescale 1ns / 1ps

module tb_i2c_bfm_chk;

    localparam CLK_HZ   = 50000000;
    localparam SCL_HZ   = 100000;
    localparam CLK_DIV  = CLK_HZ / SCL_HZ - 2;      // ≈ 498

    // 注入给"IMU"的假数据。挑选原则：
    //   ① 14 个字节**两两不同** —— 顺序错/错位一眼看出
    //   ② 每个字节的**高低半字节也不同** —— 否则"半字节交换"这个变异会变成空操作
    //      （第一版用 0x1122/0x3344…，每字节都是重复半字节，变异自证当场抓到"漏掉"）
    //   0x3B..0x48 = AX_H AX_L AY_H AY_L AZ_H AZ_L TMP_H TMP_L GX_H GX_L GY_H GY_L GZ_H GZ_L
    localparam [15:0] AX = 16'h1A2B, AY = 16'h3C4D, AZ = 16'h5E6F;
    localparam [15:0] TP = 16'h7081;
    localparam [15:0] GX = 16'h92A3, GY = 16'hB4C5, GZ = 16'hD6E7;

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50MHz

    reg rstn = 1'b0;                                // 低有效（uii2c 的约定）

    // ---- 主机侧 ----
    wire        m_scl;
    wire        m_sda;
    reg  [23:0] wr_data;
    reg  [7:0]  wr_cnt, rd_cnt;
    reg         req, mode;
    wire [111:0] rd_data;
    wire        busy, bus_err, sda_dg;

    uii2c #(
        .WMEN_LEN (3 ),
        .RMEN_LEN (14),
        .CLK_DIV  (CLK_DIV)
    ) u_mst (
        .I_clk       (clk     ),
        .I_rstn      (rstn    ),
        .O_iic_scl   (m_scl   ),
        .IO_iic_sda  (m_sda   ),
        .I_wr_data   (wr_data ),
        .I_wr_cnt    (wr_cnt  ),
        .O_rd_data   (rd_data ),
        .I_rd_cnt    (rd_cnt  ),
        .I_iic_mode  (mode    ),
        .I_iic_req   (req     ),
        .O_iic_busy  (busy    ),
        .O_iic_bus_error(bus_err),
        .IO_iic_sda_dg  (sda_dg)
    );

    // ---- 从机模型 ----
    wire [15:0] bfm_wr_bytes, bfm_rd_bytes, bfm_cfg_cnt;
    wire [7:0]  bfm_last_addr, bfm_last_rd;
    wire        bfm_cfg_wr;
    wire [7:0]  bfm_cfg_addr, bfm_cfg_data;
    wire [7:0]  bfm_ackerr;
    wire        no_ack = 1'b0;

    mpu6050_slave_bfm #(.DEV_ADDR(7'h68)) u_slv (
        .I_clk(clk), .I_rst_n(rstn),
        .SCL(m_scl), .SDA(m_sda),
        .I_ax(AX), .I_ay(AY), .I_az(AZ), .I_temp(TP),
        .I_gx(GX), .I_gy(GY), .I_gz(GZ),
        .I_no_ack(no_ack),
        .O_wr_bytes(bfm_wr_bytes), .O_rd_bytes(bfm_rd_bytes),
        .O_last_regaddr(bfm_last_addr),
        .O_cfg_cnt(bfm_cfg_cnt),
        .O_cfg_wr(bfm_cfg_wr),
        .O_cfg_addr(bfm_cfg_addr),
        .O_cfg_data(bfm_cfg_data),
        .O_last_rd_reg(bfm_last_rd),
        .O_ack_err_cnt(bfm_ackerr)
    );

    // 总线必须有上拉（I2C 靠上拉拉高）
    pullup(m_scl);
    pullup(m_sda);

    integer fd, i, fd2;

    //--------------------------------------------------------------------------
    // 总线级调试 dump（只在 --debug 时需要，默认也写，文件很小）
    //   记录 SCL/SDA 每次变化 + 从机模型此刻的状态/位计数，用来定位"读到哪一步断了"
    //--------------------------------------------------------------------------
    initial fd2 = $fopen("dump_i2c_bus.txt", "w");
    always @ (m_scl or m_sda) begin
        if (rstn)
            $fwrite(fd2, "%0t scl=%b sda=%b st=%0d bitn=%0d drv=%b\n",
                    $time, m_scl, m_sda, u_slv.state, u_slv.bitn, u_slv.drive_en);
    end

    //--------------------------------------------------------------------------
    // 从机每写一个寄存器就给一个脉冲，这里抓下来记成一行
    //--------------------------------------------------------------------------
    always @ (posedge clk) begin
        if (rstn && bfm_cfg_wr)
            $fwrite(fd, "W %0d %0d\n", bfm_cfg_addr, bfm_cfg_data);
    end

    //--------------------------------------------------------------------------
    //--------------------------------------------------------------------------
    // ⚠ 握手必须照抄官方摄像头配置模块（uicfgcs500_720p.v 的 2'd1/2'd2/2'd3）：
    //   I_iic_req 要**一直按住**，直到 uii2c 在它自己的 scl_clk 上升沿上认了、
    //   把 O_iic_busy 抬起来，那时才能放开。
    //   第一版写成"按一个 clk 就放开"——uii2c 在 5µs 才采一次，根本抓不到，
    //   于是整个仿真 TIMEOUT（这个坑记下来）。
    //--------------------------------------------------------------------------
    task do_xfer(input [23:0] wd, input [7:0] wc, input [7:0] rc, input md);
        begin
            @(negedge clk);
            wait (busy == 1'b0);
            wr_data = wd;  wr_cnt = wc;  rd_cnt = rc;  mode = md;
            req = 1'b1;
            wait (busy == 1'b1);        // 按住直到主机认了
            @(negedge clk);
            req = 1'b0;
            wait (busy == 1'b0);        // 等它做完
            @(negedge clk);
        end
    endtask

    initial begin
        fd = $fopen("dump_i2c_bfm_chk.txt", "w");
        if (fd == 0) begin $display("TB: FATAL 打不开 dump"); $finish; end
        $fwrite(fd, "# tb_i2c_bfm_chk CLK_DIV=%0d AX=%04h AY=%04h AZ=%04h TP=%04h GX=%04h GY=%04h GZ=%04h\n",
                CLK_DIV, AX, AY, AZ, TP, GX, GY, GZ);

        rstn    = 1'b0;
        req     = 1'b0;
        wr_data = 24'd0; wr_cnt = 8'd0; rd_cnt = 8'd0; mode = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;
        repeat (20) @(posedge clk);

        // ---- 1) 写一个配置寄存器：PWR_MGMT_1(0x6B) = 0x00 ----
        //   I_wr_data[7:0] 先发 => 器件地址，然后寄存器地址，然后数据
        do_xfer({8'h00, 8'h6B, 8'hD0}, 8'd3, 8'd0, 1'b0);
        $display("TB: 写配置完成 busy=%0d err=%0d", busy, bus_err);

        // ---- 2) 随机读 0x3B 起 14 字节 ----
        //   ⚠ 拼接顺序踩过一次：{A,B,C} 里 **C 在最低位**，而 uii2c 是
        //     I_wr_data[7:0] **先发**。第一版写成 {8'h3B, 8'hD0, 8'h00}，
        //     结果先发出去的是 0x00（不是器件地址），从机正确地拒绝了它。
        do_xfer({8'h00, 8'h3B, 8'hD0}, 8'd2, 8'd14, 1'b1);
        $display("TB: 随机读完成 err=%0d", bus_err);

        repeat (200) @(posedge clk);

        // ---- dump 14 字节连读结果（按收到的顺序：O_rd_data[7:0] 是第一个）----
        $fwrite(fd, "R");
        for (i = 0; i < 14; i = i + 1)
            $fwrite(fd, " %0d", rd_data[i*8 +: 8]);
        $fwrite(fd, "\n");
        $fwrite(fd, "# bus_err=%0d rd_bytes=%0d wr_bytes=%0d ack_err=%0d last_addr=%0d\n",
                bus_err, bfm_rd_bytes, bfm_wr_bytes, bfm_ackerr, bfm_last_addr);

        $fclose(fd);
        $display("TB: done. rd_bytes=%0d wr_bytes=%0d bus_err=%0d", bfm_rd_bytes, bfm_wr_bytes, bus_err);
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;                     // 20ms 仿真时间
        $display("TB: TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule
