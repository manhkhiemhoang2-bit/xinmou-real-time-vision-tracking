//==============================================================================
// 文件名   : alg_region_fill_96.v
// 模块名   : alg_region_fill_96
// 日期     : 2026-09-18
// 版本     : v3.0（回到 v1 的控制链结构 + 逐拍模型定死的窗口抽头 + 上升沿填充）
// 描述     : 96-bit 算法通道 · 扩展要求 2.4(1)「风格化 / 视觉增强」· 区域填充
//            输入 = 二值掩膜（三字节全 0xFF 白 / 全 0x00 黑），
//            输出 = 填充后的二值掩膜（同格式、同拍率、同拍对齐）。
//
//  ---------------------------------------------------------------------------
//  【一、处理链（两级）】
//  ---------------------------------------------------------------------------
//  第 1 级 3×3 膨胀（dilate）：把白像素在其 3×3 邻域内扩散，把断开的轮廓接上、
//      把细缝堵住。判定量 = 窗口 9 个像素中**任一**为白。
//      ⚠「白」的判据【本模块与 sim\ref_region_fill.py **写死同一个口径**】：
//            white(p) == (p == 24'hFFFFFF)      —— 三字节全 0xFF
//        不取「亮度 >= 128」。依据：上游 alg_binarize_96 / alg_sobel_96 阈值化后的
//        像素**只有 24'hFFFFFF 与 24'h000000 两个合法取值**，两种口径在合法输入上
//        完全等价；而"三字节全 0xFF"不需要算亮度，也不会把中间灰误判成白。
//  第 2 级 行内扫描填充（scanline fill）：**只在"由黑变白"那一下翻转 inside**
//            rise   = edge & ~edge_prev      （edge_prev = **左边那个像素**）
//            inside = inside ^ rise
//            out    = edge | inside
//      ⚠⚠ 为什么不是"每个白像素翻一次"（原规格，已作废，留档）：
//        每个白像素翻一次 ⇒ 翻转次数 = 边缘带的**像素宽度**：
//          1/3 像素宽（奇数）→ 填上；2/4 像素宽（偶数）→ **填不上**。
//        上游是 Sobel 边缘，边缘带本来就是 2~3 像素宽且不稳定 ⇒ 变成赌奇偶。
//        改成上升沿判据后，翻转次数 = 边缘**游程**个数，与宽度无关。
//      ⚠ 串行：4 级链按 pix0 → pix3 推进（rise_k 依赖 e_{k−1}），不是并行 XOR。
//      ⚠⚠ 本模块**只能吃轮廓图，绝对不能吃实心图**：实心色块行内只有"整段白"，
//        上升沿只在段首出现一次 ⇒ inside 一路保持到行尾，整幅花掉。
//        集成时必须接在**边缘检测**之后，不能接在二值化（实心色块）之后。
//
//  ---------------------------------------------------------------------------
//  【二、延迟 = 3 拍（I_tdata 进 → O_tdata 出），5 路输出严格同拍】
//  ---------------------------------------------------------------------------
//  第 1 级：r_x/r_y/r_word/r_src/r_tlast/r_tuser/r_vld1 + 行缓存读出链
//  第 2 级：O_tdata（= 第 1 级 r_src）+ O_tvalid/O_tlast/O_tuser + r_inside
//  共 3 级寄存器 ⇒ 延迟 3 拍。TB 用**独立计数器**（不读 DUT 内部）钉死：
//  O_tvalid/O_tlast/O_tuser == 各自延迟 3 拍、输出有效拍数 == 输入有效拍数。
//
//  ⚠ 本版把 v2.0 的"6 bit 滚动窗口 + 读写分拍"整套**退回**到 v1 的
//    "读地址领先 1 拍 + 两级读出链"结构：v2.0 的控制链（tvalid/tlast/tuser）
//    实测出现 80+ 拍失配、且无法在有限轮次内收敛；v1 的控制链是逐拍对齐、
//    实测零失配的。v1 唯一的问题在窗口抽头的取法（下条），本版只改那里。
//
//  ---------------------------------------------------------------------------
//  【三、窗口抽头的取法（逐拍模型定死，不再靠推理）】
//  ---------------------------------------------------------------------------
//  行缓存：2 行 × BPL 拍 × 32 bit，每条只存 1 bit/像素（一行 1280 bit = 160 字节，
//  两条合计 320 字节 < 1 块 ERAM）。地址仍是"拍号"。
//  读地址 = x_grp + 1（领先写地址 1 拍；读地址恒 ≠ 写地址 ⇒ 同拍无读写冲突，
//  不依赖器件的 read-first 语义）。
//
//  ⚠⚠ 读出链的用法（v3.2 用**探针实测**重新定死；v3.1 的写法是错的，留档）：
//    记 r_x = 装配用的拍号（第 1 级采到的 x_grp）。读口在上一拍发出地址 x_grp+1，
//    实测（sim\_probe_taps_rf.v，7 轮位平面扫描还原绝对坐标）：
//        r_rdX      = 第 r_x+1 组   ← **右邻居组**（位 3 = 列 4x+4）
//        r_rdX_s1   = 第 r_x   组   ← **本组**
//        r_rdX_s2   = 第 r_x−1 组   ← **左邻组**（位 0 = 列 4x−1）
//    v3.1 错在把 s2 当"本组"、s1 当"右邻" ⇒ 上/中两行整体左偏一组（4 列）、
//    窗口被"斜切"（底行采 4x−1..4x+4，上/中行采 4x−4..4x），实测 311 个像素失配。
//    ⚠ 左邻必须取 s2 的 **bit0**（列 4(x−1)+3 = 4x−1）；取 bit3 会拿到列 4x−4。
//    底行左邻居仍走 r_bl1（= 上一拍 r_word[0] = 列 4x−1），与 win3x3_96 §5 同法。
//    三条 ERAM 硬规则（S1第二批_接口冻结.md §6）逐条落实：读地址位宽 = ceil(log2(BPL))；
//    读数据寄存器直连阵列；阵列上无复位、无 initial。
//
//  ---------------------------------------------------------------------------
//  【四、掩蔽 / 复位口径（照抄 win3x3_96）】
//  ---------------------------------------------------------------------------
//  空间计数器按 **I_tvalid** 门控、I_tuser 复位（win3x3_96 §6 逐字同构）。
//  窗口可信判据逐字照抄 win3x3_96 §7：
//        w_win_valid = (r_y >= 3) && (r_x != 0) && (!r_tuser)
//  · 有效掩蔽实际宽 **3 拍**（前 3 行 + 每行第 0 拍），列 0..3 ——
//    ⚠ v3.2：行门槛由 2 改成 **3**：因为本模块输出**晚一行**（见下条），
//      "输出第 2 行"承载的是输入第 1 行的结果，而输入第 1 行按口径要被掩蔽
//      ⇒ 掩蔽行数必须跟着位移一起挪（2→3）。实测：311→108 之后这一步把失配降到 1。
//  · 不可信时膨胀结果短路压零 ⇒ 填充自然输出全黑，且未初始化的行缓存内容（X）
//    不会漏进组合逻辑。
//  · inside / edge_prev 在**行内最后一拍**（r_x == LAST_BEAT）置 0（见 §13），
//    于是下一拍（下一行行首）入口状态天然为 0；不挂在 tlast 的时序上。
//
//  ⚠⚠ 行错位约定（**本项目窗口类算子的统一口径**，不是 bug，判据必须照此对齐）：
//    窗口 r0/r1/r2 = 第 y−2 / y−1 / y 行，装配在本拍（第 y 行）数据进窗口之后
//    ⇒ 中心行是 y−1 ⇒ **输出拍 y 承载的是输入第 y−1 行的填充结果**（整体晚一行）。
//      · 与 src\win3x3_96.v 同口径（它文件头同样写 r0/r1/r2 = y−2/y−1/y、中心 y−1）；
//      · 全尺寸 checker sim\check_alg_top_full.py 里的 _shift1() 就是这条位移；
//      · M2/M3/M4 这些"过窗口"档位本来就按整体位移一行比对；
//      · ⇒ 逐像素判据必须把参考**整体下移一行**再比（shift1）；用 shift0 比必然错；
//      · ⇒ 掩蔽行门槛 = 3（"输出第 y 行"等价于"参考第 y−1 行"）。
//    架构原因（不要再试图"修"成 shift0）：latency 3 + 2 条行缓存（存的都是**已收到**
//    的行）⇒ 输出第 y 行时第 y+1 行还没进来，窗口看不到 y+1 ⇒ shift0 物理上做不到。
//
//  ⚠ 已知边界（实测 1 个像素，已定位）：底行最右像素的右邻取"下一拍的首像素"
//    （w_bot_4 = w_w0，与 win3x3_96 §5 的 w_bot_4 = w_g0 同法）。若该拍之后
//    I_tvalid 连续拉低 **≥2 拍**，这个像素在本模块必须锁存输出的那一拍还没到
//    ⇒ 该像素算错。实测：8 帧 2560 像素里 1 个（f3 y4 col15）。
//    win3x3_96 是同一写法，但它的 TB 没有气泡，所以这个边界从未暴露。
//
//  ---------------------------------------------------------------------------
//  【五、拍内像素序】pix0 = I_tdata[95:72] 行内**最左**，pix3 = [23:0] 最右。
//  ---------------------------------------------------------------------------
//  【六、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/
//  #delay；无用户 latch（组合全部 assign/wire）；一个 always 只干一件事。
//==============================================================================

module alg_region_fill_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire         I_clk,
    input  wire         I_rst_n,      // 低有效异步复位
    input  wire [95:0]  I_tdata,      // 二值掩膜：4 像素 × 24bit，只有 FFFFFF / 000000
    input  wire         I_tvalid,
    input  wire         I_tlast,      // 行末 beat（EOL）
    input  wire         I_tuser,      // 帧首 beat（SOF，1 拍脉冲）
    input  wire         I_tready,     // 直通，不用于反压
    output reg  [95:0]  O_tdata,      // 填充后的二值掩膜，延迟 3 拍
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

//------------------------------------------------------------------------------
// 0. 常量与 tready 直通
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE = IMG_WIDTH >> 2;                     // 1280 >> 2 = 320
// ⚠ XW 必须**刚好**是 ceil(log2(BEATS_PER_LINE))：320 → 9（多给一位 TD 拒 ERAM）
localparam XW = $clog2(BEATS_PER_LINE);                         // 320 → 9
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;             // 319（行末拍）
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;                 // 719
localparam [23:0]   WHITE     = 24'hFFFFFF;
localparam [23:0]   BLACK     = 24'h000000;

assign O_tready = I_tready;                                     // C-3：全链路不反压

//------------------------------------------------------------------------------
// 1. 输入拍拆包（pix0 最左 → pix3 最右）与"白"判据
//------------------------------------------------------------------------------
wire [23:0] w_pix0 = I_tdata[95:72];        // 列 4*x_grp + 0（最左）
wire [23:0] w_pix1 = I_tdata[71:48];
wire [23:0] w_pix2 = I_tdata[47:24];
wire [23:0] w_pix3 = I_tdata[23: 0];        // 列 4*x_grp + 3（最右）

wire w_w0 = (w_pix0 == WHITE);
wire w_w1 = (w_pix1 == WHITE);
wire w_w2 = (w_pix2 == WHITE);
wire w_w3 = (w_pix3 == WHITE);
wire [3:0] w_masks = {w_w0, w_w1, w_w2, w_w3};   // [3] = 列 4x+0（最左）

//------------------------------------------------------------------------------
// 2. 行缓存：2 行 × BPL 拍 × 32 bit（每像素只占 1 bit，见 §三）
//    ⚠ 绝不在复位里清零、绝不给 initial 值（否则 TD 把阵列退化成 slice 寄存器）。
//------------------------------------------------------------------------------
reg [31:0] r_line1_mem [0:BEATS_PER_LINE-1];   //synthesis ram_style = bram
reg [31:0] r_line2_mem [0:BEATS_PER_LINE-1];   //synthesis ram_style = bram

//------------------------------------------------------------------------------
// 3. 寄存器声明
//------------------------------------------------------------------------------
reg [XW-1:0] r_x_grp;             // 拍计数器 0..BPL-1
reg [10:0]   r_y_pos;             // 行计数器 0..IMG_HEIGHT-1

// ---- 第 1 级流水 ----
reg [10:0] r_x;                   // 装配用的拍号
reg [10:0] r_y;                   // 装配用的行号
reg [3:0]  r_word;                // 底行 4 个掩膜位（[3] = 最左）
reg [95:0] r_src;                 // 原样输入（喂 O_tdata）
reg        r_tuser;
reg        r_tlast;
reg        r_vld1;
reg        r_vld2;                // 第 2 级有效标志（O_* 装载使能）
reg        r_last2, r_user2;      // 第 2 级控制
reg [95:0] r_fill2;               // 第 2 级：填充结果
reg [95:0] r_src2;                // 第 2 级：r_src 的副本（保留，不接输出）

// ---- 行缓存读出与对齐链（**故意不给复位/初值**，同 win3x3_96 §9）----
reg [31:0] r_rd1;
reg [31:0] r_rd1_s1;
reg [31:0] r_rd1_s2;
reg [31:0] r_rd2;
reg [31:0] r_rd2_s1;
reg [31:0] r_rd2_s2;

// ---- 左邻居专用位移链（底行专用）----
//   r_bl1 = 上一拍第 4 个像素 = 列 4x−1（底行左邻居）
//   ⚠ v3.2 起中/顶行的左邻居改从行缓存读出链 s2 的 bit0 取（见 §9），
//     原来的 r_bl2/r_bl3（r_word 的再延迟，装的是**底行**的旧列）已删除：
//     探针实测它们给出的坐标根本不是"中/顶行的左邻"，而是另一行的旧数据。
reg r_bl1;

// ---- 填充状态 ----
reg        r_inside;
reg        r_edge_prev;
// （v3.1 的 r_clr 已删除：行边界改由 w_row_end = (r_x == LAST_BEAT) 判定，见 §13）

//------------------------------------------------------------------------------
// 4. 行缓存读地址 = 本拍拍号 + 1（读写恒不同址 ⇒ 同拍无冲突）
//------------------------------------------------------------------------------
wire [XW-1:0] w_rd_addr = (r_x_grp == LAST_BEAT) ? {XW{1'b0}} : (r_x_grp + 1'b1);

//------------------------------------------------------------------------------
// 5. 行缓存本体：写入 + 同步读（同一条 RAM 的写口与读口）
//    · 写 line1[X] ← 本拍 4 个掩膜位（第 y 行第 X 组）
//    · 写 line2[X] ← r_rd1（line1 同址旧值）⇒ line2 恒为第 y−2 行
//    · 读 r_rd1 ← line1[X+1]、r_rd2 ← line2[X+1]（同步读，晚一拍出数据）
//    ⚠ 本块【没有复位分支、没有 initial】
//------------------------------------------------------------------------------
always @ (posedge I_clk) begin
    if (I_tvalid) begin
        r_line1_mem[r_x_grp] <= w_masks;
        r_line2_mem[r_x_grp] <= r_rd1;
        r_rd1    <= r_line1_mem[w_rd_addr];
        r_rd2    <= r_line2_mem[w_rd_addr];
        r_rd1_s1 <= r_rd1;
        r_rd1_s2 <= r_rd1_s1;
        r_rd2_s1 <= r_rd2;
        r_rd2_s2 <= r_rd2_s1;
    end
end

//------------------------------------------------------------------------------
// 6. 第 1 级流水寄存器（一个 always 只干一件事）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x <= 11'd0;
        r_y <= 11'd0;
    end else if (I_tvalid) begin
        r_x <= r_x_grp;
        r_y <= r_y_pos;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_word <= 4'd0;
    else if (I_tvalid)
        r_word <= w_masks;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_src <= 96'd0;
    else if (I_tvalid)
        r_src <= I_tdata;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tuser <= 1'b0;
        r_tlast <= 1'b0;
    end else if (I_tvalid) begin
        r_tuser <= I_tuser;
        r_tlast <= I_tlast;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;             // 不加 I_tvalid 门控（握手延迟）
end

//------------------------------------------------------------------------------
// 7. 左邻居位移链（见第 3 节说明）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_bl1 <= 1'b0;
    end else if (I_tvalid) begin
        r_bl1 <= r_word[0];              // 上一拍第 4 个像素 = 列 4x−1
    end
end

//------------------------------------------------------------------------------
// 8. 坐标推进（win3x3_96 §6 逐字同构）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin
            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin
            r_x_grp <= {XW{1'b0}};
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 9. 3×3 窗口装配（纯组合 assign ⇒ 天然无 latch）
//    按 §三 的推导（逐拍模型定死）：
//        r_rdX_s2 = 第 r_x     组  ⇒ 本组 4 个像素（位 3..0 = 列 4x..4x+3）
//        r_rdX_s1 = 第 r_x + 1 组  ⇒ 位 3 = 列 4x+4（右邻居）
//        左邻居（列 4x−1）走独立位移链 r_bl*
//    图外补 0：r_x == 0 时左邻居在图外；r_x == LAST_BEAT 时右邻居在图外。
//------------------------------------------------------------------------------
// ---- 上行 r0 = 第 y−2 行（line2）----
//  ⚠⚠ v3.2 修正（探针 _probe_taps_rf.v 7 轮位平面扫描实测的绝对坐标）：
//     v3.1 这里取 r_rd2_s2 当"本组"、r_rd2_s1 当"右邻"，实测**整体左偏一组（4 列）**：
//     第 x 拍的上/中两行采到的是 4x−4..4x 列，而底行采的是 4x−1..4x+4 列 ⇒ 窗口被"斜切"。
//     正确的取法：本组 = s1、右邻 = 读口当拍新值 r_rdX、左邻 = s2 的**第 0 位**
//     （第 x−1 组的最右像素 = 列 4x−1；⚠ 是 bit0 不是 bit3，bit3 是列 4(x−1)+0）。
wire w_top_m1 = (r_x == 11'd0)     ? 1'b0 : r_rd2_s2[0];
wire w_top_0  = r_rd2_s1[3];
wire w_top_1  = r_rd2_s1[2];
wire w_top_2  = r_rd2_s1[1];
wire w_top_3  = r_rd2_s1[0];
wire w_top_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd2[3];

// ---- 中行 r1 = 第 y−1 行（line1）----
wire w_mid_m1 = (r_x == 11'd0)     ? 1'b0 : r_rd1_s2[0];
wire w_mid_0  = r_rd1_s1[3];
wire w_mid_1  = r_rd1_s1[2];
wire w_mid_2  = r_rd1_s1[1];
wire w_mid_3  = r_rd1_s1[0];
wire w_mid_4  = (r_x == LAST_BEAT) ? 1'b0 : r_rd1[3];

// ---- 下行 r2 = 第 y 行（第 1 级副本）----
wire w_bot_m1 = (r_x == 11'd0)     ? 1'b0 : r_bl1;
wire w_bot_0  = r_word[3];
wire w_bot_1  = r_word[2];
wire w_bot_2  = r_word[1];
wire w_bot_3  = r_word[0];
wire w_bot_4  = (r_x == LAST_BEAT) ? 1'b0 : w_w0;   // 下一拍首像素 = 列 4x+4

//------------------------------------------------------------------------------
// 10. 窗口可信判据（win3x3_96 §7 同口径；行门槛 3 —— 见 §四 的"晚一行"约定）
//------------------------------------------------------------------------------
wire w_win_valid = (r_y >= 11'd3) && (r_x != 11'd0) && (!r_tuser);

//------------------------------------------------------------------------------
// 11. 3×3 膨胀（组合）：窗口内任一为白即边缘；不可信时短路压零
//------------------------------------------------------------------------------
wire w_e0_raw = |{ w_top_m1, w_top_0, w_top_1, w_mid_m1, w_mid_0, w_mid_1,
                   w_bot_m1, w_bot_0, w_bot_1 };
wire w_e1_raw = |{ w_top_0, w_top_1, w_top_2, w_mid_0, w_mid_1, w_mid_2,
                   w_bot_0, w_bot_1, w_bot_2 };
wire w_e2_raw = |{ w_top_1, w_top_2, w_top_3, w_mid_1, w_mid_2, w_mid_3,
                   w_bot_1, w_bot_2, w_bot_3 };
wire w_e3_raw = |{ w_top_2, w_top_3, w_top_4, w_mid_2, w_mid_3, w_mid_4,
                   w_bot_2, w_bot_3, w_bot_4 };

wire w_e0 = w_win_valid & w_e0_raw;
wire w_e1 = w_win_valid & w_e1_raw;
wire w_e2 = w_win_valid & w_e2_raw;
wire w_e3 = w_win_valid & w_e3_raw;

//------------------------------------------------------------------------------
// 12. 上升沿判据 + 行内扫描填充（pix0 → pix3 串行）
//------------------------------------------------------------------------------
wire w_rise0 = w_e0 & ~r_edge_prev;         // 跨拍传递的"上一个像素"
wire w_ins0  = r_inside;
wire w_ins1  = w_ins0 ^ w_rise0;
wire w_rise1 = w_e1 & ~w_e0;
wire w_ins2  = w_ins1 ^ w_rise1;
wire w_rise2 = w_e2 & ~w_e1;
wire w_ins3  = w_ins2 ^ w_rise2;
wire w_rise3 = w_e3 & ~w_e2;
wire w_ins4  = w_ins3 ^ w_rise3;

wire w_fill0 = w_e0 | w_ins0;
wire w_fill1 = w_e1 | w_ins1;
wire w_fill2 = w_e2 | w_ins2;
wire w_fill3 = w_e3 | w_ins3;

wire [23:0] w_opix0 = w_fill0 ? WHITE : BLACK;
wire [23:0] w_opix1 = w_fill1 ? WHITE : BLACK;
wire [23:0] w_opix2 = w_fill2 ? WHITE : BLACK;
wire [23:0] w_opix3 = w_fill3 ? WHITE : BLACK;

// ⚠ 像素顺序：pix0（列 4x+0，最左）必须放最高位 [95:72]（S0-02 §2.1）。
wire [95:0] w_result = {w_opix0, w_opix1, w_opix2, w_opix3};

//------------------------------------------------------------------------------
// 13. 填充状态更新：inside / edge_prev 的**行边界**用"输出侧行内拍号 r_x"判定
//
//     ⚠⚠ v3.2 改法（v3.1 的 r_clr 路径作废，留档说明为什么）：
//       v3.1 用 r_tlast（I_tlast 打一拍）再打一拍得到 r_clr 去清零。问题是
//       r_tlast 的**装载沿**与"下一行行首"天然差一拍：清零发生在**行首那一拍之后**，
//       于是行首那一拍的入口 inside 仍是上一行的残留 ⇒ 每行开头多填 4 个像素
//       （实测形貌：每行开头 `####.`，参考是 `.....`）。而行尾那一拍本身没被截断，
//       两头各错一边。
//       正确做法：把"这属于哪一行"变成**拍号的纯函数**——
//           本拍是行内最后一拍（r_x == LAST_BEAT）⇒ 下一拍必然是下一行行首
//           ⇒ 在**本拍**就把 inside/edge_prev 置 0，
//       于是行首那一拍的入口状态天然为 0；行末那一拍自己照常运算、结果照常输出。
//       r_x 与列号/几何计数器同源（都来自 r_x_grp），不依赖 tlast 的时序；
//       tlast 只用于接口契约（O_tlast），不再参与 inside 的状态。
//------------------------------------------------------------------------------
wire w_row_end = (r_x == LAST_BEAT);        // 行内最后一拍

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_inside    <= 1'b0;
        r_edge_prev <= 1'b0;
    end else if (r_vld1) begin
        if (w_row_end) begin
            r_inside    <= 1'b0;
            r_edge_prev <= 1'b0;
        end else begin
            r_inside    <= w_ins4;
            r_edge_prev <= w_e3;
        end
    end
end

//------------------------------------------------------------------------------
// 14. 输出级（第 2 级）：5 路同一时钟沿装载 ⇒ 延迟 3 拍、彼此严格同拍
//     ⚠ tlast/tuser 必须与 tvalid 走同样多的级数，否则会比 tvalid 早到；
//       且必须有显式 else 归零，否则 tlast 脉冲之后会一直保持 1。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld2 <= 1'b0;
    else
        r_vld2 <= r_vld1;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_last2 <= 1'b0;
    else
        r_last2 <= r_tlast;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_user2 <= 1'b0;
    else
        r_user2 <= r_tuser;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_src2 <= 96'd0;
    else if (r_vld1)
        r_src2 <= r_src;
end

//    ⚠⚠ 输出必须是**填充结果** w_result，不是原样输入！
//       v1 遗留结构把 O_tdata 接成了 r_src2（原样输入延迟 3 拍），
//       于是"填充算出来了但没送出去"——A2/A8 这类只看"延迟/值域"的断言照样全绿，
//       只有**逐像素比对**（A5）会暴露它。这是本项目"别只数拍数、必须逐像素比"的
//       又一个实例。
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_fill2 <= 96'd0;
    else if (r_vld1)
        r_fill2 <= w_result;            // 第 2 级：寄存填充结果
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld2)
        O_tdata <= r_fill2;             // 第 3 级：输出（与 O_tvalid/tlast/tuser 同拍）
    else
        O_tdata <= 96'd0;               // C-4：无有效输入拍时输出清零，不留 X
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld2;             // = I_tvalid 延迟 3 拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else if (r_vld2) begin
        O_tlast <= r_last2;
        O_tuser <= r_user2;
    end else begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end
end

//------------------------------------------------------------------------------
// 15. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//     被**有意省略**的是 2 个行缓存阵列与它们的读出对齐链：阵列不能有复位/初值；
//     读出链的值直接来自阵列，留着 X 反而能证明掩蔽纪律真的把 X 压住了。
//------------------------------------------------------------------------------
initial begin
    r_x_grp     = {XW{1'b0}};
    r_y_pos     = 11'd0;
    r_x         = 11'd0;
    r_y         = 11'd0;
    r_word      = 4'd0;
    r_src       = 96'd0;
    r_tuser     = 1'b0;
    r_tlast     = 1'b0;
    r_vld1      = 1'b0;
    r_vld2      = 1'b0;
    r_last2     = 1'b0;
    r_user2     = 1'b0;
    r_src2      = 96'd0;
    r_fill2     = 96'd0;
    r_bl1       = 1'b0;
    r_inside    = 1'b0;
    r_edge_prev = 1'b0;
    O_tdata     = 96'd0;
    O_tvalid    = 1'b0;
    O_tlast     = 1'b0;
    O_tuser     = 1'b0;
end

endmodule
