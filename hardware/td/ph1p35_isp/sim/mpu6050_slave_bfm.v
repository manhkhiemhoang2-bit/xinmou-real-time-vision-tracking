//==============================================================================
// mpu6050_slave_bfm.v —— MPU6050 的 I2C 从机**行为模型**（Bus Functional Model）
//
// 干什么：
//   在仿真里冒充一颗 MPU6050，让 gim_imu_i2c 能在**不上板**的情况下被完整验证。
//   为什么必须自己写：真器件不可能接进仿真；没有它，I2C 时序、寄存器读写、
//   14 字节连读的字节序这三样一个都验不了。
//
// ⚠ 手写从机模型去验手写主机，最危险的失败是"两个一起错、还互相吻合"。
//   所以本模型的正确性**必须靠一个已知good的主机来反证** ——
//   见 sim\tb_i2c_bfm_chk.v：把工程里那个已经在硬件上跑通的厂商主机 uii2c
//   （摄像头配置就在用它）接到本模型上，先确认它能正确读回寄存器。
//   那条通过之后，本模型才有资格去验我们自己写的 gim_imu_i2c。
//
// 位计数约定（**这是本文件最容易写错的地方，写清楚**）：
//   `bitn` = "下一次 SCL 上升沿将要传递的那一位的序号"，0..8，8 之后回 0。
//     bitn = 0..6  -> 数据位 7..1
//     bitn = 7     -> 数据位 0（这一拍上升沿采完，一个字节就收完了）
//     bitn = 8     -> ACK 拍
//   按 I2C 规矩：**上升沿采样、下降沿改数据**。所以在下降沿上看 bitn，
//   它等于"下一次上升沿要传的位"。
//
// 支持的行为（够 MPU6050 用）：
//   · 7 位器件地址（参数给，MPU6050 = 0x68）+ R/W
//   · 随机读：START + 写(器件地址) + 写(寄存器地址) + **重复 START** + 读(器件地址)
//     + 连读 N 字节，最后一字节回 NACK（与真器件一致）
//   · 顺序写：START + 写(器件地址) + 写(寄存器地址) + 写数据...（寄存器地址自增）
//   · 256 字节寄存器文件；0x3B~0x48 那 14 个数据寄存器由端口实时注入
//   · WHO_AM_I(0x75) 返回 {地址,1'b0}（MPU6050 读整字节为 0xD0，bits[6:1]=0x68）
//   · **故障注入**：I_no_ack=1 时对任何地址都不回 ACK
//
// 组织方式：用 I_clk 对 SCL/SDA **过采样**（100kHz 的 SCL 在 50MHz 下是 500 拍）
//   再做边沿检测。这样不关心 SCL 具体频率，也不用对慢时钟不友好的 `posedge scl`。
//
// ⚠ 这是测试平台的一部分，不参与综合。
//==============================================================================
`timescale 1ns / 1ps

module mpu6050_slave_bfm #(
    parameter [6:0] DEV_ADDR = 7'h68
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    inout  wire        SCL,
    inout  wire        SDA,

    input  wire [15:0] I_ax, I_ay, I_az, I_temp,
    input  wire [15:0] I_gx, I_gy, I_gz,
    input  wire        I_no_ack,

    output reg  [15:0] O_wr_bytes,
    output reg  [15:0] O_rd_bytes,
    output reg  [7:0]  O_last_regaddr,
    output reg  [15:0] O_cfg_cnt,
    // ⚠ 不用数组端口：Verilog-2001 不允许数组做端口。
    //   改成"每写一个寄存器给一个 1 拍脉冲 + 地址 + 数据"，由 TB 负责记录。
    output reg         O_cfg_wr,
    output reg  [7:0]  O_cfg_addr,
    output reg  [7:0]  O_cfg_data,
    output reg  [7:0]  O_last_rd_reg,
    output reg  [7:0]  O_ack_err_cnt                // 地址不匹配 / 故障注入的次数
);

    //--------------------------------------------------------------------------
    // 1. 过采样 + 边沿检测
    //--------------------------------------------------------------------------
    reg scl_r1, scl_r2, sda_r1, sda_r2;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            scl_r1 <= 1'b1; scl_r2 <= 1'b1;
            sda_r1 <= 1'b1; sda_r2 <= 1'b1;
        end else begin
            scl_r1 <= SCL;  scl_r2 <= scl_r1;
            sda_r1 <= SDA;  sda_r2 <= sda_r1;
        end
    end

    wire scl_rise  =  scl_r1 & ~scl_r2;
    wire scl_fall  = ~scl_r1 &  scl_r2;
    wire sda_in    =  sda_r1;
    wire start_det = scl_r1 & ~sda_r1 &  sda_r2;   // SCL 高时 SDA 下降
    wire stop_det  = scl_r1 &  sda_r1 & ~sda_r2;   // SCL 高时 SDA 上升

    //--------------------------------------------------------------------------
    // 2. 寄存器文件与读接口
    //--------------------------------------------------------------------------
    reg [7:0] mem [0:255];
    integer k;

    // 数据区 0x3B..0x48：按注入值返回（不放进 mem，避免和注入值打架）
    function [7:0] rd_reg;
        input [7:0] a;
        reg [15:0] w;
        begin
            if (a == 8'h75) begin
                // WHO_AM_I：真器件读整字节是 **0x68**（所有现成驱动都这么判）。
                //   数据手册的定义是 bits[6:1] = 器件地址（0x34），bit7/bit0 为 0。
                //   ⇒ 被测主机**应该只判 bits[6:1]**，这样 0x68 和 0xD0 都能过；
                //     只判整字节 == 0x68 则依赖 bit7=0 这个手册没明说的细节。
                rd_reg = {1'b0, DEV_ADDR};
            end else if (a >= 8'h3B && a <= 8'h48) begin
                case (a)
                    8'h3B: w = I_ax;   8'h3C: w = I_ax;
                    8'h3D: w = I_ay;   8'h3E: w = I_ay;
                    8'h3F: w = I_az;   8'h40: w = I_az;
                    8'h41: w = I_temp; 8'h42: w = I_temp;
                    8'h43: w = I_gx;   8'h44: w = I_gx;
                    8'h45: w = I_gy;   8'h46: w = I_gy;
                    8'h47: w = I_gz;   8'h48: w = I_gz;
                    default: w = 16'd0;
                endcase
                // ⚠ 奇偶映射别写反：MPU6050 的 0x3B = ACCEL_XOUT_**H**、0x3C = _L。
                //   0x3B 是**奇数**地址 ⇒ 奇数给**高**字节、偶数给低字节。
                //   （第一版写成 `a[0] ? w[7:0] : w[15:8]`，读回来的是 0x22 而不是 0x11，
                //     靠"注入值每一字节都不一样"这条设计一眼看出来了。）
                rd_reg = a[0] ? w[15:8] : w[7:0];
            end else begin
                rd_reg = mem[a];
            end
        end
    endfunction

    //--------------------------------------------------------------------------
    // 3. SDA 驱动控制：只在"该从机驱动"的时段拉，其余放高阻（外部上拉）
    //--------------------------------------------------------------------------
    reg drive_en, drive_val;
    assign SDA = drive_en ? drive_val : 1'bz;

    //--------------------------------------------------------------------------
    // 4. 状态机
    //--------------------------------------------------------------------------
    localparam S_ADDR  = 3'd0;   // 收 器件地址+R/W
    localparam S_RX    = 3'd1;   // 收 一个字节（寄存器地址 或 写数据）
    localparam S_TX    = 3'd2;   // 发 一个字节
    localparam S_RXACK = 3'd3;   // 收 主机对刚发出字节的 ACK/NACK

    reg [2:0]  state;
    reg [3:0]  bitn;             // 0..8，见文件头
    reg [7:0]  shreg;            // 接收移位
    reg [7:0]  txbyte;           // 发送移位
    reg [7:0]  regaddr;
    reg        rw;
    reg        addr_ok;          // 本字节的地址是否匹配
    reg        first_byte;       // 一个传输里收到的第一个字节是器件地址

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state <= S_ADDR; bitn <= 4'd0; shreg <= 8'd0; txbyte <= 8'd0;
            regaddr <= 8'd0; rw <= 1'b0; addr_ok <= 1'b0; first_byte <= 1'b1;
            drive_en <= 1'b0; drive_val <= 1'b1;
            O_wr_bytes <= 16'd0; O_rd_bytes <= 16'd0;
            O_last_regaddr <= 8'd0; O_cfg_cnt <= 16'd0; O_last_rd_reg <= 8'd0;
            O_ack_err_cnt <= 8'd0;
            O_cfg_wr <= 1'b0; O_cfg_addr <= 8'd0; O_cfg_data <= 8'd0;
            for (k = 0; k < 256; k = k + 1) mem[k] <= 8'd0;
            mem[8'h6B] <= 8'h40;      // PWR_MGMT_1 复位后 0x40（SLEEP=1），真器件如此
        end else begin
            O_cfg_wr <= 1'b0;         // 默认清零；下面真要写寄存器时在同一拍置 1 => 1 拍脉冲
            //========== START：一次新传输开始 ==========
            if (start_det) begin
                state      <= S_ADDR;
                bitn       <= 4'd0;
                drive_en   <= 1'b0;
                first_byte <= 1'b1;
            end
            //========== STOP：结束 ==========
            else if (stop_det) begin
                state    <= S_ADDR;
                bitn     <= 4'd0;
                drive_en <= 1'b0;
            end
            //========== SCL 上升沿：采样 ==========
            else if (scl_rise) begin
                bitn <= (bitn == 4'd8) ? 4'd0 : (bitn + 4'd1);
                if (bitn <= 4'd7 && state != S_TX)
                    shreg <= {shreg[6:0], sda_in};       // 先把这一位移进来

                case (state)
                    // ---- 收器件地址 ----
                    S_ADDR: if (bitn == 4'd7) begin
                        rw       <= sda_in;              // 第 8 位（bitn=7）就是 R/W
                        addr_ok  <= ({shreg[6:0], sda_in} >> 1) == DEV_ADDR;
                    end
                    // ---- 收 寄存器地址 / 写数据 ----
                    S_RX: if (bitn == 4'd7) begin
                        if (first_byte) begin
                            regaddr        <= {shreg[6:0], sda_in};
                            O_last_regaddr <= {shreg[6:0], sda_in};
                            first_byte     <= 1'b0;
                        end else begin
                            // 顺序写：写进 mem，地址自增，并给一个"写了一次"的脉冲
                            mem[regaddr] <= {shreg[6:0], sda_in};
                            O_wr_bytes   <= O_wr_bytes + 16'd1;
                            O_cfg_wr     <= 1'b1;
                            O_cfg_addr   <= regaddr;
                            O_cfg_data   <= {shreg[6:0], sda_in};
                            O_cfg_cnt    <= O_cfg_cnt + 16'd1;
                            regaddr      <= regaddr + 8'd1;
                        end
                    end
                    // ---- 收 主机应答（读方向，第 9 拍）----
                    S_RXACK: if (bitn == 4'd8) begin
                        O_rd_bytes <= O_rd_bytes + 16'd1;
                        if (sda_in == 1'b0) begin              // 主机 ACK -> 还要读
                            regaddr <= regaddr + 8'd1;
                            txbyte  <= rd_reg(regaddr + 8'd1);
                            state   <= S_TX;
                        end else begin                          // 主机 NACK -> 读完
                            state <= S_ADDR;
                        end
                    end
                    default: ;
                endcase
            end
            //========== SCL 下降沿：改数据 / 定下一拍的源 ==========
            else if (scl_fall) begin
                // 下降沿上 bitn = "下一次上升沿要传的位序号"
                case (state)
                    // ---- 器件地址字节的 ACK 拍 ----
                    S_ADDR: if (bitn == 4'd8) begin
                        if (I_no_ack || !addr_ok) begin
                            drive_en     <= 1'b0;           // 不回 ACK
                            O_ack_err_cnt<= O_ack_err_cnt + 8'd1;
                            state        <= S_ADDR;         // 主机应当放弃
                        end else begin
                            drive_en <= 1'b1; drive_val <= 1'b0;   // ACK
                            if (rw) begin
                                txbyte        <= rd_reg(regaddr);
                                O_last_rd_reg <= regaddr;
                                state         <= S_TX;
                            end else begin
                                state <= S_RX;              // 接着收寄存器地址
                            end
                        end
                    end
                    // ---- 寄存器地址 / 写数据的 ACK 拍 ----
                    S_RX: if (bitn == 4'd8) begin
                        drive_en <= ~I_no_ack;
                        drive_val<= 1'b0;                   // ACK
                        state    <= S_RX;
                    end else begin
                        drive_en <= 1'b0;                   // 数据位期间放开，主机在驱动
                    end
                    // ---- 发送数据位：bitn=0..7 对应 bit7..bit0 ----
                    S_TX: if (bitn <= 4'd7) begin
                        drive_en  <= 1'b1;
                        drive_val <= txbyte[7];
                        txbyte    <= {txbyte[6:0], 1'b0};
                    end else begin
                        // bitn=8 -> 这一拍是 ACK，交给主机驱动。
                        // ⚠ 必须**同时切到 S_RXACK**，否则永远收不到主机的应答、
                        //   O_rd_bytes 一直是 0（第一版就漏了这一步，被 rd_bytes=0 抓到）。
                        drive_en  <= 1'b0;
                        state     <= S_RXACK;
                    end
                    // ---- 等主机应答期间必须一直放开 ----
                    S_RXACK: drive_en <= 1'b0;
                    default: drive_en <= 1'b0;
                endcase
            end
        end
    end

endmodule
