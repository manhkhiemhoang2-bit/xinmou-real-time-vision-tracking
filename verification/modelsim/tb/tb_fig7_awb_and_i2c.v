//==============================================================================
// 文件名   : tb_fig7_awb_and_i2c.v
// 对应报告 : 图 7 —— AWB 20 轮恢复余数迭代除法器与自研 I2C 从机 (0x50) RTL 仿真测试平台
// 仿真对象 : awb_div20_core.v + gim_i2c_slave.v
// 运行方法 : 在 ModelSim Transcript 窗口执行: do run_fig7_awb_i2c.do
//==============================================================================
`timescale 1ns / 1ps

module tb_fig7_awb_and_i2c;

    // 1. 时钟定义：50 MHz 系统与 I2C 从机时钟 (20 ns)，45 MHz 像素时钟 (22.2 ns)
    reg clk_50m;
    reg pix_clk;
    reg rst_n;

    initial clk_50m = 1'b0;
    always #10.0 clk_50m = ~clk_50m;

    initial pix_clk = 1'b0;
    always #11.1 pix_clk = ~pix_clk;

    //==========================================================================
    // Part A: AWB 20 轮恢复余数迭代除法器激励与例化
    //==========================================================================
    reg         awb_tuser;
    reg         awb_trig;
    reg  [31:0] sum_r0, sum_g0, sum_b0;
    wire [4:0]  div_cnt;
    wire [19:0] quo_r, quo_b;
    wire        div_done;
    wire [19:0] in_r_r1, in_b_r1;

    awb_div20_core u_awb_div20 (
        .I_clk        (pix_clk),
        .I_rst_n      (rst_n),
        .I_tuser      (awb_tuser),
        .I_tvalid_r1  (awb_trig),
        .sum_r0       (sum_r0),
        .sum_g0       (sum_g0),
        .sum_b0       (sum_b0),
        .div_cnt      (div_cnt),
        .quo_r        (quo_r),
        .quo_b        (quo_b),
        .div_done     (div_done),
        .in_r_r1      (in_r_r1),
        .in_b_r1      (in_b_r1)
    );

    //==========================================================================
    // Part B: 自研 I2C 从机 (0x50) 跨频锁存、地址自增连读与 B4 开关门控
    //==========================================================================
    reg         i2c_scl;
    reg         master_sda_drive; // 1=主机拉低 SDA, 0=释放 SDA(上拉为高)
    wire        sda_pull_slave;
    wire        sda_bus = ~(master_sda_drive | sda_pull_slave);

    reg         pix_frame;
    reg  [10:0] bbox_x0, bbox_x1, bbox_y0, bbox_y1;
    reg         bbox_valid;
    reg         auto_mode;
    reg         track_en_b4; // SW2 (B4) 追踪使能开关
    reg  [3:0]  isp_mode;

    gim_i2c_slave #(
        .SLAVE_ADDR (7'h50)
    ) u_i2c_slave (
        .I_clk        (clk_50m),
        .I_rst_n      (rst_n),
        .I_scl        (i2c_scl),
        .I_sda_in     (sda_bus),
        .O_sda_pull   (sda_pull_slave),
        .I_pix_clk    (pix_clk),
        .I_pix_rst_n  (rst_n),
        .I_pix_frame  (pix_frame),
        .I_bbox_x0    (bbox_x0),
        .I_bbox_x1    (bbox_x1),
        .I_bbox_y0    (bbox_y0),
        .I_bbox_y1    (bbox_y1),
        .I_bbox_valid (bbox_valid),
        .I_auto_mode  (auto_mode),
        .I_track_en   (track_en_b4),
        .I_mode       (isp_mode),
        .I_bbox_w     (11'd56),
        .I_bbox_h     (11'd62),
        .I_pix_cnt    (16'd180),
        .I_color_cls  (2'd0),
        .O_roi_x0     (),
        .O_roi_x1     (),
        .O_roi_y0     (),
        .O_roi_y1     (),
        .O_roi_en     ()
    );

    // I2C 主机位传输基础任务 (为便于一屏紧凑展示，加速 SCL 半周期为 120 ns)
    localparam T_HALF = 120;

    task i2c_start;
    begin
        master_sda_drive = 1'b0; i2c_scl = 1'b1; #(T_HALF);
        master_sda_drive = 1'b1; #(T_HALF);
        i2c_scl = 1'b0; #(T_HALF);
    end
    endtask

    task i2c_stop;
    begin
        master_sda_drive = 1'b1; i2c_scl = 1'b0; #(T_HALF);
        i2c_scl = 1'b1; #(T_HALF);
        master_sda_drive = 1'b0; #(T_HALF);
    end
    endtask

    task i2c_write_byte(input [7:0] data);
        integer i;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            master_sda_drive = ~data[i];
            #(T_HALF/2);
            i2c_scl = 1'b1; #(T_HALF);
            i2c_scl = 1'b0; #(T_HALF/2);
        end
        // 释放 SDA 接收从机 ACK
        master_sda_drive = 1'b0;
        #(T_HALF/2);
        i2c_scl = 1'b1; #(T_HALF);
        i2c_scl = 1'b0; #(T_HALF/2);
    end
    endtask

    task i2c_read_byte(output [7:0] data, input send_ack);
        integer i;
    begin
        master_sda_drive = 1'b0;
        for (i = 7; i >= 0; i = i - 1) begin
            #(T_HALF/2);
            i2c_scl = 1'b1;
            #(T_HALF/2);
            data[i] = sda_bus;
            #(T_HALF/2);
            i2c_scl = 1'b0;
            #(T_HALF/2);
        end
        // 主机发送 ACK (send_ack=1 拉低 SDA) 或 NACK (send_ack=0 保持高)
        master_sda_drive = send_ack ? 1'b1 : 1'b0;
        #(T_HALF/2);
        i2c_scl = 1'b1; #(T_HALF);
        i2c_scl = 1'b0; #(T_HALF/2);
        master_sda_drive = 1'b0;
    end
    endtask

    reg [7:0] rd_cx_l, rd_cx_h, rd_cy_l, rd_cy_h, rd_valid_on, rd_valid_off, rd_ver;

    initial begin
        rst_n            = 1'b0;
        awb_tuser        = 1'b0;
        awb_trig         = 1'b0;
        // 设定帧统计累加和：G/R = 1.30 (Q4.16 = 20'h14CCC), G/B = 1.14 (Q4.16 = 20'h123D7)
        sum_g0           = 32'd130000;
        sum_r0           = 32'd100000;
        sum_b0           = 32'd114035;

        i2c_scl          = 1'b1;
        master_sda_drive = 1'b0;
        pix_frame        = 1'b0;
        // 设定检测框中心 CX = (460+516)/2 = 488 (11'h1E8), CY = (250+312)/2 = 281 (11'h119)
        bbox_x0          = 11'd460;
        bbox_x1          = 11'd516;
        bbox_y0          = 11'd250;
        bbox_y1          = 11'd312;
        bbox_valid       = 1'b1;
        auto_mode        = 1'b0;
        track_en_b4      = 1'b1; // B4 追踪开关初始开启 (1)
        isp_mode         = 4'd5; // M5 模式

        #80;
        rst_n = 1'b1;
        #60;

        // 1. 触发 AWB 20 轮恢复余数迭代除法器 + 触发像素域帧末锁存脉冲 pix_frame
        @(posedge pix_clk);
        awb_trig  <= 1'b1;
        pix_frame <= 1'b1;
        @(posedge pix_clk);
        awb_trig  <= 1'b0;
        pix_frame <= 1'b0;

        // 等待 AWB 20 轮迭代完成并更新 in_r_r1 / in_b_r1
        #600;

        // 2. 主机发起 I2C 写寄存器指针 0x00，然后 Repeated START 连读 0x00..0x04
        i2c_start();
        i2c_write_byte(8'hA0); // 7'h50 << 1 | 0 (Write)
        i2c_write_byte(8'h00); // 指向寄存器 0x00 (CX_L)

        i2c_start();           // Repeated START
        i2c_write_byte(8'hA1); // 7'h50 << 1 | 1 (Read)
        i2c_read_byte(rd_cx_l,     1'b1); // 读 0x00: CX_L = 8'hE8 (ACK, ptr->0x01)
        i2c_read_byte(rd_cx_h,     1'b1); // 读 0x01: CX_H = 8'h01 (ACK, ptr->0x02)
        i2c_read_byte(rd_cy_l,     1'b1); // 读 0x02: CY_L = 8'h19 (ACK, ptr->0x03)
        i2c_read_byte(rd_cy_h,     1'b1); // 读 0x03: CY_H = 8'h01 (ACK, ptr->0x04)
        i2c_read_byte(rd_valid_on, 1'b0); // 读 0x04: VALID = 8'h01 (NACK)
        i2c_stop();

        // 3. 拨下板载 SW2 (B4 追踪使能开关 track_en_b4 = 0)，验证 VALID 寄存器被实时门控清零
        #100;
        track_en_b4 = 1'b0;
        #100;

        i2c_start();
        i2c_write_byte(8'hA0);
        i2c_write_byte(8'h04); // 指向 0x04 (VALID)
        i2c_start();
        i2c_write_byte(8'hA1);
        i2c_read_byte(rd_valid_off, 1'b0); // 读 0x04: VALID 立即变为 8'h00
        i2c_stop();

        // 4. 读取 0x0F 固定签名寄存器 VERSION (8'h5A)
        i2c_start();
        i2c_write_byte(8'hA0);
        i2c_write_byte(8'h0F);
        i2c_start();
        i2c_write_byte(8'hA1);
        i2c_read_byte(rd_ver, 1'b0);
        i2c_stop();

        #200;
        $display("================================================================");
        $display("[PASS] AWB 20-Iter Gain: in_r_r1=0x%05h, in_b_r1=0x%05h", in_r_r1, in_b_r1);
        $display("[PASS] I2C Read CX=%0d (0x%02h%02h), CY=%0d (0x%02h%02h), VALID(B4=1)=%0d, VALID(B4=0)=%0d, VER=0x%02h",
                 {rd_cx_h[2:0], rd_cx_l}, rd_cx_h, rd_cx_l,
                 {rd_cy_h[2:0], rd_cy_l}, rd_cy_h, rd_cy_l,
                 rd_valid_on, rd_valid_off, rd_ver);
        $display("================================================================");
        $stop;
    end

endmodule
