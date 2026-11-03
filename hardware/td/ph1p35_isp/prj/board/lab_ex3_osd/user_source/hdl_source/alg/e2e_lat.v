//==============================================================================
// e2e_lat.v —— 采集到显示的总延迟（毫秒），显示在 OSD 上
//
// 需求依据：题面要求"将采集到显示的延迟进行可视化（如帧计数），以体现系统实时性"。
//
// 口径（重要，写清楚避免误解）：
//   ① 起点：采集侧帧首 I_cap_tuser（本工程接 MIPI 接收输出的帧首 m_aixs_tuser）
//   ② 终点：显示侧帧首 I_disp_tgl 的翻转沿（本工程接 HDMI 侧帧首/场同步，
//            经两级触发器同步到本模块时钟域后再取边沿）
//   ③ 测得的差 Δ = 「显示帧首出现的时刻 − 最近一次采集帧首的时刻」，范围 0~一帧周期
//   ④ 再叠加 BIAS_MS：帧在 DDR 帧缓存里停留的那一帧时间（默认 33ms ≈ 30fps 一帧）
//
//   ⇒ 屏显值 = Δ平滑值 + BIAS_MS，代表"从采集到显示的一整段时间"，
//      并用 2^AVG_SH 次滑动平均抑制抖动（默认 128 次 ≈ 2 秒，可覆盖完整的相位滑动周期），
//      按 1ms 分辨率显示。
//
// 为什么需要 BIAS_MS：显示端是从 DDR 帧缓存读数据扫描的，正在扫描的这帧是
//   之前某次采集写入的。片上无法直接比对"哪一帧"，因此用一个可配置的帧缓存
//   偏置常量表示这段停留时间；该常量应通过外部秒表对比法一次标定
//   （屏显值与秒表实测一致即可）。
//
// 时钟：本模块运行在图像主时钟域（与 OSD 相同）；显示侧信号来自 HDMI 像素时钟域，
//   只传一个单比特翻转信号（慢速、每帧翻转一次），经两级同步即可，无数据通路风险。
//==============================================================================
module e2e_lat #(
    parameter integer CLK_HZ   = 39660000,   // 本模块时钟频率（与 lat_measure 同一标定值）
    parameter integer BIAS_MS  = 33,         // 帧缓存偏置（毫秒）
    parameter integer AVG_SH   = 2           // 滑动平均：2^AVG_SH 次
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_cap_tuser,          // 采集侧帧首（本时钟域）
    input  wire        I_disp_tgl,           // 显示侧帧首翻转信号（异步，单比特）

    output reg  [9:0]  O_lat_ms,             // 屏显：总延迟（毫秒，饱和到 999）
    output reg  [15:0] O_raw_ms              // 调试：最近一次原始测量值（未加偏置）
);

    // ---------------- 1) 显示侧翻转沿同步 ----------------
    reg [2:0] r_tgl_sync;
    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) r_tgl_sync <= 3'd0;
        else          r_tgl_sync <= {r_tgl_sync[1:0], I_disp_tgl};
    end
    wire w_disp_pulse = r_tgl_sync[2] ^ r_tgl_sync[1];   // 任一沿都算一次显示帧首

    // ---------------- 2) 毫秒时基 ----------------
    localparam integer TICK = (CLK_HZ / 1000 > 0) ? (CLK_HZ / 1000) : 1;
    reg [31:0] r_tick;
    reg [15:0] r_ms_now;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_tick   <= 32'd0;
            r_ms_now <= 16'd0;
        end else if (r_tick >= TICK - 1) begin
            r_tick   <= 32'd0;
            r_ms_now <= r_ms_now + 16'd1;
        end else begin
            r_tick   <= r_tick + 32'd1;
        end
    end

    // ---------------- 3) 采集帧首时刻锁存 ----------------
    reg [15:0] r_cap_ms;
    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)          r_cap_ms <= 16'd0;
        else if (I_cap_tuser)  r_cap_ms <= r_ms_now;      // 锁存"最近一次采集帧首"的毫秒值
    end

    // ---------------- 4) 显示帧首时求差 + 滑动平均 + 偏置 ----------------
    wire [15:0] w_delta = r_ms_now - r_cap_ms;            // 0 ~ 一帧周期
    reg  [21:0] r_acc;      // 最多 256 次 × 999ms = 255744，22 位够
    reg  [9:0]  r_cnt;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_acc    <= 22'd0;
            r_cnt    <= 10'd0;
            O_lat_ms <= 10'd0;
            O_raw_ms <= 16'd0;
        end else if (w_disp_pulse) begin
            if (r_cnt >= ((1 << AVG_SH) - 1)) begin
                // 4 次平均后加偏置（本次值一并计入）
                O_raw_ms <= w_delta;
                O_lat_ms <= (((r_acc + w_delta) >> AVG_SH) + BIAS_MS > 999)
                            ? 10'd999
                            : (((r_acc + w_delta) >> AVG_SH) + BIAS_MS);
                r_acc    <= 22'd0;
                r_cnt    <= 10'd0;
            end else begin
                r_acc <= r_acc + w_delta;
                r_cnt <= r_cnt + 10'd1;
            end
        end
    end

endmodule
