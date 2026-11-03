//==============================================================================
// 文件名   : osd_mixer.v
// 模块名   : osd_mixer
// 日期     : 2026-09-17
// 版本     : v1.6
// 描述     : OSD 叠加混合器 —— 「安路」Logo + 一行动态信息（FR-4 硬性要求）
//
//  2026-10-24 v1.6（资源/时序优化）：字库 my_charlib 由「672 条 case 的组合译码器」
//  改成「同步读 ROM（片上 ERAM，1 拍读延迟）」。因为 RAM 读多了一拍，本模块在
//  第 1 级流水之后**再插一级**（§11b 的 p2 寄存器组），把混合级的所有陪跑信号
//  整体再延后一拍，保证文字位置 / 掩蔽优先级 / 混合规则逐拍不变。
//  ⇒ **唯一的行为变化**：O_tdata/O_tvalid/O_tlast/O_tuser 相对输入的延迟由
//     **2 拍变成 3 拍**（屏上 LAT 读数 +1）。已用改动前的 RTL 当参考模型逐拍比对
//     证明「新版输出 = 旧版整体延迟 1 拍、其余逐 bit 相等」
//     （sim_charlib_ram\tb_osd_equiv.v，ALL PASS）。
//  为什么值得：TD 实测 u_charlib #lut = 3785（全设计最大的单块 LUT 消耗），
//     换成 672x16 的 ERAM 约 1 块；同时把 "r_info_x → O_tdata" 这条约 20 级 LUT
//     的关键路径在 ERAM 处劈成两段（地址侧 / 混合侧），详见 §二·补2 与 §11b。
//
//  2026-09-17 v1.5（G1 返工）：安路 Logo 从"例化官方 anlogic_logo_rom 4 份"改成
//  "一拍读 4 像素的 ERAM 位图"（src\alg_logo_eram.v）。原因是官方那个文件是
//  6387 条 case 的组合译码器，4 份 ≈ 10236 slice，器件放不下（见 §五·补.1）。
//  同一版顺带把档位字符补到 M7（§5）。
//  2026-09-17 v1.4：首次接入安路 Logo（比赛基础要求 (4)）。
//
//  ---------------------------------------------------------------------------
//  【一、数据通路】
//  ---------------------------------------------------------------------------
//  本模块串在 alg_top 之后、视频输出之前，是**纯叠加**模块：不改算法结果，
//  只在指定的矩形区域内把原像素换成 OSD 颜色，区域外一个 bit 都不动。
//
//      I_tdata(96) ──┬────────────────────────────────► 原样透传（区外）
//                    └──► 像素级替换（区内） ────────► O_tdata(96)
//
//  ---------------------------------------------------------------------------
//  【二、延迟契约（S0-02 §8.1⑥：所有输出同拍）】
//  ---------------------------------------------------------------------------
//  输出相对输入**恒定延迟 3 拍**（v1.6 起；v1.2~v1.5 是 2 拍，v1.1 是 1 拍），
//  4 路输出（tdata/tvalid/tlast/tuser）全部在**同一级输出寄存器**上装载 ——
//  不存在"数据走 3 拍、控制走 2 拍"的错位。
//  O_tready 是组合直通（`assign O_tready = I_tready;`），全链路不反压。
//
//  为什么 v1.6 又多了 1 拍：字库改成同步读 ROM（ERAM）后，"
//  地址进 → 下一拍点阵出"，这 1 拍必须由流水线吸收。做法**不是**把输出级再延一拍
//  （那会让混合级读到已经翻页的坐标），而是**在混合级前面插一级 p2 寄存器**
//  （§11b）：点阵从那块 ROM 的读寄存器出来时，陪跑的像素/Logo/字内列基址/行区间
//  也从 p2 同时出来，两边仍然逐拍对齐。清单见 §11b，一个都不能漏。
//
//  ---------------------------------------------------------------------------
//  【二·补、为什么把延迟从 1 拍改成 2 拍（2026-09-16 时序优化）】
//  ---------------------------------------------------------------------------
//  TD 布线后报告：本模块是全设计**自研代码的最差路径** ——
//      Begin: u_isp_top/u_osd_mixer/r_info_x_reg[8]
//      End  : u_isp_top/u_osd_mixer/O_tdata_reg[14]
//      Data Path Delay 14.623ns / Logic Level 17 / Slack 1.853ns @16.668ns(60MHz)
//  逐级展开就是一条**没有寄存器的长组合链**：
//      r_info_x → 十进制拆位(9 级优先比较链 + 4 级行波加法) → 十位链 → 个位
//      → ASCII → case(w_txt_ci) 选字符码 → w_rom_index → my_charlib 查表
//      → 点阵位选 w_txt_hit0..3 → w_pix_text_hit → w_mix → O_tdata
//
//  **加在哪**：在"十进制数字/字符码算完"与"查表 + 命中 + 混合"之间，插入一级
//  流水寄存器（§11）。第 1 级 = 原来的组合逻辑（只把它的结果寄存下来）；
//  第 2 级 = ASCII/字符码/字库索引/查表/命中/混合/输出（§12、§13）。
//
//  **核心纪律**：合并点另一侧的所有信号必须**一起寄存同样一拍**，两边才仍然
//  逐拍对齐 —— 位置侧（行/列/字符下标/字内列基址）、Logo 侧（4 命中 + 4 颜色
//  = 100 bit）、像素数据（96 bit）、以及控制（tvalid/tlast/tuser 派生的
//  r_vld1/r_tlast/r_tuser）一个都不能漏。漏一个就是两面错位，不是"少一点功能"。
//
//  **代价与收益**：O_tdata / O_tvalid / O_tlast / O_tuser 相对输入的延迟由
//  1 拍变成 2 拍（这是**唯一**的行为变化，用改造前的 RTL 当参考模型逐拍比对
//  证明：输出序列 = 老版本整体延迟 1 拍，见 sim/check_pipe_equiv.py）。
//  掩蔽规则、文字>Logo>原像素的优先级、O_tready 语义一律不动。
//
//  ⚠ 两个最容易漏的"活叶子"（第 2 级绝不能再直接读，否则等价性被破坏）：
//    · w_mode_chars 由**端口** I_info_mode 组合而来（不是 r_info_mode）；
//    · FPS 的两个半字节由 r_info_fps 组合而来。
//    两者都在第 1 级一起寄存（§11），连"输入侧同一沿变化"也逐拍对齐。
//
//  ---------------------------------------------------------------------------
//  【二·补2、v1.6：字库改 ERAM 之后，第 2 拍从哪里来（改动前必读）】
//  ---------------------------------------------------------------------------
//  v1.5 的第 2 级是**纯组合**的：p1 寄存器 → 字符槽 case → ASCII→索引 →
//  my_charlib(case 查表) → 点阵位选 → 混合 → O_tdata 寄存器。整条链就是那条
//  约 20 级 LUT 的关键路径。
//
//  v1.6 把 my_charlib 换成同步读 ROM：**地址进 → 下一拍点阵出**。于是：
//      · 第 1 级（§11，p1）不动：坐标/十进制/字符槽下标/Logo/像素照旧捕获；
//      · 第 1 级之后仍然算 字符槽 case → ASCII→字库索引 → 送进 ROM 的地址
//        （这一段只剩几级 LUT，且**不再往下长**）；
//      · ROM 的读寄存器 = 新的"点阵出来那一拍"（第 2 拍）；
//      · 同一沿再打一组 p2 寄存器（§11b），把混合要用的一切陪跑量从 p1 复制过来；
//      · 第 3 拍：点阵位选 + 混合 → 输出寄存器（§13）。
//  关键不变式（等价性的全部依据，一句话）：
//      **ROM 的地址和 p2 的数据来自同一拍同一个 p1 值**（都是 p1(j)），
//      所以"点阵属于哪个像素"与"像素数据/列基址"永远不会错位。
//  逐拍等价：新版任意一拍 k 的输出 ≡ 旧版第 k-1 拍的输出（含 tvalid/tlast/tuser、
//  含气泡期强制置 0 的语义），由 tb_osd_equiv.v 全域逐比特比对，ALL PASS。
//
//  ---------------------------------------------------------------------------
//  【三、坐标定义（与 S0-02 §2.1 一致，逐字）】
//  ---------------------------------------------------------------------------
//  一拍 = 行内相邻 4 个像素：I_tdata[95:72] 是**最左**像素（列 4*x_grp+0），
//  I_tdata[71:48]/[47:24]/[23:0] 依次右移。所以
//      x(k) = 4*r_x + k      k = 0..3      （r_x 是拍计数器，不是像素计数器）
//      y    = r_y
//  行 = 320 拍（1280/4），拍计数绕回点 319→0 时行号 +1；帧首 I_tuser 把坐标归零。
//
//  ---------------------------------------------------------------------------
//  【四、相位（本文件最容易踩的地方，务必按这里的约定读）】
//  ---------------------------------------------------------------------------
//  链路上同时存在三份"坐标"，它们**不是同一拍**，混用就是本模块历史上
//  文字面 447/16384 像素不符的根因：
//
//    (1) 计数器相位  r_x_grp / r_y_pos
//        语义是"上一拍处理完的拍号"，所以**本拍总线**上那份像素的列基准
//        是 4*r_x_grp（不是 4*(r_x_grp+1)）。
//    (2) 总线相位    w_x_base = 4*r_x, r_x = r_x_now
//        r_x_now 在装载 O_tdata 的同一沿从 w_x_nx 载入，w_x_nx = r_x_grp+1，
//        所以它比"本拍总线像素"**早一拍**。Logo 面用这一相位，与
//        LOGO_X/LOGO_Y 常量同相，实测 0 错 —— 不要动它。
//    (3) 像素真值相位  r_x_txt / r_y_txt
//        = 4*r_x_grp / r_y_pos，正好等于"本拍总线那一份像素"的坐标。
//        文字面必须用这一相位，否则整行文字右移 4 像素、下移 1 行。
//
//  ---------------------------------------------------------------------------
//  【五、OSD 版面（全部参数化，默认 1280x720）】
//  ---------------------------------------------------------------------------
//  · 安路 Logo：alg_logo_eram（**官方素材**量化后的 160x160 ERAM 位图，见 §10b），
//    左上角 (ANLOGO_X, ANLOGO_Y) = (0, 0)。
//    ⇒ 比赛基础要求 (4)「OSD 须包含『安路』标识 Logo」。
//  · 自研 Logo：my_logo_rom（自研原创 128x64，1bpp + 2 色），(LOGO_X, LOGO_Y)，
//    默认右下角。
//  · 文字：my_charlib（自研原创 42 字 x 16x16 点阵），一行最多 N_CHAR_MAX 个字，
//    左上角 (TEXT_X, TEXT_Y)，每字 16 像素宽、16 行高，1x 不缩放。
//  · 叠加优先级：**文字 > 安路Logo > 自研Logo > 原像素**。
//    真实版面（1280x720）三者互不重叠：安路 Logo 占 x<160 且 y<160，自研 Logo 在
//    右下 (1136,640)，文字在左下 (16,688)。但优先级必须写死 —— TB 会故意让三个面
//    重叠来激发它，靠"反正不重叠"省掉优先级判断是测不出来的隐患。
//  · 三个 OSD 面都是"命中即替换"的硬叠加：自研 Logo（my_logo_rom，1bpp + 2 色）、
//    文字（my_charlib，点阵位）都只有 1 bit 命中位；安路面是 6 bit/像素的调色板下标，
//    index 0 当透明。**都没有 alpha**，没有半透明混合 —— 与官方 osd 例程口径一致，
//    也便于逐像素做精确自证。
//    （官方素材 anlogic_logo_rom.v 的 6387 条 case 项 bit24 全为 1，即"在表里 = 不透明"，
//      透明像素由 case 的 default=0 兜住；已用脚本对着 .v 全文核过，不是猜的。）
//  · 例化数：自研 Logo ROM 是**逐像素**接口（地址只指一个像素），一拍 4 个像素要
//    4 个实例（`u_logo0..3`）；字库是**逐字符**接口（行号 + 字符下标），同拍 4 个像素
//    的行号/字符下标完全相同（只有字内列不同），所以只例化 1 个（§12.3）；
//    安路 Logo 是**一拍读一个字（4 像素）**的 ERAM，所以只例化 1 个（§10b）。
//
//  ---------------------------------------------------------------------------
//  【五·补、安路 Logo 的实现取舍（改动前先读这段）】
//  ---------------------------------------------------------------------------
//  1【为什么不用官方那个 .v 直接例化】它是 6387 条 case 的**组合**译码器，TD 实测
//    单份 #lut 3143 / #slice 2559；一拍 4 像素要 4 份 ≈ 10236 slice，而器件只有
//    21216 slice、板级工程已用 13891 ⇒ 放不下，方案作废（面积由案例条数决定，
//    跟输出位宽无关，降色深/降分辨率都救不了）。改用 ERAM 位图：8 块 ERAM 换掉
//    约 10236 slice，详见 §10b 与 src\alg_logo_eram.v。
//  2【量化】官方素材 579 色 → 63 色调色板 + index0 透明（6 bit/像素）。
//    每通道误差 max 20 / mean 0.62 / >16 的像素 7 个（0.11%）；对照 16 色只省 1 块
//    ERAM 却把误差放大到 max 47 / mean 1.68 ⇒ 选 64 色。台账与独立复算见
//    sim\logo_64c.stats.txt 与 sim\check_anlogo.py 的"编码保真度"断言。
//  3【对齐约束】一拍读一个字 ⇒ **ANLOGO_X 必须是 4 的倍数**（§10c 有仿真护栏）。
//    代价是位置不能任意摆；本设计要求固定在左上角 (0,0)，不受影响。
//  4【相位】ERAM 读是"地址进 → 下一拍数据出"，所以坐标必须**提前一拍**送给它
//    （§10b 的 w_x_nx1/w_y_nx1）。这是本节唯一容易错的地方，漏一拍 = 整面右移 4 像素。
//  5【乘法器】官方 hdmi_mixer 的 S_logo_y*LOGO_W 被 TD 推成 DSPMULT，是官方基线
//    最差路径的一部分。这里行基址写成移位加法（40 = 32 + 8），绝不出乘法器。
//
//  ---------------------------------------------------------------------------
//  【六、信息字符化的下标表（TEXT_LEN = 27）】
//  ---------------------------------------------------------------------------
//   pos:  0 1 2 3 4 5 6 7 8 9 ...             （每个 pos = 16 像素）
//    0..1  : "M" + 档位号（I_info_mode 0..8 → '0'..'8'，其它 → 字库未定义位 = 空白）
//    2     : 空格
//    3..6  : "FPS:"
//    7..8  : I_info_fps[7:0] 的高/低半字节，**十六进制**显示
//    9     : 空格
//    10..13: "LAT:"
//    14..16: I_info_lat 的 3 位十进制
//    17    : 空格
//    18..19: "X:"
//    20..23: I_info_x 的 4 位十进制
//    24    : 'Y'（"Y:xxxx" 因版面长度截断，只留 'Y' 标记）
//    25+   : '?'，排版补位（超过 N_CHAR_MAX 的实际不显示）
//  ※ FPS 用十六进制是**故意**的：32 位二进制转十进制要真除法器（几百 LUT），
//    改成 hex 显示信息量等价。lat/x 是 11 位，用常数比较逐位展开（见 §5 实现）。
//
//  ---------------------------------------------------------------------------
//  【七、没做的事 / 已知限制（如实列出）】
//  ---------------------------------------------------------------------------
//  1. 十进制展开是"逐位常数比较"写法，不是通用除法器，只覆盖 0..999 / 0..2047；
//     I_info_lat 超过 999 时千位截断显示 0。
//  2. I_info_cnt 与 I_info_y **本版不显示**：一行版面放不下，任务点名要的是
//     档位/帧率/延迟/坐标(x)。端口保留在接口上，综合壳里参与异或防止被裁。
//  3. 纯硬叠加：无 alpha 混合、无背景框、无字符缩放。
//  4. 安路 Logo 是 6 bit/像素的**有损量化**（63 色），不是逐 bit 还原官方素材；
//     误差台账见 §五·补.2，误差界由 check_anlogo.py 独立复算并断言。
//  5. 安路 Logo 的列位置必须 4 像素对齐（ANLOGO_X % 4 == 0，§10c 护栏）；
//     本设计固定在 (0,0)，不受影响。
//  6. 面积：ERAM 8 块 + 调色板 4x24 LUT 是**估算**（依据 prj\_eram_init_check\
//     logo_mem24.area 的同规模实测），本模块未跑 TD 综合，以板级工程下一次综合为准。
//
//  ---------------------------------------------------------------------------
//  【八、编码纪律】
//  ---------------------------------------------------------------------------
//  · Verilog-2001，单文件单模块，UTF-8 无 BOM；I_/O_ 端口前缀，r_/w_ 内部前缀。
//  · 不用 function/task/fork/wait/force/#delay；无 latch（每个 always 要么带复位、
//    要么组合分支完整）；一个 always 只干一件事。
//  · 复位风格：坐标计数器与流水线寄存器用异步复位（与 win3x3_96 同风格），
//    信息寄存器用同步复位（S0-02 §0 推荐）。两者都不产生 latch。
//==============================================================================
`timescale 1ns / 1ps

module osd_mixer #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    // ---- 安路官方 Logo 版面：左上角 (0,0)。160x160 是**素材固有尺寸**，见下面 localparam ----
    parameter ANLOGO_X   = 0,
    parameter ANLOGO_Y   = 0,
    // ---- Logo 版面：★2026-10-25 竞赛十周年 Logo（288x114）移到右上角 (984, 8) ----
    //      安路 Logo 只占左上 160x160，右上角 y<160 且 x>160 全空，可容纳 288 宽 ⇒ 字高 32px
    parameter LOGO_X     = IMG_WIDTH  - 296,      // 1280-296 = 984（288 宽 + 8 右边距）
    parameter LOGO_Y     = 8,                     // 上边距 8
    // ---- 文字版面：默认左下角，左边距 16、下边距 16 ----
    parameter TEXT_X     = 16,
    parameter TEXT_Y     = IMG_HEIGHT - 32,       // 720-32   = 688
    // ---- 颜色 ----
    parameter [23:0] OSD_LOGO_COLOR = 24'h154B96, // 竞赛十周年 Logo 主色（深蓝 #154B96）
    parameter [23:0] OSD_TEXT_COLOR = 24'hFFFFFF  // 文字前景
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    // ---- 视频流（来自 alg_top）----
    input  wire [95:0]  I_tdata,       // 4 x RGB888，[95:72] 是最左像素
    input  wire         I_tvalid,
    input  wire         I_tlast,
    input  wire         I_tuser,
    input  wire         I_tready,
    // ---- 要显示的信息（静态，可由上层更新）----
    input  wire [10:0]  I_info_mode,   // 当前档位号 0..7（M6=帧差、M7=直方图均衡）
    input  wire [31:0]  I_info_fps,    // 帧率
    input  wire [10:0]  I_info_lat,    // 延迟（拍）
    input  wire [10:0]  I_info_x,      // 检测坐标
    input  wire [10:0]  I_info_y,
    input  wire [31:0]  I_info_cnt,
    // ★★2026-10-22 新增：实测分辨率与帧计数（由 frame_stat 数出来，不是常量）
    input  wire [15:0]  I_info_hpx,     // 实测每行像素数
    input  wire [15:0]  I_info_vln,     // 实测每帧行数
    // ★★2026-10-24 采集→显示的总延迟（来自 e2e_lat 模块，单位：毫秒）
    input  wire [9:0]   I_info_latms,
    input  wire [5:0]   I_info_idx,      // ★本秒内帧序号 0~FPS_NOM-1    // 检测数量：非零 = 检测到（驱动 TARGET/NONE，见 §七.2）
    // 2026-09-20（2.4(2)「识别」）：算法侧真算出来的颜色类别。
    //   0 = 红主导 / 1 = 绿主导 / 2 = 蓝主导。只在 COLOR 档显示
    //   （别的档位命中像素不是"颜色命中"，报类别会误导）。见 §11 第 38~43 格。
    input  wire [1:0]   I_info_class,
    // 2026-09-20（2.5(2) 动态目标跟踪）：跟踪编号 0..99。只在 COLOR 档、且检测到目标时
    //   显示 —— 挤在第 42~43 格，与第 38~40 格的颜色名合成 "RED 01"。
    //   ⚠ 不是帧计数器：只有在目标**丢失 >=4 帧后重新捕获**时才 +1（见 alg_color_detect_96 §10c）。
    input  wire [7:0]   I_info_tid,
    input  wire [2:0]   I_info_fam_valid,
    input  wire [32:0]  I_info_fam_cx,I_info_fam_cy,
    input  wire         I_info_auto,
    // ★★ 2026-10-03 夜：1=本帧无目标 ⇒ "X:xxxx Y:xxxx" 段整体打空格（数字跳成 0000 迷惑，
    //   整段消失最直白）。只影响显示，不碰任何统计语义。
    input  wire         I_info_nov,
    // ---- 输出 ----
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready
);

//------------------------------------------------------------------------------
// 0. 常量
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE = IMG_WIDTH >> 2;             // 1280 >> 2 = 320 拍/行
localparam XW             = $clog2(BEATS_PER_LINE);     // 320 → 9
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;     // 319
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;         // 719

// 2026-09-20：16 → 32 → **40**。
//   16 那次：第 16 格之后**全被切掉** ⇒ LAT 个位看不到（屏上 "LAT:00"）、
//   已写好代码的 X 坐标一个像素都画不出来。
//   32 那次：X 坐标与完整 LAT 上屏了，同时暴露了 X 千位的拆位 bug（已修）。
//   40 这次（2.4(2) 缺口 1）：腾出第 24~29 格放 "Y:xxxx"。
//   40 格 = 640 像素宽，起于 TEXT_X=16 ⇒ 占 x∈[16,656)，与右下角自研 Logo(1136,640)
//   和左上角安路 Logo(y<160) 都不重叠。
//   ⚠ 位宽这次**必须动**：40 > 32，`w_txt_ci` 从 5 位扩到 6 位（取 dx[9:4]）。
//     32 格时 5 位刚好取满 0..31，所以那次不用改；这次不能照抄。
localparam N_CHAR_MAX = 64;                             // ★2026-10-22 48→64：新增分辨率/帧计数两栏
localparam TEXT_W     = 16;                             // 单字像素宽
localparam TEXT_H     = 16;                             // 单字像素高

// ---- 安路官方 Logo 的固有尺寸是 160x160，**不在这里**参数化：
//      位图/调色板/地址口径全部落在 src\alg_logo_eram.v 里（它才是消费方）；
//      本模块只负责把坐标提前一拍喂过去 + 把命中/颜色并进第 1 级流水（§10b）。

assign O_tready = I_tready;                             // 全链路不反压

//------------------------------------------------------------------------------
// 1. 坐标计数器（计数器相位：语义是"上一拍处理完的拍号"）
//------------------------------------------------------------------------------
reg [XW-1:0] r_x_grp;        // 拍计数器 0..319（不是像素计数器）
reg [10:0]   r_y_pos;        // 行计数器 0..719

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin                              // 帧首：坐标同步
            r_x_grp <= {XW{1'b0}};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin        // 行末回绕
            r_x_grp <= {XW{1'b0}};
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 2. 坐标流水
//
// 计数器 r_x_grp/r_y_pos 的语义是"上一拍处理完的拍号"（它在同一沿才 +1），
// 所以本拍数据的坐标 = 计数器加一（含行末回绕）：
//     w_x_nx / w_y_nx = 本拍数据的坐标（纯组合）
//     r_x_now / r_y_now = 打一拍，与输入侧那份数据同拍
// 输出级装载的就是 I_tdata，所以判据直接用 r_x_now/r_y_now（别名 r_x/r_y）。
//------------------------------------------------------------------------------
reg [10:0] w_x_nx;           // 本拍（正被装载的那一拍）数据的列组号
reg [10:0] w_y_nx;           // 本拍数据的行号

always @ (*) begin
    if (I_tuser) begin                                   // 帧首：本拍就是 (0, 0)
        w_x_nx = 11'd0;
        w_y_nx = 11'd0;
    end else if (r_x_grp == LAST_BEAT) begin              // 行末：列回绕、行 +1
        w_x_nx = 11'd0;
        w_y_nx = (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
    end else begin
        w_x_nx = {2'b00, r_x_grp} + 11'd1;
        w_y_nx = r_y_pos;
    end
end

// r_x_now = w_x_nx 打一拍。
// ⚠⚠ 它**不是**"本拍被装载的那份数据自己的坐标"，而是**上一拍**的坐标：
//   r_x_grp <= r_x_grp + 1 且 w_x_nx = r_x_grp + 1  ⇒  r_x_now(t) ≡ r_x_grp(t)。
//   换句话说这个寄存器是冗余的。2026-09-14 修正：原注释把它写成了本拍坐标，
//   Logo 面据此拿它做判据，于是整体右移 4 像素（独立复测 822/16384 像素不符）。
reg [10:0]   r_x_now;
reg [10:0]   r_y_now;
reg          r_tlast;
reg          r_tuser;
reg          r_vld1;         // I_tvalid 延迟 1 拍（**不被 I_tvalid 门控**）

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_now <= 11'd0;
        r_y_now <= 11'd0;
    end else if (I_tvalid) begin
        r_x_now <= w_x_nx;
        r_y_now <= w_y_nx;
    end
end

// r_x/r_y 只是 r_x_now 的别名，**已不再用作 OSD 判据坐标**（判据统一用下面的
// w_x_base / w_y_base = 本拍坐标）。保留它们仅仅因为 tb_osd_mixer.v 的 dump 还在探。
wire [10:0] r_x = r_x_now;
wire [10:0] r_y = r_y_now;

//------------------------------------------------------------------------------
// 2b. OSD 判据坐标（文字面与 Logo 面**共用这一份**——共用是硬要求：两面画在同一份
//     I_tdata 上，必须与同一份像素同拍）。
//     基准 = 4 × 本拍坐标；w_x_nx / w_y_nx 就是"本拍总线上那份像素"的坐标：
//     计数器 r_x_grp 的语义是"上一拍拍号"（它在本沿才 +1），故 w_x_nx = r_x_grp + 1。
//------------------------------------------------------------------------------
wire [10:0] w_x_base = {w_x_nx[8:0], 2'b00};
wire [10:0] w_y_base = w_y_nx;

wire [11:0] w_txt_dx_txt = {1'b0, w_x_base} - {1'b0, TEXT_X};
wire w_multi_osd=(I_info_mode==11'd13)||((I_info_mode==11'd7)&&I_info_auto);
wire w_auto_text_row=w_multi_osd && (w_y_base>=TEXT_Y) && (w_y_base<TEXT_Y+TEXT_H);
// Eight clear scanlines between the two 16-pixel text rows. Rebase the
// upper row's glyph address as well, so its letters are not rotated by 8.
wire [3:0] w_txt_row=(w_multi_osd && !w_auto_text_row)
                    ? (w_y_base-(TEXT_Y-TEXT_H-8)) & 4'hF
                    : (w_y_base-TEXT_Y) & 4'hF;
wire        w_txt_inrow  = ((w_y_base >= TEXT_Y) && (w_y_base < (TEXT_Y + TEXT_H)))
                         || (w_multi_osd && w_y_base>=TEXT_Y-TEXT_H-8 && w_y_base<TEXT_Y-8);
wire        w_txt_incol  = (w_x_base >= TEXT_X) &&
                           (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)));

//------------------------------------------------------------------------------
// 3. 文字面拍级量（组合）
//
//  ⚠ 字内列基址必须取 dx[3:2]：dx = x - TEXT_X 恒为 4 的倍数，bit[1:0] 永远为 0；
//    早先错写成 dx[1:0]，基址恒 0，于是每一拍都去取点阵的 bit[15:12]，
//    屏幕上每个字只剩最左 4 列反复重画（实测 447/16384 像素不符）。
//------------------------------------------------------------------------------
wire [5:0] w_txt_ci       = w_txt_dx_txt[9:4];
wire [1:0] w_txt_col_base = w_txt_dx_txt[3:2];
wire [7:0] w_auto_char;
wire [2:0] w_auto_count,w_auto_valid;
wire w_auto_ready;
reg r_auto_row_p1,r_is_auto_p1;
auto_target_text u_auto_text(
 .I_clk(I_clk),.I_rst_n(I_rst_n),.I_frame(I_tvalid&&I_tuser),
 .I_valid(I_info_fam_valid),.I_x(I_info_fam_cx),.I_y(I_info_fam_cy),
 .I_idx(w_txt_ci),.O_char(w_auto_char),.O_count(w_auto_count),
 .O_valid(w_auto_valid),.O_ready(w_auto_ready));
always @(posedge I_clk or negedge I_rst_n) begin
 if(!I_rst_n) begin r_auto_row_p1<=0;r_is_auto_p1<=0;end
 else begin r_auto_row_p1<=w_auto_text_row;r_is_auto_p1<=w_multi_osd;end
end
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tlast <= 1'b0;
        r_tuser <= 1'b0;
    end else if (I_tvalid) begin
        r_tlast <= I_tlast;
        r_tuser <= I_tuser;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;         // 这就是握手延迟本身
end

//------------------------------------------------------------------------------
// 4. 信息寄存器（上层可随时更新；延迟 1 拍生效，与像素流无相位关系）
//------------------------------------------------------------------------------
reg [10:0] r_info_mode;
reg [31:0] r_info_fps;
reg [10:0] r_info_lat;
reg [10:0] r_info_x;
reg [10:0] r_info_y;
// 2026-09-20（2.4(2)「叠加检测结果与文字说明」）：I_info_cnt 原来只挂在端口上、
//   内部一根线都没接（旧注释说"一行版面放不下"）。现在第 25~30 格空出来了，
//   用它的"是否非零"当作**检测到目标**的标志，驱动屏上的 "TARGET"/"NONE"。
//   走两级寄存（本处 1 级 + §11 再 1 级），与 X 的十进制各位**完全同相** ——
//   照抄 §二·补 的纪律：端口派生的量要和别的信号一起寄存，否则两面错位。
reg [31:0] r_info_cnt;
// 2026-09-20：颜色类别，**逐条照抄 r_info_cnt 的两级寄存路径**
//   （本处 1 级 + §11 再 1 级）—— 这样"有没有目标"(r_hit_p1) 与
//   "是什么类别"(r_class_p1) 永远同相，不会出现一个是新帧、一个是旧帧。
reg [1:0]  r_info_class;
// 2026-09-20：跟踪编号，与 r_info_class **逐条同路**（本处 1 级 + §11 再 1 级）。
reg [7:0]  r_info_tid;

always @ (posedge I_clk) begin
    if (!I_rst_n) begin
        r_info_mode <= 11'd0;
        r_info_fps  <= 32'd0;
        r_info_lat  <= 11'd0;
        r_info_x    <= 11'd0;
        r_info_y    <= 11'd0;
        r_info_cnt  <= 32'd0;
        r_info_class <= 2'd0;
        r_info_tid   <= 8'd0;
    end else begin
        r_info_mode <= I_info_mode;
        r_info_fps  <= I_info_fps;
        r_info_lat  <= I_info_lat;
        r_info_x    <= I_info_x;
        r_info_y    <= I_info_y;
        r_info_cnt  <= I_info_cnt;
        r_info_class <= I_info_class;
        r_info_tid   <= I_info_tid;
    end
end

//------------------------------------------------------------------------------
// 5. 档位号 → "M<n>" 两个字符（16 bit = {第一个字符, 第二个字符}）
//    2026-09-17：补到 M7（并行工作流给 alg_top 加了 M6 = 帧差运动检测、
//    M7 = 直方图均衡）。漏补的话这两个档位在屏上只显示一个 "M" 加一片空白 ——
//    因为 '?'(0x3F) 在 §12.2 的 ASCII→字库索引里落到"未定义 → 空格"，
//    不是打成 '?' 字形）。0..7 之外的档位仍然走 default。
//------------------------------------------------------------------------------
reg [15:0] w_mode_chars;

always @ (*) begin
    case (I_info_mode)
        11'd0:   w_mode_chars = 16'h4D30;   // "M0"
        11'd1:   w_mode_chars = 16'h4D31;   // "M1"
        11'd2:   w_mode_chars = 16'h4D32;   // "M2"
        11'd3:   w_mode_chars = 16'h4D33;   // "M3"
        11'd4:   w_mode_chars = 16'h4D34;   // "M4"
        11'd5:   w_mode_chars = 16'h4D35;   // "M5"
        11'd13:  w_mode_chars = 16'h4D35;   // \"M5\"（13=AUTO 档显示编码）
        11'd6:   w_mode_chars = 16'h4D36;   // "M6"（帧差运动检测）
        11'd7:   w_mode_chars = 16'h4D37;   // "M7"（直方图均衡）
            11'd8:   w_mode_chars = 16'h4D38;   // "M8"（动漫风格）
        default: w_mode_chars = 16'h4D3F;   // "M?"（字库未定义位 → 显示为空白）
    endcase
end

//------------------------------------------------------------------------------
// 5b. 档位号 → **算法名**（5 个字符 = 40 bit）—— 2026-09-20
//
//   进阶 2.5(1)「多算法切换与**状态显示**」：原来只显示 "M3" 这种**编号**，
//   评委得先记住"M3 是边缘检测"才看得懂。改成直接显示算法名，一眼就明白在演示什么。
//
//   · 名字一律 5 个字符、不足的**右补空格** ⇒ 版面定长，后面的字段不会跟着漂。
//   · 字母全部取自 my_charlib 的 42 字库（0-9 A-Z : . / 空格 安 路）——
//     没有小写字母、没有 '-' 和 '='，所以名字只能用大写字母。
//   · 名字里避开 TARGET/MOTION，因为"TARGET"已经被检测结果那一栏占用了，
//     同一个屏上出现两次会让人以为是同一件事。所以 M5 用 COLOR、M6 用 MOVE。
//   · **独立的 always 块**，不碰上面那套 "M<n>" 的逻辑 —— 出问题时影响面小。
//------------------------------------------------------------------------------
reg [39:0] w_mode_name;

always @ (*) begin
    case (I_info_mode)
        11'd0:   w_mode_name = {8'h52, 8'h41, 8'h57, 8'h20, 8'h20};   // "RAW  " 原图
        11'd1:   w_mode_name = {8'h47, 8'h52, 8'h41, 8'h59, 8'h20};   // "GRAY " 灰度
        11'd2:   w_mode_name = {8'h42, 8'h49, 8'h4E, 8'h20, 8'h20};   // "BIN  " 二值化
        11'd3:   w_mode_name = {8'h45, 8'h44, 8'h47, 8'h45, 8'h20};   // "EDGE " 边缘提取
        11'd4:   w_mode_name = {8'h42, 8'h4C, 8'h55, 8'h52, 8'h20};   // "BLUR " 平滑
        11'd5:   w_mode_name = {8'h43, 8'h4F, 8'h4C, 8'h4F, 8'h52};   // "COLOR" 颜色目标检测
        11'd13:  w_mode_name = {8'h41, 8'h55, 8'h54, 8'h4F, 8'h20};   // \"AUTO \" 颜色自动识别
        11'd6:   w_mode_name = {8'h4D, 8'h4F, 8'h56, 8'h45, 8'h20};   // "MOVE " 帧差运动检测
        11'd7:   w_mode_name = {8'h46, 8'h4F, 8'h43, 8'h55, 8'h53};   // FOCUS
            11'd8:   w_mode_name = {8'h41, 8'h4E, 8'h49, 8'h4D, 8'h20};   // "ANIM " 动漫风格
        default: w_mode_name = {8'h20, 8'h20, 8'h20, 8'h20, 8'h20};   // 全空格
    endcase
end

//------------------------------------------------------------------------------
// 6. 十进制逐位展开（常数比较 + 常数乘法减法，无除法器、无 function）
//------------------------------------------------------------------------------
wire [3:0] w_lat_h = (r_info_lat >= 11'd900) ? 4'd9 :
                     (r_info_lat >= 11'd800) ? 4'd8 :
                     (r_info_lat >= 11'd700) ? 4'd7 :
                     (r_info_lat >= 11'd600) ? 4'd6 :
                     (r_info_lat >= 11'd500) ? 4'd5 :
                     (r_info_lat >= 11'd400) ? 4'd4 :
                     (r_info_lat >= 11'd300) ? 4'd3 :
                     (r_info_lat >= 11'd200) ? 4'd2 :
                     (r_info_lat >= 11'd100) ? 4'd1 : 4'd0;

wire [10:0] w_lat_r2 = r_info_lat - ({7'd0, w_lat_h} * 11'd100);

wire [3:0] w_lat_t = (w_lat_r2 >= 11'd90) ? 4'd9 :
                     (w_lat_r2 >= 11'd80) ? 4'd8 :
                     (w_lat_r2 >= 11'd70) ? 4'd7 :
                     (w_lat_r2 >= 11'd60) ? 4'd6 :
                     (w_lat_r2 >= 11'd50) ? 4'd5 :
                     (w_lat_r2 >= 11'd40) ? 4'd4 :
                     (w_lat_r2 >= 11'd30) ? 4'd3 :
                     (w_lat_r2 >= 11'd20) ? 4'd2 :
                     (w_lat_r2 >= 11'd10) ? 4'd1 : 4'd0;

wire [10:0] w_lat_r1 = w_lat_r2 - ({7'd0, w_lat_t} * 11'd10);
wire [3:0]  w_lat_o  = w_lat_r1[3:0];

// I_info_x 是 11 位（0..2047）：千位只有 0/1 两种，一次比较即可
// 2026-09-20 修：千位原来只给 0/1（`>=1000 ? 1 : 0`），**给不出 2**。
//   I_info_x 是 11 位（0..2047），所以 2000~2047 会被拆错，而且一错四位：
//     2047 -> 千位取 1、余 1047 -> 百位取 9、余 147 -> 十位取 9、余 57
//          -> 个位取 57[3:0] = 9     ⇒ 得到 "1999"（应为 "2047"）
//   这个 bug 一直藏着：排版表第 20~23 格（X 四位）此前被 N_CHAR_MAX=16 切在屏外，
//   从没画出来过；把行放宽到 32 格后它第一次上屏，逐像素比对立刻报了 774 处不符
//   （4 个字形 × 3 帧 × 每字形约 64 个亮点，数目正好对上）。
//   ⚠ 真实系统里 X ≤ 1279（画面宽 1280），碰不到 2000 以上，所以板上不会错；
//     但文件头写明覆盖 0..2047，这是实打实的契约缺口，补一个比较级修掉。
// The former input register plus combinational decimal expansion is
// replaced by an equivalent synchronous ROM lookup directly on I_info_x/y.
// Its result has the same clock phase as the former r_info_x/y digits.
reg [15:0] coord_bcd_rom [0:2047]; //synthesis ram_style = bram
integer coord_init;
initial begin
    for(coord_init=0;coord_init<2048;coord_init=coord_init+1)
        coord_bcd_rom[coord_init]=((coord_init/1000)<<12)
             |(((coord_init/100)%10)<<8)|(((coord_init/10)%10)<<4)|(coord_init%10);
end
reg [15:0] r_coord_x_bcd,r_coord_y_bcd;
always @(posedge I_clk) begin
    r_coord_x_bcd<=coord_bcd_rom[I_info_x];
    r_coord_y_bcd<=coord_bcd_rom[I_info_y];
end
wire [3:0] w_x_th=I_rst_n?r_coord_x_bcd[15:12]:4'd0;
wire [3:0] w_x_h=I_rst_n?r_coord_x_bcd[11:8]:4'd0;
wire [3:0] w_x_t=I_rst_n?r_coord_x_bcd[7:4]:4'd0;
wire [3:0] w_x_o=I_rst_n?r_coord_x_bcd[3:0]:4'd0;

// ---- 2026-09-20（2.5(2) 动态跟踪）：跟踪编号 → 两位十进制 --------------------
//   **零除法**，与上面 X/Y/LAT 同一手法。编号 0..99 ⇒ 十位只可能是 0..9（一串常数比较），
//   个位 = v - 十位*10（常数乘 10 = 加法）。
//   ⚠ 这一串比较**必须喂给 §11 的寄存器**，不能在 §12 里现算：
//     `r_info_x → O_tdata` 本来就是 osd_mixer 里最长的组合链（逻辑级数 19），
//     再往 §12 的锥里塞 9 级比较 + 一次 8 位减法会直接吃掉时序余量。
//     放进流水级之后，§12 只剩一个 "0x30 + 数字"，与别的十进制位完全同构。
//   ⚠ 声明位置必须在 §11 之前：Verilog-2001 不做前向引用（这里踩过一次）。
wire [3:0] w_tid_t = (r_info_tid >= 8'd90) ? 4'd9 :
                     (r_info_tid >= 8'd80) ? 4'd8 :
                     (r_info_tid >= 8'd70) ? 4'd7 :
                     (r_info_tid >= 8'd60) ? 4'd6 :
                     (r_info_tid >= 8'd50) ? 4'd5 :
                     (r_info_tid >= 8'd40) ? 4'd4 :
                     (r_info_tid >= 8'd30) ? 4'd3 :
                     (r_info_tid >= 8'd20) ? 4'd2 :
                     (r_info_tid >= 8'd10) ? 4'd1 : 4'd0;
wire [7:0] w_tid_r2 = r_info_tid - ({4'd0, w_tid_t} * 8'd10);
wire [3:0] w_tid_o  = w_tid_r2[3:0];

// ---- 2026-09-20（2.4(2) 缺口 1）：I_info_y 的十进制拆位，与上面 X 那套**同构** ----
//   第 24~29 格将显示 "Y:xxxx"，所以 Y 也必须能拆成十进制。
//   Y 同样是 11 位（0..2047）⇒ 千位也要能出 0/1/2。**这里特意不图省事写成 0/1**，
//   否则就是把 X 刚修掉的那个 bug 原样复制一遍。
//   真实系统里 Y ≤ 719（画面高 720），但这个契约按 0..2047 写，照抄 X 最省心。
wire [3:0] w_y_th=I_rst_n?r_coord_y_bcd[15:12]:4'd0;
wire [3:0] w_y_h=I_rst_n?r_coord_y_bcd[11:8]:4'd0;
wire [3:0] w_y_t=I_rst_n?r_coord_y_bcd[7:4]:4'd0;
wire [3:0] w_y_o=I_rst_n?r_coord_y_bcd[3:0]:4'd0;

//------------------------------------------------------------------------------
// 7~9. 字符槽 ASCII / 字符码选择(case) / ASCII→字库索引 / my_charlib 例化
//      —— v1.2 起这三节**整体下移到第 2 级流水**（见本文件 §12）。
//         理由：它们的输入（十进制各位、w_txt_ci、w_txt_row）已经在 §11 被
//         寄存了一拍，留在这里会让第 1 级重新长出那条长链。
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// 10. Logo ROM 例化：**逐像素**接口，一拍 4 个像素 → 4 个实例
//     第 k 个像素的绝对列号 = 4*r_x + k，所以送给 ROM 的 x 偏移 = 该列号 - LOGO_X。
//     ⚠ 偏移量必须用**像素级**列号算（用拍号 r_x 会得到负值下溢）。
//     越界地址由 ROM 内部 case 的 default 兜住（返回 O_hit = 0），所以这里不做
//     额外的矩形判据，避免与素材不一致。
//------------------------------------------------------------------------------
wire [11:0] w_logo_dy = {1'b0, w_y_base} - {1'b0, LOGO_Y};
wire [11:0] w_logo_dx = {1'b0, w_x_base} - {1'b0, LOGO_X};

wire w_logo_hit0, w_logo_hit1, w_logo_hit2, w_logo_hit3;
wire [23:0] w_logo_col0, w_logo_col1, w_logo_col2, w_logo_col3;

// 4 个逐像素 case-ROM 实例已移除，改为 1 个 ERAM 实例（见 §10b 之后的 my_logo_rom_eram）


// O_hit = 1 才是"笔画"像素：只在命中处把原像素换成 Logo 的前景色；O_hit = 0
// 的像素保持原像素不变 —— Logo 是"贴"上去的图形，不是一个不透明色块。
// 命中判据完全由 ROM 的 O_hit 给出，RTL 不另造判据。

//------------------------------------------------------------------------------
// 10b. 安路官方 Logo：alg_logo_eram（一拍读 4 像素的 ERAM，比赛基础要求 (4)）
//
//  【为什么不是官方 anlogic_logo_rom】
//    那个文件是 6387 条 case 的**组合**译码器，TD 实测单份 #lut 3143 / #slice 2559
//    （prj\logo_ab\logo_a_full160\area.txt）。一拍 4 像素要 4 份 ≈ 10236 slice，而器件
//    只有 21216 slice、板级工程已用 13891 ⇒ **放不下**（面积由案例条数决定，跟输出
//    位宽无关，降色深/降分辨率都救不了）。改成 160x160 按 4 像素/字打包的 ERAM
//    （6400 字 x 24bit = 6bit/像素 x 4，63 色调色板在 RTL 里查表），实测
//    6400x24 只吃 #eram 8 / #lut 20（prj\_eram_init_check\logo_mem24.area）。
//    ⇒ 用 8 块 ERAM（共 108 块）换掉约 10236 slice。细节见 src\alg_logo_eram.v 文件头。
//
//  【⚠ 本节唯一容易错的地方：ERAM 读是"地址进 → 下一拍数据出"】
//    alg_logo_eram 的输入不是"本拍那 4 个像素"的坐标，而是**下一拍**那 4 个像素的
//    坐标（模块内 r_word <= r_mem[addr] 打了一拍）。所以这里必须把坐标**提前一拍**
//    算出来（w_x_nx1 / w_y_nx1 = 比 w_x_nx/w_y_nx 再晚一拍的坐标），模块的输出才
//    恰好落在"它描述的那一拍"上，与 w_logo_hit*/w_pix_text_hit 同拍进第 1 级。
//    少算这一拍 = 安路 Logo 整面右移 4 像素（check_anlogo.py 会大面积失配）。
//    本项目在"数据/控制差一拍"上出过事故（§13），这条不许凭感觉改。
//
//  【坐标相位对照（§四的三份坐标，别混）】
//    w_x_nx/w_y_nx   = **本拍**总线上那份像素的坐标（§2b）
//    w_x_nx1/w_y_nx1 = **下一拍**上台那份像素的坐标（本节新增，只喂 alg_logo_eram）
//    两者都从计数器 r_x_grp/r_y_pos 组合而来，行末/帧首的回绕必须各算一次
//------------------------------------------------------------------------------
// 下一拍（+1 拍）上台那份数据的坐标。
//   · 本拍 = 行末（r_x_grp == LAST_BEAT-1）⇒ 下一拍 = 下一行行首（行号 +1，末行回绕）
//   · 本拍 = 行首（r_x_grp == LAST_BEAT）⇒ 下一拍 = **同一行**的第 1 拍
//   · 帧首（I_tuser）本拍 = (0,0) ⇒ 下一拍 = (1,0)
//
//  ⚠⚠ 2026-09-17 踩过的坑（check_anlogo.py 抓出来的，只错 1 个像素）：
//    r_x_grp == LAST_BEAT 那一拍的**行号不是 r_y_pos，而是 r_y_pos+1** —— 行号是在
//    r_x_grp 由 LAST_BEAT 回绕到 0 的**同一次时钟沿**才 +1 的，也就是说"回绕"和"+1 行"
//    是同一件事，r_y_pos 自己还没动。这里最初写成 w_y_nx1 = r_y_pos，于是每行都有
//    一拍去读**上一行**的字：列 4..6 恰好永远透明，唯一会露馅的是"上一行第 7 列"，
//    而全图第 7 列只有 1 个不透明像素 ⇒ 整帧只错 1 个像素（(7,127) 丢失、(7,128) 冒出来）。
//    这种"每行错一拍、却几乎看不出来"的缺陷正是必须逐像素 bit 比对的原因。
reg [10:0] w_x_nx1;
reg [10:0] w_y_nx1;

always @ (*) begin
    if (I_tuser) begin
        w_x_nx1 = 11'd1;
        w_y_nx1 = 11'd0;
    end else if (r_x_grp == (LAST_BEAT - 1'b1)) begin
        w_x_nx1 = 11'd0;
        w_y_nx1 = (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
    end else if (r_x_grp == LAST_BEAT) begin
        w_x_nx1 = 11'd1;
        w_y_nx1 = (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);   // ⚠ 与 w_y_nx 同式
    end else begin
        w_x_nx1 = {2'b00, r_x_grp} + 11'd2;
        w_y_nx1 = r_y_pos;
    end
end

// 下一拍的像素级列基准（= 4 × 拍号）。ANLOGO_X 必须是 4 的倍数才能与此对齐（§10b 末）
wire [10:0] w_an_xb_nx1 = {w_x_nx1[8:0], 2'b00};

//------------------------------------------------------------------------------
// 10c. 再提前一拍：nx2（2026-09-21 时序优化配套）
//      alg_logo_eram 内部给坐标加了一级寄存器（把 11 级组合链劈成两段），
//      所以调用方必须把坐标**再提前一拍**送进去：原来送 nx1，现在送 nx2。
//      nx2 = next(nx1)，回绕规则与 nx1 完全同构（行末回 0、末行回 0）。
//      ⚠ 输出对齐不变：an_logo 多的一拍延迟正好被"提前一拍喂"抵消，
//        它在第 B 拍吐出的仍然是第 B 拍那 4 个像素的 Logo 数据。
//------------------------------------------------------------------------------
reg [10:0] w_x_nx2;
reg [10:0] w_y_nx2;

always @ (*) begin
    if (w_x_nx1 == LAST_BEAT) begin
        w_x_nx2 = 11'd0;
        w_y_nx2 = (w_y_nx1 == LAST_ROW) ? 11'd0 : (w_y_nx1 + 11'd1);
    end else begin
        w_x_nx2 = w_x_nx1 + 11'd1;
        w_y_nx2 = w_y_nx1;
    end
end

wire [10:0] w_an_xb_nx2 = {w_x_nx2[8:0], 2'b00};

//------------------------------------------------------------------------------
// 10a'. 「2017-2026 / 国赛十周年」Logo：ERAM 位图版（一拍读 4 像素）
//   与 alg_logo_eram 完全同相位：坐标打 1 拍 + ERAM 读 1 拍 = 2 拍，
//   所以同样喂**下下一拍**的坐标（w_an_xb_nx2 / w_y_nx2）。
//   位图 4096 字 x 16 bit（16 像素/段），按段内 x[3:2] 选本拍 4 像素。
//------------------------------------------------------------------------------
wire [11:0] w_logo_dx2 = {1'b0, w_an_xb_nx2} - {1'b0, LOGO_X};
wire [11:0] w_logo_dy2 = {1'b0, w_y_nx2}    - {1'b0, LOGO_Y};

my_logo_rom_eram #(
    .COLOR_FG (OSD_LOGO_COLOR),
    .COLOR_BG (24'h000000)
) u_logo_eram (
    .I_clk     (I_clk),
    .I_rst_n   (I_rst_n),
    .I_dx_nx2  (w_logo_dx2),
    .I_dy_nx2  (w_logo_dy2),
    .O_hit0    (w_logo_hit0),
    .O_hit1    (w_logo_hit1),
    .O_hit2    (w_logo_hit2),
    .O_hit3    (w_logo_hit3),
    .O_color0  (w_logo_col0),
    .O_color1  (w_logo_col1),
    .O_color2  (w_logo_col2),
    .O_color3  (w_logo_col3)
);


wire        w_an_hit0, w_an_hit1, w_an_hit2, w_an_hit3;
wire [23:0] w_an_col0, w_an_col1, w_an_col2, w_an_col3;

alg_logo_eram #(
    .ANLOGO_X (ANLOGO_X),
    .ANLOGO_Y (ANLOGO_Y)
) u_an_logo (
    .I_clk       (I_clk),
    .I_rst_n     (I_rst_n),
    .I_x_base_nx (w_an_xb_nx2),      // **下下一拍**的列基准（2026-09-21 起 an_logo 内部多一级寄存）
    .I_y_nx      (w_y_nx2),
    .O_hit0      (w_an_hit0),
    .O_hit1      (w_an_hit1),
    .O_hit2      (w_an_hit2),
    .O_hit3      (w_an_hit3),
    .O_col0      (w_an_col0),
    .O_col1      (w_an_col1),
    .O_col2      (w_an_col2),
    .O_col3      (w_an_col3)
);

//------------------------------------------------------------------------------
// 10c. 配置护栏（仿真）：ANLOGO_X 必须是 4 的倍数
//
//  alg_logo_eram 一拍只读一个字（4 个像素），字内列号 = (x_base - ANLOGO_X)/4。
//  x_base = 4×拍号恒为 4 的倍数，所以 ANLOGO_X 一旦不是 4 的倍数，字地址就整体
//  错位、整幅安路 Logo 花掉。这条在综合里是常数（真实设计 ANLOGO_X = 0，被优化掉），
//  只在仿真里作为断言源存在：TB 把 r_an_cfg_err 写进 dump，check_anlogo.py 断言
//  "合法配置 = 0、非法用例 = 1"；同时 $display 出声，别让人以为只是警告。
//
//  ⚠ 2026-09-17 修：原来这里用 `// synopsys translate_off/on` 把声明对综合隐藏，
//    但**用到它的那一句在下面的 initial 块里、没被一起包住** ⇒ TD 报
//    `HDL-8007 ERROR: 'r_an_cfg_err' is not declared`，并且**把整个 osd_mixer 模块丢弃**
//    （那一轮的面积数字全部作废）。ModelSim 仿真里声明在，看不出任何问题 —— 只有跑 TD 才暴露。
//    现在声明与使用都对综合可见：它只在 initial 里被赋一个常数，会被常量折叠，代价 0。
//------------------------------------------------------------------------------
reg r_an_cfg_err;      // 1 = 配置非法（仅仿真意义；综合里是常数、被折叠掉）

//------------------------------------------------------------------------------
// 11. 【v1.2 新增 · 第 1 级流水】把第 2 级要用到的**全部叶子值**寄存一拍
//
//  这一级就是老版本"组合到 w_mix 为止"的前半段：数字拆位、位置判据、Logo 查表
//  都在这一级算完（与 v1.1 逐 bit 相同），然后在同一个时钟沿把结果整体捕获
//  —— 即"把老版本 O_tdata 的整个输入锥体一起打一拍"。
//
//  ⚠ 合并点另一侧一个都不能漏，清单（共 364 bit）：
//      十进制各位 7x4 = 28  · FPS 半字节 8   · 档位 ASCII 16（来自端口！）
//      位置 13（inrow/incol/ci[4:0]/col_base[2]/row[4]）
//      Logo 4+96 = 100      · 安路 Logo 4+96 = 100（v1.4 新增）
//      · 原像素 96
//  ★2026-10-24 v1.6：这一级**保持不变**；因为字库多了一拍读延迟，混合级要用到的
//    "陪跑量"子集在 §11b 又复制了一级（p2）。十进制各位/字符槽/档位名这一组
//    不需要 p2 —— 它们只需要活到"送 ROM 地址"那一拍（第 1 级之后立即用掉）。
//      （2026-09-16 修复前这里还有 r_vld2/r_tlast2/r_tuser2 三位控制，已删除：
//        它们让控制链比数据链多一拍，见 §13。）
//  本模块**不门控**这一级（与老版本输出级同语义）：有效与否只由控制位决定，
//  第 2 级在控制位为 0 时把 O_tdata 强制置 0 —— 所以气泡期捕获到什么值都不影响。
//------------------------------------------------------------------------------
reg [3:0]  r_x_th_p1, r_x_h_p1, r_x_t_p1, r_x_o_p1;         // I_info_x 的十进制各位
reg [3:0]  r_lat_h_p1, r_lat_t_p1, r_lat_o_p1;              // I_info_lat 的十进制各位
reg [3:0]  r_y_th_p1, r_y_h_p1, r_y_t_p1, r_y_o_p1;         // I_info_y 的十进制各位（2026-09-20）
reg [3:0]  r_fps_hi_p1, r_fps_lo_p1;                        // I_info_fps 低字节的两个半字节
reg [15:0] r_mode_chars_p1;                                 // 端口 I_info_mode 的组合结果（活叶子）
// 2026-09-20：算法名（5 字符）也要**和别的活叶子一起寄存**，否则第 2 级读到的
//   是当拍组合值，与十进制各位差一拍 —— 这正是 §二·补 里点名的那个坑。
reg [39:0] r_mode_name_p1;
reg        r_txt_inrow_p1, r_txt_incol_p1;                  // 文字面行/列区间
reg [5:0]  r_txt_ci_p1;                                     // 字符槽下标（40 格 ⇒ 6 位）
// 2026-09-20：检测命中标志（= 第 1 级寄存的"命中数非零"）。
//   与 r_x_*_p1 同一级、同一沿装载 ⇒ 与 X 的十进制各位同相，不会错位。
reg        r_hit_p1;
reg        r_info_nov_p1;   // ★2026-10-03 与 r_hit_p1 同沿（显示组合同步）
// 2026-09-20：颜色类别（第 2 级）。与 r_hit_p1 同沿装载 ⇒ 同相。
reg [1:0]  r_class_p1;
// 2026-09-20：跟踪编号（第 2 级）+ 它的两位十进制。与 r_class_p1 同沿装载。
reg [3:0]  r_tid_t_p1, r_tid_o_p1;   // 跟踪编号的十位/个位（§11 寄存，见 §12.1a）
// 2026-09-20：「本帧是不是 COLOR 档」—— 与 r_hit_p1 同沿装载。
//   类别只在 COLOR 档有意义（别的档位命中像素不是颜色命中，报类别会误导）。
reg        r_is_color_p1;
reg [1:0]  r_txt_col_base_p1;                               // 字内列基址（一拍 4 像素）
reg [3:0]  r_txt_row_p1;                                    // 字模行号
reg        r_logo_hit0_p1, r_logo_hit1_p1,
           r_logo_hit2_p1, r_logo_hit3_p1;                  // Logo 命中（4 像素）
reg [23:0] r_logo_col0_p1, r_logo_col1_p1,
           r_logo_col2_p1, r_logo_col3_p1;                  // Logo 颜色（4 像素）
reg        r_an_hit0_p1, r_an_hit1_p1,
           r_an_hit2_p1, r_an_hit3_p1;                      // 安路 Logo 命中（4 像素，v1.4）
reg [23:0] r_an_col0_p1, r_an_col1_p1,
           r_an_col2_p1, r_an_col3_p1;                      // 安路 Logo 颜色（4 像素，v1.4）
reg [95:0] r_pix_data_p1;                                   // 原像素（4 x RGB888）
// ⚠ 2026-09-16 修复：此处原本还有 r_vld2/r_tlast2/r_tuser2（把控制再延一拍），
//   使控制链 3 拍而数据链只有 2 拍 —— O_tuser/O_tlast 比它们标记的数据晚 1 拍。
//   已删除，控制改用 r_vld1/r_tlast/r_tuser，四路同为延迟 2 拍。详见 §13。

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_th_p1   <= 4'd0;
        r_x_h_p1    <= 4'd0;
        r_x_t_p1    <= 4'd0;
        r_x_o_p1    <= 4'd0;
        r_lat_h_p1  <= 4'd0;
        r_lat_t_p1  <= 4'd0;
        r_lat_o_p1  <= 4'd0;
        r_y_th_p1   <= 4'd0;
        r_y_h_p1    <= 4'd0;
        r_y_t_p1    <= 4'd0;
        r_y_o_p1    <= 4'd0;
        r_fps_hi_p1 <= 4'd0;
        r_fps_lo_p1 <= 4'd0;
        r_mode_chars_p1 <= 16'd0;
        r_mode_name_p1  <= 40'd0;
        r_txt_inrow_p1  <= 1'b0;
        r_txt_incol_p1  <= 1'b0;
        r_txt_ci_p1     <= 6'd0;
        r_hit_p1        <= 1'b0;
        r_info_nov_p1   <= 1'b0;
        r_class_p1      <= 2'd0;
        r_tid_t_p1      <= 4'd0;
        r_tid_o_p1      <= 4'd0;
        r_is_color_p1   <= 1'b0;
        r_txt_col_base_p1 <= 2'd0;
        r_txt_row_p1    <= 4'd0;
        r_logo_hit0_p1  <= 1'b0;
        r_logo_hit1_p1  <= 1'b0;
        r_logo_hit2_p1  <= 1'b0;
        r_logo_hit3_p1  <= 1'b0;
        r_logo_col0_p1  <= 24'd0;
        r_logo_col1_p1  <= 24'd0;
        r_logo_col2_p1  <= 24'd0;
        r_logo_col3_p1  <= 24'd0;
        r_an_hit0_p1    <= 1'b0;
        r_an_hit1_p1    <= 1'b0;
        r_an_hit2_p1    <= 1'b0;
        r_an_hit3_p1    <= 1'b0;
        r_an_col0_p1    <= 24'd0;
        r_an_col1_p1    <= 24'd0;
        r_an_col2_p1    <= 24'd0;
        r_an_col3_p1    <= 24'd0;
        r_pix_data_p1   <= 96'd0;
    end else begin
        r_x_th_p1   <= w_x_th;
        r_x_h_p1    <= w_x_h;
        r_x_t_p1    <= w_x_t;
        r_x_o_p1    <= w_x_o;
        r_lat_h_p1  <= w_lat_h;
        r_lat_t_p1  <= w_lat_t;
        r_lat_o_p1  <= w_lat_o;
        r_y_th_p1   <= w_y_th;
        r_y_h_p1    <= w_y_h;
        r_y_t_p1    <= w_y_t;
        r_y_o_p1    <= w_y_o;
        r_fps_hi_p1 <= r_info_fps[7:4];
        r_fps_lo_p1 <= r_info_fps[3:0];
        r_mode_chars_p1 <= w_mode_chars;
        r_mode_name_p1  <= w_mode_name;
        r_txt_inrow_p1  <= w_txt_inrow;
        r_txt_incol_p1  <= w_txt_incol;
        r_txt_ci_p1     <= w_txt_ci;
        r_hit_p1        <= (r_info_cnt != 32'd0);
        r_info_nov_p1   <= I_info_nov;
        r_class_p1      <= r_info_class;
        r_tid_t_p1      <= w_tid_t;
        r_tid_o_p1      <= w_tid_o;
        r_is_color_p1   <= (r_info_mode == 11'd5) || (r_info_mode == 11'd13);   // 5/13 = 固定红/AUTO
        r_txt_col_base_p1 <= w_txt_col_base;
        r_txt_row_p1    <= w_txt_row;
        r_logo_hit0_p1  <= w_logo_hit0;
        r_logo_hit1_p1  <= w_logo_hit1;
        r_logo_hit2_p1  <= w_logo_hit2;
        r_logo_hit3_p1  <= w_logo_hit3;
        r_logo_col0_p1  <= w_logo_col0;
        r_logo_col1_p1  <= w_logo_col1;
        r_logo_col2_p1  <= w_logo_col2;
        r_logo_col3_p1  <= w_logo_col3;
        r_an_hit0_p1    <= w_an_hit0;
        r_an_hit1_p1    <= w_an_hit1;
        r_an_hit2_p1    <= w_an_hit2;
        r_an_hit3_p1    <= w_an_hit3;
        r_an_col0_p1    <= w_an_col0;
        r_an_col1_p1    <= w_an_col1;
        r_an_col2_p1    <= w_an_col2;
        r_an_col3_p1    <= w_an_col3;
        r_pix_data_p1   <= I_tdata;
    end
end

//------------------------------------------------------------------------------
// 11b. 【v1.6 新增 · p2 寄存器组】把混合级的"陪跑量"整体再延后一拍
//
//  为什么需要：字库换成同步读 ROM 后，点阵是在"地址那一拍"的**下一拍**才出来。
//  而混合级必须拿"同一份像素"的点阵/Logo/原像素/列基址。所以陪跑量要跟着再走
//  一级寄存器，才能在点阵出来的那一拍与它同拍相遇。
//
//  ⚠ 这一组是**纯延迟复制**（r_*_p2 <= r_*_p1），不含任何运算 —— 这样"新版第 k 拍
//    的混合输入 = 旧版第 k-1 拍的混合输入"是结构性成立的，不靠逐个信号去对拍。
//
//  ⚠ 清单（共 300 bit）—— **一个都不能漏**，漏一个就是文字面/Logo 面错位：
//      原像素 96（4 x RGB888）
//      自研 Logo 4 命中 + 4x24 颜色 = 100
//      安路 Logo 4 命中 + 4x24 颜色 = 100   ← 最容易漏的就是这两组 24 bit 颜色
//      文字面 4：inrow 1 + incol 1 + 字内列基址 2
//    不需要 p2 的（第 1 级之后立刻用掉，不进混合级）：
//      十进制各位 28 / FPS 8 / 档位 ASCII 16 / 档位名 40 / 字符槽下标 6 /
//      字模行号 4（喂 ROM 地址）/ hit / nov / class / is_color / tid 各位。
//
//  ⚠ 控制链同样要 +1 拍（§11c），否则就是 2026-09-16 那次"数据 2 拍、控制 3 拍"
//    事故的镜像版（这次是数据 3 拍、控制 2 拍），tuser/tlast 会整体早一拍。
//------------------------------------------------------------------------------
reg [95:0] r_pix_data_p2;                                   // 原像素（4 x RGB888）
reg        r_logo_hit0_p2, r_logo_hit1_p2,
           r_logo_hit2_p2, r_logo_hit3_p2;                  // 自研 Logo 命中（4 像素）
reg [23:0] r_logo_col0_p2, r_logo_col1_p2,
           r_logo_col2_p2, r_logo_col3_p2;                  // 自研 Logo 颜色（4 像素）
reg        r_an_hit0_p2, r_an_hit1_p2,
           r_an_hit2_p2, r_an_hit3_p2;                      // 安路 Logo 命中（4 像素）
reg [23:0] r_an_col0_p2, r_an_col1_p2,
           r_an_col2_p2, r_an_col3_p2;                      // 安路 Logo 颜色（4 像素）
reg        r_txt_inrow_p2, r_txt_incol_p2;                  // 文字面行/列区间
reg [1:0]  r_txt_col_base_p2;                               // 字内列基址

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_pix_data_p2   <= 96'd0;
        r_logo_hit0_p2  <= 1'b0;
        r_logo_hit1_p2  <= 1'b0;
        r_logo_hit2_p2  <= 1'b0;
        r_logo_hit3_p2  <= 1'b0;
        r_logo_col0_p2  <= 24'd0;
        r_logo_col1_p2  <= 24'd0;
        r_logo_col2_p2  <= 24'd0;
        r_logo_col3_p2  <= 24'd0;
        r_an_hit0_p2    <= 1'b0;
        r_an_hit1_p2    <= 1'b0;
        r_an_hit2_p2    <= 1'b0;
        r_an_hit3_p2    <= 1'b0;
        r_an_col0_p2    <= 24'd0;
        r_an_col1_p2    <= 24'd0;
        r_an_col2_p2    <= 24'd0;
        r_an_col3_p2    <= 24'd0;
        r_txt_inrow_p2  <= 1'b0;
        r_txt_incol_p2  <= 1'b0;
        r_txt_col_base_p2 <= 2'd0;
    end else begin
        r_pix_data_p2   <= r_pix_data_p1;
        r_logo_hit0_p2  <= r_logo_hit0_p1;
        r_logo_hit1_p2  <= r_logo_hit1_p1;
        r_logo_hit2_p2  <= r_logo_hit2_p1;
        r_logo_hit3_p2  <= r_logo_hit3_p1;
        r_logo_col0_p2  <= r_logo_col0_p1;
        r_logo_col1_p2  <= r_logo_col1_p1;
        r_logo_col2_p2  <= r_logo_col2_p1;
        r_logo_col3_p2  <= r_logo_col3_p1;
        r_an_hit0_p2    <= r_an_hit0_p1;
        r_an_hit1_p2    <= r_an_hit1_p1;
        r_an_hit2_p2    <= r_an_hit2_p1;
        r_an_hit3_p2    <= r_an_hit3_p1;
        r_an_col0_p2    <= r_an_col0_p1;
        r_an_col1_p2    <= r_an_col1_p1;
        r_an_col2_p2    <= r_an_col2_p1;
        r_an_col3_p2    <= r_an_col3_p1;
        r_txt_inrow_p2  <= r_txt_inrow_p1;
        r_txt_incol_p2  <= r_txt_incol_p1;
        r_txt_col_base_p2 <= r_txt_col_base_p1;
    end
end

//------------------------------------------------------------------------------
// 11c. 【v1.6】控制链同步 +1 拍（r_vld2 / r_tlast2 / r_tuser2）
//  都是**纯延迟复制**（与输出级的装载条件一一对应）：
//      O_tvalid(k) = r_vld2(k-1) = r_vld1(k-2) = 旧版 O_tvalid(k-1)
//      O_tlast (k) = r_tlast2(k-1)= r_tlast(k-2)= 旧版 O_tlast (k-1)
//      O_tuser (k) = r_tuser2(k-1)= r_tuser(k-2)= 旧版 O_tuser (k-1)
//  即控制链与数据链一样只多 1 拍，四路仍然严格同拍（§13）。
//------------------------------------------------------------------------------
reg r_vld2;          // I_tvalid 延迟 2 拍
reg r_tlast2;
reg r_tuser2;

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tlast2 <= 1'b0;
        r_tuser2 <= 1'b0;
    end else begin
        r_tlast2 <= r_tlast;
        r_tuser2 <= r_tuser;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld2 <= 1'b0;
    else
        r_vld2 <= r_vld1;
end

//------------------------------------------------------------------------------
// 12. 【第 2 级】ASCII → 字符码 → 字库索引 → （ROM 读寄存器）→ 点阵 → 命中 → 混合
//
//  输入**全部**来自 §11 的寄存器：这里不许再读任何端口或未寄存量。
//  与 v1.1 的对应关系（逐字）：
//      w_x_o/w_lat_h/... → r_x_o_p1/r_lat_h_p1/...   （十进制各位）
//      w_txt_ci          → r_txt_ci_p1                （case 的选择量）
//      w_txt_row         → r_txt_row_p1               （字模行号 → ROM 地址）
//      w_txt_col_base    → r_txt_col_base_p1          （字内列基址）
//      w_txt_inrow/incol → r_txt_inrow_p1/r_txt_incol_p1
//      w_logo_hit*/col*  → r_logo_hit*_p1/r_logo_col*_p1
//      I_tdata           → r_pix_data_p1
//
//  ★2026-10-24 v1.6 的分层（很重要，别把跨层混用）：
//      (A) 字符槽 case / ASCII→索引：**仍然在第 2 拍**，输入是 p1，输出当拍直接
//          接进 my_charlib 的地址口（这一段只有几级 LUT，且到此为止）。
//      (B) 点阵（w_glyph_bits）：ROM 读寄存器输出，**第 3 拍**才有效，
//          它对应的是"地址那一拍的 p1" = 第 3 拍 p2 里的那份像素。
//      (C) 命中判据 / 混合：**第 3 拍**，全部改读 p2（§11b）+ 点阵，
//          绝不能再读 p1（p1 那时已经翻到下一份像素了）。
//------------------------------------------------------------------------------
// ---- 12.1 字符槽 ASCII（下标定义见文件头 §六，与 v1.1 完全一致）----
wire [7:0] w_ch_x_o   = {4'h0, r_x_o_p1}   + 8'h30;
wire [7:0] w_ch_x_t   = {4'h0, r_x_t_p1}   + 8'h30;
wire [7:0] w_ch_x_h   = {4'h0, r_x_h_p1}   + 8'h30;
wire [7:0] w_ch_x_th  = {4'h0, r_x_th_p1}  + 8'h30;
// 2026-09-20：I_info_y 的十进制各位 → ASCII（与上面 X 那四行同构）
wire [7:0] w_ch_y_o   = {4'h0, r_y_o_p1}   + 8'h30;
wire [7:0] w_ch_y_t   = {4'h0, r_y_t_p1}   + 8'h30;
wire [7:0] w_ch_y_h   = {4'h0, r_y_h_p1}   + 8'h30;
wire [7:0] w_ch_y_th  = {4'h0, r_y_th_p1}  + 8'h30;
wire [7:0] w_ch_lat_o = {4'h0, r_lat_o_p1} + 8'h30;
wire [7:0] w_ch_lat_t = {4'h0, r_lat_t_p1} + 8'h30;
wire [7:0] w_ch_lat_h = {4'h0, r_lat_h_p1} + 8'h30;
// FPS 十六进制：半字节 0..9 → '0'..'9'，10..15 → ':'..'?'（可辨认；不做 A..F 映射以省 LUT）
wire [7:0] w_ch_fps_hi = 8'h30 + {4'h0, r_fps_hi_p1};
wire [7:0] w_ch_fps_lo = 8'h30 + {4'h0, r_fps_lo_p1};

//------------------------------------------------------------------------------
// ★★2026-10-22 三组 BCD：实测行像素 / 实测行数 / 帧计数
//   屏幕上显示 "H1280 V0720 F0123" 时，1 2 8 0 这四个数字来自计数器实测，
//   而不是写死的常量——这是"分辨率 1280×720"的硬证据。
//------------------------------------------------------------------------------
wire [15:0] w_bcd_hpx;   // 4 位十进制 {千,百,十,个}
wire [15:0] w_bcd_vln;

bin2bcd #(.BIN_W(11), .DIGITS(4)) u_bcd_hpx (.I_bin(I_info_hpx), .O_bcd(w_bcd_hpx));   // ★BIN_W 16->11：实测值最大 2047，缩短组合链
bin2bcd #(.BIN_W(11), .DIGITS(4)) u_bcd_vln (.I_bin(I_info_vln), .O_bcd(w_bcd_vln));   // ★BIN_W 16->11：同上

// ★★2026-10-24 采集→显示总延迟（毫秒）的三位十进制
// Equivalent registered 10-bit -> three-digit decimal conversion.
reg [11:0] latms_rom [0:1023]; //synthesis ram_style = bram
integer latms_init;
initial begin
    for(latms_init=0;latms_init<1024;latms_init=latms_init+1)
        latms_rom[latms_init]=(((latms_init/100)%10)<<8)
               |(((latms_init/10)%10)<<4)|(latms_init%10);
end
reg [11:0] r_latms_rom;
always @(posedge I_clk) r_latms_rom<=latms_rom[I_info_latms];
wire [11:0] r_bcd_lat=I_rst_n?r_latms_rom:12'd0;

// ★★2026-10-24 本秒内帧序号（0~29）两位十进制
wire [7:0] w_bcd_idx;
bin2bcd #(.BIN_W(6), .DIGITS(2)) u_bcd_idx (.I_bin(I_info_idx), .O_bcd(w_bcd_idx));

// ★★2026-10-24 时序优化：把四组 BCD 结果打一拍寄存。
//   理由：bin2bcd 是 double-dabble 组合链（比较+加 3 逐位串行），是长组合路径；
//   而它驱动的数值（分辨率/延迟/帧序号）每帧才变化一次，打一拍对显示毫无影响，
//   却能把"测量值 → BCD → 字符编码"这条长链切成两段短路径，改善时序余量。
reg [15:0] r_bcd_hpx, r_bcd_vln;

reg [ 7:0] r_bcd_idx;
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_bcd_hpx <= 16'd0;
        r_bcd_vln <= 16'd0;

        r_bcd_idx <= 8'd0;
    end else begin
        r_bcd_hpx <= w_bcd_hpx;
        r_bcd_vln <= w_bcd_vln;

        r_bcd_idx <= w_bcd_idx;
    end
end

reg [7:0] w_char_code;

//------------------------------------------------------------------------------
// 12.1a 第 38~43 格的 6 个字符（2026-09-20，扩展要求 2.4(2)「识别」+ 文字说明）
//
//   三种情形，逐条写清：
//     ① 没检测到（r_hit_p1 = 0）  → "NONE  "
//     ② COLOR 档且检测到          → "RED 01" / "GRN 02" / "BLU 03"
//                                    （前 3 格颜色名 + 1 格空格 + 2 格**跟踪编号**）
//     ③ 其余档位且检测到          → "TARGET"
//
//   2026-09-20 补（进阶 2.5(2)「动态目标跟踪」）：第 42~43 格改成跟踪编号。
//   **为什么编号只占这 2 格、不新开字段**：版面 48 格已经排满，而 44~47 只剩 4 格，
//   放不下 "ID:xx"（5 格）。把编号并进检测结果那一栏既省版面，读起来也更顺：
//   "RED 01" 一眼就是"1 号红色目标"，不需要额外的图例去解释。
//   ⚠ 别的档位（TARGET）放不下编号，也就不显示 —— 那几档本来也没有"跟踪"这回事。
//
//   **为什么只在 COLOR 档报颜色名**：类别 = 命中像素的主导通道。只有 COLOR 档的
//   "命中"是**颜色命中**（像素落在目标色的容差球内），此时主导通道正是目标的颜色；
//   别的档位的命中来自运动/边缘，像素本身什么颜色都有，这时报一个颜色名会误导评委。
//   所以宁可分情形：颜色名只在它成立的地方出现，其余档位保留原来那句 "TARGET"。
//
//   三个字母全部取自 my_charlib 的 42 字库（R E D G N B L U 都在），没有造新字。
//   ASCII：R=52 E=45 D=44 G=47 N=4E B=42 L=4C U=55 T=54 A=41 O=4F 空格=20
//   2026-10-03 四族：Y=59 W=57（"YLW nn" = 黄族）
//
//   为什么单独一个 always 块、不并进下面那个大 case：出问题时影响面小，
//   且这 6 个字符有"整体含义"（是个词，不能逐字各判各的）。
//------------------------------------------------------------------------------
reg [47:0] w_det_chars;     // {第1字, 第2字, ..., 第6字}，最左字在 [47:40]

// 编号的十进制拆位在 §6（必须在 §11 之前声明）；这里只做 "0x30 + 数字"。
wire [7:0] w_ch_tid_t = 8'h30 + {4'h0, r_tid_t_p1};      // 十位（§11 寄存）
wire [7:0] w_ch_tid_o = 8'h30 + {4'h0, r_tid_o_p1};      // 个位（§11 寄存）

always @ (*) begin
    if (!r_hit_p1)
        w_det_chars = {8'h4E, 8'h4F, 8'h4E, 8'h45, 8'h20, 8'h20};   // "NONE  "
    else if (r_is_color_p1) begin
        // 前 3 格颜色名 + 1 格空格 + 2 格跟踪编号（编号按两位显示，1 号打成 "01"）
        case (r_class_p1)
            2'd0:    w_det_chars = {8'h52, 8'h45, 8'h44, 8'h20, w_ch_tid_t, w_ch_tid_o}; // "RED nn"
            2'd1:    w_det_chars = {8'h47, 8'h52, 8'h4E, 8'h20, w_ch_tid_t, w_ch_tid_o}; // "GRN nn"
            2'd2:    w_det_chars = {8'h42, 8'h4C, 8'h55, 8'h20, w_ch_tid_t, w_ch_tid_o}; // "BLU nn"
            // 2026-10-03 AUTO 四族：黄族（Y=59 L=4C W=57，均在 42 字库里，没有造新字）
            default: w_det_chars = {8'h59, 8'h4C, 8'h57, 8'h20, w_ch_tid_t, w_ch_tid_o}; // "YLW nn"
        endcase
    end
    else
        w_det_chars = {8'h54, 8'h41, 8'h52, 8'h47, 8'h45, 8'h54};   // "TARGET"
end

always @ (*) begin
    case (r_txt_ci_p1)
        // ---- 2026-09-20（2.5(1) 状态显示）：第 0~4 格 = **算法名** --------------
        //   为什么放最前面：屏幕上第一眼就该看到"现在在演示什么算法"。
        //   与 "M<n>" 编号并存（编号在第 6~7 格）—— 编号是我们文档里用的，
        //   名字是给评委看的，两者都留着便于对账。
        6'd0:    w_char_code = r_mode_name_p1[39:32];   // 算法名 第1字
        6'd1:    w_char_code = r_mode_name_p1[31:24];   // 第2字
        6'd2:    w_char_code = r_mode_name_p1[23:16];   // 第3字
        6'd3:    w_char_code = r_mode_name_p1[15:8];    // 第4字
        6'd4:    w_char_code = r_mode_name_p1[7:0];     // 第5字
        6'd5:    w_char_code = 8'h20;                // 空格
        6'd6:    w_char_code = r_mode_chars_p1[15:8];   // 'M'
        6'd7:    w_char_code = r_mode_chars_p1[7:0];    // 档位数字
        6'd8:    w_char_code = 8'h20;                // 空格
        6'd9:    w_char_code = 8'h46;                // 'F'
        6'd10:   w_char_code = 8'h50;                // 'P'
        6'd11:   w_char_code = 8'h53;                // 'S'
        6'd12:   w_char_code = 8'h3A;                // ':'
        6'd13:   w_char_code = w_ch_fps_hi;
        6'd14:   w_char_code = w_ch_fps_lo;
        6'd15:   w_char_code = 8'h20;                // 空格
        6'd16:   w_char_code = 8'h4C;                // 'L'
        6'd17:   w_char_code = 8'h41;                // 'A'
        6'd18:   w_char_code = 8'h54;                // 'T'
        6'd19:   w_char_code = 8'h3A;                // ':'
        6'd20:   w_char_code = w_ch_lat_h;
        6'd21:   w_char_code = w_ch_lat_t;
        6'd22:   w_char_code = w_ch_lat_o;
        6'd23:   w_char_code = 8'h20;                // 空格
        6'd24:   w_char_code = (r_info_nov_p1 ? 8'h20 : (8'h58));                // 'X'
        6'd25:   w_char_code = (r_info_nov_p1 ? 8'h20 : (8'h3A));                // ':'
        6'd26:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_x_th));
        6'd27:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_x_h));
        6'd28:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_x_t));
        6'd29:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_x_o));
        6'd30:   w_char_code = (r_info_nov_p1 ? 8'h20 : (8'h20));                // 空格
        // ---- 2026-09-20（2.4(2)）：Y 坐标 + 检测结果文字 ----------------------
        //   Y 坐标（第 31~36 格）："Y:" + 四位十进制，与 X 同构。
        //   检测结果（第 38~43 格）："NONE  " / "RED   " / "GRN   " / "BLU   " /
        //     "TARGET" —— 六字整体由 w_det_chars 给出，理由见 §12.1a。
        //   全部取**已经寄存到本级**的 r_hit_p1 / r_class_p1 / r_is_color_p1，
        //   与十进制各位同相，不会出现"坐标是新帧、类别是旧帧"。
        6'd31:   w_char_code = (r_info_nov_p1 ? 8'h20 : (8'h59));                // 'Y'
        6'd32:   w_char_code = (r_info_nov_p1 ? 8'h20 : (8'h3A));                // ':'
        6'd33:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_y_th));
        6'd34:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_y_h));
        6'd35:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_y_t));
        6'd36:   w_char_code = (r_info_nov_p1 ? 8'h20 : (w_ch_y_o));
        6'd37:   w_char_code = 8'h20;                // 空格
        6'd38:   w_char_code = w_det_chars[47:40];
        6'd39:   w_char_code = w_det_chars[39:32];
        6'd40:   w_char_code = w_det_chars[31:24];
        6'd41:   w_char_code = w_det_chars[23:16];
        6'd42:   w_char_code = w_det_chars[15:8];
        6'd43:   w_char_code = w_det_chars[7:0];
        // ---- ★2026-10-22 第 44~61 格：实测分辨率 + 帧计数 ----------------
        //   版式：" H1280 V0720 F0123"（16 格，其余补空格）
        //   为什么不用冒号：格数紧张，H/V/F 单字母 + 4 位数字已足够辨识。
        6'd44:   w_char_code = 8'h20;                               // 空格
        6'd45:   w_char_code = {4'h0, r_bcd_hpx[15:12]} + 8'h30;    // "1280X720"：实测每行像素数
        6'd46:   w_char_code = {4'h0, r_bcd_hpx[11:8] } + 8'h30;
        6'd47:   w_char_code = {4'h0, r_bcd_hpx[7:4]  } + 8'h30;
        6'd48:   w_char_code = {4'h0, r_bcd_hpx[3:0]  } + 8'h30;
        6'd49:   w_char_code = 8'h58;                               // 'X'
        6'd50:   w_char_code = {4'h0, r_bcd_vln[11:8] } + 8'h30;    // 实测每帧行数
        6'd51:   w_char_code = {4'h0, r_bcd_vln[7:4]  } + 8'h30;
        6'd52:   w_char_code = {4'h0, r_bcd_vln[3:0]  } + 8'h30;
        6'd53:   w_char_code = 8'h20;                               // 空格
        6'd54:   w_char_code = 8'h54;                               // 'T'
        6'd55:   w_char_code = 8'h3A;                               // ':'
        6'd56:   w_char_code = {4'h0, r_bcd_lat[11:8]} + 8'h30;     // 采集→显示延迟 百
        6'd57:   w_char_code = {4'h0, r_bcd_lat[7:4] } + 8'h30;     // 十
        6'd58:   w_char_code = {4'h0, r_bcd_lat[3:0] } + 8'h30;     // 个（ms）
        6'd59:   w_char_code = 8'h20;                               // 空格
        6'd60:   w_char_code = 8'h46;                               // 'F'
        6'd61:   w_char_code = 8'h3A;                               // ':'
        6'd62:   w_char_code = {4'h0, r_bcd_idx[7:4] } + 8'h30;     // 本秒内帧序号 十位
        6'd63:   w_char_code = {4'h0, r_bcd_idx[3:0] } + 8'h30;     // 个位（0~29，每秒归零）
        default: w_char_code = 8'h3F;                              // '?'（第 62~63 格补位）
    endcase
    if(r_is_auto_p1 && r_txt_ci_p1>=24 && r_txt_ci_p1<=43) begin
        case(r_txt_ci_p1)
            24:w_char_code="R";25:w_char_code="G";26:w_char_code="B";27:w_char_code=":";
            28:w_char_code=8'h30+{5'd0,w_auto_count};
            30:w_char_code="R";31:w_char_code=":";32:w_char_code=8'h30+{7'd0,w_auto_valid[0]};
            34:w_char_code="G";35:w_char_code=":";36:w_char_code=8'h30+{7'd0,w_auto_valid[1]};
            38:w_char_code="B";39:w_char_code=":";40:w_char_code=8'h30+{7'd0,w_auto_valid[2]};
            default:w_char_code=" ";
        endcase
    end
    if(r_auto_row_p1) w_char_code=w_auto_ready ? w_auto_char:8'h20;
end

// ---- 12.2 ASCII → my_charlib 索引（表见 my_charlib.v 头部 / gen_osd_rom.py:CHARLIB_INDEX）
//      '0'..'9' 0x30..0x39 → idx  0..9    idx = ascii - 0x30
//      'A'..'Z' 0x41..0x5A → idx 10..35   idx = ascii - 0x37
//      ':' 0x3A → 36   '.' 0x2E → 37   '/' 0x2F → 38   ' ' 0x20 → 39
reg [7:0] w_rom_index;

always @ (*) begin
    if ((w_char_code >= 8'h30) && (w_char_code <= 8'h39))
        w_rom_index = w_char_code - 8'h30;          // 数字
    else if ((w_char_code >= 8'h41) && (w_char_code <= 8'h5A))
        w_rom_index = w_char_code - 8'h37;          // 大写字母
    else if (w_char_code == 8'h20)
        w_rom_index = 8'd39;                        // 空格
    else if (w_char_code == 8'h3A)
        w_rom_index = 8'd36;                        // ':'
    else if (w_char_code == 8'h2E)
        w_rom_index = 8'd37;                        // '.'
    else if (w_char_code == 8'h2F)
        w_rom_index = 8'd38;                        // '/'
    else
        w_rom_index = 8'd39;                        // 未定义 → 空格
end

// ---- 12.3 字库例化（自研原创素材；★v1.6：改成**同步读 ROM**，多 1 拍读延迟）
//      一拍 4 个像素共用同一行字模（字符下标与行号都是拍级量），所以只例化 1 个，
//      4 个像素各自从返回的 16 bit 里取自己那一位（§12.5）。
//      ⚠ 接口与旧版的唯一区别：新增 I_clk，O_bits 变成"地址进 → 下一拍出"。
//        所以 w_glyph_bits 描述的是"送地址那一拍（第 2 拍）的 p1"，
//        它合法可用的时刻是第 3 拍 —— 正好与 §11b 的 p2 同拍（见 §12 的 A/B/C 分层）。
wire [15:0] w_rom_glyph_bits;
reg r_dash_active;
reg [15:0] r_dash_bits;
always @(posedge I_clk or negedge I_rst_n) begin
 if(!I_rst_n) begin r_dash_active<=0;r_dash_bits<=0;end
 else begin
  r_dash_active<=w_char_code==8'h2d;
  r_dash_bits<=(r_txt_row_p1==7||r_txt_row_p1==8)?16'h3ffc:16'd0;
 end
end
wire [15:0] w_glyph_bits=r_dash_active ? r_dash_bits:w_rom_glyph_bits;

my_charlib u_charlib (
    .I_clk   (I_clk),           // ★v1.6 新增：同步读时钟
    .I_index (w_rom_index),
    .I_row   (r_txt_row_p1),
    .O_bits  (w_rom_glyph_bits)
);

// ---- 12.4 逐像素命中判据（文字面）
//      文字：本拍落在文字行/列范围内 && 该字该行该列的点阵 bit = 1 → 命中
//      字内列 = (x - TEXT_X) & 15 = {r_txt_col_base_p2, 2'b00} + k
//      字库 bit[15] 是最左像素，所以取 w_glyph_bits[15 - 列号]。
//      ⚠ v1.6：行/列区间与列基址必须用 **p2**（与点阵同拍的那份像素），
//        用 p1 就是"拿下一份像素的窗口去套这一份像素的点阵"。
wire [3:0] w_txt_col0 = {r_txt_col_base_p2, 2'b00};
wire [3:0] w_txt_col1 = w_txt_col0 + 4'd1;
wire [3:0] w_txt_col2 = w_txt_col0 + 4'd2;
wire [3:0] w_txt_col3 = w_txt_col0 + 4'd3;

wire w_txt_hit0 = r_txt_inrow_p2 && r_txt_incol_p2 && w_glyph_bits[15 - w_txt_col0];
wire w_txt_hit1 = r_txt_inrow_p2 && r_txt_incol_p2 && w_glyph_bits[15 - w_txt_col1];
wire w_txt_hit2 = r_txt_inrow_p2 && r_txt_incol_p2 && w_glyph_bits[15 - w_txt_col2];
wire w_txt_hit3 = r_txt_inrow_p2 && r_txt_incol_p2 && w_glyph_bits[15 - w_txt_col3];

wire [3:0] w_pix_text_hit = {w_txt_hit3, w_txt_hit2, w_txt_hit1, w_txt_hit0};

// ---- 12.5 像素混合：文字 > 安路Logo > 自研Logo > 原像素
//      ⚠⚠ 下标必须是 k，**不是** 3-k：w_pix_text_hit = {hit3,hit2,hit1,hit0}，而
//         w_mixk 送的是原像素的第 k 个（pix0 = [95:72] = 最左，x 偏移 k）。
//         写成 3-k 会把一拍的 4 个像素整体镜像翻转（2026-09-14 已修，此处只是搬家）。
//      ⚠ v1.4：安路 Logo 插在文字与自研 Logo 之间 —— 真值表必须与
//         check_osd.py / check_anlogo.py 的期望模型逐字一致，改这里必同步改模型。
//      ⚠ v1.6：全部输入改读 **p2**（§11b）—— 与 ROM 出来的点阵同拍的那份像素。
//         优先级、颜色、掩蔽规则一个字都没动，只是整体晚了一拍。
wire [23:0] w_mix0 = w_pix_text_hit[0] ? OSD_TEXT_COLOR :
                     (r_an_hit0_p2     ? r_an_col0_p2 :
                     (r_logo_hit0_p2   ? r_logo_col0_p2 : r_pix_data_p2[95:72]));
wire [23:0] w_mix1 = w_pix_text_hit[1] ? OSD_TEXT_COLOR :
                     (r_an_hit1_p2     ? r_an_col1_p2 :
                     (r_logo_hit1_p2   ? r_logo_col1_p2 : r_pix_data_p2[71:48]));
wire [23:0] w_mix2 = w_pix_text_hit[2] ? OSD_TEXT_COLOR :
                     (r_an_hit2_p2     ? r_an_col2_p2 :
                     (r_logo_hit2_p2   ? r_logo_col2_p2 : r_pix_data_p2[47:24]));
wire [23:0] w_mix3 = w_pix_text_hit[3] ? OSD_TEXT_COLOR :
                     (r_an_hit3_p2     ? r_an_col3_p2 :
                     (r_logo_hit3_p2   ? r_logo_col3_p2 : r_pix_data_p2[23:0]));

wire [95:0] w_mix = {w_mix0, w_mix1, w_mix2, w_mix3};

//------------------------------------------------------------------------------
// 13. 输出级（第 3 级寄存器）：4 路输出在同一级装载，且**控制与数据严格同拍**
//
//  ⚠⚠ 2026-09-16 修复（数据/控制 1 拍错位，v1.1 起就存在）：
//   修复前四路写的都是"再延一拍"的控制（r_vld2/r_tlast2/r_tuser2），而数据链只有
//   2 级 ⇒ 实测数据延迟 2 拍、控制延迟 3 拍。后果（sim\_skew_work 实测证据）：
//     · 输入 I_tuser=1 那一拍携带 beat 0，而 O_tuser=1 那一拍输出的是 beat 1
//       —— 整帧相对 tuser 错开 1 拍（= 4 像素），beat 0 从未以 O_tvalid=1 出现；
//     · O_tlast 同样晚 1 拍（输入 beat 31 的 tlast 落在携带 beat 32 的那一拍）；
//     · 段尾多出 1 拍"O_tvalid=1 却携带气泡期陈旧数据"（丢头 1 拍 + 补尾 1 拍垃圾）。
//   下游 data_96bit_to_128bit 按 tuser 复位打包，会因此整体错位。
//   修法（v1.2~v1.5）：控制链去掉多出来的那一级，直接用 r_vld1/r_tlast/r_tuser ⇒
//   四路同为延迟 2 拍。
//
//  ★2026-10-24 v1.6：数据链因为 ROM 读多了一拍而变成 3 级，所以控制链也**同步
//   再补一级**（§11c 的 r_vld2/r_tlast2/r_tuser2），四路仍然严格同拍 = 3 拍。
//   这正是上面那次事故的镜像版，别只改数据不改控制。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld2)
        O_tdata <= w_mix;
    else
        O_tdata <= 96'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld2;             // = I_tvalid 延迟 3 拍，与 O_tdata 同拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tlast <= 1'b0;
    else
        O_tlast <= r_tlast2;            // 与 O_tdata 同拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tuser <= 1'b0;
    else
        O_tuser <= r_tuser2;            // 与 O_tdata 同拍
end

//------------------------------------------------------------------------------
// 14. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//------------------------------------------------------------------------------
initial begin
    r_x_grp     = {XW{1'b0}};
    r_y_pos     = 11'd0;
    r_x_now     = 11'd0;
    r_y_now     = 11'd0;
    r_tlast     = 1'b0;
    r_tuser     = 1'b0;
    r_vld1      = 1'b0;
    r_info_mode = 11'd0;
    r_info_fps  = 32'd0;
    r_info_lat  = 11'd0;
    r_info_x    = 11'd0;
    r_info_cnt  = 32'd0;
    r_info_y    = 11'd0;
    r_info_class = 2'd0;
    r_info_tid   = 8'd0;
    // ---- v1.2 第 1 级流水（与 §11 的复位分支逐一相同）----
    r_x_th_p1   = 4'd0;
    r_x_h_p1    = 4'd0;
    r_x_t_p1    = 4'd0;
    r_x_o_p1    = 4'd0;
    r_lat_h_p1  = 4'd0;
    r_lat_t_p1  = 4'd0;
    r_lat_o_p1  = 4'd0;
    r_fps_hi_p1 = 4'd0;
    r_fps_lo_p1 = 4'd0;
    r_mode_chars_p1 = 16'd0;
    r_mode_name_p1  = 40'd0;
    r_txt_inrow_p1  = 1'b0;
    r_txt_incol_p1  = 1'b0;
    r_txt_ci_p1     = 6'd0;
    r_y_th_p1   = 4'd0;
    r_y_h_p1    = 4'd0;
    r_y_t_p1    = 4'd0;
    r_y_o_p1    = 4'd0;
    r_hit_p1        = 1'b0;
    r_info_nov_p1   = 1'b0;
    r_class_p1      = 2'd0;
    r_tid_t_p1      = 4'd0;
    r_tid_o_p1      = 4'd0;
    r_is_color_p1   = 1'b0;
    r_txt_col_base_p1 = 2'd0;
    r_txt_row_p1    = 4'd0;
    r_logo_hit0_p1  = 1'b0;
    r_logo_hit1_p1  = 1'b0;
    r_logo_hit2_p1  = 1'b0;
    r_logo_hit3_p1  = 1'b0;
    r_logo_col0_p1  = 24'd0;
    r_logo_col1_p1  = 24'd0;
    r_logo_col2_p1  = 24'd0;
    r_logo_col3_p1  = 24'd0;
    // ---- v1.4 安路 Logo 第 1 级（与 §11 的复位分支逐一相同）----
    r_an_hit0_p1    = 1'b0;
    r_an_hit1_p1    = 1'b0;
    r_an_hit2_p1    = 1'b0;
    r_an_hit3_p1    = 1'b0;
    r_an_col0_p1    = 24'd0;
    r_an_col1_p1    = 24'd0;
    r_an_col2_p1    = 24'd0;
    r_an_col3_p1    = 24'd0;
    r_pix_data_p1   = 96'd0;
    // ---- v1.6 p2 寄存器组（与 §11b 的复位分支逐一相同）----
    r_pix_data_p2   = 96'd0;
    r_logo_hit0_p2  = 1'b0;
    r_logo_hit1_p2  = 1'b0;
    r_logo_hit2_p2  = 1'b0;
    r_logo_hit3_p2  = 1'b0;
    r_logo_col0_p2  = 24'd0;
    r_logo_col1_p2  = 24'd0;
    r_logo_col2_p2  = 24'd0;
    r_logo_col3_p2  = 24'd0;
    r_an_hit0_p2    = 1'b0;
    r_an_hit1_p2    = 1'b0;
    r_an_hit2_p2    = 1'b0;
    r_an_hit3_p2    = 1'b0;
    r_an_col0_p2    = 24'd0;
    r_an_col1_p2    = 24'd0;
    r_an_col2_p2    = 24'd0;
    r_an_col3_p2    = 24'd0;
    r_txt_inrow_p2  = 1'b0;
    r_txt_incol_p2  = 1'b0;
    r_txt_col_base_p2 = 2'd0;
    // ---- v1.6 控制链第 2 级（与 §11c 的复位分支逐一相同）----
    r_vld2      = 1'b0;
    r_tlast2    = 1'b0;
    r_tuser2    = 1'b0;
    O_tdata     = 96'd0;
    O_tvalid    = 1'b0;
    O_tlast     = 1'b0;
    O_tuser     = 1'b0;
    // ---- 配置护栏（§10c，只仿真；综合里是常数）----
    r_an_cfg_err = ((ANLOGO_X % 4) != 0);
    if (r_an_cfg_err)
        $display("*** ERROR: osd_mixer: ANLOGO_X=%0d 不是 4 的倍数 —— alg_logo_eram 一拍读 4 像素（4px/字），列位置必须 4 像素对齐，否则整幅安路 Logo 错位。",
                 ANLOGO_X);
end
endmodule

// Frame-level RGB coordinate text builder. One shared serial BCD converter,
// one synchronous character cache; avoids six long pixel-rate converters.
module auto_target_text(
 input wire I_clk,I_rst_n,I_frame,
 input wire [2:0] I_valid,
 input wire [32:0] I_x,I_y,
 input wire [5:0] I_idx,
 output reg [7:0] O_char,
 output reg [2:0] O_count,O_valid,
 output reg O_ready
);
 localparam IDLE=0,TEMPLATE=1,LOAD=2,BCD=3,DIGITS=4;
 reg [2:0] state,field;
 reg [5:0] pos;
 reg [4:0] col;
 reg [1:0] group_id,digit;
 reg [3:0] bit_count;
 reg [32:0] sx,sy;
 reg [10:0] binary;
 reg [15:0] bcd;
 reg [15:0] adjusted;
 integer j;
 always @* begin
  adjusted=bcd;
  for(j=0;j<4;j=j+1) if(bcd[j*4+:4]>=5) adjusted[j*4+:4]=bcd[j*4+:4]+4'd3;
 end
 wire [15:0] shifted={adjusted[14:0],binary[10]};
 wire [1:0] color_id=field[2:1];
 wire [5:0] coord_slot=color_id*20+(field[0]?6'd13:6'd6)+digit;
 reg [7:0] template_char;
 always @* begin
  template_char=" ";
  if(pos<60) begin
   case(col)
    0:template_char=group_id==0 ? "R":(group_id==1 ? "G":"B");
    1:template_char=group_id==0 ? "E":(group_id==1 ? "R":"L");
    2:template_char=group_id==0 ? "D":(group_id==1 ? "N":"U");
    4:template_char="X";5:template_char=":";
    11:template_char="Y";12:template_char=":";
    6,7,8,9,13,14,15,16:template_char=O_valid[group_id] ? "0":"-";
   endcase
  end
 end
 wire [7:0] digit_char=O_valid[color_id] ? (8'h30+{4'd0,bcd[15:12]}):8'h2d;
 reg [7:0] text_mem[0:63]; //synthesis ram_style = bram
 always @(posedge I_clk) begin
  O_char<=text_mem[I_idx];
  if(state==TEMPLATE) text_mem[pos]<=template_char;
  else if(state==DIGITS) text_mem[coord_slot]<=digit_char;
 end
 always @(posedge I_clk or negedge I_rst_n) begin
  if(!I_rst_n) begin
   state<=IDLE;field<=0;pos<=0;col<=0;group_id<=0;digit<=0;
   bit_count<=0;sx<=0;sy<=0;binary<=0;bcd<=0;
   O_count<=0;O_valid<=0;O_ready<=0;
  end else if(I_frame) begin
   sx<=I_x;sy<=I_y;O_valid<=I_valid;
   O_count<={2'd0,I_valid[0]}+{2'd0,I_valid[1]}+{2'd0,I_valid[2]};
   O_ready<=0;state<=TEMPLATE;pos<=0;col<=0;group_id<=0;field<=0;
  end else case(state)
   TEMPLATE: begin
    if(pos==63) state<=LOAD;
    else begin pos<=pos+1'b1;
     if(col==19) begin col<=0;group_id<=group_id+1'b1;end
     else col<=col+1'b1;
    end
   end
   LOAD: begin
    binary<=field[0] ? sy[color_id*11+:11]:sx[color_id*11+:11];
    bcd<=0;bit_count<=0;state<=BCD;
   end
   BCD: begin
    bcd<=shifted;binary<={binary[9:0],1'b0};
    if(bit_count==10) begin digit<=0;state<=DIGITS;end
    else bit_count<=bit_count+1'b1;
   end
   DIGITS: begin
    bcd<={bcd[11:0],4'd0};
    if(digit==3) begin
     if(field==5) begin state<=IDLE;O_ready<=1;end
     else begin field<=field+1'b1;state<=LOAD;end
    end else digit<=digit+1'b1;
   end
  endcase
 end
endmodule
