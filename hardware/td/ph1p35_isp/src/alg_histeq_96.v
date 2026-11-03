//==============================================================================
// 文件名   : alg_histeq_96.v
// 模块名   : alg_histeq_96
// 日期     : 2026-09-17
// 版本     : v1.1
// 描述     : 96-bit 算法通道 · M6 直方图均衡（比赛进阶要求 2.5(5)「图像质量自动调节」）
//            AE/AWB 是厂商 IP 提供的，本模块补齐缺的那一块：逐通道直方图均衡。
//
//  ---------------------------------------------------------------------------
//  【一、功能与口径（这一节就是合同，验证判据按它写，不按实现写）】
//  ---------------------------------------------------------------------------
//  1) 逐通道（R/G/B 各 256 bin）统计直方图 → 累积分布 CDF → 映射表 → 逐像素查表。
//  2) **统计抽样口径**：每 4 个「有效拍」只统计 1 拍，且只统计该拍的 pix0（行内最左像素）。
//     · 相位计数器 r_smp_ph 按 I_tvalid 门控、在 I_tuser 拍复位为 0（tuser 拍 = 相位 0）；
//       采样条件 = `I_tvalid && (I_tuser || r_smp_ph == 0)`。
//       **除 I_tvalid 与相位外不加任何门控**（不加 window_valid、不加行号、不加帧状态）。
//     · 1280×720 时抽到的是每行第 0,16,32,...,1264 列（每行 80 个样本）：
//         SAMPLES_PER_LINE  = BEATS_PER_LINE / 4 = 320/4 = 80
//         SAMPLES_PER_FRAME = 80 * IMG_HEIGHT  = 80*720 = 57,600
//     · 前提：**IMG_WIDTH 必须是 16 的倍数**（⇒ BEATS_PER_LINE % 4 == 0），否则行内采样相位
//       会逐行漂移，一帧样本数不再是上面的公式。
//  3) **直方图存储**：{ch[1:0], bin[7:0]} 共 768 个地址 × 17 bit
//     （16 bit 计数 + 1 bit「本轮有效」tag），装在**一块 ERAM** 里（768*17 = 13,056 bit ≤ 20 kbit）。
//     · 地址位宽 AW = $clog2(768) = 10，**刚好**等于阵列真实深度的位宽 —— S1 冻结文档 §6 第 1 条
//       实测过：读地址多给一位 TD 就拒绝推断 ERAM（320 深给 11 位 → #eram 0 / #dram lut 512）。
//     · 阵列上**没有复位循环、没有 initial**（同一节第 4 条），所以复位后内容在仿真里是 X、
//       在真机里是随机值。tag 位就是为这件事准备的：
//         RMW 时若 tag 不是 1，计数**直接写成 1**（而不是 X+1 / 随机值+1）；
//         扫描时 tag 不是 1 的 bin 计数按 0 处理。
//       ⇒ 「复位后第一帧的直方图」确定且正确，**不需要任何上电清阵列的合同**，接上流就能用。
//     · 扫描时「读一个 bin 顺手把该 bin 写 0」（read-and-clear），扫完阵列全 0，
//       下一帧直接累加 ⇒ 也不需要独立的清零过程。
//     ⚠ **tag 判定必须放在时钟块里（v1.1 修正，仿真实测踩过）**：
//       最初写成 `always @(*) if (tag==1) ... else ...`，指望 "if(X) 走 else" 来吃掉阵列的 X。
//       语义上没错（ModelSim 实测 if(X) 确实走 else，三目才会按位合并出 X），但
//       **`always @(*)` 是事件驱动：输入恒为 X 时它根本不重新求值**（X→X 不产生事件），
//       于是判决寄存器一直停在初值 X，X 照样进阵列。改成 **posedge 时钟块里的 if** 之后，
//       每个时钟沿都重新判决 ⇒ 既 X 安全又与实现无关（时钟沿必然发生）。
//  4) **归一化**：K = (255 * 65536) / SAMPLES_PER_FRAME 是**编译期常数**：
//         1280×720：K = floor(16711680 / 57600) = 290  （290 = 256+32+2 ⇒ 两个加法器，零 DSP）
//         map[bin] = (cdf[bin] * K) >> 16，cdf 含当前 bin。**没有运行期除法、没有 DSP**。
//     ⚠ 口径后果（写进判据，不是 bug）：满直方图时 cdf = 57600
//       ⇒ map = floor(57600*290 / 65536) = floor(254.88) = **254**。
//       即 floor 归一化下最大映射值是 254 而不是 255；低对比度输入被铺开到 0..254。
//       参考模型 sim\ref_histeq.py 用**同一个整数公式**，逐比特一致。
//  5) **映射表 = 12 份 LUTRAM 副本**（4 个像素 lane × R/G/B）：每拍要查 12 次，单块 RAM 做不到。
//       每份深度 256、宽 8；第 i 份负责 I_tdata 的第 i 个字节（i=0 是最高的 [95:88]，与像素 lane
//       的位序逐位对应），查表结果按同样位序拼回 96 bit ⇒ 不存在「拼错字节序」的空间。
//       写口 12 份共用同一地址/数据，同一通道的 4 份同时写（生成映射表时 12 份写同一个值）。
//       属性写 distributed/dram 是为了**保证不被推断成 ERAM**
//       （12 份 256×8 共 24 kbit，不写属性综合器完全可能把它们塞进 ERAM 或退成寄存器）。
//       ⚠ 本条**无法在本任务内验证**（不许跑 TD），交付报告「未验证风险」里已列明。
//  6) **帧边界 ping-pong（滞后 1 帧）**：第 f 帧用「第 f-1 帧统计出来的表」，第 0 帧用恒等（= 旁路）。
//     · 触发点 = 本帧最后一个有效拍（`I_tvalid && I_tlast && r_y_pos == IMG_HEIGHT-1 && !I_tuser`），
//       此后是帧消隐，扫描引擎用 768×3 + 收尾 ≈ 2310 拍把 CDF/映射表算完并重写映射表；
//       下一次 tuser 起新表生效 —— 帧内**绝不**改表，所以不会撕裂。
//     · **接口合同（TB 里是断言）**：帧末有效拍 → 下一帧 tuser 之间必须有 ≥ 2600 个 I_clk。
//       真实链路每行行末都有行消隐、帧间有几十万拍消隐（见交付报告，余量 2 个数量级）；
//       违反合同的后果按下面的「仲裁」执行 —— 能跑、不产生 X，但不是正常口径：
//       扫描期间到来的样本被丢弃（统计让位给扫描），映射表可能只写了一半。
//  7) **使能 I_en**：只控制输出选择器，**不影响统计与制表**（关着也在统计，打开立刻可用）。
//     · I_en=0 → O_tdata **逐比特** = I_tdata 延迟 2 拍。
//       本模块**不**在无效拍清零（与 alg_binarize 的 C-4 不同，理由见 §二），
//       于是「逐比特旁路」这条判据可以在**每一个**时钟沿上比对，比「只在有效拍比」强。
//     · I_en=1 且还没有可用映射表（复位后第 0 帧）→ 同样走旁路 ⇒ 第 0 帧输出 = 输入（恒等表）。
//
//  ---------------------------------------------------------------------------
//  【二、延迟 = 2 拍（TB 用独立移存器逐拍钉死，不读 DUT 内部）】
//  ---------------------------------------------------------------------------
//   第 1 级（T → T+1）：r_in1 ← I_tdata；r_vld1/r_tlast1/r_tuser1 ← I_tvalid/I_tlast/I_tuser；
//                       r_en1 ← I_en；r_mapok1 ←「已有可用映射表」
//   第 2 级（T+1 → T+2）：O_tdata ← (r_en1 && r_mapok1) ? 映射表读回值 : r_in1
//                         O_tvalid ← r_vld1；O_tlast/O_tuser ← r_vld1 && r_tlast1/r_tuser1
//   · 映射表（LUTRAM）是同步读：T 拍给地址（= I_tdata 的 12 个字节），T+1 拍数据在 r_map_q 上，
//     与第 2 级同沿装载 ⇒ 查表与旁路**同为 2 拍**，切使能不改变延迟。
//   · r_vld1 只是把 I_tvalid 打拍（不门控、不丢尾拍）⇒ 输出有效拍数 == 输入有效拍数。
//   · 为什么无效拍不清零：清零会让「旁路逐比特相等」只在有效拍成立，判据就弱一档；
//     而本模块所有状态都有确定初值（阵列靠 tag 自初始化），不存在 X 外泄，
//     所以敢让无效拍也原样透传。若将来 alg_top 要求与其它档位一致（C-4 清零），
//     在第 2 级加一个 `else O_tdata <= 96'd0;` 即可，不影响任何其它口径。
//
//  ---------------------------------------------------------------------------
//  【三、累加器流水（4 拍预算，判定放在寄存器里）】
//  ---------------------------------------------------------------------------
//   采样拍 T 起：T 发 ch0 读、T+1 发 ch1 读、T+2 发 ch2 读；
//   读回数据在下一拍进判定寄存器（时钟块里的 tag if/else），再下一拍写回：
//        T+2 写 ch0、T+3 写 ch1、T+4 写 ch2
//   下一个采样拍最早在 T+4（每 4 个有效拍 1 个样本，最快也是 4 拍以后），
//   那一拍同时发 ch0 读 + 写上一轮的 ch2 —— 地址里含通道号，永不撞同一地址。
//
//  ---------------------------------------------------------------------------
//  【四、资源估算（本模块**无法**在 TD 上实测，交付报告里逐条列为未验证风险）】
//  ---------------------------------------------------------------------------
//   · LUT6：12 × 256×8 LUTRAM（≈32 LUT6/份 ⇒ ≈384）+ 数据通路/加法/比较 ≈ 350 ⇒ 约 750
//   · ERAM：1 块（768×17 = 13,056 bit；若 TD 按 512 深分块，则可能是 2 块 —— 未验证）
//   · DSP ：0（常数乘法综合成移位加法；全程无运行期除法、无跨时钟、无厂商 IP）
//   · DFF ：96（映射表读回）+ 96（输出）+ 96（旁路）+ 少量控制 ≈ 300
//
//  ---------------------------------------------------------------------------
//  【五、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/#delay；
//  无用户 latch；无组合 always 块（组合逻辑 100% 是 assign/wire）；内部寄存器 r_ 前缀、
//  内部线网 w_ 前缀；端口保持 I_/O_。
//==============================================================================

module alg_histeq_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [95:0]  I_tdata,     // 4 像素 × RGB888，pix0（最左）在 [95:72]
    input  wire         I_tvalid,
    input  wire         I_tlast,     // 行末拍
    input  wire         I_tuser,     // 帧首拍（1 拍脉冲）
    input  wire         I_tready,
    input  wire         I_en,        // 使能；0 = 逐比特旁路（默认关）
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

//------------------------------------------------------------------------------
// 0. 编译期常量
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE    = IMG_WIDTH >> 2;                    // 1280 → 320
localparam XW                = $clog2(BEATS_PER_LINE);            // 320 → 9
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE[XW-1:0] - 1'b1;    // 319
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;                   // 719
localparam SAMPLES_PER_FRAME = (BEATS_PER_LINE >> 2) * IMG_HEIGHT;// 80*720 = 57,600
localparam [31:0]   K_CONST   = (32'd255 * 32'd65536) / SAMPLES_PER_FRAME;  // 16,711,680/57,600 = 290
localparam HIST_DEPTH        = 768;                               // 3 通道 × 256 bin
localparam AW                = $clog2(HIST_DEPTH);                // 768 → 10（刚好等于深度位宽）

localparam [1:0] S_IDLE  = 2'd0;   // 扫描引擎空闲
localparam [1:0] S_RUN   = 2'd1;   // 扫描中（ph = 0 发读 / 1 锁判定 / 2 累加+写回+写映射表）
localparam [1:0] S_FLUSH = 2'd2;   // 扫描收尾（置 map_ok）

assign O_tready = I_tready;

//------------------------------------------------------------------------------
// 1. 输入拍拆字节
//    统计只需要 pix0 的 RGB；查表时 12 个字节各自当地址用（见 §6）。
//------------------------------------------------------------------------------
wire [7:0] w_pix0_r = I_tdata[95:88];      // pix0 = 行内最左像素
wire [7:0] w_pix0_g = I_tdata[87:80];
wire [7:0] w_pix0_b = I_tdata[79:72];

//------------------------------------------------------------------------------
// 2. 采样相位 + 空间计数器（推进/复位口径照抄 win3x3_96.v §6：按 I_tvalid 门控、tuser 复位）
//    本模块是**逐点**算子，没有 3×3 窗口，所以不需要 win3x3 那套空间掩蔽；
//    这里照抄的是「计数器怎么走」，不是「掩蔽怎么写」。
//------------------------------------------------------------------------------
reg [1:0]    r_smp_ph;      // 本拍相位：tuser 拍 = 0，其后每个有效拍 +1（模 4）
reg [XW-1:0] r_x_grp;       // 行内拍号 0..319（当前的拍，不是下一拍）
reg [10:0]   r_y_pos;       // 行号 0..719

// 采样判据：**只看 I_tvalid 与相位**，不做任何其它门控（合同第 2 条）
wire w_smp_now = I_tvalid && (I_tuser || (r_smp_ph == 2'd0));

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_smp_ph <= 2'd0;
    else if (I_tvalid) begin
        if (I_tuser)                       // 帧首拍定义成相位 0
            r_smp_ph <= 2'd1;
        else if (r_smp_ph == 2'd3)
            r_smp_ph <= 2'd0;
        else
            r_smp_ph <= r_smp_ph + 2'd1;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin                       // 帧首：本拍是第 0 拍，下一拍是第 1 拍
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
// 3. 直方图 ERAM（768 × 17）
//    字格式：{tag[16], count[15:0]}
//      tag = 1 → count 是本轮（本帧）的有效计数；tag != 1（含 X）→ 本轮没写过，按 0 算。
//    端口：1 个写口 + 1 个同步读口（与 winx3x3_96 的行缓存同一写法）。
//    ⚠ 阵列上**没有复位、没有 initial**（S0-02 C-6 / S1 §6 第 4 条）。
//------------------------------------------------------------------------------
reg [16:0] r_hist_mem [0:HIST_DEPTH-1];   //synthesis ram_style = bram
reg [16:0] r_hist_q;                      // 同步读数据（直连阵列，中间不做任何运算）

//------------------------------------------------------------------------------
// 3.5 扫描引擎的状态与触发（**声明放这里**：累加器要用 w_sc_run 做仲裁，
//      Verilog 的标识符必须先声明后使用）
//------------------------------------------------------------------------------
reg [1:0]  r_sc_state;
reg [1:0]  r_sc_ph;         // 0 = 发读地址，1 = 锁计数判定，2 = 累加 CDF + 写回 0 + 写映射表
reg [1:0]  r_sc_ch;         // 当前通道 0/1/2
reg [8:0]  r_sc_bin;        // 当前 bin 0..255（9 位便于判 255）
reg [AW-1:0] r_sc_a;        // 本 bin 的地址（{ch, bin}），写回/写映射表都用它
reg [15:0] r_sc_cnt;        // 锁定的 bin 计数（clocked ⇒ X 安全且仿真可靠，见文件头 §一.3）
reg [16:0] r_cdf;           // 本通道累积分布（<= 57600，17 位宽裕）
reg        r_map_ok;        // 已经做出过一张完整映射表（在此之前输出走旁路）

wire w_sc_run    = (r_sc_state != S_IDLE);
wire w_frame_end = I_tvalid && I_tlast && (r_y_pos == LAST_ROW) && (!I_tuser);
// ⚠ w_sc_start 的定义**下移到 §4 累加器声明之后**（2026-09-20 修）：
//   它现在还要读 r_acc_rd / r_dec_v / r_rd_v 判断"流水是否排空"，
//   而本项目的规矩是标识符必须先声明后使用（§三 3.5 那条注释就是为这事写的）。

//------------------------------------------------------------------------------
// 4. 累加器 RMW 流水：一个样本 3 个通道，4 拍预算内做完（时序见文件头 §三）
//    · r_acc_rd：0 = 本拍是采样拍（发 ch0 读），1 = 发 ch1 读，2 = 发 ch2 读，3 = 空闲
//    · r_ra_s0/r_ra_s1：读地址流水；r_ra_s1 正好是"该写回"的那个地址
//    · r_rd_v：上一拍发过读 ⇒ 本拍 r_hist_q 对应它，可以判决
//    · r_dec_data/r_dec_v：判决结果与"本拍写回"的有效位
//------------------------------------------------------------------------------
reg [1:0]    r_acc_rd;
reg [AW-1:0] r_acc_a1;      // 采样拍锁存的 ch1/ch2 地址
reg [AW-1:0] r_acc_a2;
reg [AW-1:0] r_ra_s0;
reg [AW-1:0] r_ra_s1;
reg          r_rd_v;
reg          r_dec_v;
reg [16:0]   r_dec_data;

wire [AW-1:0] w_smp_a0 = {2'd0, w_pix0_r};        // 采样拍组合发出的 ch0 读地址
// 本拍是否"发出了一个有效读"：
//   · r_acc_rd = 1/2  → 正在发 ch1/ch2 读
//   · 采样拍（r_acc_rd = 3）→ 本拍组合发出 ch0 读
// 注意采样拍这一条必须算进来，否则读地址流水会漏掉 ch0（v1.1 修正）。
wire          w_acc_sample  = w_smp_now && (!w_sc_run) && (r_acc_rd == 2'd3);
wire          w_acc_reading = ((r_acc_rd == 2'd1) || (r_acc_rd == 2'd2) || w_acc_sample)
                              && (!w_sc_run);

// ---------------------------------------------------------------------------
// w_sc_start：帧末脉冲**挂起**，等累加流水排空再启动扫描（2026-09-20 修，第二个 bug）
//
//   为什么必须等：帧末最后一个采样的**最后一个通道（B）**写回，落在帧结束之后 1 拍；
//   而写口仲裁是"扫描优先"（§6 的 w_hist_waddr = w_sc_run ? r_sc_a : w_acc_waddr），
//   于是那一笔被扫描抢掉 ⇒ **B 通道每帧少 1 个样本**。
//   实测反推（8 场景回归）：const 场景 B 的 cdf = 31（应 32）、lowc 场景 30（应 31），
//   与 map 实测值 f7/ff、ef/f7 逐位吻合；R/G 两个通道全对。
//   （原注释写"扫描抢占：流水立刻收摊（合同内不会发生）"，是把"帧消隐够长"
//     当成了"帧边界不撞"——实际撞点就在帧末那一拍本身。）
//   消隐合同 ≥2600 拍，多等这几拍无影响。
// ---------------------------------------------------------------------------
reg r_sc_pend;
// ⚠ 顺序有讲究：两个 wire 必须在 always 块**之前**声明 —— 那个 always 块里
//   要用 w_sc_start 清 r_sc_pend，而 r_sc_pend 又是 w_sc_start 的输入。
//   （vlog-2730 实测踩过：块写在声明前就编译不过。）
wire w_acc_drained = (r_acc_rd == 2'd3) && (!r_dec_v) && (!r_rd_v);
wire w_sc_start    = r_sc_pend && w_acc_drained && (!w_sc_run);

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_sc_pend <= 1'b0;
    else if (w_sc_start)
        r_sc_pend <= 1'b0;
    else if (w_frame_end && (!w_sc_run))
        r_sc_pend <= 1'b1;
end

// 本拍发出的读地址：扫描优先；否则按累加器相位给
wire [AW-1:0] w_acc_raddr = (r_acc_rd == 2'd1) ? r_acc_a1 :
                            (r_acc_rd == 2'd2) ? r_acc_a2 : w_smp_a0;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_acc_rd <= 2'd3;
    else if (w_sc_start)
        r_acc_rd <= 2'd3;                         // 扫描抢占：流水立刻收摊（合同内不会发生）
    else if (r_acc_rd == 2'd3) begin
        if (w_smp_now && (!w_sc_run))
            r_acc_rd <= 2'd1;
    end else begin
        r_acc_rd <= r_acc_rd + 2'd1;              // 1→2→3
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_acc_a1 <= {AW{1'b0}};
        r_acc_a2 <= {AW{1'b0}};
    end else if (w_smp_now && (!w_sc_run) && (r_acc_rd == 2'd3)) begin
        r_acc_a1 <= {2'd1, w_pix0_g};
        r_acc_a2 <= {2'd2, w_pix0_b};
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_ra_s0 <= {AW{1'b0}};
        r_ra_s1 <= {AW{1'b0}};
    end else begin
        if (w_acc_reading)
            r_ra_s0 <= w_acc_raddr;
        r_ra_s1 <= r_ra_s0;
    end
end

// 4.1 计数判决（**时钟块里的 if/else**）：tag 是 1 才累加，否则从 1 起。
//     X（阵列没写过）时 if 条件为 X ⇒ 走 else ⇒ 写成确定的 1（不会把 X 写进阵列）。
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_dec_data <= 17'h1_0000;
    else if (r_rd_v) begin
        if (r_hist_q[16] == 1'b1)
            r_dec_data <= { 1'b1, r_hist_q[15:0] + 16'd1 };
        else
            r_dec_data <= { 1'b1, 16'd1 };
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_rd_v <= 1'b0;
    else
        r_rd_v <= w_acc_reading;                  // 本拍发的读，下一拍数据有效
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_dec_v <= 1'b0;
    else if (w_sc_start)
        r_dec_v <= 1'b0;
    else
        r_dec_v <= r_rd_v;                        // 判决晚一拍落地 ⇒ 写回
end

// 累加器的写口
wire          w_acc_we    = r_dec_v && (!w_sc_run);
wire [AW-1:0] w_acc_waddr = r_ra_s1;

//------------------------------------------------------------------------------
// 5. 扫描引擎本体：帧末触发，把 768 个 bin 扫一遍
//    ph=0：发读地址 {ch,bin}（同步读，下一拍出数据）
//    ph=1：锁计数判定（tag 不是 1 按 0 算）
//    ph=2：CDF += 计数；把该 bin 写 0（read-and-clear）；把 map[bin] 写进 12 份映射表
//    每个 bin 3 拍 ⇒ 768*3 + 收尾 ≈ 2310 拍，帧消隐里做，慢无所谓。
//------------------------------------------------------------------------------
// ph=0 读"本 bin"；ph=1/2 把读地址挪到"下一个 bin"——避免同一拍对同一地址又读又写
// （ph=2 的读数据本来就不用了；挪开之后读写地址永远不同，TD 侧语义最干净）。
wire [AW-1:0] w_sc_raddr = {r_sc_ch, (r_sc_ph == 2'd0) ? r_sc_bin[7:0]
                                                     : (r_sc_bin[7:0] + 8'd1)};
wire          w_sc_rd    = (r_sc_state == S_RUN) && (r_sc_ph == 2'd0);
wire          w_sc_proc  = (r_sc_state == S_RUN) && (r_sc_ph == 2'd2);
// 2026-09-20 修：一个通道扫完（最后一个 bin 处理完、且还没到最后一个通道）→ 换通道。
//   换通道时 **CDF 必须清零** —— 它是"本通道"的累积分布（见 §三 与 r_cdf 的声明注释）。
//   原先只在整轮扫描开始时清（w_sc_start），换通道没清，于是 ch1/ch2 接着上一通道的
//   终值往上加，map 立刻超过 255 被钳到 0xFF。实测症状（8 场景回归）：
//     R 通道逐像素全对，G/B 整片 0xFF
//     lowc    : got=07ffff07ffff... exp=070707...
//     uniform : got=00ffff00ffff... exp=000000...
wire          w_sc_ch_adv = (r_sc_state == S_RUN) && (r_sc_ph == 2'd2) &&
                            (r_sc_bin == 9'd255) && (r_sc_ch != 2'd2);

// CDF 与映射值（全部由寄存器算出来，路径短且无 X）
wire [16:0] w_cdf_new  = r_cdf + {1'b0, r_sc_cnt};
wire [31:0] w_map_prod = w_cdf_new * K_CONST;             // 常数乘法 ⇒ 移位加法，零 DSP
wire [7:0]  w_map_val  = (w_map_prod[31:16] > 16'd255) ? 8'hFF : w_map_prod[23:16];

// 映射表写口（12 份副本共用同一地址/数据；同一通道的 4 份同时写）
wire        w_map_we    = w_sc_proc;
wire [7:0]  w_map_waddr = r_sc_a[7:0];
wire [7:0]  w_map_wdata = w_map_val;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_sc_a <= {AW{1'b0}};
    else if (w_sc_rd)
        r_sc_a <= w_sc_raddr;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_sc_cnt <= 16'd0;
    else if ((r_sc_state == S_RUN) && (r_sc_ph == 2'd1)) begin
        if (r_hist_q[16] == 1'b1)
            r_sc_cnt <= r_hist_q[15:0];
        else
            r_sc_cnt <= 16'd0;                    // 本轮没写过（含 X）⇒ 按 0 算
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cdf <= 17'd0;
    else if (w_sc_start || w_sc_ch_adv)
        r_cdf <= 17'd0;
    else if (w_sc_proc)
        r_cdf <= w_cdf_new;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_sc_state <= S_IDLE;
        r_sc_ph    <= 2'd0;
        r_sc_ch    <= 2'd0;
        r_sc_bin   <= 9'd0;
        r_map_ok   <= 1'b0;
    end else if (w_sc_start) begin
        r_sc_state <= S_RUN;
        r_sc_ph    <= 2'd0;
        r_sc_ch    <= 2'd0;
        r_sc_bin   <= 9'd0;
    end else if (r_sc_state == S_RUN) begin
        if (r_sc_ph == 2'd2) begin
            if (r_sc_bin == 9'd255) begin
                if (r_sc_ch == 2'd2) begin
                    r_sc_state <= S_FLUSH;        // 最后一个 bin 处理完 → 收尾
                    r_sc_ph    <= 2'd0;
                end else begin
                    r_sc_ch  <= r_sc_ch + 2'd1;
                    r_sc_bin <= 9'd0;
                    r_sc_ph  <= 2'd0;
                end
            end else begin
                r_sc_bin <= r_sc_bin + 9'd1;
                r_sc_ph  <= 2'd0;
            end
        end else begin
            r_sc_ph <= r_sc_ph + 2'd1;
        end
    end else if (r_sc_state == S_FLUSH) begin
        r_sc_state <= S_IDLE;
        r_map_ok   <= 1'b1;                       // 完整映射表就位，下一帧起生效
    end
end

//------------------------------------------------------------------------------
// 6. 直方图 ERAM 的读写（写口：扫描优先；读口：同步读，数据寄存器直连阵列）
//------------------------------------------------------------------------------
wire          w_hist_we    = w_sc_run ? w_sc_proc : w_acc_we;
wire [AW-1:0] w_hist_waddr = w_sc_run ? r_sc_a     : w_acc_waddr;
wire [16:0]   w_hist_wdata = w_sc_run ? 17'd0      : r_dec_data;
wire [AW-1:0] w_hist_raddr = w_sc_run ? w_sc_raddr : w_acc_raddr;

always @(posedge I_clk) begin
    if (w_hist_we)
        r_hist_mem[w_hist_waddr] <= w_hist_wdata;
    r_hist_q <= r_hist_mem[w_hist_raddr];
end

//------------------------------------------------------------------------------
// 7. 映射表：12 份分布式 RAM 副本（256 × 8）
//    第 gi 份负责 I_tdata 的第 gi 个字节（gi=0 是 [95:88] = lane0 的 R）：
//      字节 → 通道 = gi % 3（0=R,1=G,2=B），lane = gi / 3
//    读：地址 = 该字节本身；写：只有 (gi % 3) == 当前扫描通道 的 4 份同时写。
//    属性写三种形式，目的只有一个：**别让综合器把这 12 份 256×8 塞进 ERAM**：
//      · (* ram_style = "distributed" *) / (* syn_ramstyle = "distributed" *)：通用工具链写法；
//      · //synthesis ram_style = dram ：安路 TD 的**注释**形式，且 dram 才是 TD 合法值
//        （S1 冻结文档 §6 第 5 条：TD 合法值只有 none/dram/bram/bram_144k，
//         官方例程里的 "block" 不在表内，TD 报 SYN-5041 后回退 AUTO）。
//      ⚠ 本任务不许跑 TD ⇒ 属性是否被 TD 接受**未经验证**，已列进交付报告的风险清单。
//------------------------------------------------------------------------------
reg [95:0] r_map_q;                     // 12 份副本的读回值，位序与 I_tdata 逐位对应

genvar gi;
generate
    for (gi = 0; gi < 12; gi = gi + 1) begin : g_map
        wire [7:0] w_rd_addr = I_tdata[95 - 8*gi -: 8];
        (* ram_style = "distributed", syn_ramstyle = "distributed" *)
        reg [7:0] r_map_mem [0:255];   //synthesis ram_style = dram
        always @(posedge I_clk) begin
            if (w_map_we && ((gi % 3) == r_sc_ch[1:0]))
                r_map_mem[w_map_waddr] <= w_map_wdata;
            r_map_q[95 - 8*gi -: 8] <= r_map_mem[w_rd_addr];
        end
    end
endgenerate

//------------------------------------------------------------------------------
// 8. 输出级：第 1 级打拍 + 第 2 级装载 ⇒ 总延迟 2 拍
//    旁路路径只有 r_in1 + O_tdata 两级寄存器：
//      第 1 级：r_in1  ← I_tdata(T)
//      第 2 级：O_tdata ← r_in1（此刻 r_in1 正是 I_tdata(T)）⇒ O_tdata(T+2) = I_tdata(T)
//    查表路径：T 拍给地址 → T+1 拍 r_map_q 有效 → T+2 拍同沿装载 ⇒ 同样是 2 拍。
//------------------------------------------------------------------------------
reg [95:0] r_in1;
reg        r_vld1;
reg        r_tlast1;
reg        r_tuser1;
reg        r_en1;
reg        r_mapok1;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_in1 <= 96'd0;
    else
        r_in1 <= I_tdata;                  // 不门控：无效拍也原样透传（见文件头 §二）
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;                // = I_tvalid 延迟 1 拍（不门控，不丢尾拍）
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tlast1 <= 1'b0;
        r_tuser1 <= 1'b0;
    end else begin
        r_tlast1 <= I_tlast;
        r_tuser1 <= I_tuser;
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_en1 <= 1'b0;
    else
        r_en1 <= I_en;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_mapok1 <= 1'b0;
    else
        r_mapok1 <= r_map_ok;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_en1 && r_mapok1)
        O_tdata <= r_map_q;                // 查表结果（同步读的读回值，同为 2 拍）
    else
        O_tdata <= r_in1;                  // 旁路：逐比特 = I_tdata 延迟 2 拍
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld1;                // = I_tvalid 延迟 2 拍
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= r_vld1 && r_tlast1;
        O_tuser <= r_vld1 && r_tuser1;
    end
end

//------------------------------------------------------------------------------
// 9. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//    被**有意省略**的只有直方图阵列 r_hist_mem 与 12 份映射表阵列：
//      · 阵列不能有复位/初值（否则 TD 不会推断成 RAM，S0-02 C-6）；
//      · 直方图靠 tag 位自初始化（§一.3），映射表靠 r_map_ok=0 时的旁路屏蔽，
//        所以阵列里的 X 永远不会泄漏到输出 —— 仿真里直接可验。
//------------------------------------------------------------------------------
initial begin
    r_smp_ph   = 2'd0;
    r_x_grp    = {XW{1'b0}};
    r_y_pos    = 11'd0;
    r_acc_rd   = 2'd3;
    r_acc_a1   = {AW{1'b0}};
    r_acc_a2   = {AW{1'b0}};
    r_ra_s0    = {AW{1'b0}};
    r_ra_s1    = {AW{1'b0}};
    r_rd_v     = 1'b0;
    r_dec_v    = 1'b0;
    r_sc_pend  = 1'b0;              // 2026-09-20 新增（与复位分支同值，仿真防 X）
    r_dec_data = 17'h1_0000;
    r_sc_state = S_IDLE;
    r_sc_ph    = 2'd0;
    r_sc_ch    = 2'd0;
    r_sc_bin   = 9'd0;
    r_sc_a     = {AW{1'b0}};
    r_sc_cnt   = 16'd0;
    r_cdf      = 17'd0;
    r_map_ok   = 1'b0;
    r_map_q    = 96'd0;
    r_in1      = 96'd0;
    r_vld1     = 1'b0;
    r_tlast1   = 1'b0;
    r_tuser1   = 1'b0;
    r_en1      = 1'b0;
    r_mapok1   = 1'b0;
    O_tdata    = 96'd0;
    O_tvalid   = 1'b0;
    O_tlast    = 1'b0;
    O_tuser    = 1'b0;
end

endmodule
