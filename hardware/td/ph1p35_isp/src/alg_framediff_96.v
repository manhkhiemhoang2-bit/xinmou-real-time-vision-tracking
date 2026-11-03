//==============================================================================
// 文件名   : alg_framediff_96.v
// 模块名   : alg_framediff_96
// 日期     : 2026-09-17
// 版本     : v1.0
// 描述     : 96-bit AXI4-Stream 算法通道 · M6 帧差法运动目标检测（8x8 降采样）
//
//  输入 = **灰度流**（gray_bt601_96 的输出：每个像素 R/G/B 三字节都填同一个 Y，
//  见 S1第二批_接口冻结.md 与 gray_bt601_96.v），本模块只取 pix0 的最高字节。
//  为什么吃灰度流而不是原始彩色：M1 判据已经把 gray_bt601_96 的输出逐位钉在
//  金标准 A.gray_bt601 上，本模块直接复用那条**已验证**的灰度来源，避免把
//  BT.601 的移位加法公式在本文件里再抄一遍（抄错就是"帧差和 M1 灰度不一致"，
//  而那种不一致在本模块里无法自证）。
//
//  ---------------------------------------------------------------------------
//  【一、几何（8x8 降采样，口径写死在这里）】
//  ---------------------------------------------------------------------------
//  一拍 = 行内相邻 4 个像素，pix0 = I_tdata[95:72] 是**最左**像素（S0-02 §2.1）。
//  记 beat 计数器 = x_grp（0..BEATS_PER_LINE-1）、行计数器 = y（0..IMG_HEIGHT-1）。
//
//  采样点（"运动格子"中心）：
//      x_grp 为**偶数** 且 y % 8 == 0 ⇒ pix0 的绝对坐标 = (x, y) = (8*cx, 8*cy)
//      其中 cx = x_grp >> 1 ∈ [0, CX-1]、cy = y >> 3 ∈ [0, CY-1]
//      CX = IMG_WIDTH/8、CY = IMG_HEIGHT/8（1280x720 → 160 x 90；160x64 → 20 x 8）
//  一拍只可能产生 0 或 1 个采样点（一拍里 pix0 只有一个），且采样事件间隔恒为 2 拍。
//
//  计数器口径（与 win3x3_96 §6 **逐字同构**，这一点必须看懂再改）：
//      r_x_grp / r_y_pos 是"**本拍总线上那一拍**的拍号/行号"，
//      按 **I_tvalid** 门控推进、**I_tuser** 把坐标钉回 (0,0) 的下一位（0,0 → 下一拍 1,0）。
//      即：tuser 那一拍 r_x_grp=0 / r_y_pos=0，与 win3x3_96 / alg_color_detect_96 同口径。
//
//  ---------------------------------------------------------------------------
//  【二、存储与地址（单块 ERAM，行主序，无乘法）】
//  ---------------------------------------------------------------------------
//  单块阵列 r_prev_mem[0:CX*CY-1]，每格：NORM=0 存原灰度(8bit 用)、NORM=1 存"灰度−当时亮度水平"的 9bit 补码（2026-10-02）。
//      地址 = cy*CX + cx            （行主序）
//  **地址不用乘法算**：维护 r_row_base = 当前采样行的基址（= cy*CX），
//  每进入一个采样行（y%8==0 的那一行的第 0 拍）加一次 CX：
//      · I_tuser（帧首）⇒ 0
//      · 采样行首拍    ⇒ r_row_base + CX
//  因为"采样行首拍"这一拍自己就要用**新**基址，所以本拍用的是组合出来的
//  w_row_base（见 §4），寄存器在同一个沿装载它 ⇒ 行内每一拍 r_row_base 都等于本行基址。
//
//  ERAM 纪律（S1第二批_接口冻结.md §6，逐条落实）：
//      ① 读地址位宽 = ceil(log2(深度)) = AW，写/读地址寄存器都用 [AW-1:0]；
//      ② 读数据寄存器 r_prev 直连阵列，中间没有任何运算；
//      ③ 写口、读口**各自独立 always 块**（一个写口 + 一个读口，同钟简单双口）；
//      ④ 阵列上**没有复位循环、没有 initial**（加了 TD 会退化成 slice 寄存器）；
//      ⑤ ram_style 用注释形式 `//synthesis ram_style = bram`（安路自家 IP 的写法）；
//      ⑥ 是否真推断出 ERAM 只看 TD report_area 的 #eram / #dram lut，不看日志。
//
//  ---------------------------------------------------------------------------
//  【三、读写冲突规避（本模块的关键时序）】
//  ---------------------------------------------------------------------------
//  采样事件在拍 c：
//      · 拍 c   ：组合出采样地址 w_smp_addr 送**读地址**口 ⇒ 沿 c 把旧值装进 r_prev
//      · 拍 c+1 ：把同一地址送**写地址**口、写数据 = 拍 c 采到的灰度 ⇒ 沿 c+1 写入
//  于是"读同一地址"与"写同一地址"**永远错开一拍**，同拍内不存在读写冲突，
//  不依赖 RAM 原语的 read-during-write 语义（也就不用管它是 read-first 还是 write-first）。
//  采样事件间隔 2 拍 ⇒ 下一次读地址出现在 c+2，与 c+1 的写也不冲突。
//
//  判决在拍 c+1 做：r_prev（旧值）与 r_cur（拍 c 采到的灰度）都在拍 c+1 有效。
//      差分  diff   = (cur >= prev) ? cur - prev : prev - cur      （无符号绝对差）
//      判决  motion = prev_valid && (diff > DIFF_TH)               （DIFF_TH 默认 24）
//  ⚠ NORM=0 时 diff 最大 255（与旧 8bit 式逐位一致）；NORM=1 时两个 ±255 偏移相减最大 510，
//       判决位宽取 10bit，与 {2'b0,DIFF_TH} 比较（2026-10-02 注释随实现更新）。
//
//  ---------------------------------------------------------------------------
//  【四、首帧（"还没写过"）怎么办 —— 与任务书字面不同，理由在这里】
//  ---------------------------------------------------------------------------
//  任务书 2.1 写"首帧存储器内容为复位值 0，自然不产生运动"。这条**在数学上不成立**：
//  若 prev = 0，则 diff = |cur - 0| = cur，灰度 > DIFF_TH 的格子**全都会报运动**
//  （实测 160x64 的第 0 帧：160/160 个格子全部报运动，见 sim/_m6_probe.py），
//  而"整屏运动"恰恰是任务书想避免的现象。
//  同时阵列**不能**给复位值/初值（§二④，给了就没有 ERAM）：仿真里阵列是 X，
//  不处理的话 X 会经 diff → motion → 白点 → O_tdata 一路泄到输出（判据 F 会报 X）。
//
//  本模块的做法（**行为可观测、仿真确定**）：
//      r_mem_full = 0 直到"整块阵列被完整写过一遍"（= 本帧最后一个采样点写完），
//      在此之前 motion 恒 0（`r_mem_full && (diff > DIFF_TH)`，0 与会 X 的操作数
//      按 Verilog 语义结果是 0，X 不会传播）；此后按正常帧差工作。
//      ⇒ 首帧整帧无运动（= "没有可比对象"），从第 2 帧起是真正的相邻帧差。
//  这一条是**有意的口径决定**，不是 hack：真实硬件上电后 ERAM 内容同样不可知，
//  "第一帧不出运动"是唯一有意义的语义。判据侧（check_alg_top_full.py 的 M6 黄金
//  模型）按同一口径实现：第 0 帧运动格子全 0。
//
//  ---------------------------------------------------------------------------
//  【五、延迟（对齐口径，与 alg_top 的 LAT=5 配套）】
//  ---------------------------------------------------------------------------
//  本模块的"拍"以**输入灰度流**为基准（灰度流本身 = 原始 I_tdata 延迟 1 拍）。
//      拍 c   ：采样（本拍 total 线上那一拍就是采样拍）
//      拍 c+1 ：判决
//      拍 c+2 ：O_motion_pix0 装载 ⇒ 端口上有效
//  ⇒ O_motion_pix0 相对**本模块输入**延迟 2 拍，相对**原始 I_tdata** 延迟 3 拍。
//    alg_top 再补 1 拍即到"MUX 输入 = 4 拍"，与其余档位同拍（总延迟 L = 5 拍）。
//  ⚠ 任务书 2.1 的括号里写"模块内部把 I_tdata 打 1 拍来对齐差分结果"：本模块确实把
//    采样值打 1 拍（r_cur），判决就发生在这一拍上（与 r_prev 同拍）；但**端口**延迟
//    是 2 拍 —— 同步读的物理下界：读地址在采样拍发出、读数据下一拍才有效、判决再打
//    一拍。要压成 1 拍只能把读地址提前一拍发（预测下一个采样拍），那会引入跨行/跨帧
//    的地址预测状态机，收益只有 1 拍、风险大得多，故不做。
//
//  ---------------------------------------------------------------------------
//  【六、帧边界态（本帧统计 / bbox）】
//  ---------------------------------------------------------------------------
//  w_frame_start = r_vld1 && r_tu_d1（帧首拍**之后那一拍**，与 alg_color_detect_96 §四同款）：
//      · 把上一帧累加好的 r_cnt / r_min_* / r_max_* 锁进 O_motion_cnt / O_motion_bbox_*
//        （O_motion_valid = 上一帧是否有运动），此后整帧稳定，不撕裂；
//      · 同时把累加器清零，并把**帧首那一个采样点**（格子 (0,0)）计入新帧。
//      两件事同一个沿、非阻塞赋值 ⇒ 锁存读到的是旧累加值，互不干扰。
//  运动统计**不做** window_valid 掩蔽（模块没有掩蔽输入口）：掩蔽是"显示纪律"，
//  alg_top 统一在输出级做一次（与 S1 铁律 2 一致）。所以 bbox 可能包含被掩蔽的
//  格子（x<4 或 y<2 那条带），画框时那条边会被掩蔽掉 —— 这是有意的、与 M5 口径
//  的差异，已在集成验证报告里写明。
//
//  【七、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/
//  #delay；无 latch（组合逻辑全 assign/wire）；一个 always 只干一件事；
//  低有效异步复位（存储器阵列除外，见 §二④）。
//==============================================================================

module alg_framediff_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter [7:0] DIFF_TH = 8'd24,     // 帧差阈值（严格大于才算运动）
    // ★★ 2026-10-02 新增 NORM：亮度归一化（POC 见 workspace\sim\m6_norm_poc.py，台账 10-02）。
    //   问题：AGC/光线让整帧亮度一起漂移，帧差会把漂移判成运动（±12% 漂移+高对比背景
    //         误报 3.2%，仿真实测）。办法：比较之前把"整帧亮度水平"减掉——运动是局部的，
    //         亮度漂移是全局的，减掉全局就只剩局部。
    //   实现（因果流式，只有加法移位，无除法无 DSP）：
    //     r_m_run = 对采样灰度跑 IIR(τ=16 个采样) ≈ 当前帧整帧均值；
    //     阵列存 (灰度 − 写入时刻的 r_m_run)，9bit 补码 —— 上一帧已被它自己那帧的均值归一；
    //     判决 = |(cur − m_now) − 存值|。NORM=0 时存 {1'b0,灰度}、判决通路高位恒 0，
    //     与旧 8bit 绝对差【逐位等价】⇒ 已验证的 M6 口径一个字不变。
    parameter        NORM = 1'b0,   // 逗号：后面还有 parameter DS
    parameter integer DS = 8             // 降采样倍率，必须是 2 的幂（8x8 -> 8）
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [95:0]  I_tdata,      // 灰度流：每像素三字节同值，pix0 = [95:72]
    input  wire         I_tvalid,
    input  wire         I_tuser,      // 帧首拍（本模块的帧基准）
    input  wire         I_tready,     // 直通，不用于反压（C-3）
    output wire         O_tready,
    // ---- 运动点（与"延迟 2 拍的像素流"同拍，见 §五）----
    output reg          O_motion_pix0,
    // ---- 帧级统计 ----
    output wire [31:0]  O_frame_motion_cnt,   // 本帧运动格子数（实时累加）
    output reg  [31:0]  O_motion_cnt,         // 帧边界锁存（上一帧的总数）
    output reg  [10:0]  O_motion_bbox_x0,     // 上一帧运动区域：像素坐标
    output reg  [10:0]  O_motion_bbox_x1,     //   格子坐标 x8（x1/y1 = cx*8+7，不越界）
    output reg  [10:0]  O_motion_bbox_y0,
    output reg  [10:0]  O_motion_bbox_y1,
    output reg          O_motion_valid        // 上一帧是否有运动（cnt != 0）
);

//------------------------------------------------------------------------------
// 0. 常量与 tready 直通
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE = IMG_WIDTH >> 2;             // 1280 -> 320 / 160 -> 40
// ⚠ 拍计数器/行缓冲地址位宽必须**刚好**是 ceil(log2(BEATS_PER_LINE))（冻结文档 §6①）
localparam XW  = $clog2(BEATS_PER_LINE);                // 320 -> 9 / 40 -> 6
localparam CX  = IMG_WIDTH  / 8;                        // 160 / 20（编译期常量，不是电路乘法器）
localparam CY  = IMG_HEIGHT / 8;                        // 90  / 8
localparam DEPTH = CX * CY;                             // 14400 / 160（编译期常量）
// ⚠ AW = ceil(log2(DEPTH))：1280x720 -> 14（2^14=16384 > 14400）、160x64 -> 8（256 > 160）。
//   深度不是 2 的幂是允许的，但地址位宽多给一位 TD 就放弃 ERAM（冻结文档 §6① 的实测）。
localparam AW  = $clog2(DEPTH);
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;     // 319 / 39（行末拍）
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;         // 719 / 63
// 最后一个采样点：最后一个采样行（y = (CY-1)*8）的最后一个偶数拍（x_grp = BPL-2）
localparam [10:0]   LAST_SMP_ROW = (CY - 1) * 8;        // 712 / 56
localparam [10:0]   LAST_SMP_X   = (CX - 1) * 8;        // 1272 / 152（= 4*(BPL-2)）
// 空 bbox 哨兵：min > max（与 alg_color_detect_96 的 BBOX_SENT 同款）
localparam [10:0]   BBOX_SENT = 11'h7FF;
// CX 的 AW 位常量形式（零扩展；避免对 integer 型 localparam 做位选）
localparam [AW-1:0] CX_AW = CX;

assign O_tready = I_tready;                             // C-3：全链路不反压

//------------------------------------------------------------------------------
// 1. 存储阵列（单写口 + 单读口，同钟简单双口）
//    ⚠ 绝不在复位里清零、绝不给 initial（§二④）
//------------------------------------------------------------------------------
reg [8:0] r_prev_mem [0:DEPTH-1];   //synthesis ram_style = bram  ★2026-10-02 8→9bit（NORM 存带符号偏移；
//   深度不变(14400)，9bit×14400 仍是 2 块 BRAM，ERAM 用量与 8bit 相同）

//------------------------------------------------------------------------------
// 2. 寄存器声明
//------------------------------------------------------------------------------
// ---- 2.1 坐标计数器（口径见文件头 §一）----
reg [XW-1:0] r_x_grp;                 // 本拍总线上那一拍的拍号 0..BPL-1
reg [10:0]   r_y_pos;                 // 本拍总线上那一拍的行号 0..IMG_HEIGHT-1
reg [AW-1:0] r_row_base;              // 当前采样行的基址 = cy*CX

// ---- 2.2 采样/判决流水 ----
reg [AW-1:0] r_wr_addr;               // 拍 c 的采样地址（拍 c+1 用作写地址）
reg          r_wr_en;                 // 拍 c 是采样拍 ⇒ 拍 c+1 写
reg [8:0]    r_cur;                   // 拍 c 采到的（归一化）灰度，打 1 拍 ★2026-10-02 8→9bit
reg [8:0]    r_prev;                  // 阵列读数据（直连阵列，无运算）★8→9bit
reg [7:0]    r_m_run;                 // ★★ 2026-10-02 当前帧整帧亮度水平的 IIR 估计（无符号均值）
reg          r_smp_d1;                // "本拍是判决拍"（= 采样拍延迟 1 拍）
reg [10:0]   r_smp_x;                 // 采样点的像素坐标 x = 4*x_grp
reg [10:0]   r_smp_y;                 // 采样点的行号 y

// ---- 2.3 帧边界 ----
reg          r_vld1;                  // I_tvalid 延迟 1 拍（不门控，C-4）
reg          r_tu_d1;                 // I_tuser 延迟 1 拍（按 I_tvalid 门控）
reg          r_mem_full;              // 阵列是否已被完整写过一遍（§四）

// ---- 2.4 帧内累加（min/max/count）----
reg [10:0]   r_min_x, r_max_x;
reg [10:0]   r_min_y, r_max_y;
reg [31:0]   r_cnt;

//------------------------------------------------------------------------------
// 3. 采样判定与组合逻辑
//------------------------------------------------------------------------------
// 采样拍：有效拍 && 拍号为偶 && 行号 %8==0（⇒ pix0 的绝对坐标 = (8*cx, 8*cy)）
wire w_smp = I_tvalid && (r_x_grp[0] == 1'b0) && (r_y_pos[2:0] == 3'd0);

// 采样行首拍（每 8 行的第 0 拍）：本行基址 = 上一采样行基址 + CX；帧首归 0
wire w_smp_row_start = w_smp && (r_x_grp == {XW{1'b0}});
wire [AW-1:0] w_row_base = I_tuser ? {AW{1'b0}}
                         : (w_smp_row_start ? (r_row_base + CX_AW) : r_row_base);

// 采样地址 = 本行基址 + cx（cx = x_grp>>1；只有偶拍会用，此时 x_grp[0]==0）
wire [AW-1:0] w_smp_cx   = {{(AW-XW+1){1'b0}}, r_x_grp[XW-1:1]};
wire [AW-1:0] w_smp_addr = w_row_base + w_smp_cx;

// pix0 的灰度（灰度流三字节同值 ⇒ 取最高字节即可）
wire [7:0] w_gray_p0 = I_tdata[95:88];

// ★★ 2026-10-02 归一化组合件（NORM=0 时 r_m_run 不动、w_wr_val = 原灰度补 0，逐位等价）
wire [7:0] w_m_err_up = (w_gray_p0 > r_m_run) ? (w_gray_p0 - r_m_run) : 8'd0;
wire [7:0] w_m_err_dn = (r_m_run > w_gray_p0) ? (r_m_run - w_gray_p0) : 8'd0;
// ★对抗审查P1-2修正：两方向都用 (err+8)>>4（四舍五入）。可证 stp<=err 恒成立：
//   err>=8 时 (err+8)/16<=err；err<8 时 stp=0。于是 上步 r_m+stp<=gray<=255 不溢出，
//   下步 r_m-stp>=gray>=0 不回绕 —— 旧版下行 (err+63)>>4 在 err=3 时步进 4，
//   r_m_run=3 遇 gray=0（暗场/黑边）直接减穿回绕成 255（审查反例）。
//   代价：|err|<8 时不动 => 均值有 ±7 的死区（本来就是慢速跟踪，可接受）。
wire [8:0] w_m_up9    = {1'b0, w_m_err_up} + 9'd8;
wire [8:0] w_m_dn9    = {1'b0, w_m_err_dn} + 9'd8;
wire [7:0] w_m_stp_up = {3'b0, w_m_up9[8:4]};
wire [7:0] w_m_stp_dn = {3'b0, w_m_dn9[8:4]};
wire [7:0] w_m_run_nx = (w_gray_p0 >= r_m_run) ? (r_m_run + w_m_stp_up)
                                               : (r_m_run - w_m_stp_dn);
wire [8:0] w_gray_nx  = (w_gray_p0 >= r_m_run) ? {1'b0, (w_gray_p0 - r_m_run)}
                                               : (~{1'b0, (r_m_run - w_gray_p0)} + 9'd1);  // 9bit 补码
wire [8:0] w_wr_val   = NORM ? w_gray_nx : {1'b0, w_gray_p0};

// 差分与判决（判决拍 = 采样拍 + 1；r_cur / r_prev 在这一拍同时有效）
// ★★ 2026-10-02：9bit 补码相减 -> 判符号取绝对值（NORM=0 时操作数 bit8 恒 0，数值与旧式逐位一致）。
//   ⚠ 不能再无符号 >= 比较：NORM=1 时 r_cur/r_prev 是有符号偏移量。
wire [9:0] w_d10    = {r_cur[8], r_cur} - {r_prev[8], r_prev};   // ★对抗审查P1-1修正：必须符号扩展。
//   零扩展 {1'b0,x} 只在一侧为负时把 (+5)-(-10)=15 算成 512-15=497 —— 静止场景里灰度恰好
//   跨在亮度水平两侧的格子会全部误报运动（变异用例 tb_m6_norm f8 实测：旧式报 3 格，新式 0）。
wire [9:0] w_diff   = w_d10[9] ? (~w_d10 + 10'd1) : w_d10;
wire       w_motion = r_mem_full && (w_diff > {2'b0, DIFF_TH});

// 帧边界：帧首拍之后那一拍（= 新的这一帧的累加起点，见文件头 §六）
wire w_frame_start = r_vld1 && r_tu_d1;

// "整块阵列已被完整写过一遍"：最后一个采样点写完的那一拍
wire w_last_smp_d = r_smp_d1 && (r_smp_y == LAST_SMP_ROW) && (r_smp_x == LAST_SMP_X);

//------------------------------------------------------------------------------
// 4. 阵列本体：写口 / 读口各自独立 always 块（§二③）
//    没有复位分支、没有 initial。读口和写口**不同拍**（§三），不存在同拍同址冲突。
//------------------------------------------------------------------------------
always @ (posedge I_clk) begin
    if (r_wr_en)
        r_prev_mem[r_wr_addr] <= r_cur;
end

always @ (posedge I_clk) begin
    if (w_smp)
        r_prev <= r_prev_mem[w_smp_addr];
end

//------------------------------------------------------------------------------
// 5. 采样/判决流水寄存器（一个 always 只搬一件东西）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_wr_addr <= {AW{1'b0}};
    else
        r_wr_addr <= w_smp_addr;                 // 非采样拍的地址值无意义（写使能为 0）
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_wr_en <= 1'b0;
    else
        r_wr_en <= w_smp;                        // 采样拍 ⇒ 下一拍写
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cur <= 9'd0;
    else
        r_cur <= w_wr_val;                       // ★2026-10-02 归一化后打 1 拍（NORM=0 即原灰度）
end

// ★★ 2026-10-02 r_m_run：每个采样灰度过一次 IIR（NORM=0 时永不更新，省逻辑）
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_m_run <= 8'd128;
    else if (w_smp && NORM)
        r_m_run <= w_m_run_nx;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_d1 <= 1'b0;
    else
        r_smp_d1 <= w_smp;                       // 判决拍标志
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_x <= 11'd0;
    else
        r_smp_x <= {r_x_grp, 2'b00};             // 采样点像素列 = 4*x_grp（偶拍 ⇒ 8*cx）
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_y <= 11'd0;
    else
        r_smp_y <= r_y_pos;                      // 采样点行号
end

//------------------------------------------------------------------------------
// 6. 坐标推进（win3x3_96 §6 逐字同构：按 I_tvalid 门控 + I_tuser 复位）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin                       // 帧首：本拍坐标就是 (0,0)，下一拍是 (1,0)
            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin
            r_x_grp <= {XW{1'b0}};               // 行末回绕
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 7. 行基址推进（每进入一个采样行 +CX；帧首归 0）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_row_base <= {AW{1'b0}};
    else if (w_smp_row_start)
        r_row_base <= w_row_base;
end

//------------------------------------------------------------------------------
// 8. 帧边界寄存器（C-4 握手延迟 + 存储完整标志）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;                      // 不加 I_tvalid 门控（C-4）
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_tu_d1 <= 1'b0;
    else if (I_tvalid)
        r_tu_d1 <= I_tuser;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_mem_full <= 1'b0;
    else if (w_last_smp_d)
        r_mem_full <= 1'b1;                      // 最后一个采样点判决完 ⇒ 阵列内容已完整
end

//------------------------------------------------------------------------------
// 9. 帧内累加（运动格子数 + bbox，像素坐标）
//    帧首那一拍：清零 + 把帧首采样点（格子 (0,0)）计入；其余判决拍按条件更新。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_x <= BBOX_SENT;
    else if (w_frame_start)
        r_min_x <= (r_smp_d1 && w_motion) ? r_smp_x : BBOX_SENT;
    else if (r_smp_d1 && w_motion && (r_smp_x < r_min_x))
        r_min_x <= r_smp_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_x <= 11'd0;
    else if (w_frame_start)
        r_max_x <= (r_smp_d1 && w_motion) ? (r_smp_x + 11'd7) : 11'd0;
    else if (r_smp_d1 && w_motion && ((r_smp_x + 11'd7) > r_max_x))
        r_max_x <= r_smp_x + 11'd7;              // 格子右下角像素坐标 = cx*8+7 <= W-1
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_y <= BBOX_SENT;
    else if (w_frame_start)
        r_min_y <= (r_smp_d1 && w_motion) ? r_smp_y : BBOX_SENT;
    else if (r_smp_d1 && w_motion && (r_smp_y < r_min_y))
        r_min_y <= r_smp_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_y <= 11'd0;
    else if (w_frame_start)
        r_max_y <= (r_smp_d1 && w_motion) ? (r_smp_y + 11'd7) : 11'd0;
    else if (r_smp_d1 && w_motion && ((r_smp_y + 11'd7) > r_max_y))
        r_max_y <= r_smp_y + 11'd7;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt <= 32'd0;
    else if (w_frame_start)
        r_cnt <= (r_smp_d1 && w_motion) ? 32'd1 : 32'd0;
    else if (r_smp_d1 && w_motion)
        r_cnt <= r_cnt + 32'd1;
end

assign O_frame_motion_cnt = r_cnt;               // 本帧实时累计值

//------------------------------------------------------------------------------
// 10. 输出级
//     O_motion_pix0：判决结果打 1 拍（= 采样拍 + 2，见 §五）
//     O_motion_*   ：帧边界锁存（§六），整帧稳定
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_pix0 <= 1'b0;
    else
        O_motion_pix0 <= r_smp_d1 && w_motion;    // 非判决拍恒 0（r_smp_d1=0）
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_cnt <= 32'd0;
    else if (w_frame_start)
        O_motion_cnt <= r_cnt;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_x0 <= BBOX_SENT;
    else if (w_frame_start)
        O_motion_bbox_x0 <= r_min_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_x1 <= 11'd0;
    else if (w_frame_start)
        O_motion_bbox_x1 <= r_max_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_y0 <= BBOX_SENT;
    else if (w_frame_start)
        O_motion_bbox_y0 <= r_min_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_bbox_y1 <= 11'd0;
    else if (w_frame_start)
        O_motion_bbox_y1 <= r_max_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_motion_valid <= 1'b0;
    else if (w_frame_start)
        O_motion_valid <= (r_cnt != 32'd0);       // 非阻塞 ⇒ 读到的是上一帧的总数
end

//------------------------------------------------------------------------------
// 11. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//     被**有意省略**的是阵列 r_prev_mem 与读数据寄存器 r_prev（§二④）：
//     · 阵列不能有复位/初值（否则退化成 slice 寄存器，冻结文档 §6④）；
//     · r_prev 直接来自阵列，给它初值也改不了"阵列本身是 X"；留着 X 反而能证明
//       §四的 r_mem_full 确实把未初始化内容压住了（M6 判据 F 会盯这件事）。
//------------------------------------------------------------------------------
initial begin
    r_x_grp       = {XW{1'b0}};
    r_y_pos       = 11'd0;
    r_row_base    = {AW{1'b0}};
    r_wr_addr     = {AW{1'b0}};
    r_wr_en       = 1'b0;
    r_cur         = 9'd0;
    r_m_run       = 8'd128;
    r_smp_d1      = 1'b0;
    r_smp_x       = 11'd0;
    r_smp_y       = 11'd0;
    r_vld1        = 1'b0;
    r_tu_d1       = 1'b0;
    r_mem_full    = 1'b0;
    r_min_x       = BBOX_SENT;
    r_max_x       = 11'd0;
    r_min_y       = BBOX_SENT;
    r_max_y       = 11'd0;
    r_cnt         = 32'd0;
    O_motion_pix0 = 1'b0;
    O_motion_cnt  = 32'd0;
    O_motion_bbox_x0 = BBOX_SENT;
    O_motion_bbox_x1 = 11'd0;
    O_motion_bbox_y0 = BBOX_SENT;
    O_motion_bbox_y1 = 11'd0;
    O_motion_valid   = 1'b0;
end

endmodule
