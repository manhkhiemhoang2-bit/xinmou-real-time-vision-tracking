//==============================================================================
// gim_i2c_slave.v —— FPGA 坐标 I2C 从机（7-bit 地址 0x50）
//
// 寄存器映射（只读，地址自增；0x10~0x17 可写 ROI）：
//   0x00  CX_L     目标中心 x 低 8 位
//   0x01  CX_H     x[10:8]（低 3 位有效）
//   0x02  CY_L     目标中心 y 低 8 位
//   0x03  CY_H     y[10:8]
//   0x04  VALID    bit0 = 本帧是否检出目标且允许追踪（受 B4 开关 I_track_en 门控）
//   0x05  FRAME_L  帧计数低 8 位（每帧 +1，MCU 双读防撕裂用）
//   0x06  FRAME_H  帧计数高 8 位
//   0x07  MODE     当前 ISP 档位 [3:0]（M0~M8）
//   0x08  W_L      目标框宽低 8 位
//   0x09  W_H      目标框宽[10:8]
//   0x0A  H_L      目标框高低 8 位
//   0x0B  H_H      目标框高[10:8]
//   0x0C  PIX_CNT  命中像素数（饱和到 255）
//   0x0D  CLS      颜色类别（0=红, 1=绿, 2=蓝）
//   0x0E  STATUS   bit7=1(有效签名), bit2=SW2(B4)追踪使能, bit1=AUTO子档, bit0=ROI使能
//   0x0F  VERSION  固定 0x5A（握手/自检用）
//==============================================================================
`timescale 1ns / 1ps

module gim_i2c_slave #(
    parameter [6:0] SLAVE_ADDR = 7'h50
)(
    // ---- 50MHz 域（I2C 状态机）----
    input  wire        I_clk,
    input  wire        I_rst_n,

    // ---- I2C 总线观测 / 开漏控制 ----
    input  wire        I_scl,
    input  wire        I_sda_in,
    output reg         O_sda_pull,

    // ---- 像素域输入（接 isp_top / alg_top 的检测结果）----
    input  wire        I_pix_clk,
    input  wire        I_pix_rst_n,
    input  wire        I_pix_frame,
    input  wire [10:0] I_bbox_x0,
    input  wire [10:0] I_bbox_x1,
    input  wire [10:0] I_bbox_y0,
    input  wire [10:0] I_bbox_y1,
    input  wire        I_bbox_valid,
    input  wire        I_auto_mode,
    input  wire        I_track_en,        // ★SW2(B4)：1=开启追踪，0=关闭追踪
    input  wire [3:0]  I_mode,

    // ---- 质量信息 ----
    input  wire [10:0] I_bbox_w,
    input  wire [10:0] I_bbox_h,
    input  wire [15:0] I_pix_cnt,
    input  wire [1:0]  I_color_cls,

    // ---- MCU 写入的 ROI 窗口 ----
    output reg  [10:0] O_roi_x0,
    output reg  [10:0] O_roi_x1,
    output reg  [10:0] O_roi_y0,
    output reg  [10:0] O_roi_y1,
    output reg         O_roi_en
);

    //==========================================================================
    // 1. 像素域：帧脉冲拍锁存 (cx, cy, valid, mode) 并翻转 toggle
    //==========================================================================
    wire [11:0] w_cx = ({1'b0, I_bbox_x0} + {1'b0, I_bbox_x1}) >> 1;
    wire [11:0] w_cy = ({1'b0, I_bbox_y0} + {1'b0, I_bbox_y1}) >> 1;

    reg [11:0] r_cx, r_cy;
    reg        r_vld;
    reg [3:0]  r_mode;
    reg        r_tgl;

    always @ (posedge I_pix_clk or negedge I_pix_rst_n) begin
        if (!I_pix_rst_n) begin
            r_cx   <= 12'd0;
            r_cy   <= 12'd0;
            r_vld  <= 1'b0;
            r_mode <= 4'd0;
            r_tgl  <= 1'b0;
        end else if (I_pix_frame) begin
            r_cx   <= w_cx;
            r_cy   <= w_cy;
            r_vld  <= I_bbox_valid;
            r_mode <= I_mode;
            r_tgl  <= ~r_tgl;
        end
    end

    //==========================================================================
    // 2. 50MHz 域：三级同步旗子 + 拨码开关 B4(I_track_en) / A4(I_auto_mode) 实时同步
    //==========================================================================
    reg r_s1, r_s2, r_s3;
    reg [1:0] r_trk_sync;
    reg [1:0] r_auto_sync;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_s1        <= 1'b0;
            r_s2        <= 1'b0;
            r_s3        <= 1'b0;
            r_trk_sync  <= 2'b11;
            r_auto_sync <= 2'b00;
        end else begin
            r_s1        <= r_tgl;
            r_s2        <= r_s1;
            r_s3        <= r_s2;
            r_trk_sync  <= {r_trk_sync[0],  I_track_en};
            r_auto_sync <= {r_auto_sync[0], I_auto_mode};
        end
    end

    wire w_upd = r_s2 ^ r_s3;

    //==========================================================================
    // 3. 影子寄存器：w_upd 拍拷贝帧数据，拨码开关 r_trk_s / r_auto_s 每拍实时更新
    //==========================================================================
    reg [11:0] r_cx_s, r_cy_s;
    reg        r_vld_s;
    reg [3:0]  r_mode_s;
    reg [15:0] r_frame;
    reg [10:0] r_w_s, r_h_s;
    reg [15:0] r_cnt_s;
    reg [1:0]  r_cls_s;
    reg        r_auto_s;
    reg        r_trk_s;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_cx_s   <= 12'd0;
            r_cy_s   <= 12'd0;
            r_vld_s  <= 1'b0;
            r_mode_s <= 4'd0;
            r_frame  <= 16'd0;
            r_w_s    <= 11'd0;
            r_h_s    <= 11'd0;
            r_cnt_s  <= 16'd0;
            r_cls_s  <= 2'd0;
            r_auto_s <= 1'b0;
            r_trk_s  <= 1'b1;
        end else begin
            // 实时反映 B4(I_track_en) 与 A4(I_auto_mode) 开关状态，无需等待帧脉冲
            r_trk_s  <= r_trk_sync[1];
            r_auto_s <= r_auto_sync[1];
            if (w_upd) begin
                r_cx_s   <= r_cx;
                r_cy_s   <= r_cy;
                r_vld_s  <= r_vld;
                r_mode_s <= r_mode;
                r_frame  <= r_frame + 16'd1;
                r_w_s    <= I_bbox_w;
                r_h_s    <= I_bbox_h;
                r_cnt_s  <= I_pix_cnt;
                r_cls_s  <= I_color_cls;
            end
        end
    end

    //==========================================================================
    // 4. 寄存器指针与读回 mux
    //    ★关键修复：0x04(VALID) 同时受 r_trk_s(B4) 门控，且 0x0E bit2 实时返回 r_trk_s。
    //      这样无论 MCU 固件检查 0x04 还是 0x0E，B4 拨下(0) 都能立刻停止舵机追踪！
    //==========================================================================
    reg [7:0]  r_ptr;
    reg        r_wr_data;
    reg [10:0] r_roi_x0, r_roi_x1, r_roi_y0, r_roi_y1;
    reg        r_roi_en;

    reg [7:0] r_rdata;

    always @ (*) begin
        case (r_ptr)
            8'h00:   r_rdata = r_cx_s[7:0];
            8'h01:   r_rdata = {5'd0, r_cx_s[10:8]};
            8'h02:   r_rdata = r_cy_s[7:0];
            8'h03:   r_rdata = {5'd0, r_cy_s[10:8]};
            8'h04:   r_rdata = {7'd0, r_vld_s & r_trk_s & ~r_auto_s}; // VALID（B4=0 或 AUTO 时禁追）
            8'h05:   r_rdata = r_frame[7:0];
            8'h06:   r_rdata = r_frame[15:8];
            8'h07:   r_rdata = {4'd0, r_mode_s};
            8'h08:   r_rdata = r_w_s[7:0];
            8'h09:   r_rdata = {5'd0, r_w_s[10:8]};
            8'h0A:   r_rdata = r_h_s[7:0];
            8'h0B:   r_rdata = {5'd0, r_h_s[10:8]};
            8'h0C:   r_rdata = (r_cnt_s > 16'd255) ? 8'hFF : r_cnt_s[7:0];
            8'h0D:   r_rdata = {6'd0, r_cls_s};
            8'h0E:   r_rdata = {1'b1, 4'd0, r_trk_s, r_auto_s, O_roi_en}; // bit7=1, bit2=B4使能, bit1=AUTO, bit0=ROI
            8'h0F:   r_rdata = 8'h5A;
            default: r_rdata = 8'h00;
        endcase
    end

    //==========================================================================
    // 5. SCL / SDA 的 2 级同步采样 + 边沿检测
    //==========================================================================
    reg r_scl_s1, r_scl_s2, r_scl_d;
    reg r_sda_s1, r_sda_s2, r_sda_d;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_scl_s1 <= 1'b0;
            r_scl_s2 <= 1'b0;
            r_scl_d  <= 1'b0;
            r_sda_s1 <= 1'b0;
            r_sda_s2 <= 1'b0;
            r_sda_d  <= 1'b0;
        end else begin
            r_scl_s1 <= I_scl;
            r_scl_s2 <= r_scl_s1;
            r_scl_d  <= r_scl_s2;
            r_sda_s1 <= I_sda_in;
            r_sda_s2 <= r_sda_s1;
            r_sda_d  <= r_sda_s2;
        end
    end

    wire w_scl_rise =  r_scl_s2 & ~r_scl_d;
    wire w_scl_fall = ~r_scl_s2 &  r_scl_d;
    wire w_sda_rise =  r_sda_s2 & ~r_sda_d;
    wire w_sda_fall = ~r_sda_s2 &  r_sda_d;

    wire w_start = w_sda_fall & r_scl_s2 & r_scl_d;
    wire w_stop  = w_sda_rise & r_scl_s2 & r_scl_d;

    //==========================================================================
    // 6. 总线卡死保护：50ms 超时释放 SDA
    //==========================================================================
    localparam [21:0] BUS_TO_LIMIT = 22'd2500000;

    reg [21:0] r_to_cnt;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_to_cnt <= 22'd0;
        else if (w_scl_rise | w_scl_fall | w_start | w_stop)
            r_to_cnt <= 22'd0;
        else if (r_to_cnt < BUS_TO_LIMIT)
            r_to_cnt <= r_to_cnt + 22'd1;
    end

    wire w_bus_to = (r_to_cnt >= BUS_TO_LIMIT);

    //==========================================================================
    // 7. I2C 从机状态机
    //==========================================================================
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_ADDR  = 3'd1;
    localparam [2:0] ST_AACK  = 3'd2;
    localparam [2:0] ST_WDATA = 3'd3;
    localparam [2:0] ST_WACK  = 3'd4;
    localparam [2:0] ST_RDATA = 3'd5;
    localparam [2:0] ST_RACK  = 3'd6;

    reg [2:0] r_state;
    reg [3:0] r_bit;
    reg [7:0] r_sh;
    reg       r_rw;
    reg       r_mack;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_state    <= ST_IDLE;
            r_roi_x0   <= 11'd0; r_roi_x1 <= 11'h7FF;
            r_roi_y0   <= 11'd0; r_roi_y1 <= 11'h7FF;
            r_roi_en   <= 1'b0;
            r_wr_data  <= 1'b0;
            r_bit      <= 4'd0;
            r_sh       <= 8'd0;
            r_ptr      <= 8'd0;
            r_rw       <= 1'b0;
            r_mack     <= 1'b0;
            O_sda_pull <= 1'b0;
        end else if (w_start) begin
            r_wr_data  <= 1'b0;
            r_state    <= ST_ADDR;
            r_bit      <= 4'd0;
            O_sda_pull <= 1'b0;
        end else if (w_stop) begin
            r_state    <= ST_IDLE;
            O_sda_pull <= 1'b0;
        end else if (w_bus_to) begin
            r_state    <= ST_IDLE;
            O_sda_pull <= 1'b0;
        end else begin
            case (r_state)

                ST_ADDR: begin
                    if (w_scl_rise) begin
                        r_sh  <= {r_sh[6:0], r_sda_s2};
                        r_bit <= r_bit + 4'd1;
                    end
                    if (w_scl_fall && (r_bit == 4'd8)) begin
                        r_bit <= 4'd0;
                        if (r_sh[7:1] == SLAVE_ADDR) begin
                            r_rw       <= r_sh[0];
                            O_sda_pull <= 1'b1;
                            r_state    <= ST_AACK;
                        end else begin
                            r_state    <= ST_IDLE;
                        end
                    end
                end

                ST_AACK: begin
                    if (w_scl_fall) begin
                        r_bit <= 4'd0;
                        if (r_rw) begin
                            O_sda_pull <= ~r_rdata[7];
                            r_sh       <= r_rdata;
                            r_state    <= ST_RDATA;
                        end else begin
                            O_sda_pull <= 1'b0;
                            r_state    <= ST_WDATA;
                        end
                    end
                end

                ST_WDATA: begin
                    if (w_scl_rise) begin
                        r_sh  <= {r_sh[6:0], r_sda_s2};
                        r_bit <= r_bit + 4'd1;
                    end
                    if (w_scl_fall && (r_bit == 4'd8)) begin
                        r_bit <= 4'd0;
                        if (!r_wr_data) begin
                            r_ptr     <= r_sh;
                            r_wr_data <= 1'b1;
                        end else begin
                            case (r_ptr)
                                8'h10: r_roi_x0[7:0]  <= r_sh;
                                8'h11: r_roi_x0[10:8] <= r_sh[2:0];
                                8'h12: r_roi_x1[7:0]  <= r_sh;
                                8'h13: r_roi_x1[10:8] <= r_sh[2:0];
                                8'h14: r_roi_y0[7:0]  <= r_sh;
                                8'h15: r_roi_y0[10:8] <= r_sh[2:0];
                                8'h16: r_roi_y1[7:0]  <= r_sh;
                                8'h17: r_roi_y1[10:8] <= r_sh[2:0];
                                default: ;
                            endcase
                            if (r_ptr >= 8'h10 && r_ptr <= 8'h17)
                                r_roi_en <= 1'b1;
                            r_ptr <= r_ptr + 8'd1;
                        end
                        O_sda_pull <= 1'b1;
                        r_state    <= ST_WACK;
                    end
                end

                ST_WACK: begin
                    if (w_scl_fall) begin
                        O_sda_pull <= 1'b0;
                        r_state    <= ST_WDATA;
                    end
                end

                ST_RDATA: begin
                    if (w_scl_rise)
                        r_bit <= r_bit + 4'd1;
                    if (w_scl_fall) begin
                        if (r_bit == 4'd8) begin
                            r_bit      <= 4'd0;
                            O_sda_pull <= 1'b0;
                            r_state    <= ST_RACK;
                        end else begin
                            O_sda_pull <= ~r_sh[6];
                            r_sh       <= {r_sh[6:0], 1'b0};
                        end
                    end
                end

                ST_RACK: begin
                    if (w_scl_rise) begin
                        r_mack <= ~r_sda_s2;
                        if (~r_sda_s2)
                            r_ptr <= r_ptr + 8'd1;
                    end
                    if (w_scl_fall) begin
                        r_bit <= 4'd0;
                        if (r_mack) begin
                            O_sda_pull <= ~r_rdata[7];
                            r_sh       <= r_rdata;
                            r_state    <= ST_RDATA;
                        end else begin
                            O_sda_pull <= 1'b0;
                            r_state    <= ST_IDLE;
                        end
                    end
                end

                default: begin
                    r_state    <= ST_IDLE;
                    O_sda_pull <= 1'b0;
                end

            endcase
        end
    end

    always @ (*) begin
        O_roi_x0 = r_roi_x0;
        O_roi_x1 = r_roi_x1;
        O_roi_y0 = r_roi_y0;
        O_roi_y1 = r_roi_y1;
        O_roi_en = r_roi_en;
    end

endmodule
