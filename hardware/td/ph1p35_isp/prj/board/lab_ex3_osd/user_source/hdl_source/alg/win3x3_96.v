//==============================================================================
// 文件名   : win3x3_96.v
// 模块名   : win3x3_96
// 日期     : 2026-09-13
// 版本     : v2.0（几何重写）
// 描述     : 96-bit AXI4-Stream 算法通道 · 3x3 灰度窗口（M2/M3/M4 共用骨架）
//
//  ---------------------------------------------------------------------------
//  【一、几何规格（全部用绝对坐标说话，这是本模块唯一的正确性定义）】
//  ---------------------------------------------------------------------------
//  一拍 = 行内相邻 4 个像素。设第 k 个中心像素的绝对坐标为
//        x = 4*x_grp + k      (k = 0..3, x_grp = 拍计数器 0..319)
//        y = y_pos            (0..719)
//  则本模块在【输出拍】为 (y, x_grp) 时，O_window 上的 36 个抽头必须满足：
//
//        O_window[8*(4*(3*r+c)+k) +: 8] == gray(y - 2 + r, 4*x_grp + k + c - 1)
//        r = 0/1/2  →  行 y-2 / y-1 / y        （Δy = -2 / -1 / 0）
//        c = 0/1/2  →  列 4x+k-1 / 4x+k / 4x+k+1（Δx = -1 / 0 / +1）
//        k = 0..3   →  该拍第 k 个中心像素
//
//  其中 gray(px, py) = 图像焦点的灰度样本；出图边界按 0 补（列 -1 与列 1280）。
//  换句话说：**r0 恒为第 y-2 行，r1 恒为第 y-1 行，r2 恒为第 y 行；
//  每一行的第 k 个中心像素的窗口恒以列 4x+k 为中心。Δy = -2/-1/0，Δx = 0。**
//
//  行缓存存量：line1 恒存第 y-1 行、line2 恒存第 y-2 行，**都是"全行"**，
//  不是"上一行的一部分"。横向的左右邻居靠读数据对齐链补（见 §3）。
//
//  ---------------------------------------------------------------------------
//  【二、v2.0 修订记录（必读：v1.x 有一个致命几何错误）】
//  ---------------------------------------------------------------------------
//  v1.0/v1.1 2026-09-13  首版。行缓存读地址人为偏移 +2（`rd_addr = x_r + 2`），
//                       且 line2 的写入取的是【读出链上的 mid_r1】而不是
//                       "line1 同址旧值"，两处叠加导致三行寄存器整体错位到
//                       Δy = -4/-3/-2、Δx = +1 —— 行缓存里存的东西根本不是
//                       "上一行/上上行"，只是"错位行的错位内容"，且该错误
//                       无法靠调 rd_addr 偏移修（结构性问题）。
//  v2.0     2026-09-13  几何重写：
//    (1) 行缓存改回官方 edge_detect_96.v 的"同址读旧值 → 写下一级"结构，
//        但把异步读换成**同步读**（TD 推断 ERAM 的硬条件，见 §3）；
//        读地址只领先 1 拍（不是 2 拍），line2 写入 = line1 同址旧值。
//    (2) 横向邻居改为"读数据 3 级对齐链"（r_rd1 / r_rd1_s1 / r_rd1_s2），
//        三级对应同一行的第 X+1 / X / X-1 拍，天然给出列 4x-1 / 4x..4x+3 / 4x+4。
//    (3) 数据/控制/窗口 6 路输出全部落在**同一个**第 2 级流水寄存器上，
//        延迟严格 2 拍（S0-02 C-1 / §8.1 第 ⑥ 条）。
//    (4) 掩蔽期输出原图：O_tdata = 输入原样延迟 2 拍（**不从行缓存取**，
//        因为前两行缓存内容是未初始化的 X）。
//
//  ---------------------------------------------------------------------------
//  【三、ERAM 推断（S0-02 §7 的核心资源约束）】
//  ---------------------------------------------------------------------------
//  两条行缓存各 320 拍 × 32 bit = 10,240 bit（= 全分辨率 1280 样本 × 8 bit/行）。
//  TD 综合成 ERAM 的三条件（SWUG106《综合与FPGA应用编码指南》§5.6.13.1，P88-89）：
//        条件一：同步读（读操作同步 或 读地址同步采样）
//        条件二：写端口数量不超过 2
//        条件三：单写口场景，深度不小于 64（显式指定 ram_style=bram 时不限深度）
//  本实现逐条满足：读数据 r_rd1/r_rd2 是寄存器（同步读）；每条缓存各 1 个写口；
//  深度 320 ≥ 64。存储阵列上**没有任何复位/initial 赋值**（官方源码 110-112 行
//  原话：给 10-Kbit 缓冲加复位循环，会把它们变成 slice 寄存器）。
//
//  ⚠ 条件之外还有一条硬约束（2026-09-14 实测定位）：**读地址的位宽必须等于
//    阵列实际深度的位宽**。r_x_grp 原来写成 11 位（[10:0]），阵列是 [0:319]，
//    TD 按 2^11=2048 深度建 RAM 模型 → 与 320 深的阵列对不上 → 直接放弃 ERAM，
//    两块 10-Kbit 缓冲退成 512 个 dram lut（#lut 951；日志 HDL-1100 照样报
//    "Inferred 2 RAMs"，所以光看日志看不出问题）。收成 9 位后 #eram 2 / #dram0。
//    注意只有**读**地址宽度管用：把写地址截成 9 位、读地址仍 11 位，照样 eram=0；
//    只截读地址就能过。地址截成 10 位也不行 —— 阈值就是 ceil(log2(320))=9。
//    佐证：把阵列声明成 [0:2047]（11 位铺满）时 TD 肯收，但要 7 块 ERAM
//    （2048×32×2/20Kb=6.4），说明它确实是按地址位宽算的深度。
//    对照数据见 _eram_check\ERAM根因定位报告.md。
//
//  ram_style 属性值：**`bram`**。取值不是猜的，证据见交付报告：
//    · TD 6.2 用户手册 §3「Synthesis ram_style」P125-126：可取值为
//      bram / bram_144k / dram / none，写法 `//synthesis ram_style = bram`；
//    · SWUG106 §4.2.6（P29-30）：可选值 none|dram|bram|bram_144k，
//      bram 可带变形 `bram{_9k,_20k,_32k}{(fast),(power),(area)}`；
//    · 官方例程 edge_detect_96.v 写的 `"block"` 不在任何取值表里，TD 判
//      SYN-5041「wrong RAM_STYLE ... AUTO is really used」（lab_ex2 syn_1/run.log:1150）。
//    · 安路自家 Soft FIFO IP 对 HX1P35A 板级包的生成代码用的是注释形式：
//      `reg [MIN_WIDTH-1:0] memory [MAX_DEPTH-1:0];  //synthesis ram_style = bram`
//      （02_官方例程…/HX1P35A_Contest_202606/2_Example/32_cs500_mipi_hdmi/td/al_ip/
//        wfifo/wfifo/RTL/soft_fifo_al_b841486f440b.v:487）。
//  这里用后者这种已被安路自家 IP 在该器件上使用过的注释形式。
//
//  ---------------------------------------------------------------------------
//  【四、延迟（S0-02 C-1 = 2 拍 / C-1b = 1 行空间延迟）】
//  ---------------------------------------------------------------------------
//  第 1 级：r_x/r_y/r_gray/r_src/r_tuser/r_tlast  （输入打拍，C-1a 要求的那一级）
//  第 2 级：O_window / O_window_valid / O_tdata / O_tlast / O_tuser / O_tvalid
//           —— 6 路全部在此级装载 ⇒ 逐路延迟都是 2 拍，彼此严格同拍。
//  O_tdata 在本级直接取第 1 级的 r_src（**没有第 3 级**），所以 O_tdata 与
//  O_window 同拍，都是 2 拍。
//
//  ---------------------------------------------------------------------------
//  【五、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/
//  #delay；无用户 latch；内部寄存器 r_ 前缀、内部线网 w_ 前缀；端口保持 I_/O_。
//==============================================================================

module win3x3_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire         I_clk,
    input  wire         I_rst_n,      // 低有效异步复位（S0-02 §1 / C-6）
    input  wire         I_tlast,      // 行末 beat（EOL）
    input  wire         I_tuser,      // 帧首 beat（SOF）
    input  wire [95:0]  I_tdata,      // 灰度结果（每像素高字节 = 灰度样本）
    input  wire         I_tvalid,
    input  wire         I_tready,     // 直通，不用于反压（C-3）
    output reg          O_tlast,
    output reg          O_tuser,
    output reg  [95:0]  O_tdata,      // 原样输入，延迟 2 拍（掩蔽期输出原图用）
    output reg          O_tvalid,
    output wire         O_tready,
    output reg  [287:0] O_window,     // 4 个中心像素 × 3x3 灰度窗口（索引见 §一）
    output reg          O_window_valid
);

//------------------------------------------------------------------------------
// 0. 常量与 tready 直通
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE = IMG_WIDTH >> 2;                     // 1280 >> 2 = 320
// ⚠ XW 是"拍计数器/行缓存地址"的位宽，必须**刚好**是 ceil(log2(BEATS_PER_LINE))=9。
//   多给一位（原来是 11 位）TD 就拒绝把行缓存推断成 ERAM，整块掉进 DRAM(LUT)：
//   实测 11 位 → #eram 0 / #dram lut 512 / #lut 951；
//        9 位 → #eram 2 / #dram lut 0   / #lut 302（_eram_check\ERAM根因定位报告.md）
localparam XW = $clog2(BEATS_PER_LINE);                         // 320 → 9
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;             // 319（行末拍）
localparam [10:0] LAST_ROW  = IMG_HEIGHT - 1;                   // 719

assign O_tready = I_tready;

//------------------------------------------------------------------------------
// 1. 输入拍拆包：1 拍 = 行内相邻 4 个像素 → 4 个灰度样本
//    I_tdata[95:72] 是行内最左像素（S0-02 §2.1），所以高字节到低字节 = 左到右。
//------------------------------------------------------------------------------
wire [7:0]  w_g0 = I_tdata[95:88];      // 列 4*x_grp + 0（最左）
wire [7:0]  w_g1 = I_tdata[71:64];      // 列 4*x_grp + 1
wire [7:0]  w_g2 = I_tdata[47:40];      // 列 4*x_grp + 2
wire [7:0]  w_g3 = I_tdata[23:16];      // 列 4*x_grp + 3（最右）
wire [31:0] w_gray_in = {w_g0, w_g1, w_g2, w_g3};

//------------------------------------------------------------------------------
// 2. 行缓存：2 行 × 320 拍 × 32 bit
//    word[a] = {g(4a), g(4a+1), g(4a+2), g(4a+3)}，字节 [31:24] 最左、[7:0] 最右。
//    ⚠ 绝不在复位里清零、绝不给 initial 值（S0-02 C-6）。
//------------------------------------------------------------------------------
reg [31:0] r_line1_mem [0:BEATS_PER_LINE-1];   //synthesis ram_style = bram
reg [31:0] r_line2_mem [0:BEATS_PER_LINE-1];   //synthesis ram_style = bram

//------------------------------------------------------------------------------
// 3. 寄存器声明
//------------------------------------------------------------------------------
// ---- 3.1 坐标计数器（与官方 edge_detect_96.v:128-142 同一推进规则）----
reg [XW-1:0] r_x_grp;             // 拍计数器 0..319（不是像素计数器）；位宽见 §0 的 XW
reg [10:0] r_y_pos;               // 行计数器 0..719

// ---- 3.2 第 1 级流水：输入打拍（C-1a 要求的那一级）----
//    r_x / r_y 是"被装配窗口的那一拍"自己的绝对坐标，窗口装配（§5）、掩蔽判断
//    （§6）全部以它们为准 —— 因此掩蔽边界与数据天然同拍，不存在晚 2 拍的问题。
reg [10:0] r_x;
reg [10:0] r_y;
reg [31:0] r_gray;                // 被装配拍的 4 个灰度样本（= 底行 r2 的 4 个）
reg [95:0] r_src;                 // 被装配拍的原样输入数据（喂 O_tdata）
reg [7:0]  r_bot_left;            // 再前一拍的 w_g3 = 底行左邻居（列 4x-1）
reg        r_tuser;
reg        r_tlast;

// ---- 3.3 C-4 握手延迟：I_tvalid 延迟 1 拍（**不被 I_tvalid 门控**）----
//    输出级用 r_vld1 当"第 1 级里的这一拍是真拍"的判据，于是 O_tvalid 正好是
//    I_tvalid 的 2 拍延迟；输入停止后 2 拍输出自然归零（不丢尾拍、不多出拍）。
reg        r_vld1;

// ---- 3.4 行缓存读出与横向对齐链（**故意不给复位/初值**，见 §7 说明）----
//    读地址只领先拍计数器 1 拍，所以读出链的三级正好对应同一行的三拍：
//      r_rdX     = 第 X+1 拍 → 字节 0  = 列 4x+4（右邻居）
//      r_rdX_s1  = 第 X   拍 → 字节 3..0 = 列 4x..4x+3（本组）
//      r_rdX_s2  = 第 X-1 拍 → 字节 3  = 列 4x-1（左邻居）
reg [31:0] r_rd1;
reg [31:0] r_rd1_s1;
reg [31:0] r_rd1_s2;
reg [31:0] r_rd2;
reg [31:0] r_rd2_s1;
reg [31:0] r_rd2_s2;

// ---- 3.5 组合：行缓存读地址 ----
//    为什么是 x_grp+1：本拍发出的地址，数据下一拍才出现在 r_rdX 上；而那正是
//    "下一拍要被装配的那一拍"所需的**右邻居组**。取模 320 的回绕点 x_grp=319 → 0
//    是自洽的：那一拍要的右邻居在图外（列 1280），§5 会把它强制补 0。
//    读地址恒 ≠ 写地址（写 x_grp、读 x_grp+1），所以同一拍内不存在读写冲突，
//    也不需要"读优先/写优先"语义。
wire [XW-1:0] w_rd_addr = (r_x_grp == LAST_BEAT) ? {XW{1'b0}} : (r_x_grp + 1'b1);

//------------------------------------------------------------------------------
// 4. 行缓存本体：写入 + 同步读（同一条 RAM 的两个端口，写在一个 always 里）
//    · 写 line1[a] ← 本拍 4 个灰度样本        ⇒ line1 恒为第 y-1 行（同址旧值被读走后覆盖）
//    · 写 line2[a] ← line1[a] 的旧值          ⇒ line2 恒为第 y-2 行
//      （r_rd1 正是上一拍从地址 w_rd_addr 读出的 line1 旧值；由 §3.5 的地址关系
//        可知 w_rd_addr(上一拍) == x_grp(本拍)，所以这里写的就是同址旧值。）
//    · 读 r_rd1/r_rd2 ← 地址 w_rd_addr（同步读，晚一拍出数据）
//    ⚠ 本块【没有复位分支】：加了复位循环，TD 会把 10-Kbit 阵列退化成 slice
//      寄存器（DFF），比 LUTRAM 更糟。初始化完全靠 §6 的掩蔽纪律完成。
//------------------------------------------------------------------------------
always @ (posedge I_clk) begin
    if (I_tvalid) begin
        r_line1_mem[r_x_grp] <= w_gray_in;
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
// 5. 第 1 级流水寄存器（一件一件写，每个 always 只干一件事）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x     <= 11'd0;
        r_y     <= 11'd0;
    end else if (I_tvalid) begin
        r_x     <= r_x_grp;
        r_y     <= r_y_pos;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_gray <= 32'd0;
    else if (I_tvalid)
        r_gray <= w_gray_in;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_src <= 96'd0;
    else if (I_tvalid)
        r_src <= I_tdata;
end

//    ⚠ 取的是【已打拍】的 r_gray[7:0]，不是总线上本拍的 w_g3：
//      装配窗口时，底行的组号是 X = x_grp(上一拍)，左邻居 = 第 X-1 组的第 4 个样本，
//      也就是【上上拍】总线上的 w_g3。总线上本拍的 w_g3 是第 X 组的最后一个样本，
//      用它会把左邻居错成"中心列 +3"（横向差 4 列，行首还会串行）。
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_bot_left <= 8'd0;
    else if (I_tvalid)
        r_bot_left <= r_gray[7:0];
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
        r_vld1 <= I_tvalid;             // 不加 I_tvalid 门控（C-4 的握手延迟）
end

//------------------------------------------------------------------------------
// 6. 坐标推进（官方 edge_detect_96.v:128-142 逐字同构）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= 11'd0;
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin                     // 帧首：同步坐标（0 → 1 就是本拍的 +1）
            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin
            r_x_grp <= {XW{1'b0}};              // 行末回绕
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 7. 窗口装配（纯组合，全部写成 wire ⇒ 天然无 latch）
//    三行各 6 个样本，覆盖列 [4x-1 .. 4x+4]：
//        s_m1 = 列 4x-1（左）   s0..s3 = 列 4x..4x+3（本组）   s4 = 列 4x+4（右）
//    第 k 个中心像素（列 4x+k）的窗口 = {s(k-1), s(k), s(k+1)}。
//    图外补 0：x_r == 0 时左邻居在图外；x_r == 319 时右邻居在图外。
//------------------------------------------------------------------------------
// ---- 上行 r0 = 第 y-2 行（来自 line2）----
wire [7:0] w_top_m1 = (r_x == 11'd0)      ? 8'd0 : r_rd2_s2[7:0];    // 列 4x-1
wire [7:0] w_top_0  = r_rd2_s1[31:24];                              // 列 4x+0
wire [7:0] w_top_1  = r_rd2_s1[23:16];                              // 列 4x+1
wire [7:0] w_top_2  = r_rd2_s1[15:8];                               // 列 4x+2
wire [7:0] w_top_3  = r_rd2_s1[7:0];                                // 列 4x+3
wire [7:0] w_top_4  = (r_x == LAST_BEAT)  ? 8'd0 : r_rd2[31:24];    // 列 4x+4

// ---- 中行 r1 = 第 y-1 行（来自 line1）----
wire [7:0] w_mid_m1 = (r_x == 11'd0)      ? 8'd0 : r_rd1_s2[7:0];    // 列 4x-1
wire [7:0] w_mid_0  = r_rd1_s1[31:24];                              // 列 4x+0
wire [7:0] w_mid_1  = r_rd1_s1[23:16];                              // 列 4x+1
wire [7:0] w_mid_2  = r_rd1_s1[15:8];                               // 列 4x+2
wire [7:0] w_mid_3  = r_rd1_s1[7:0];                                // 列 4x+3
wire [7:0] w_mid_4  = (r_x == LAST_BEAT)  ? 8'd0 : r_rd1[31:24];    // 列 4x+4

// ---- 下行 r2 = 第 y 行（= 被装配拍本身，来自输入打拍寄存器）----
wire [7:0] w_bot_m1 = (r_x == 11'd0)      ? 8'd0 : r_bot_left;       // 列 4x-1
wire [7:0] w_bot_0  = r_gray[31:24];                                // 列 4x+0
wire [7:0] w_bot_1  = r_gray[23:16];                                // 列 4x+1
wire [7:0] w_bot_2  = r_gray[15:8];                                 // 列 4x+2
wire [7:0] w_bot_3  = r_gray[7:0];                                  // 列 4x+3
// 列 4x+4 = 下一拍的第 1 个样本，**此刻正在总线上**（这正是 C-1a 说"必须打一拍"
// 的原因）；x_r == 319 时它是图外的列 1280，补 0。
// A stream bubble has no lookahead sample. Replicate the final valid pixel
// instead of reading invalid/zero data as a neighbor and creating black dots.
wire [7:0] w_bot_4  = (r_x == LAST_BEAT) ? 8'd0
                       : ((I_tvalid && !I_tuser) ? w_g0 : w_bot_3);

// ---- 抽头 → 扁平总线（索引公式见文件头 §一）----
//    按冻结索引公式 8*(4*(3*r+c)+k) 逐组核对（每组 4 字节 = k=3,2,1,0）：
//      (r,c,k) 的源列 = 4x + k + c - 1，所以 c=1 组是 (0,1,2,3)、c=0 组左移一列、
//      c=2 组右移一列 —— 相邻两组共享 3 个样本，这是全分辨率窗口的固有冗余。
wire [287:0] w_window = {
    w_bot_4, w_bot_3, w_bot_2, w_bot_1,     // r=2 c=2 下行·右列 [287:256]
    w_bot_3, w_bot_2, w_bot_1, w_bot_0,     // r=2 c=1 下行·中列 [255:224]
    w_bot_2, w_bot_1, w_bot_0, w_bot_m1,    // r=2 c=0 下行·左列 [223:192]
    w_mid_4, w_mid_3, w_mid_2, w_mid_1,     // r=1 c=2 中行·右列 [191:160]
    w_mid_3, w_mid_2, w_mid_1, w_mid_0,     // r=1 c=1 中行·中列 [159:128]
    w_mid_2, w_mid_1, w_mid_0, w_mid_m1,    // r=1 c=0 中行·左列 [127:96]
    w_top_4, w_top_3, w_top_2, w_top_1,     // r=0 c=2 上行·右列 [95:64]
    w_top_3, w_top_2, w_top_1, w_top_0,     // r=0 c=1 上行·中列 [63:32]
    w_top_2, w_top_1, w_top_0, w_top_m1     // r=0 c=0 上行·左列 [31:0]
};

wire w_window_valid = (r_y >= 11'd2) && (r_x != 11'd0) && (!r_tuser);

//------------------------------------------------------------------------------
// 8. 输出级（C-1：6 路输出全部在第 2 级装载，延迟都是 2 拍）
//    O_tdata 取第 1 级的 r_src —— 掩蔽期输出的就是**原图**（延迟 2 拍对齐），
//    而不是从行缓存里取（前两行缓存是未初始化的 X，仿真会传播 X）。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_window <= 288'd0;
    else if (r_vld1 && w_window_valid)
        O_window <= w_window;
    else
        O_window <= 288'd0;      // 掩蔽期短路清零：行缓存的 X 不会写进 O_window
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_window_valid <= 1'b0;
    else
        O_window_valid <= r_vld1 && w_window_valid;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld1)
        O_tdata <= r_src;
    else
        O_tdata <= 96'd0;        // C-4
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= r_vld1 && r_tlast;
        O_tuser <= r_vld1 && r_tuser;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld1;      // = I_tvalid 延迟 2 拍
end

//------------------------------------------------------------------------------
// 9. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//    被**有意省略**的是 2 个行缓存阵列 r_line1_mem / r_line2_mem 与它们的读出
//    对齐链 r_rd1/r_rd1_s1/r_rd1_s2/r_rd2/r_rd2_s1/r_rd2_s2：
//      · 阵列不能有复位/初值（否则退化成 slice 寄存器，S0-02 C-6）；
//      · 读出链的值直接来自阵列，给它初值也改不了"阵列本身是 X"这件事，
//        留着 X 反而能在仿真里证明掩蔽真的把 X 压住了（见 §8 的短路清零）。
//------------------------------------------------------------------------------
initial begin
    r_x_grp        = {XW{1'b0}};
    r_y_pos        = 11'd0;
    r_x            = 11'd0;
    r_y            = 11'd0;
    r_gray         = 32'd0;
    r_src          = 96'd0;
    r_bot_left     = 8'd0;
    r_tuser        = 1'b0;
    r_tlast        = 1'b0;
    r_vld1         = 1'b0;
    O_window       = 288'd0;
    O_window_valid = 1'b0;
    O_tdata        = 96'd0;
    O_tlast        = 1'b0;
    O_tuser        = 1'b0;
    O_tvalid       = 1'b0;
end

endmodule
