//==============================================================================
// 文件名   : alg_span_fill_96.v
// 模块名   : alg_span_fill_96
// 日期     : 2026-10-05（十六修）
// 描述     : 96-bit 算法通道 · M7 行内**跨度填充**（取代奇偶扫描填充）
//
//  【为什么要换】
//    旧 alg_region_fill_96 是"奇偶扫描"：行内每遇到一个白（轮廓）就翻转 inside。
//    真实画面一行里横穿好几根碎轮廓 ⇒ 填一段空一段 ⇒ 用户板上实测"画面很乱"；
//    噪声让交叉点数逐帧变 ⇒ "抖动"。帧间滤波只能压噪声，治不了这个结构问题。
//    本模块改为：**每行只取最左与最右的轮廓点，中间整段填实**。
//    一行只有一个实心块 ⇒ 结构上不可能出条纹；端点是最外侧轮廓 ⇒ 比内部碎交叉稳得多。
//    典型效果：人的轮廓 → 一整块实心剪影（评委看得懂"区域填充"）。
//
//  【数据流与时序】
//    · 行 y 扫描期间：统计本行 first/last（拍粒度 4px）；行末锁存进 r_of/r_ol/r_ov。
//    · 行 y+1 期间：输出行 y 的跨度（x 落在 [r_of, r_ol] 即白）⇒ 输出整体晚一行，
//      与旧填充模块同款契约（上层用本模块自己的 tvalid/tlast/tuser，天然自洽）。
//    · 帧首：输出帧的第 0 行是空跨度（黑），第 1 行首拍给 O_tuser ⇒ 输出帧与输入帧
//      同样是 720 行，仅内容整体下移一行（旧模块也是这个口径）。
//    · 延迟：数据 1 拍；tvalid/tlast/tuser 同步 1 拍。
//  【资源】无 ERAM：只要 first/last + 行计数，几组寄存器与比较器。
//  【编码规范】Verilog-2001；无 function/task/#delay；组合全 assign；声明一律在引用之前。
//==============================================================================

module alg_span_fill_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    // 跨度最小宽度（像素，拍粒度）：小于它的行不填。默认 0 = 全填。
    parameter [10:0] MIN_SPAN = 11'd0
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    // ---- 输入：二值掩膜（24'hFFFFFF 白 / 24'h000000 黑），pix0 在 [95:72] ----
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire         I_tready,
    // ---- 输出：填充后的二值掩膜，延迟 = 1 拍（内容整体晚一行）----
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

localparam BPL = IMG_WIDTH >> 2;                 // 320 拍/行
localparam XW  = $clog2(BPL);                    // 9
localparam [XW-1:0] LASTB = BPL - 1;
localparam [9:0]    ROWL  = IMG_HEIGHT - 1;

//------------------------------------------------------------------------------
// 1. 状态声明（全部在引用之前）
//------------------------------------------------------------------------------
reg [XW-1:0] r_x;                 // 行内拍号
reg [10:0]   r_first, r_last;     // 本行最左/最右白像素 x（拍粒度）
reg          r_any;               // 本行是否见过白
reg [10:0]   r_of, r_ol;          // 上一行锁存的跨度
reg          r_ov;                // 上一行是否有白
reg [9:0]    r_oline;             // 输出行号（0..719）

wire [10:0] w_xb = {r_x, 2'b00};  // 本拍首像素 x

//------------------------------------------------------------------------------
// 2. 本拍是否有白（掩膜只有 FF/00 两个合法值，每像素判一个字节）
//------------------------------------------------------------------------------
wire w_anyb = (I_tdata[95:88] == 8'hFF) || (I_tdata[71:64] == 8'hFF)
           || (I_tdata[47:40] == 8'hFF) || (I_tdata[23:16] == 8'hFF);

// 行末拍要把"本拍的白"一起算进跨度
wire [10:0] w_f_eff = w_anyb ? (r_any ? r_first : w_xb) : r_first;
wire [10:0] w_l_eff = w_anyb ? (w_xb + 11'd3) : r_last;
wire        w_v_eff = r_any | w_anyb;

//------------------------------------------------------------------------------
// 3. 行扫描 + 行末锁存
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x     <= {XW{1'b0}};
        r_any   <= 1'b0;
        r_first <= 11'd0;
        r_last  <= 11'd0;
        r_of    <= 11'd0;
        r_ol    <= 11'd0;
        r_ov    <= 1'b0;
        r_oline <= 10'd0;
    end else if (I_tvalid) begin
        if (r_x == LASTB) begin                  // 行末：锁存跨度，进下一行
            r_of    <= w_f_eff;
            r_ol    <= w_l_eff;
            r_ov    <= w_v_eff;
            r_any   <= 1'b0;
            r_x     <= {XW{1'b0}};
            r_oline <= (r_oline == ROWL) ? 10'd0 : (r_oline + 10'd1);
        end else begin
            if (w_anyb) begin
                if (!r_any) r_first <= w_xb;
                r_last <= w_xb + 11'd3;
                r_any  <= 1'b1;
            end
            r_x <= r_x + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 4. 输出：行 y+1 期间吐行 y 的跨度
//------------------------------------------------------------------------------
wire        w_span_ok = r_ov && ((r_ol - r_of) >= MIN_SPAN);
wire [10:0] w_x1 = w_xb + 11'd1;
wire [10:0] w_x2 = w_xb + 11'd2;
wire [10:0] w_x3 = w_xb + 11'd3;

wire w_p0 = w_span_ok && (w_xb >= r_of) && (w_xb <= r_ol);
wire w_p1 = w_span_ok && (w_x1 >= r_of) && (w_x1 <= r_ol);
wire w_p2 = w_span_ok && (w_x2 >= r_of) && (w_x2 <= r_ol);
wire w_p3 = w_span_ok && (w_x3 >= r_of) && (w_x3 <= r_ol);

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tdata  <= 96'd0;
        O_tvalid <= 1'b0;
        O_tlast  <= 1'b0;
        O_tuser  <= 1'b0;
    end else begin
        O_tvalid <= I_tvalid;
        O_tlast  <= I_tvalid && I_tlast;
        O_tuser  <= I_tvalid && (r_x == {XW{1'b0}}) && (r_oline == 10'd1);
        O_tdata  <= { w_p0 ? 24'hFFFFFF : 24'h000000,
                      w_p1 ? 24'hFFFFFF : 24'h000000,
                      w_p2 ? 24'hFFFFFF : 24'h000000,
                      w_p3 ? 24'hFFFFFF : 24'h000000 };
    end
end

assign O_tready = I_tready;

initial begin
    O_tdata  = 96'd0;
    O_tvalid = 1'b0;
    O_tlast  = 1'b0;
    O_tuser  = 1'b0;
    r_x = {XW{1'b0}}; r_any = 1'b0; r_first = 11'd0; r_last = 11'd0;
    r_of = 11'd0; r_ol = 11'd0; r_ov = 1'b0; r_oline = 10'd0;
end

endmodule
