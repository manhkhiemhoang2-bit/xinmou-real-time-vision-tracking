//==============================================================================
// 文件名   : awb_div20_core.v
// 来源模块 : isp/awb/awb.v (第 91~163 行核心 20 轮恢复余数迭代除法器)
// 说明     : 剥离安路片上 BRAM IP 封装，保留 100% 原始 RTL 寄存器与组合逻辑，便于在
//            ModelSim 中直接独立编译仿真，核验 20 轮恢复余数迭代计算 Q4.16 白平衡增益。
//==============================================================================
`timescale 1ns / 1ps

module awb_div20_core (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tuser,       // 帧首复位脉冲
    input  wire        I_tvalid_r1,   // 触发迭代启动使能
    input  wire [31:0] sum_r0,        // 当前统计红通道累加和
    input  wire [31:0] sum_g0,        // 当前统计绿通道累加和
    input  wire [31:0] sum_b0,        // 当前统计蓝通道累加和
    output reg  [4:0]  div_cnt,       // 迭代轮数计数器 (0:空闲/装载, 1..20:迭代)
    output reg  [19:0] quo_r,         // R 通道迭代商寄存器
    output reg  [19:0] quo_b,         // B 通道迭代商寄存器
    output reg         div_done,      // 20 轮迭代完成脉冲
    output reg  [19:0] in_r_r1,       // 锁存生效的 R 通道 Q4.16 增益 (0x10000 = 1.0x)
    output reg  [19:0] in_b_r1        // 锁存生效的 B 通道 Q4.16 增益 (0x10000 = 1.0x)
);

    reg  [19:0] shf_g;
    reg  [32:0] rem_r, rem_b;
    reg  [31:0] den_r_l, den_b_l;
    reg         ovf_r, ovf_b;

    wire [32:0] rem_r_sh = {rem_r[31:0], shf_g[19]};
    wire [32:0] rem_b_sh = {rem_b[31:0], shf_g[19]};
    wire        ge_r     = (rem_r_sh >= {1'b0, den_r_l});
    wire        ge_b     = (rem_b_sh >= {1'b0, den_b_l});

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            div_cnt  <= 5'd0;
            shf_g    <= 20'd0;
            rem_r    <= 33'd0;
            rem_b    <= 33'd0;
            den_r_l  <= 32'd1;
            den_b_l  <= 32'd1;
            quo_r    <= 20'h10000;
            quo_b    <= 20'h10000;
            ovf_r    <= 1'b0;
            ovf_b    <= 1'b0;
            div_done <= 1'b0;
        end else begin
            div_done <= 1'b0;
            if (div_cnt == 5'd0) begin
                if (I_tvalid_r1) begin
                    rem_r   <= {5'd0, sum_g0[31:4]};
                    rem_b   <= {5'd0, sum_g0[31:4]};
                    shf_g   <= {sum_g0[3:0], 16'd0};
                    den_r_l <= sum_r0;
                    den_b_l <= sum_b0;
                    ovf_r   <= (sum_r0 == 32'd0) || ({4'd0, sum_g0} >= {sum_r0, 4'd0});
                    ovf_b   <= (sum_b0 == 32'd0) || ({4'd0, sum_g0} >= {sum_b0, 4'd0});
                    quo_r   <= 20'd0;
                    quo_b   <= 20'd0;
                    div_cnt <= 5'd1;
                end
            end else begin
                rem_r <= ge_r ? (rem_r_sh - {1'b0, den_r_l}) : rem_r_sh;
                rem_b <= ge_b ? (rem_b_sh - {1'b0, den_b_l}) : rem_b_sh;
                quo_r <= {quo_r[18:0], ge_r};
                quo_b <= {quo_b[18:0], ge_b};
                shf_g <= {shf_g[18:0], 1'b0};
                if (div_cnt == 5'd20) begin
                    div_cnt  <= 5'd0;
                    div_done <= 1'b1;
                end else begin
                    div_cnt  <= div_cnt + 5'd1;
                end
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            in_r_r1 <= 20'h10000;
            in_b_r1 <= 20'h10000;
        end else if (div_done) begin
            in_r_r1 <= ovf_r ? 20'hfffff : quo_r;
            in_b_r1 <= ovf_b ? 20'hfffff : quo_b;
        end
    end

endmodule
