//==============================================================================
// 文件名   : alg_top.v
// 模块名   : alg_top
// 日期     : 2026-09-14
// 描述     : 96-bit AXI4-Stream 算法通道 · 顶层（8 档切换 + 掩蔽 + 延迟对齐）
//
//  ---------------------------------------------------------------------------
//  【一、全链延迟预算（M0..M6 = L=5；M7 = L=8，见 §一·补）】
//  ---------------------------------------------------------------------------
//  相对【原始 I_tdata】的延迟：
//
//    u_gray   gray_bt601_96          灰度              +1
//    u_win    win3x3_96              窗口/窗口有效      +3   (= 灰度 1 + 窗口 2)
//    u_bin/sob/smo                   三档算法结果        +4   (= 窗口 3 + 自身 1)
//    u_det    alg_color_detect_96    M5 结果            +2
//    u_rgb3 + u_rowdly               M3 提亮源彩色       +323 (= 3 + 320)
//    u_mot    alg_framediff_96       M6 运动点           +3   (= 灰度 1 + 模块 2)
//    u_rf     alg_region_fill_96     M7 区域填充         +7   (= M3 的 4 + 模块 3)
//
//  统一对齐到 **MUX 输入处延迟 4 拍**，再经本级输出寄存器 → **L = 5**。
//
//    M0 直通       0  → 本级打 4 拍
//    M1 灰度       1  → 本级打 3 拍
//    M2/M3/M4      4  → 本级打 0 拍
//    M5            2  → 本级打 2 拍
//    M6 运动点      3  → 本级打 1 拍（r_m6_mot）
//    M7 区域填充    7  → 本级打 -3 拍（**打不了**，见 §一·补）
//    window_valid  3  → 本级打 1 拍（与 MUX 输入同步）
//
//  ---------------------------------------------------------------------------
//  【一·补、为什么 M7 的延迟是 8 而不是 5（2026-09-18 新增档位时定死）】
//  ---------------------------------------------------------------------------
//  填充模块自己的契约是"延迟 3 拍"（§二 五路输出同拍），而它必须吃**边缘轮廓**，
//  边缘只有 M3 那条支路才有，且 M3 已经在延迟 4 拍 ⇒ M7 支路最早只能落在
//  4 + 3 = 7 拍（再经本级输出寄存器 = **8 拍**）。
//  既不能让填充模块"负延迟"，也不能把它接到延迟更早的位置：
//    · 接 win3x3 的窗口（延迟 3）+ 自算边缘至少要再加 1 拍 ⇒ 4 + 3 = 7，一样；
//    · 接原始流（延迟 0）则没有 3×3 邻域，根本算不出轮廓。
//  ⇒ M7 是全工程**唯一**延迟不是 5 的档位。为了让别的档位维持冻结的 L=5，
//    本级**不动** M0..M6 的任何一级，M7 支路自带控制（u_rf 的 O_tvalid/tlast/tuser），
//    由 §9 的 MUX 按档位选控制 —— 于是 M7 帧在**周期轴**上整体晚 3 拍，
//    在**拍轴**上仍是第 i 个输出有效拍 = 第 i 个输入有效拍（与别的档位同一套拍序）。
//    判据侧（check_alg_top_full.py）按"逐档延迟"处理：M7 帧 LAT=8，其余帧 LAT=5。
//
//  ---------------------------------------------------------------------------
//  【二、M3 的 I_rgb_center 为什么喂"原始彩色 + 3 拍 + 320 拍"】
//  ---------------------------------------------------------------------------
//  窗口在 cycle t 装配完时，其**底行**是 IN(t-3) 所在行，**中心行 = 底行 - 1 行**。
//  而 IN(t-3-320) = IN(t-323) 正是"底行再往上 320 拍"那一拍，即中心行同列像素。
//  所以：u_rgb3（原始彩色打 3 拍）→ u_rowdly（再延迟 320 拍）→ 输出 = IN(t-323)，与 O_window 同拍。
//
//  ⚠ 绝不能喂 win3x3_96.O_tdata —— 那是【灰度流】的延迟副本，会让 M3 的 src 变成灰度，
//      M3 就不再是"彩色边缘增强"了。（规格 §2.5 第一版犯过这个错，已更正。）
//
//  ---------------------------------------------------------------------------
//  【三、掩蔽（唯一的一处，全部 7 档统一套用）】
//  ---------------------------------------------------------------------------
//  金标准 alg_ref.py:676 对**全部 6 档**无条件套 window_valid 掩蔽（含 M0/M1），
//  M6（alg_ref 里未实现的 MODE_MOTION）按同一纪律处理。
//  所以掩蔽只在本级做一次，各算子自己不做。信号取 u_win 的 O_window_valid
//  再打 1 拍，与 MUX 输入同步。
//      O_tdata = mask ? 选中档位的结果 : 未掩蔽的原图
//  掩蔽期输出**原图**（不是黑屏）—— 与官方例程的输出全黑是有意差异。
//
//  ---------------------------------------------------------------------------
//  【四、档位切换】
//  ---------------------------------------------------------------------------
//  I_key 按下循环 0→1→2→3→4→5→6→7→0，内部消抖；I_mode_set=1 时用 I_mode_sel 强制指定。
//  ⚠ 档位锁存用的是**对齐后（延迟 4 拍）的 tuser**（w_a0_ctl[0]），不是输入的 tuser ——
//     输出比输入晚 5 拍，按输入的 tuser 锁存会让上一帧最后 5 拍就用上新档位。
//  ⚠ M7（区域填充）虽然数据通路是 8 拍，**锁存基准仍然是 w_a0_ctl 的帧首拍**：
//     换档必须换在 M0..M6 那套共用的帧边界上，否则 M7 的 3 拍差值会漏进
//     "什么时候换档"这件事里，下一档的头几拍就归错了帧。
//     实测（160x64 / 8 帧）：帧边界的 M0 输出侧有 BLANK_LEN=20 拍行消隐 + 100 拍帧消隐，
//     M7 支路的 3 拍差值整段落在消隐里 ⇒ 换档处 O_tvalid 全 0，不会切掉任何有效拍。
//
//  ---------------------------------------------------------------------------
//  【四·补、M6（帧差运动检测）在本级怎么用（2026-09-17 新增）】
//  ---------------------------------------------------------------------------
//  · u_mot 吃 **u_gray 的灰度流**（不是原始彩色）：M1 判据已经把 gray_bt601_96
//    逐位钉在金标准上，帧差复用它，避免 BT.601 公式在本项目里出现第二份实现。
//    灰度流 = 原始流延迟 1 拍，所以 u_mot 的 O_motion_pix0 相对**原始 I_tdata**
//    延迟 3 拍（1 + 模块内部 2），本级再补 1 拍（r_m6_mot）→ 正好落在 MUX 输入的 4 拍。
//  · M6 的像素 = **原图（w_a0_dat，与 M0 同一条 4 拍通路）**，再叠两层：
//      ① 运动点：O_motion_pix0 对应的那一拍里 **pix0 所在格子**有运动 ⇒ 该像素涂白；
//      ② 红框：像素落在**上一帧锁存的运动 bbox**（r_bb_*，与 M5 共用同一组帧边界
//         寄存器）内且在边框上 ⇒ 涂红 24'hFF0000。
//    **优先级：红框 > 白点**（判据侧的 M6 黄金模型按同一顺序画，见 check_alg_top_full.py）。
//  · 画框要拿"当前像素的绝对坐标"，所以本级自带一套 **M6 专用坐标计数器**
//    （与 win3x3_96 §6 同口径：按 I_tvalid 门控、I_tuser 复位）再打 4 拍 ——
//    这 4 拍是**时钟延迟**（不门控），与 r_m0_dat 同款，两者才逐拍对齐。
//    不复用 win3x3 的坐标是因为它在 3 拍、且属于灰度流水，与 MUX 输入的 4 拍对不上。
//  · 帧级统计（O_pix_count / O_bbox_*）在 M6 下取 u_mot 的帧边界锁存值：
//    锁存点仍在本级 §7.6 的 w_sof_a0（对齐 4 拍处的帧首有效拍），**按"本帧生效的
//    档位"选源** —— 注意不能用当拍的 r_mode：r_mode 在同一个沿翻新，当拍还是旧档。
//
//  ---------------------------------------------------------------------------
//  【四·补2、M7（区域填充）在本级怎么用（2026-09-18 新增）】
//  ---------------------------------------------------------------------------
//  · **输入从哪来（本次唯一的开放设计点，结论写在最前面）**：
//      读 alg_sobel_96.v 第 5 节可以定死一件事 —— M3 的输出**不是**黑白边缘，
//      而是"提亮后的彩色图"：  out = edge ? sat8(src + EDGE_K) : src
//      （src = **原图**中心行彩色）。所以 M3 通路上的信号**不是纯二值**，
//      而 alg_region_fill_96 的契约要求输入是纯二值（只有 24'hFFFFFF / 24'h000000）。
//      ⇒ M7 分支里加一级**硬阈值**（下面 §5d 的 w_rf_bin）把它变成纯二值。
//      ⚠ 不能改喂 alg_binarize_96（M2）那条支路：它的输出虽然是纯二值，但那是
//        **实心色块**（实测 160x64 前景占比 46.7%），填充模块吃实心图会让 inside
//        从段首一路保持到行尾、整幅花掉（模块文件头 §12 写死了这条）。
//  · **阈值口径（三处写死同一份，RTL / Python 参考模型 / 报告）**：
//        白 ⟺ **三个字节都 >= RF_TH**（默认 128）        （其余一律黑）
//        即 RF_TH 是"逐字节下限"，不是"亮度"、也不是"三字节全 0xFF"。
//      ⚠ 默认值 128 不是拍脑袋，是**实测**选的（sim\_m7_thresh_probe.py）：
//        · 边缘像素：提亮后 out_min = min(min(src)+128, 255) **恒 >= 128**
//          ⇒ 阈值取 <= 128 时**一个真边缘像素都不会漏**；取 129 时实测漏 28575 个
//          （1280x720 第 0 帧），所以 **128 是"不漏边缘"的最大阈值**；
//        · 非边缘像素：out = src 原样，实测 min(R,G,B) 最大 = 12（160x64）/ 120
//          （1280x720，受图里 R = 8*(y%16) <= 120 约束）⇒ 取 128 时**一个非边缘
//          像素都不会误判成白**；
//        · 结论：在这套激励上 "三字节都 >= 128" **逐像素等价于 Sobel 的 edge 掩码**
//          （1280x720 第 0 帧 0 失配 / 163777 个前景，160x64 三帧 0 失配）。
//      ⚠ 已知局限（写进报告，不藏）：这条等价**依赖上游提亮增量 K=EDGE_K**。
//        换 EDGE_K（比如 64）而不动 RF_TH，阈值语义就变了（K 越小越高概率漏边缘）。
//        RF_TH 与 EDGE_K 是一对，改一个必须复核另一个。
//  · **掩蔽：本级对 M7 不叠顶层掩蔽**（模块内部已有 3 行 + 每行第 0 拍掩蔽，见 §9）。
//    理由不只是"别叠两层"：顶层掩蔽 r_mask_d / w_a0_dat 对齐在延迟 4 拍，
//    而 M7 支路在延迟 7 拍，两者**不同拍** —— 叠上去等于把掩蔽区整体挪 3 拍
//    （= 每行 12 个像素），比不叠更错。
//  · **行位移不要"对齐掉"**：u_rf 输出第 y 行承载的是输入第 y-1 行的填充结果
//    （与 win3x3_96 同口径，见 alg_region_fill_96 文件头 §四）。M3 本身已经有一行位移，
//    所以 M7 帧相对原图一共下移 **2 行** —— 这是两个模块契约叠加的结果，
//    判据侧照这个口径算（check_alg_top_full.py 的 _shift1 用两次），本级不做任何补偿。
//
//  ---------------------------------------------------------------------------
//  【五、反压】全链路自由流，所有子模块 I_tready 直接接 I_tready，
//  O_tready 悬空（模块内部是 assign O_tready = I_tready 直通）。S0-02 C-3。
//  ⚠ 不要把子模块的 I_tready 和 O_tready 接同一根线 —— 那是 w = w 的环，没有驱动源。
//
//  ---------------------------------------------------------------------------
//  【六、帧级状态输出必须在"有效拍"上换值（2026-09-14 气泡测试修正）】
//  ---------------------------------------------------------------------------
//  O_bbox_* / O_pix_count / O_bbox_valid 是**帧级状态**：换值时刻必须由有效拍决定，
//  不能由时钟沿决定。u_det 的锁存沿是"帧首拍之后那一拍"，是个纯时钟事件 ——
//  无气泡时它落在输出流的倒数第 4 拍；含行消隐气泡时输出流在帧首拍前有一段空档，
//  那一瞬整段落进空档 ⇒ 同一份激励、有/无气泡，bbox 会在**不同的输出拍**上翻新。
//  实测：修好数据通路后仍剩 27 拍逐位不符，全部是这一组列。
//  本级做法：在输出寄存器的前一级（对齐 4 拍处）遇帧首有效拍采样一次，统计正好从
//  本帧第 0 个输出拍起可见 —— 换值时刻由有效拍决定，输入停顿在拍空间里不可见。详见 §7.6。
//
//  ---------------------------------------------------------------------------
//  【七、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/#delay；
//  无用户 latch；内部寄存器 r_ 前缀、线网 w_ 前缀；端口保持 I_/O_ 大写。
//==============================================================================

module alg_top #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter [23:0] TGT_COLOR = 24'hFF0000,   // M5 目标颜色（默认纯红）
    parameter [7:0]  TGT_TOL   = 8'd40,        // M5 颜色容差
    // ★ 2026-10-01 新增：M6 帧差阈值「板级可覆盖」参数。
    //   加它的目的：把"板级调参"和"已验证行为"隔开 ——
    //   本参数默认值 = alg_framediff_96 的原默认值 24，所以 alg_top 自己的
    //   全尺寸仿真判据【一个字都不变】；只有板级 isp_top 覆盖它才生效。
    parameter [7:0]  M6_DIFF_TH = 8'd24,       // M6 帧差阈值（严格大于才算运动）
    // ★★ 2026-10-01 新增：M5 判色方式与框色「板级可覆盖」参数（默认值 = 原行为，故仿真判据不变）
    //   上板实测：M5 只见橙色轨迹点、没有白框、坐标恒 2047 ⇒ 绝对容差判据太严。
    //   板级把 DOM_MODE 置 1 改走「红主导」判据，并把框色改成红色（符合选题规格）。
    parameter        DOM_MODE   = 1'b0,        // 0=绝对容差（默认） 1=红主导
    parameter [7:0]  DOM_MIN    = 8'd80,       // 红主导：R 至少这么亮
    parameter [7:0]  DOM_MARGIN = 8'd30,       // 红主导：R 至少比 G/B 大这么多
    parameter [23:0] BBOX_COLOR = 24'hFFFFFF,  // M5 目标框颜色（默认白）
    // ★★ 2026-10-02：COLOR_MODE 参数端口化 -> 输入 I_color_mode（板级 KEY4 现场切档）。
    parameter [7:0]  SAT_TH     = 8'd40,       // 与 alg_color_detect_96 默认值保持一致
    // ★2026-10-03 固定色档三重门参数透传（默认值=u_det 默认 ⇒ 行为不变）
    parameter [7:0]  SAT_MIN    = 8'd0,
    parameter [8:0]  COLOR_GAP  = 9'd255,
    // ★★ 2026-10-03 AUTO 档四族并行（多框多色）：黄族判据 B 余量透传（默认=u_det 默认）。
    parameter [7:0]  Y_MARGIN   = 8'd40,
    // ★★ 2026-10-02 新增：M6 亮度归一化开关。默认 0 ⇒ u_mot 行为与已验证口径【逐位一致】；
    //   板级 isp_top 覆盖为 1：帧差前减掉整帧亮度水平，抵消 AGC/光线的全局漂移（见 alg_framediff_96.v）。
    parameter        M6_NORM    = 1'b0,
    parameter integer C_OFF    = 0,            // M2/M3 自适应阈值偏置
    parameter [8:0]   EDGE_K   = 9'd128,       // M3 提亮增量
    // M7 分区填充的输入硬阈值：三字节都 >= RF_TH 记白。口径与理由见 §四·补2。
    // ⚠ 与 EDGE_K 是一对：RF_TH 必须 <= "提亮后的最小可能值" = EDGE_K，
    //   否则真边缘会被漏判成黑（实测 EDGE_K=128 时取 129 会漏 28575 个边缘像素）。
    parameter [7:0]   RF_TH    = 8'd128,
    // ★★ 2026-10-03 五修：M3 阈值倍率透传（4=金标准口径不动，板级 2）+ AUTO 黄族开关透传。
    parameter integer TH_SCALE = 4,
    parameter         AUTO_Y   = 1'b1,
    // ★六修：蓝族放宽门透传（默认=通用值 ⇒ 行为不变）。
    parameter [7:0]   SAT_TH_B = SAT_TH,
    parameter [7:0]   DOM_MIN_B= DOM_MIN,
    // ★八修：绿族领先余量透传（默认 0 ⇒ 行为不变）。
    parameter [7:0]   GREEN_M  = 8'd0,
    // ★九修：族框最小像素门槛透传（默认 1 ⇒ 行为不变）。
    parameter [31:0]  FAM_MIN  = 32'd1,
    // ★十修：M3 背景下压量 + M4 盒式核开关透传（默认 = 行为不变）。
    parameter [7:0]   EDGE_BG  = 8'd0,
    parameter         SMOOTH_BOX = 1'b0,
    // ★十一修：M2 全局自适应阈值开关透传（默认 0 = 行为不变）。
    parameter         BIN_GLOBAL = 1'b0,
    // ★十二修：绿族饱和门槛透传（默认 = SAT_TH ⇒ 行为不变）。
    parameter [7:0]   SAT_TH_G   = SAT_TH,
    // ★十六修：红/绿族专属门槛透传（默认 = 通用值 ⇒ 行为不变）。
    parameter [7:0]   SAT_TH_R   = SAT_TH,
    parameter [7:0]   DOM_MIN_R  = DOM_MIN,
    parameter [7:0]   DOM_MIN_G  = DOM_MIN,
    parameter integer KEY_DIV  = 50000         // 按键消抖计数（50MHz 下约 1ms）
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    // ---- 视频输入（96-bit AXI4-Stream，S0-02 §1）----
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tready,
    // ---- 档位控制 ----
    input  wire         I_key,          // 板载按键，按下切下一档（内部消抖）
    input  wire         I_mode_set,     // 1 = 用 I_mode_sel 强制指定
    input  wire [2:0]   I_mode_sel,
    input  wire [1:0]   I_color_mode,       // ★ 2026-10-02 M5 判色档位，直通 u_det
    // ---- 状态输出（给 OSD / 数码管 / 调试）----
    output wire [2:0]   O_mode,         // 当前生效档位
    output wire [31:0]  O_pix_count,    // M5 命中像素数 / M6 运动格子总数
    output wire [10:0]  O_bbox_x0,
    output wire [10:0]  O_bbox_x1,
    output wire [10:0]  O_bbox_y0,
    output wire [10:0]  O_bbox_y1,
    output wire         O_bbox_valid,
    // ---- 颜色类别（2026-09-20，扩展要求 2.4(2)「识别」）----
    //   0 = 红主导 / 1 = 绿主导 / 2 = 蓝主导。由 u_det 逐帧统计得出，
    //   与 O_bbox_valid 在同一拍（w_sof_a0）锁存 ⇒ "有没有"和"是什么"永远同相。
    output wire [1:0]   O_color_class,
    // ---- 跟踪编号（2026-09-20，进阶要求 2.5(2)「动态目标跟踪」）----
    //   目标连续丢失 >= 4 帧后再捕获 ⇒ +1；一直看得见就不变。与 O_color_class
    //   同一拍锁存（w_sof_a0），所以屏上"是什么颜色"和"第几号目标"永远同相。
    output wire [7:0]   O_track_id,
    // ---- 视频输出 ----
    output reg          O_tlast,
    output reg          O_tuser,
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output wire         O_tready
);

    assign O_tready = I_tready;

    localparam [2:0] MODE_RAW    = 3'd0;
    localparam [2:0] MODE_GRAY   = 3'd1;
    localparam [2:0] MODE_BIN    = 3'd2;
    localparam [2:0] MODE_EDGE   = 3'd3;
    localparam [2:0] MODE_SMOOTH = 3'd4;
    localparam [2:0] MODE_TARGET = 3'd5;
    localparam [2:0] MODE_MOTION = 3'd6;      // M6 帧差运动检测（2026-09-17 新增）
    localparam [2:0] MODE_REGIONFILL = 3'd7;  // M7 区域填充（2026-09-18 新增）

    localparam [15:0] KEY_TOP = KEY_DIV[15:0] - 16'd1;

    // M6 画框用的拍号位宽/行末拍（与 win3x3_96 §0 同一口径）
    localparam M6_BPL  = IMG_WIDTH >> 2;                    // 320 / 40
    localparam M6_XW   = $clog2(M6_BPL);                    // 9 / 6
    localparam [M6_XW-1:0] M6_LAST_BEAT = M6_BPL - 1;       // 319 / 39
    localparam [10:0]      M6_LAST_ROW  = IMG_HEIGHT - 1;   // 719 / 63

    integer i;

//------------------------------------------------------------------------------
// 1. u_gray：原始彩色 → 灰度（+1 拍）
//------------------------------------------------------------------------------
    wire [95:0] w_g_dat;
    wire        w_g_val, w_g_lst, w_g_usr;

    gray_bt601_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_gray (
        .I_clk    (I_clk),   .I_rst_n  (I_rst_n),
        .I_tlast  (I_tlast), .I_tuser  (I_tuser), .I_tdata (I_tdata),
        .I_tvalid (I_tvalid), .I_tready (I_tready),
        .O_tlast  (w_g_lst), .O_tuser  (w_g_usr), .O_tdata (w_g_dat),
        .O_tvalid (w_g_val), .O_tready ()
    );

//------------------------------------------------------------------------------
// 2. u_win：灰度 → 3x3 窗口（再 +2 拍，累计 +3）
//    O_tdata 是**灰度流**的延迟副本，只用于内部，不能当彩色用
//------------------------------------------------------------------------------
    wire [287:0] w_window;
    wire         w_wvalid;
    wire [95:0]  w_w_dat;
    wire         w_w_val, w_w_lst, w_w_usr;

    win3x3_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_win (
        .I_clk          (I_clk),    .I_rst_n  (I_rst_n),
        .I_tlast        (w_g_lst),  .I_tuser  (w_g_usr), .I_tdata (w_g_dat),
        .I_tvalid       (w_g_val),  .I_tready (I_tready),
        .O_tlast        (w_w_lst),  .O_tuser  (w_w_usr), .O_tdata (w_w_dat),
        .O_tvalid       (w_w_val),  .O_tready (),
        .O_window       (w_window), .O_window_valid (w_wvalid)
    );

//------------------------------------------------------------------------------
// 3. u_rgb3：原始彩色打 3 拍（288 个 DFF），供彩色行延迟用
//    不能用 win3x3 的 O_tdata —— 那是灰度
//    r_rgb3_ctl 打包顺序：bit2 = tvalid, bit1 = tlast, bit0 = tuser
//------------------------------------------------------------------------------
    reg [95:0] r_rgb3_dat [0:2];
    reg  [2:0] r_rgb3_ctl [0:2];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_rgb3_dat[0] <= 96'd0; r_rgb3_dat[1] <= 96'd0; r_rgb3_dat[2] <= 96'd0;
            r_rgb3_ctl[0] <= 3'd0;  r_rgb3_ctl[1] <= 3'd0;  r_rgb3_ctl[2] <= 3'd0;
        // ⚠⚠ 这里**不能**按 I_tvalid 门控（2026-09-14 气泡测试修正）。
        //   这四级是**时钟延迟**级，用来把各档路径补齐到同一拍；门控会让输入停顿
        //   期间 valid 被"冻住"，输出寄存器又无门控地照抄 → O_tvalid 在整个停顿里
        //   保持为 1，同一拍被反复重发（下游 tready 恒 1，全部被当成像素收下）。
        //   实测：640 拍输入在含气泡激励下输出 785 个有效拍（多 129 个）。
        //   官方 edge_detect_96 在同一位置是 `O_tvalid <= I_tvalid` 纯延迟，空间
        //   计数器才按 I_tvalid 门控 —— 两条通路的时间基准必须各自一致。
        end else begin
            r_rgb3_dat[0] <= I_tdata;
            r_rgb3_ctl[0] <= {I_tvalid, I_tlast, I_tuser};
            for (i = 1; i < 3; i = i + 1) begin
                r_rgb3_dat[i] <= r_rgb3_dat[i-1];
                r_rgb3_ctl[i] <= r_rgb3_ctl[i-1];
            end
        end
    end

    wire [95:0] w_c_rgb;

    rgb_row_delay_96 #(
        .IMG_WIDTH (IMG_WIDTH)
    ) u_rowdly (
        .I_clk    (I_clk),              .I_rst_n  (I_rst_n),
        .I_tlast  (r_rgb3_ctl[2][1]),   .I_tuser  (r_rgb3_ctl[2][0]),
        .I_tdata  (r_rgb3_dat[2]),
        .I_tvalid (r_rgb3_ctl[2][2]),   .I_tready (I_tready),
        .O_tlast  (),                   .O_tuser  (), .O_tdata (w_c_rgb),
        .O_tvalid (),                   .O_tready ()
    );

//------------------------------------------------------------------------------
// 4. 三个窗口算子（各自再 +1 拍，累计 +4）；三档吃同一套窗口
//------------------------------------------------------------------------------
    wire [95:0] w_b_dat, w_s_dat, w_m_dat;
    wire        w_b_val, w_b_lst, w_b_usr;
    wire        w_s_val, w_s_lst, w_s_usr;
    wire        w_m_val, w_m_lst, w_m_usr;

    alg_binarize_96 #(
        .C_OFF (C_OFF), .TH_MIN (0), .TH_MAX (255), .BIN_GLOBAL (BIN_GLOBAL)   // ★十一修
    ) u_bin (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_b_dat), .O_tvalid (w_b_val), .O_tlast (w_b_lst), .O_tuser (w_b_usr),
        .O_tready ()
    );

    alg_sobel_96 #(
        .C_OFF (C_OFF), .TH_MIN (0), .TH_MAX (255), .EDGE_K (EDGE_K), .TH_SCALE (TH_SCALE), .EDGE_BG (EDGE_BG)
    ) u_sob (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_s_dat), .O_tvalid (w_s_val), .O_tlast (w_s_lst), .O_tuser (w_s_usr),
        .O_tready ()
    );

    alg_smooth_96 #(
        .UNUSED (0),
        .SMOOTH_BOX (SMOOTH_BOX)   // ★十修
    ) u_smo (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_window_valid (w_wvalid), .I_window (w_window),
        .I_gray_src (w_w_dat), .I_rgb_center (w_c_rgb),
        .I_tvalid (w_w_val), .I_tlast (w_w_lst), .I_tuser (w_w_usr), .I_tready (I_tready),
        .O_tdata (w_m_dat), .O_tvalid (w_m_val), .O_tlast (w_m_lst), .O_tuser (w_m_usr),
        .O_tready ()
    );

//------------------------------------------------------------------------------
// 5. u_det：M5 目标检测（直接吃原始 I_tdata，+2 拍）
//    ⚠ 帧级统计（O_bbox_* / O_pix_count / O_bbox_valid）**不直接引到顶层端口**：
//      它们是帧级状态，必须在"有效拍"上换值，不能在时钟沿上换值（理由见 §7.6）。
//------------------------------------------------------------------------------
    wire [95:0] w_d_dat;
    wire        w_d_val, w_d_lst, w_d_usr;
    wire [10:0] w_det_x0, w_det_x1, w_det_y0, w_det_y1;
    wire [31:0] w_det_pc;
    wire        w_det_bbv;
    wire [1:0]  w_det_cls;
    wire [7:0]  w_det_id;
    // ★ 2026-10-03 AUTO 档四族并行（多框多色）：u_det 新输出（内部连线，不加顶层端口）
    //   族 0..3 = R/G/B/Y；O_fam_* 是 44 位平面向量，族 f 占 [11*f +: 11]。
    wire [3:0]         w_det_fv;
    wire [4*11-1:0]    w_det_fx0, w_det_fx1, w_det_fy0, w_det_fy1;

    alg_color_detect_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT),
        // ★ 2026-10-01：判色方式与框色透传（默认值不变 ⇒ 行为不变）
        .DOM_MODE   (DOM_MODE  ),
        .DOM_MIN    (DOM_MIN   ),
        .DOM_MARGIN (DOM_MARGIN),
        .BBOX_COLOR (BBOX_COLOR),
        .SAT_TH     (SAT_TH    ),
        .SAT_MIN    (SAT_MIN   ),
        .COLOR_GAP  (COLOR_GAP ),
        .Y_MARGIN   (Y_MARGIN  ),  // ★ 2026-10-03 AUTO 四族：黄族 B 余量透传
        .AUTO_Y     (AUTO_Y    ),  // ★五修：黄族开关（板级 0=红/绿/蓝）
        .SAT_TH_B   (SAT_TH_B  ),  // ★六修：蓝族专属阈值透传
        .DOM_MIN_B  (DOM_MIN_B ),
        .SAT_TH_G   (SAT_TH_G  ),  // ★十二修：绿族饱和门槛透传
        .SAT_TH_R   (SAT_TH_R  ),  // ★十六修
        .DOM_MIN_R  (DOM_MIN_R ),
        .DOM_MIN_G  (DOM_MIN_G ),
        .GREEN_M    (GREEN_M   ),  // ★八修：绿族领先余量透传
        .FAM_MIN    (FAM_MIN   )   // ★九修：族框最小像素门槛透传
    ) u_det (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_tdata (I_tdata), .I_tvalid (I_tvalid), .I_tlast (I_tlast), .I_tuser (I_tuser),
        .I_tready (I_tready),
        .I_tgt_color (TGT_COLOR), .I_tgt_tol (TGT_TOL),
        .I_color_mode (I_color_mode),   // ★ 2026-10-02
        .O_tdata (w_d_dat), .O_tvalid (w_d_val), .O_tlast (w_d_lst), .O_tuser (w_d_usr),
        .O_tready (),
        .O_bbox_x0 (w_det_x0), .O_bbox_x1 (w_det_x1),
        .O_bbox_y0 (w_det_y0), .O_bbox_y1 (w_det_y1),
        .O_pix_count (w_det_pc), .O_bbox_valid (w_det_bbv),
        .O_color_class (w_det_cls),
        .O_track_id (w_det_id),
        .O_fam_valid (w_det_fv),
        .O_fam_x0 (w_det_fx0), .O_fam_x1 (w_det_fx1),
        .O_fam_y0 (w_det_fy0), .O_fam_y1 (w_det_fy1)   // ★ 2026-10-03
    );

//------------------------------------------------------------------------------
// 5b. u_mot：M6 帧差运动检测（吃 u_gray 的**灰度流**，端口延迟 +2；相对原始流 +3）
//     ⚠ 吃灰度流而不是原始彩色：灰度值直接来自已经被 M1 判据逐位钉死的
//       gray_bt601_96，本模块不再实现第二份 BT.601 公式（口径一致靠"同一个来源"，
//       不靠"两处各写一遍然后祈祷相等"）。
//     ⚠ O_frame_motion_cnt 是"本帧实时累计值"（调试/波形用），本级不消费它；
//       O_motion_cnt 才是帧边界锁存值，经 §7.6 采样后送 O_pix_count。故此处悬空。
//------------------------------------------------------------------------------
    wire        w_mot_pix0;
    wire [31:0] w_mot_fcnt, w_mot_cnt;
    wire [10:0] w_mot_x0, w_mot_x1, w_mot_y0, w_mot_y1;
    wire        w_mot_v;

    alg_framediff_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT),
        .DIFF_TH    (M6_DIFF_TH),    // ★ 2026-10-01：改为可覆盖（默认仍是 24，行为不变）
        .NORM       (M6_NORM)        // ★★ 2026-10-02：M6 亮度归一化（默认 0 = 行为不变）
    ) u_mot (
        .I_clk (I_clk), .I_rst_n (I_rst_n),
        .I_tdata (w_g_dat), .I_tvalid (w_g_val), .I_tuser (w_g_usr), .I_tready (I_tready),
        .O_tready (),
        .O_motion_pix0 (w_mot_pix0),
        .O_frame_motion_cnt (w_mot_fcnt),
        .O_motion_cnt (w_mot_cnt),
        .O_motion_bbox_x0 (w_mot_x0), .O_motion_bbox_x1 (w_mot_x1),
        .O_motion_bbox_y0 (w_mot_y0), .O_motion_bbox_y1 (w_mot_y1),
        .O_motion_valid (w_mot_v)
    );

//------------------------------------------------------------------------------
// 5c. M6 运动点补 1 拍（3 → 4），与 w_a0_dat 同拍
//     同样是**时钟延迟**级，不按 I_tvalid 门控（理由同 r_m0_dat 上方那段）
//------------------------------------------------------------------------------
    reg r_m6_mot;

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_m6_mot <= 1'b0;
        else
            r_m6_mot <= w_mot_pix0;
    end

//------------------------------------------------------------------------------
// 5d. u_rf：M7 区域填充（吃 M3 的边缘流，**先硬阈值变成纯二值**再喂填充模块）
//
//     ⚠ 为什么是"阈值 + 填充"而不是"直接接 M3"：见 §四·补2 —— M3 的输出是
//       "提亮后的彩色图"，不是黑白边缘；填充模块的契约要求纯二值输入。
//     ⚠ 为什么阈值级**不占延迟**：读的是 alg_sobel_96 的**输出寄存器** w_s_dat
//       （延迟 4），纯组合比较 + 纯组合选择 ⇒ 填充模块的输入仍与 w_s_val/lst/usr
//       严格同拍，填充模块的"延迟 3 拍"因此原样成立（累计 4 + 3 = 7）。
//     ⚠ 像素位序与全工程一致：pix0（列 4x+0，最左）在 [95:72] ⇒ [24*(3-k) +: 24]。
//     ⚠ 判白口径（与 §四·补2 / Python 参考模型 / 报告三处写死同一份）：
//           白 = **窗口可信**（r_mask_d）**且**三个字节都 >= RF_TH
//     ⚠⚠ 为什么必须再与 r_mask_d 相与（2026-09-18 实测定位，这条不是保险而是必需）：
//       alg_sobel_96 的**窗口不可信拍**（前 2 行 + 每行第 0 拍）输出的是"窗口横跨
//       行边界/帧边界"的**未定义值** —— 实测 160x64 帧 7：第 0 拍 4 个像素在 RTL 里
//       全是"边缘"（####)，而金标准是 #...。M3 档位上看不出这个差异，因为顶层掩蔽
//       会在这些拍上把结果换成原图（判据 C 就是这么判的）。
//       但**填充模块的 3×3 膨胀会往左多吃一个像素**：第 1 拍（列 4..7）的膨胀窗口
//       含列 3，正好落在第 0 拍的未定义值上 ⇒ 每行第 4 列冒出一个假边缘 ⇒ 填充的
//       inside 翻转位置整体错位（实测 M7 帧 1051 拍不符，失配行 = 8..15/24..31/…）。
//       与 r_mask_d 相与后，这些拍在 M7 支路里被**明确声明为黑**（口径可写、可复现、
//       参考模型能算），失配归零。
//       ⚠ 另一条路是把 win3x3_96 在第 0 拍的左邻补零（让 M3 流处处有定义）——
//         那要动已验收模块，本次不做；已写进报告供定夺。
//------------------------------------------------------------------------------
    wire [95:0] w_rf_bin;                 // 阈值化后的纯二值掩膜（填充模块的输入）
    wire [95:0] w_rf_dat;                 // 填充结果
    wire        w_rf_val, w_rf_lst, w_rf_usr;

    // r_mask_d 的更新逻辑在 §7.5；这里只提前声明（同 §7.6 对 r_mode 的写法：
    // Verilog 不允许先用后声明，而本支路要用它）。
    reg r_mask_d;


    // ★十七修（用户令，2026-10-05）：M7 回退到 15:00 版 —— 官方奇偶扫描填充 + 黑白二值输出。
    //   十四修（alg_m7_stable_96 帧间滤波）与十六修（alg_span_fill_96 跨度填充）的实例
    //   已从链路摘除；两个模块文件保留在盘上，想再试时把下面这段换回去即可（各一行）。
    //   摘除的附带好处：帧缓冲不例化 ⇒ 不占 ERAM（回到 ~58/108），布局余量更大。
    alg_region_fill_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) u_rf (
        .I_clk    (I_clk),    .I_rst_n  (I_rst_n),
        .I_tdata  (w_rf_bin), .I_tvalid (w_s_val),
        .I_tlast  (w_s_lst),  .I_tuser  (w_s_usr), .I_tready (I_tready),
        .O_tdata  (w_rf_dat), .O_tvalid (w_rf_val),
        .O_tlast  (w_rf_lst), .O_tuser  (w_rf_usr), .O_tready ()
    );

//------------------------------------------------------------------------------
// 6. 延迟对齐：把各路都挪到「MUX 输入 = 延迟 4 拍」
//    7.1 M0 直通：原始输入打 4 拍（同时提供对齐后的 tuser 给档位锁存）
//------------------------------------------------------------------------------
    reg [95:0] r_m0_dat [0:3];
    reg  [2:0] r_m0_ctl [0:3];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                r_m0_dat[i] <= 96'd0;
                r_m0_ctl[i] <= 3'd0;
            end
        // ⚠⚠ 这里**不能**按 I_tvalid 门控（2026-09-14 气泡测试修正）。
        //   这四级是**时钟延迟**级，用来把各档路径补齐到同一拍；门控会让输入停顿
        //   期间 valid 被"冻住"，输出寄存器又无门控地照抄 → O_tvalid 在整个停顿里
        //   保持为 1，同一拍被反复重发（下游 tready 恒 1，全部被当成像素收下）。
        //   实测：640 拍输入在含气泡激励下输出 785 个有效拍（多 129 个）。
        //   官方 edge_detect_96 在同一位置是 `O_tvalid <= I_tvalid` 纯延迟，空间
        //   计数器才按 I_tvalid 门控 —— 两条通路的时间基准必须各自一致。
        end else begin
            r_m0_dat[0] <= I_tdata;
            r_m0_ctl[0] <= {I_tvalid, I_tlast, I_tuser};
            for (i = 1; i < 4; i = i + 1) begin
                r_m0_dat[i] <= r_m0_dat[i-1];
                r_m0_ctl[i] <= r_m0_ctl[i-1];
            end
        end
    end

    wire [95:0] w_a0_dat = r_m0_dat[3];

    // ★五修：判白加"原图本来不白"一条 —— 白 = 提亮后三字节全 >= RF_TH 且原图至少一字节
    //   < RF_TH。旧口径把白墙/亮背景也算白 ⇒ 填充区域错乱（用户板上实测）；新口径只有
    //   被 EDGE_K 提亮出来的真边缘是白。代价：两侧都 >RF_TH 的亮亮边界不再成轮廓（可接受）。
    //   ⚠ 本块从 u_rf 之前搬到下方 w_a0_dat 声明之后 —— 先用后声明=隐式 1bit 线网大坑。
    genvar g7;
    generate
        for (g7 = 0; g7 < 4; g7 = g7 + 1) begin : g_rf_bin
            wire [23:0] w_rf_src = w_s_dat[24*(3-g7) +: 24];
            wire [23:0] w_rf_org = w_a0_dat[24*(3-g7) +: 24];
            wire w_rf_wht = r_mask_d && (w_rf_src[23:16] >= RF_TH) &&
                            (w_rf_src[15: 8] >= RF_TH) &&
                            (w_rf_src[ 7: 0] >= RF_TH) &&
                            ((w_rf_org[23:16] < RF_TH) || (w_rf_org[15: 8] < RF_TH) ||
                             (w_rf_org[ 7: 0] < RF_TH));
            assign w_rf_bin[24*(3-g7) +: 24] = w_rf_wht ? 24'hFFFFFF : 24'h000000;
        end
    endgenerate

    // ★七修：M7 输出改"原图叠色"。旧版直接输出黑白二值图 ⇒ 轮廓外全黑，用户实测
    //   "黑色区域多、不开均衡像没效果"。现在轮廓外恢复实时原图，闭合区内叠半透明
    //   品红（(orig+FF00FF)/2，纯移位加法零 DSP）：AR 标记观感，纹理还看得见。
    //   对齐：w_rf_dat 在 +7 拍，w_a0_dat 在 +4 ⇒ 原图再走 3 拍时钟延迟（与
    //   r_m0_dat 同款**不门控**，理由见 §三 气泡修正注释）。
    //   ⚠ u_rf 输出天生晚一行（模块契约，金标准同口径）⇒ 叠色区比实物低 1 行，
    //     720 行里 1 行不可见，不做行补偿（补了反而和金标准口径打架）。
    reg [95:0] r_m7_org [0:2];
    integer m7i;
    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (m7i = 0; m7i < 3; m7i = m7i + 1)
                r_m7_org[m7i] <= 96'd0;
        end else begin
            r_m7_org[0] <= w_a0_dat;
            for (m7i = 1; m7i < 3; m7i = m7i + 1)
                r_m7_org[m7i] <= r_m7_org[m7i-1];
        end
    end

    wire [95:0] w_m7_base = r_m7_org[2];
    wire [95:0] w_m7_ovl;
    genvar gm7;
    generate
        for (gm7 = 0; gm7 < 4; gm7 = gm7 + 1) begin : g_m7ovl
            wire [23:0] w_rf_px  = w_rf_dat[24*(3-gm7) +: 24];
            wire [23:0] w_org_px = w_m7_base[24*(3-gm7) +: 24];
            wire [7:0]  w_mk_r   = (({1'b0, w_org_px[23:16]} + 9'h0FF) >> 1);
            wire [7:0]  w_mk_g   = (w_org_px[15:8] >> 1);
            wire [7:0]  w_mk_b   = (({1'b0, w_org_px[ 7:0]} + 9'h0FF) >> 1);
            assign w_m7_ovl[24*(3-gm7) +: 24] =
                   (w_rf_px[23:16] >= 8'h80) ? {w_mk_r, w_mk_g, w_mk_b} : w_org_px;
        end
    endgenerate

    wire [2:0]  w_a0_ctl = r_m0_ctl[3];      // bit2=tvalid, bit1=tlast, bit0=tuser

//------------------------------------------------------------------------------
//    7.2 M1 灰度：已在 1 拍，再打 3 拍
//------------------------------------------------------------------------------
    reg [95:0] r_m1_dat [0:2];
    reg  [2:0] r_m1_ctl [0:2];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            for (i = 0; i < 3; i = i + 1) begin
                r_m1_dat[i] <= 96'd0;
                r_m1_ctl[i] <= 3'd0;
            end
        // ⚠⚠ 这里**不能**按 I_tvalid 门控（2026-09-14 气泡测试修正）。
        //   这四级是**时钟延迟**级，用来把各档路径补齐到同一拍；门控会让输入停顿
        //   期间 valid 被"冻住"，输出寄存器又无门控地照抄 → O_tvalid 在整个停顿里
        //   保持为 1，同一拍被反复重发（下游 tready 恒 1，全部被当成像素收下）。
        //   实测：640 拍输入在含气泡激励下输出 785 个有效拍（多 129 个）。
        //   官方 edge_detect_96 在同一位置是 `O_tvalid <= I_tvalid` 纯延迟，空间
        //   计数器才按 I_tvalid 门控 —— 两条通路的时间基准必须各自一致。
        end else begin
            r_m1_dat[0] <= w_g_dat;
            r_m1_ctl[0] <= {w_g_val, w_g_lst, w_g_usr};
            for (i = 1; i < 3; i = i + 1) begin
                r_m1_dat[i] <= r_m1_dat[i-1];
                r_m1_ctl[i] <= r_m1_ctl[i-1];
            end
        end
    end

    wire [95:0] w_a1_dat = r_m1_dat[2];
    wire [2:0]  w_a1_ctl = r_m1_ctl[2];

//------------------------------------------------------------------------------
//    7.3 M5：已在 2 拍，再打 2 拍
//------------------------------------------------------------------------------
    reg [95:0] r_m5_dat [0:1];
    reg  [2:0] r_m5_ctl [0:1];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_m5_dat[0] <= 96'd0; r_m5_dat[1] <= 96'd0;
            r_m5_ctl[0] <= 3'd0;  r_m5_ctl[1] <= 3'd0;
        // ⚠⚠ 这里**不能**按 I_tvalid 门控（2026-09-14 气泡测试修正）。
        //   这四级是**时钟延迟**级，用来把各档路径补齐到同一拍；门控会让输入停顿
        //   期间 valid 被"冻住"，输出寄存器又无门控地照抄 → O_tvalid 在整个停顿里
        //   保持为 1，同一拍被反复重发（下游 tready 恒 1，全部被当成像素收下）。
        //   实测：640 拍输入在含气泡激励下输出 785 个有效拍（多 129 个）。
        //   官方 edge_detect_96 在同一位置是 `O_tvalid <= I_tvalid` 纯延迟，空间
        //   计数器才按 I_tvalid 门控 —— 两条通路的时间基准必须各自一致。
        end else begin
            r_m5_dat[0] <= w_d_dat;
            r_m5_ctl[0] <= {w_d_val, w_d_lst, w_d_usr};
            r_m5_dat[1] <= r_m5_dat[0];
            r_m5_ctl[1] <= r_m5_ctl[0];
        end
    end

    wire [95:0] w_a5_dat = r_m5_dat[1];
    wire [2:0]  w_a5_ctl = r_m5_ctl[1];

//------------------------------------------------------------------------------
//    7.4 M2/M3/M4：已在 4 拍，不补
//    7.5 掩蔽：window_valid 在 3 拍，再打 1 拍
//    （r_mask_d 的**声明**在 §5d —— M7 支路的输入阈值要用它，Verilog 不允许先用后声明）
//------------------------------------------------------------------------------
    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mask_d <= 1'b0;
        else
            r_mask_d <= w_wvalid;    // 同上：时钟延迟级，不按 I_tvalid 门控
    end

//------------------------------------------------------------------------------
//    7.5b M6 画框坐标：计数器（有效拍门控 + tuser 复位，win3x3_96 §6 同口径）
//         再打 4 拍（**时钟延迟**，不门控）→ 给出"即将进入 MUX 的那一拍"的行列
//    为什么必须自带一套：MUX 输入处那份像素是原始流延迟 4 拍，需要同拍的
//    "本拍拍号/行号"才能逐像素比较 bbox 边框（x==x0||x==x1||y==y0||y==y1）。
//    既有模块里没有 4 拍处的坐标（win3x3 的在 3 拍且属灰度流水），所以本级生成。
//    ⚠ 计数器按 I_tvalid 门控、4 拍延迟不门控 —— 与 r_m0_dat 的"有效拍 + 时钟延迟"
//      两条时间基准各自一致，混用会让坐标与像素错拍（本项目已栽过一次）。
//------------------------------------------------------------------------------
    reg [M6_XW-1:0] r_m6_xg;             // 本拍总线上那一拍的拍号 0..M6_BPL-1
    reg [10:0]      r_m6_y;              // 本拍总线上那一拍的行号 0..IMG_HEIGHT-1
    reg [M6_XW-1:0] r_m6_xg_d [0:3];     // 4 拍时钟延迟（与 r_m0_dat[3] 同拍）
    reg [10:0]      r_m6_y_d  [0:3];

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_m6_xg <= {M6_XW{1'b0}};
            r_m6_y  <= 11'd0;
            for (i = 0; i < 4; i = i + 1) begin
                r_m6_xg_d[i] <= {M6_XW{1'b0}};
                r_m6_y_d[i]  <= 11'd0;
            end
        end else begin
            // ---- 坐标推进（按有效拍门控、tuser 复位；官方 edge_detect_96 同构）----
            if (I_tvalid) begin
                if (I_tuser) begin
                    r_m6_xg <= {{(M6_XW-1){1'b0}}, 1'b1};
                    r_m6_y  <= 11'd0;
                end else if (r_m6_xg == M6_LAST_BEAT) begin
                    r_m6_xg <= {M6_XW{1'b0}};
                    r_m6_y  <= (r_m6_y == M6_LAST_ROW) ? 11'd0 : (r_m6_y + 11'd1);
                end else begin
                    r_m6_xg <= r_m6_xg + 1'b1;
                end
            end
            // ---- 4 拍时钟延迟（**不**门控，与 r_m0_dat 同款）----
            r_m6_xg_d[0] <= r_m6_xg;
            r_m6_y_d[0]  <= r_m6_y;
            for (i = 1; i < 4; i = i + 1) begin
                r_m6_xg_d[i] <= r_m6_xg_d[i-1];
                r_m6_y_d[i]  <= r_m6_y_d[i-1];
            end
        end
    end

//------------------------------------------------------------------------------
//    7.6 帧级统计（M5 bbox / 像素计数 / bbox_valid）搬到"有效拍"上换值
//
//    u_det 的锁存沿是 `r_vld1 && r_tu_d1` —— 帧首拍**之后那一拍**，一个纯时钟沿事件；
//    而 bbox 组是帧级状态，谁在它换值的那一瞬看到新值，取决于"那一瞬正好是本帧的第几个
//    输出拍"。无气泡时它落在输出流的倒数第 4 拍；含行消隐气泡时输出流在帧首拍前有一段
//    空档，那一瞬整段落在空档里 ⇒ 同一份激励、有/无气泡，bbox 会在**不同的输出拍**上
//    翻新。实测（check_bubble.py）：只修 rgb_row_delay 读口门控后剩下的 27 拍逐位不符
//    全是这一组列（bbv/x0/x1/y0/y1/pix），且全部落在每帧最后 3 个输出拍上。
//
//    修法：在**输出寄存器的前一级**（对齐 4 拍处 = 该拍在本拍末被装载进 O_*）遇到
//    **帧首有效拍**时采样一次 u_det 的统计，于是这份统计正好从本帧第 0 个输出拍起可见。
//    换值时刻由"有效拍"决定 ⇒ 输入侧停顿在拍空间里不可见。
//    采样点 T+4 恒晚于 u_det 的锁存沿 T+1（T = 帧首拍的输入拍号；帧首拍必为有效拍，
//    所以 r_vld1(T+1)=1、r_tu_d1(T+1)=1 是必然的，与别处有没有气泡无关），
//    又远早于下一帧的锁存沿 ⇒ 采到的必然是"上一帧完整统计"，与金标准的 bbox_prev
//    语义（整帧都画/报上一帧的框）逐拍一致。
//    依据：官方 edge_detect_96.v 里空间与帧边界一律用有效拍判据，只有跨拍延迟用纯时钟。
//    （u_det 内部画框仍用它自己的寄存器 —— A/B/C/D/E 五项金标准比对的都是那条数据通路，
//      本组寄存器只改顶层端口的换值时刻，不动任何像素。）
//
//    2026-09-17 M6 扩展：u_mot 的统计按**同一套规则**（同样的锁存点、同样的"上一帧"
//    语义）在同一个沿被采样，**按"本帧生效的档位"选源**：
//        下一档 = I_mode_set ? I_mode_sel : r_mode_hold     （= r_mode 在同一个沿要装载的值）
//        M6 ⇒ 采 u_mot 的三组量；其余档 ⇒ 采 u_det 的（行为逐位不变）。
//    ⚠ 不能用当拍的 r_mode 选源：r_mode 也在 w_sof_a0 这个沿翻新，当拍它还是旧档，
//      会让"进入 M6 的第一帧"报出 M5 的 bbox（差一帧）。u_mot 的锁存沿同样是 T+2
//      （灰度流比原始流晚 1 拍、模块内部再晚 1 拍），恒早于这里的 T+4 ⇒ 采到的
//      一定是"上一帧的完整运动统计"。
//------------------------------------------------------------------------------
    reg [10:0] r_bb_x0, r_bb_x1, r_bb_y0, r_bb_y1;
    reg [31:0] r_bb_pc;
    reg        r_bb_v;
    reg [1:0]  r_bb_cls;
    reg [7:0]  r_bb_id;
    // ★ 2026-10-03 AUTO 四族（多框多色）：u_det 的四族帧级输出在本级**同沿**（w_sof_a0）
    //   锁存一份，供 §7.7c 的 M5 画框链使用。理由与 r_bb_* 完全相同：帧级量必须
    //   在"有效拍"上换值，画框比较必须与像素同一条 4 拍时间基准。
    reg [3:0]          r_bb_fv;
    reg [4*11-1:0]     r_bb_fx0, r_bb_fx1, r_bb_fy0, r_bb_fy1;

    // "对齐 4 拍处的帧首有效拍" —— 就是本拍末要被装进 O_* 的那一拍
    wire w_sof_a0 = w_a0_ctl[2] & w_a0_ctl[0];

    // 档位寄存器在这里**提前声明**（更新逻辑仍在 §8）：因为"下一帧生效的档位"
    // 在本节的帧边界采样里就要用到，而 Verilog 不允许先用后声明。
    reg [2:0] r_mode_hold;
    reg [2:0] r_mode;

    // 下一帧生效的档位（与 r_mode 在同一个沿装载，更新见 §8）
    wire [2:0] w_mode_nx = I_mode_set ? I_mode_sel : r_mode_hold;

    // 换档沿（§8 用它装载 r_mode）：
    //   · 默认 = a0 的帧首有效拍 w_sof_a0（延迟 4 拍处）—— 换档在它的**下一拍**生效，
    //     对 M0..M6 无所谓：各支路同相，且帧首那一拍本来就在顶层掩蔽区（输出原图），
    //     旧档位算出来的值与新档位相同。
    //   · ⚠ 但**切进 M7** 必须提前 1 拍（用延迟 3 拍的 r_m0_ctl[2] 取同一个帧首拍）：
    //     u_rf 的控制相位比别的支路晚 3 拍，若仍在 w_sof_a0 换档，旧档位会在
    //     新帧第一拍上先吐一遍，紧接着 M7 支路又把它吐一遍
    //     ⇒ 实测 160x64/8 帧的 M6→M7 边界多出 **1 个有效拍 + 1 个 tuser**（20481 vs 20480）。
    //     提前 1 拍后：换档发生在 M7 支路第一拍到达之前，而那段正好落在帧消隐上
    //     （本链路帧首前 120 拍 tvalid=0，判据 I 已把这条工况钉死）。
    //     ⚠ 依赖：切进 M7 时帧首前至少 3 拍无有效数据（否则那 3 拍会多吐）。
    //   · ⚠⚠ 2026-09-23 补：**「切出 M7」是上面那条的镜像，原来漏了**。
    //     M7 支路延迟 7 拍、其余档 4 拍（相对差 3 拍）。原来"切出 M7"仍走 w_sof_a0，
    //     ⇒ r_mode 要到 T+5 才变，而 T+4 那拍 MUX 仍按 M7 选源 = IN(T-3)；T+5 起才换成
    //     新档 = IN(T+1)。**中间的 IN(T)（新帧第 0 拍、携带 tuser）被整个跳过。**
    //     实测（sim\run_m7out_full.ps1，档位表 [0,1,3,7,0]，f3=M7 → f4=M0）：
    //         in_beats = 1152000 / out_beats = 1151999   ← 少 1 个有效拍
    //         out_tuser = 4（应为 5，少 1 个）/ out_tlast = 3600（正确，行边界没坏）
    //     触发：按键循环是 M7 → MODE_RAW，**按第 9 下必然触发**。
    //     修法：**切出 M7 也提前 1 拍**（w_out_m7 单独判：当前档是 M7 且下一档不是）。
    //     提前后 r_mode 在 T+4 就变成新档 ⇒ N=T+4 那拍 MUX 已给出 IN(T)，
    //     输出寄存一拍后 O_tdata(T+5)=IN(T)。被跳过的 IN(T-3..T-1) 全落在帧消隐上。
    //     ⚠ 与"切进 M7"同款依赖：切出 M7 时帧首前至少 3 拍无有效数据。
    //     ⚠ w_sof_a0 那一项要 && !w_out_m7：否则切出时 T+4 还会再锁一次
    //       （那时 r_mode 已是新档、w_mode_nx 也是它，属无害重复锁存，但写清楚免得误读）。
    wire w_sof_pre = r_m0_ctl[2][2] & r_m0_ctl[2][0];
    wire w_out_m7  = (r_mode == MODE_REGIONFILL) && (w_mode_nx != MODE_REGIONFILL);
    wire w_mode_sw = (w_sof_a0 && !w_out_m7)
                  || (w_sof_pre && ((w_mode_nx == MODE_REGIONFILL) || w_out_m7));

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_bb_x0 <= 11'h7FF;  r_bb_x1 <= 11'd0;      // 与 u_det 的 BBOX_SENT 一致
            r_bb_y0 <= 11'h7FF;  r_bb_y1 <= 11'd0;
            r_bb_pc <= 32'd0;    r_bb_v  <= 1'b0;
            r_bb_cls <= 2'd0;
            r_bb_id  <= 8'd0;
            r_bb_fv  <= 4'd0;                            // 2026-10-03 四族（M5 画框用）
            r_bb_fx0 <= {4{11'h7FF}};  r_bb_fx1 <= 44'd0;
            r_bb_fy0 <= {4{11'h7FF}};  r_bb_fy1 <= 44'd0;
        end else if (w_sof_a0) begin
            // 颜色类别与跟踪编号都与档位无关（只有 u_det 在做颜色统计），故不进下面的档位分支。
            // M6 帧里消费方不显示它们，采到的值是 u_det 的口径，不影响任何显示。
            r_bb_cls <= w_det_cls;
            r_bb_id  <= w_det_id;
            // 四族同理恒采 u_det（只有它在做族统计）；固定档下不显示、不画（见 §7.7c）。
            r_bb_fv  <= w_det_fv;
            r_bb_fx0 <= w_det_fx0;  r_bb_fx1 <= w_det_fx1;
            r_bb_fy0 <= w_det_fy0;  r_bb_fy1 <= w_det_fy1;
            if (w_mode_nx == MODE_MOTION) begin         // M6：运动 bbox / 运动格子数
                r_bb_x0 <= w_mot_x0;  r_bb_x1 <= w_mot_x1;
                r_bb_y0 <= w_mot_y0;  r_bb_y1 <= w_mot_y1;
                r_bb_pc <= w_mot_cnt; r_bb_v  <= w_mot_v;
            end else begin                              // M0..M5 + M7：u_det 的（不变）
                r_bb_x0 <= w_det_x0;  r_bb_x1 <= w_det_x1;
                r_bb_y0 <= w_det_y0;  r_bb_y1 <= w_det_y1;
                r_bb_pc <= w_det_pc;  r_bb_v  <= w_det_bbv;
            end
        end
    end

    assign O_bbox_x0    = r_bb_x0;
    assign O_bbox_x1    = r_bb_x1;
    assign O_bbox_y0    = r_bb_y0;
    assign O_bbox_y1    = r_bb_y1;
    assign O_pix_count  = r_bb_pc;
    assign O_bbox_valid = r_bb_v;
    assign O_color_class = r_bb_cls;
    assign O_track_id    = r_bb_id;

//------------------------------------------------------------------------------
//    7.7 M6 像素叠加（纯组合，全部落在 MUX 输入的 4 拍上）
//        ① 运动点：r_m6_mot（O_motion_pix0 补 1 拍）⇒ 本拍 **pix0** 涂白
//        ② 红框   ：像素落在**上一帧**运动 bbox（r_bb_*，已在帧边界锁存）的边框上 ⇒ 涂红
//        优先级：红框 > 白点（判据侧 check_alg_top_full.py 的 M6 黄金模型同序）。
//        本框判据与 alg_color_detect_96 §5 的 draw_bbox 逐条一致（行边/列边各带范围约束，
//        bbox 无效时 min>max 直接压掉），只是颜色换成红、且作用在 4 拍处的原图上。
//------------------------------------------------------------------------------
    wire [10:0] w_m6_xbase = {r_m6_xg_d[3], 2'b00};      // 本拍第 0 像素的绝对列号
    wire        w_m6_bb_ok = (r_bb_x0 <= r_bb_x1) && (r_bb_y0 <= r_bb_y1);

    wire [95:0] w_m6_dat;

    genvar g6;
    generate
        for (g6 = 0; g6 < 4; g6 = g6 + 1) begin : g_m6
            wire [10:0] w_m6_xk  = w_m6_xbase + g6;
            wire w_m6_on_row = ((r_m6_y_d[3] == r_bb_y0) || (r_m6_y_d[3] == r_bb_y1))
                            && (w_m6_xk >= r_bb_x0) && (w_m6_xk <= r_bb_x1);
            wire w_m6_on_col = ((w_m6_xk == r_bb_x0) || (w_m6_xk == r_bb_x1))
                            && (r_m6_y_d[3] >= r_bb_y0) && (r_m6_y_d[3] <= r_bb_y1);
            wire w_m6_red = w_m6_bb_ok && (w_m6_on_row || w_m6_on_col);
            wire w_m6_wht = r_m6_mot && (g6 == 0);       // 运动点只落在 pix0
            assign w_m6_dat[24*(3-g6) +: 24] =
                   w_m6_red ? 24'hFF0000 :
                   (w_m6_wht ? 24'h00FF00 : w_a0_dat[24*(3-g6) +: 24]);
        end
    endgenerate

//------------------------------------------------------------------------------
//    7.7c M5 AUTO 四框叠加（2026-10-03 多框多色）
//        使能：w_m5fam = DOM_MODE && AUTO 档（I_color_mode==3）。
//          · DOM_MODE=0（绝对容差档）与固定色档：w_m5fam=0 ⇒ MUX 仍取 w_a5_dat，
//            即 u_det 内部已画好的**单框**（BBOX_COLOR、旧坐标），行为逐位不变。
//          · AUTO 档：u_det 内部仍会先在胜族框位置画一遍 BBOX_COLOR（不动它的逻辑），
//            本叠加与胜族框**逐像素同坐标**（r_bb_f* 与 r_bb_* 同沿锁存、AUTO 下
//            O_bbox_* 就是胜族 bbox），按族色重画 ⇒ 覆盖单框色，其余有像素的族各补画一框。
//        族色：族0 红 FF0000 / 族1 绿 00FF00 / 族2 蓝 0000FF / 族3 黄 FFFF00。
//        画框判据与 §7.7 的 M6 红框、u_det §5 draw_bbox 逐条一致（行边/列边各带
//        范围约束、11 位比较、min>max 哨兵直接压掉、族 valid 才画）；
//        两框交叠时族优先级 R>G>B>Y（与帧尾平局同序，确定可复现）。
//        坐标：与 M6 同一套 4 拍计数器 r_m6_*_d[3]（w_a5_dat 与 w_a0_dat 同拍：
//        u_det +2、本级再 +2，合计 +4 ⇒ 与 M6 支路逐拍对齐，理由见 §一 延迟预算）。
//------------------------------------------------------------------------------
    wire w_m5fam = DOM_MODE && (I_color_mode == 2'd3);   // 四框模式
    wire [10:0] w_m5_xbase = {r_m6_xg_d[3], 2'b00};      // 本拍第 0 像素的绝对列号

    wire [3:0] w_m5_edge [0:3];                          // [族][像素]：落在该族框边上

    genvar g5f, g5p;
    generate
        for (g5f = 0; g5f < 4; g5f = g5f + 1) begin : g_m5fam
            wire [10:0] w_f5x0 = r_bb_fx0[g5f*11 +: 11];
            wire [10:0] w_f5x1 = r_bb_fx1[g5f*11 +: 11];
            wire [10:0] w_f5y0 = r_bb_fy0[g5f*11 +: 11];
            wire [10:0] w_f5y1 = r_bb_fy1[g5f*11 +: 11];
            wire        w_f5ok = (w_f5x0 <= w_f5x1) && (w_f5y0 <= w_f5y1);
            for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_m5px
                wire [10:0] w_m5_xk = w_m5_xbase + g5p;
                wire w_m5_on_row = ((r_m6_y_d[3] == w_f5y0) || (r_m6_y_d[3] == w_f5y1))
                                && (w_m5_xk >= w_f5x0) && (w_m5_xk <= w_f5x1);
                wire w_m5_on_col = ((w_m5_xk == w_f5x0) || (w_m5_xk == w_f5x1))
                                && (r_m6_y_d[3] >= w_f5y0) && (r_m6_y_d[3] <= w_f5y1);
                assign w_m5_edge[g5f][g5p] = r_bb_fv[g5f] && w_f5ok
                                          && (w_m5_on_row || w_m5_on_col);
            end
        end
    endgenerate

    wire [95:0] w_m5_dat;

    generate
        for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_m5out
            assign w_m5_dat[24*(3-g5p) +: 24] =
                   w_m5_edge[0][g5p] ? 24'hFF0000 :
                   (w_m5_edge[1][g5p] ? 24'h00FF00 :
                   (w_m5_edge[2][g5p] ? 24'h0000FF :
                   (w_m5_edge[3][g5p] ? 24'hFFFF00 :
                    w_a5_dat[24*(3-g5p) +: 24])));
        end
    endgenerate

//------------------------------------------------------------------------------
// 8. 档位累计 + 锁存
//    锁存基准用 w_a0_ctl[0]（= 对齐后 4 拍的 tuser），与 MUX 输入同步；
//    用它而不是输入 I_tuser，否则上一帧最后 5 拍会用上新档位。
//    按键循环 8 档：0→1→2→3→4→5→6→7→0（M6 于 2026-09-17、M7 于 2026-09-18 加入）。
//------------------------------------------------------------------------------
    reg  [15:0] r_div;
    reg         r_key_d;
    reg         r_key_pulse;
    // r_mode_hold / r_mode 的声明在 §7.6 开头（帧边界采样要先用到它们）

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_div       <= 16'd0;
            r_key_d     <= 1'b0;
            r_key_pulse <= 1'b0;
        end else begin
            r_key_d     <= I_key;
            r_key_pulse <= 1'b0;
            if (I_key != r_key_d)
                r_div <= 16'd0;
            else if (r_div != KEY_TOP) begin
                r_div <= r_div + 16'd1;
                if (r_div == KEY_TOP - 16'd1)
                    r_key_pulse <= ~I_key;      // 按下（低有效）才产生脉冲
            end
        end
    end

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mode_hold <= MODE_RAW;
        else if (r_key_pulse)
            r_mode_hold <= (r_mode_hold == MODE_REGIONFILL) ? MODE_RAW : (r_mode_hold + 3'd1);
    end

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_mode <= MODE_RAW;
        else if (w_mode_sw)                        // = w_sof_a0，或切进 M7 时提前 1 拍
            r_mode <= w_mode_nx;                   // = I_mode_set ? I_mode_sel : r_mode_hold
    end

    assign O_mode = r_mode;

//------------------------------------------------------------------------------
// 9. 8 选 1 MUX + 掩蔽 + 输出寄存器（→ M0..M6 L = 5；M7 L = 8，见 §一·补）
//------------------------------------------------------------------------------
    reg [95:0] w_mux_dat;
    reg  [2:0] w_mux_ctl;

    always @ (*) begin
        case (r_mode)
            MODE_RAW    : begin w_mux_dat = w_a0_dat; w_mux_ctl = w_a0_ctl; end
            MODE_GRAY   : begin w_mux_dat = w_a1_dat; w_mux_ctl = w_a1_ctl; end
            MODE_BIN    : begin w_mux_dat = w_b_dat;  w_mux_ctl = {w_b_val, w_b_lst, w_b_usr}; end
            MODE_EDGE   : begin w_mux_dat = w_s_dat;  w_mux_ctl = {w_s_val, w_s_lst, w_s_usr}; end
            MODE_SMOOTH : begin w_mux_dat = w_m_dat;  w_mux_ctl = {w_m_val, w_m_lst, w_m_usr}; end
            MODE_TARGET : begin w_mux_dat = w_m5fam ? w_m5_dat : w_a5_dat;   // 2026-10-03 AUTO 四框
                                    w_mux_ctl = w_a5_ctl; end
            MODE_MOTION : begin w_mux_dat = w_m6_dat; w_mux_ctl = w_a0_ctl; end
            // M7：数据与控制**都取 u_rf 自己的**（该支路在延迟 7 拍，
            //     用 w_a0_ctl 会把 M7 帧的行边界切错 3 拍；见 §一·补）
            MODE_REGIONFILL : begin w_mux_dat = w_rf_dat;   // ★十二修：回退黑白二值（用户：叠色出紫条纹，上一版其实可以）。w_m7_ovl 保留备用。
                                    w_mux_ctl = {w_rf_val, w_rf_lst, w_rf_usr}; end
            // 非法档位回落到直通，与复位值 M0 同一条路
            default     : begin w_mux_dat = w_a0_dat; w_mux_ctl = w_a0_ctl; end
        endcase
    end

    // 掩蔽期输出【原图】：用 M0 那条对齐后的原图（同在延迟 4 拍）
    //
    // ⚠⚠ M7 例外：**本级不叠顶层掩蔽**，直接用填充结果。两条理由：
    //   (1) u_rf 内部已有同口径的掩蔽（3 行 + 每行第 0 拍，见模块文件头 §四），
    //       任务书 §二 明令"这一档不要再叠行掩蔽"；
    //   (2) 顶层掩蔽 r_mask_d 与 w_a0_dat 都对齐在延迟 4 拍，而 M7 支路在延迟 7 拍，
    //       硬叠会把掩蔽区整体挪 3 拍（每行 12 像素）—— 比不叠更错。
    //   于是 M7 帧的掩蔽区输出**黑**（模块契约），其余档位仍是"掩蔽期输出原图"。
    wire [95:0] w_masked_dat = (r_mode == MODE_REGIONFILL) ? w_mux_dat
                             : (r_mask_d ? w_mux_dat : w_a0_dat);

//------------------------------------------------------------------------------
// 7.7d XY 十字准星（2026-10-03 夜，用户点名）
//      中心 = 当前档 r_bb_* 的 1/2（M5=获胜族框（固定档=并集框），M6=运动框）。
//      只在 M5/M6 生效；横线 y=cy、x∈[cx-8,cx+8]，竖线 x=cx、y∈[cy-8,cy+8]，黄 FFFF00。
//      12bit 加宽后再移位（x0+x1 最大 2558>2047，11bit 相加会截——framediff 同型老坑）。
//      优先级：准星 > 框 > 轨迹点 > 原图（本块挂在最终 w_masked_dat 之后=天然最上层）。
//      M7 无端：门控只放 MODE_TARGET/MODE_MOTION，且在 4 拍域（r_m6_xg_d/y_d[3]
//      就是 MUX 输入那拍的坐标，M5 四框 §7.7c 同基准）。
//------------------------------------------------------------------------------
wire        w_xh_en = r_bb_v && ((r_mode == MODE_TARGET) || (r_mode == MODE_MOTION))
                   && (r_bb_x0 <= r_bb_x1) && (r_bb_y0 <= r_bb_y1);
wire [11:0] w_xh_cx = ({1'b0, r_bb_x0} + {1'b0, r_bb_x1}) >> 1;
wire [11:0] w_xh_cy = ({1'b0, r_bb_y0} + {1'b0, r_bb_y1}) >> 1;
wire [3:0]  w_xh_hit;
generate
    for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_xh
        wire [11:0] w_xh_px = {1'b0, w_m5_xbase} + g5p;
        wire [11:0] w_xh_py = {1'b0, r_m6_y_d[3]};
        wire [11:0] w_xh_dx = (w_xh_px >= w_xh_cx) ? (w_xh_px - w_xh_cx) : (w_xh_cx - w_xh_px);
        wire [11:0] w_xh_dy = (w_xh_py >= w_xh_cy) ? (w_xh_py - w_xh_cy) : (w_xh_cy - w_xh_py);
        assign w_xh_hit[g5p] = w_xh_en
            && (((w_xh_py == w_xh_cy) && (w_xh_dx <= 12'd8))
             || ((w_xh_px == w_xh_cx) && (w_xh_dy <= 12'd8)));
    end
endgenerate
wire [95:0] w_xh_dat;
generate
    for (g5p = 0; g5p < 4; g5p = g5p + 1) begin : g_xhmix
        assign w_xh_dat[24*(3-g5p) +: 24] =
               w_xh_hit[g5p] ? 24'hFFFF00 : w_masked_dat[24*(3-g5p) +: 24];
    end
endgenerate

    always @ (posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tdata  <= 96'd0;
            O_tvalid <= 1'b0;
            O_tlast  <= 1'b0;
            O_tuser  <= 1'b0;
        end else begin
            O_tdata      <= w_xh_dat;
            O_tvalid <= w_mux_ctl[2];
            O_tlast  <= w_mux_ctl[1];
            O_tuser  <= w_mux_ctl[0];
        end
    end

endmodule
