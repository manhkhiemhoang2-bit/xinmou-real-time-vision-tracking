//==============================================================================
// 文件名   : gray_bt601_96.v
// 模块名   : gray_bt601_96
// 日期     : 2026-09-13
// 描述     : 96-bit AXI4-Stream 算法通道 · M1 灰度档（BT.601 整数灰度）
//            一个 beat = 行内相邻 4 个像素（pix0 = I_tdata[95:72] 最左，
//            pix3 = I_tdata[23:0] 最右），每像素 24 bit = {R[23:16], G[15:8], B[7:0]}。
//            对 4 个像素并行做 Y = (77*R + 150*G + 29*B) >> 8，并把 Y 复制到
//            R/G/B 三个通道，输出仍是 96-bit RGB888（接口位宽不变，S0-02 C-7）。
//
//            延迟：C-1 点操作 = 1 拍（I_tdata 进 → O_tdata 出）。
//            端口名 / 位序 / 语义逐字遵守 S0-02_接口冻结_96bit算法通道.md v1.2
//            §1/§2/§3/§4，可直接原位替换 isp_top.v 里的 u_edge_detect_96。
//
// 修订记录 :
//   v1.0  2026-09-13  首版：BT.601 灰度，纯移位加法实现，零 DSP。
//==============================================================================

module gray_bt601_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        I_clk,
    input  wire        I_rst_n,      // 低有效异步复位（低有效信号加 _n 后缀）
    input  wire        I_tlast,      // 行末 beat（EOL），一帧 720 次
    input  wire        I_tuser,      // 帧首 beat（SOF），一帧 1 次
    input  wire [95:0] I_tdata,      // 4 像素 × RGB888
    input  wire        I_tvalid,
    input  wire        I_tready,     // 直通，不用于反压（S0-02 C-3）
    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid,
    output wire        O_tready
);

//------------------------------------------------------------------------------
// 0. tready 纯直通（S0-02 §1 / C-3）
//    整条 ISP 链路是自由流：上游不认识反压，模块内部不得出现停顿状态机。
//------------------------------------------------------------------------------
assign O_tready = I_tready;

//------------------------------------------------------------------------------
// 1. 通道拆分
//    pix0 在最高位段 = 行内最左像素（S0-02 §2.2，极易搞错，务必按此顺序）
//------------------------------------------------------------------------------
wire [7:0] pix0_r = I_tdata[95:88];
wire [7:0] pix0_g = I_tdata[87:80];
wire [7:0] pix0_b = I_tdata[79:72];

wire [7:0] pix1_r = I_tdata[71:64];
wire [7:0] pix1_g = I_tdata[63:56];
wire [7:0] pix1_b = I_tdata[55:48];

wire [7:0] pix2_r = I_tdata[47:40];
wire [7:0] pix2_g = I_tdata[39:32];
wire [7:0] pix2_b = I_tdata[31:24];

wire [7:0] pix3_r = I_tdata[23:16];
wire [7:0] pix3_g = I_tdata[15:8];
wire [7:0] pix3_b = I_tdata[7:0];

//------------------------------------------------------------------------------
// 2. Y = (77*R + 150*G + 29*B) >> 8
//
// 为什么用"移位加法"而不是乘法（硬性要求，也是答辩证据）：
//   系数和 77 + 150 + 29 = 256 = 2^8，最大 255 * 256 = 65280 < 2^16 → 无溢出；
//   右移 8 位即"加权平均"，不需要除法器、不需要 DSP。
//   三个系数都能被 2 的幂唯一分解，于是乘法退化成"移位（纯连线）+ 加法"：
//       77  = 64 + 8 + 4 + 1     → 4 项，3 个加法器
//       150 = 128 + 16 + 4 + 2   → 4 项，3 个加法器
//       29  = 16 + 8 + 4 + 1     → 4 项，3 个加法器
//       三项求和                 → 2 个加法器
//   合计 11 个 16-bit 加法器 / 像素，共 44 个；移位是常数移位 → 零资源。
//
// 位宽：所有移位都在 16-bit 上做（{8'd0, ch} 显式扩到 16 位），
//       单项最大 255 << 7 = 32640，总和最大 65280，均 < 2^16 → 不会截位。
//------------------------------------------------------------------------------
wire [15:0] pix0_r16 = { 8'd0, pix0_r };
wire [15:0] pix0_g16 = { 8'd0, pix0_g };
wire [15:0] pix0_b16 = { 8'd0, pix0_b };
wire [15:0] pix1_r16 = { 8'd0, pix1_r };
wire [15:0] pix1_g16 = { 8'd0, pix1_g };
wire [15:0] pix1_b16 = { 8'd0, pix1_b };
wire [15:0] pix2_r16 = { 8'd0, pix2_r };
wire [15:0] pix2_g16 = { 8'd0, pix2_g };
wire [15:0] pix2_b16 = { 8'd0, pix2_b };
wire [15:0] pix3_r16 = { 8'd0, pix3_r };
wire [15:0] pix3_g16 = { 8'd0, pix3_g };
wire [15:0] pix3_b16 = { 8'd0, pix3_b };

// 77 * R = (R << 6) + (R << 3) + (R << 2) + R
wire [15:0] pix0_wr = (pix0_r16 << 6) + (pix0_r16 << 3) + (pix0_r16 << 2) + pix0_r16;
wire [15:0] pix1_wr = (pix1_r16 << 6) + (pix1_r16 << 3) + (pix1_r16 << 2) + pix1_r16;
wire [15:0] pix2_wr = (pix2_r16 << 6) + (pix2_r16 << 3) + (pix2_r16 << 2) + pix2_r16;
wire [15:0] pix3_wr = (pix3_r16 << 6) + (pix3_r16 << 3) + (pix3_r16 << 2) + pix3_r16;

// 150 * G = (G << 7) + (G << 4) + (G << 2) + (G << 1)
wire [15:0] pix0_wg = (pix0_g16 << 7) + (pix0_g16 << 4) + (pix0_g16 << 2) + (pix0_g16 << 1);
wire [15:0] pix1_wg = (pix1_g16 << 7) + (pix1_g16 << 4) + (pix1_g16 << 2) + (pix1_g16 << 1);
wire [15:0] pix2_wg = (pix2_g16 << 7) + (pix2_g16 << 4) + (pix2_g16 << 2) + (pix2_g16 << 1);
wire [15:0] pix3_wg = (pix3_g16 << 7) + (pix3_g16 << 4) + (pix3_g16 << 2) + (pix3_g16 << 1);

// 29 * B = (B << 4) + (B << 3) + (B << 2) + B
wire [15:0] pix0_wb = (pix0_b16 << 4) + (pix0_b16 << 3) + (pix0_b16 << 2) + pix0_b16;
wire [15:0] pix1_wb = (pix1_b16 << 4) + (pix1_b16 << 3) + (pix1_b16 << 2) + pix1_b16;
wire [15:0] pix2_wb = (pix2_b16 << 4) + (pix2_b16 << 3) + (pix2_b16 << 2) + pix2_b16;
wire [15:0] pix3_wb = (pix3_b16 << 4) + (pix3_b16 << 3) + (pix3_b16 << 2) + pix3_b16;

wire [15:0] pix0_ysum = pix0_wr + pix0_wg + pix0_wb;
wire [15:0] pix1_ysum = pix1_wr + pix1_wg + pix1_wb;
wire [15:0] pix2_ysum = pix2_wr + pix2_wg + pix2_wb;
wire [15:0] pix3_ysum = pix3_wr + pix3_wg + pix3_wb;

// >> 8（系数和为 256，故右移 8 位即归一化，结果天然落在 0~255）
wire [7:0] pix0_y = pix0_ysum[15:8];
wire [7:0] pix1_y = pix1_ysum[15:8];
wire [7:0] pix2_y = pix2_ysum[15:8];
wire [7:0] pix3_y = pix3_ysum[15:8];

wire [95:0] gray_data = { pix0_y, pix0_y, pix0_y,
                          pix1_y, pix1_y, pix1_y,
                          pix2_y, pix2_y, pix2_y,
                          pix3_y, pix3_y, pix3_y };

//------------------------------------------------------------------------------
// 3. 输出寄存器（C-1：点操作 1 拍）
//    O_tdata 直接寄存组合灰度结果 → I_tdata 进到 O_tdata 出恰好 1 拍。
//    C-4：I_tvalid = 0 时 O_tdata 必须给 96'd0、O_tvalid = 0，
//         照抄例程写法，避免 X 传播到下游帧缓存。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tdata <= 96'd0;
    end else if (!I_tvalid) begin
        O_tdata <= 96'd0;
    end else begin
        O_tdata <= gray_data;
    end
end

//------------------------------------------------------------------------------
// 4. 控制信号透传（C-5：与本模块延迟拍数 N = 1 同拍对齐）
//    tuser = 帧首单拍、tlast = 行末单拍（一帧 720 次，不是帧末！S0-02 §3）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= I_tlast;
        O_tuser <= I_tuser;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tvalid <= 1'b0;
    end else begin
        O_tvalid <= I_tvalid;
    end
end

//------------------------------------------------------------------------------
// 5. 上电初值（综合到 FPGA 的 FF 初值，与复位目标值逐一相同）
//    本模块没有行缓存，无需 C-6 例外，全部寄存器都显式初始化。
//------------------------------------------------------------------------------
initial begin
    O_tdata  = 96'd0;
    O_tlast  = 1'b0;
    O_tuser  = 1'b0;
    O_tvalid = 1'b0;
end

endmodule
