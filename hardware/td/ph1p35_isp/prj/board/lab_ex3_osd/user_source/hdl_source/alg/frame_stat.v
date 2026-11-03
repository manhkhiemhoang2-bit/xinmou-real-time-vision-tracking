//==============================================================================
// frame_stat.v —— 实测帧统计（分辨率自证 + 帧计数）
//
// 目的：屏幕上显示的 "1280x720" 必须是**数出来的**，而不是写死的常量。
//   本模块在视频流上实测三个量：
//     · 每行像素数 O_h_px     —— 一行内 tvalid 拍数 × PX_PER_BEAT
//     · 每帧行数   O_v_lines  —— 一帧内 tlast 个数
//     · 帧计数     O_frames   —— tuser 个数（连续递增即证明不丢帧）
//
// 口径：
//   · tuser 为**单拍脉冲**（本项目约定），出现即表示新一帧开始；
//     在该拍把上一帧统计出的 v_lines 锁存，并清零行计数。
//   · tlast 为行尾拍，在该拍把 h_px 锁存并清零拍计数。
//   · 只统计 tvalid 有效的拍（气泡不计入），保证与真实像素数一致。
//
// 为什么 ×PX_PER_BEAT：96bit 流每拍含 4 个像素（4×24bit），一行 1280 像素
//   = 320 拍 ⇒ 320×4 = 1280，与分辨率一致。
//==============================================================================
module frame_stat #(
    parameter integer PX_PER_BEAT = 4,
    parameter integer H_W = 11,
    parameter integer V_W = 11,
    parameter integer F_W = 32,
    parameter integer FPS_NOM = 30        // ★名义帧率：每 FPS_NOM 帧算 1 秒（随实际帧率配置改）
)(
    input  wire              I_clk,
    input  wire              I_rst_n,
    input  wire              I_tvalid,
    input  wire              I_tlast,
    input  wire              I_tuser,

    output reg  [H_W-1:0]    O_h_px,      // 实测每行像素数
    output reg  [V_W-1:0]    O_v_lines,   // 实测每帧行数
    output reg  [F_W-1:0]    O_frames,    // 已过帧数
    output reg  [15:0]       O_secs,      // 已运行秒数（每 FPS_NOM 帧 +1；30fps 下 30 帧=1 秒）
    output wire  [5:0]       O_sec_idx    // ★本秒内帧序号 0~FPS_NOM-1（屏上 F 字段，每秒归零）
);

    reg [7:0]     r_fps_div;    // 0..FPS_NOM-1 分频（凑够 FPS_NOM 帧 = 1 秒）
    reg [H_W-1:0] r_beat_cnt;   // 本行已收拍数
    reg [V_W-1:0] r_line_cnt;   // 本帧已收行数

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_beat_cnt <= {H_W{1'b0}};
            r_line_cnt <= {V_W{1'b0}};
            O_h_px     <= {H_W{1'b0}};
            O_v_lines  <= {V_W{1'b0}};
            O_frames   <= {F_W{1'b0}};
            O_secs     <= 16'd0;
            r_fps_div  <= 8'd0;
        end else begin
            // ---- 帧首：锁存上一帧行数、清零行计数、帧号加一 ----
            if (I_tuser) begin
                O_v_lines  <= r_line_cnt;
                r_line_cnt <= {V_W{1'b0}};
                O_frames   <= O_frames + {{(F_W-1){1'b0}}, 1'b1};
                // 每 60 帧 = 1 秒（60fps 名义值；实际帧率不同时 S 会相应偏快/偏慢，
                // 正好可以用秒表核对真实帧率）
                if (r_fps_div == (FPS_NOM - 1)) begin
                    r_fps_div <= 8'd0;
                    O_secs    <= O_secs + 16'd1;
                end else begin
                    r_fps_div <= r_fps_div + 8'd1;
                end
            end

            if (I_tvalid) begin
                r_beat_cnt <= r_beat_cnt + {{(H_W-1){1'b0}}, 1'b1};
                if (I_tlast) begin
                    // 行尾：本拍也含像素 ⇒ 拍数 +1 再乘每拍像素数
                    O_h_px     <= (r_beat_cnt + {{(H_W-1){1'b0}}, 1'b1}) << 2;   // ★×4 用移位，不用乘法器
                    r_beat_cnt <= {H_W{1'b0}};
                    r_line_cnt <= r_line_cnt + {{(V_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    assign O_sec_idx = r_fps_div;   // 本秒内已计帧数（0..FPS_NOM-1）

endmodule
