//==============================================================================
// frm_dly.v —— 采集到显示的"帧延迟"测量（题面"帧计数法"可视化）
//
// 目的：把"从采集端到显示端一共落后几帧"直接测出来并显示在屏幕上。
//
// 做法：输入侧与输出侧各数一个帧首脉冲：
//     IN  —— 采集侧的帧首计数（本工程接 w_norm_tuser，链路入口的规范化帧首）
//     OUT —— 显示侧的帧首计数（本工程接 osd_O_tuser，OSD 输出帧首）
//   两者的差值 = 已经采集但尚未显示完的帧数 = **帧延迟**
//
// 判读：
//   D0 ⇒ 零帧缓存，采集与显示同步推进（实时性最好的情形）
//   D1 ⇒ 有 1 帧缓存（经典的乒乓缓存双缓冲，延迟 1 帧）
//   D2+ ⇒ 缓存更深
//
// 说明：这里只统计"帧"级别；帧内的像素级延迟由 lat_measure 的 LAT 字段给出（单位：拍）。
//==============================================================================
module frm_dly #(
    parameter integer SAT_MAX = 15          // 延迟显示饱和值（4 位十进制个位够用）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_in_tuser,          // 采集侧帧首
    input  wire        I_out_tuser,         // 显示侧帧首

    output reg  [15:0] O_in_cnt,            // 采集侧帧计数
    output reg  [15:0] O_out_cnt,           // 显示侧帧计数
    output reg  [7:0]  O_dly                // 帧延迟（饱和到 SAT_MAX）
);

    reg [15:0] r_in_cnt;
    reg [15:0] r_out_cnt;

    // 差值 = 已采集 − 已显示（正常情况下不会为负；若因复位时序出现负值，钳到 0）
    wire [16:0] w_diff = {1'b0, r_in_cnt} - {1'b0, r_out_cnt};

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_in_cnt  <= 16'd0;
            r_out_cnt <= 16'd0;
        end else begin
            if (I_in_tuser)  r_in_cnt  <= r_in_cnt  + 16'd1;
            if (I_out_tuser) r_out_cnt <= r_out_cnt + 16'd1;
        end
    end

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_in_cnt  <= 16'd0;
            O_out_cnt <= 16'd0;
            O_dly     <= 8'd0;
        end else begin
            O_in_cnt  <= r_in_cnt;
            O_out_cnt <= r_out_cnt;
            if (w_diff[16])                              // 出现负数（复位/异常）⇒ 钳 0
                O_dly <= 8'd0;
            else if (w_diff > SAT_MAX)
                O_dly <= SAT_MAX[7:0];
            else
                O_dly <= w_diff[7:0];
        end
    end

endmodule
