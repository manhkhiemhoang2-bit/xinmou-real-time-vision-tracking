//==============================================================================
// 文件名   : osd_mixer.v
// 模块名   : osd_mixer
// 日期     : 2026-09-16
// 版本     : v1.2
// 描述     : OSD 叠加混合器 —— 「安路」Logo + 一行动态信息（FR-4 硬性要求）
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
//  输出相对输入**恒定延迟 2 拍**（v1.2 起；v1.1 是 1 拍），4 路输出
//  （tdata/tvalid/tlast/tuser）全部在**同一个第 2 级寄存器**上装载 ——
//  不存在"数据走 2 拍、控制走 1 拍"的错位。
//  O_tready 是组合直通（`assign O_tready = I_tready;`），全链路不反压。
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
//  · Logo：my_logo_rom（自研原创 128x64，1bpp + 2 色），左上角 (LOGO_X, LOGO_Y)。
//  · 文字：my_charlib（自研原创 42 字 x 16x16 点阵），一行最多 N_CHAR_MAX 个字，
//    左上角 (TEXT_X, TEXT_Y)，每字 16 像素宽、16 行高，1x 不缩放。
//  · 叠加优先级：文字 > Logo > 原像素（文字压在 Logo 上时文字赢）。
//  · 两个 ROM 都**不存 alpha**，只有 1 bit 命中位；因此是"命中即替换"的硬叠加，
//    没有半透明混合 —— 与官方 osd 例程口径一致，也便于逐像素做精确自证。
//  · ROM 例化数：Logo ROM 是**逐像素**接口（I_x 只指一个像素），所以一拍 4 个像素
//    要 4 个实例（`g_logo`）；字库是**逐字符**接口（行号 + 字符下标），同拍 4 个
//    像素的行号/字符下标完全相同（只有字内列不同），所以只例化 1 个（§9）。
//
//  ---------------------------------------------------------------------------
//  【六、信息字符化的下标表（TEXT_LEN = 27）】
//  ---------------------------------------------------------------------------
//   pos:  0 1 2 3 4 5 6 7 8 9 ...             （每个 pos = 16 像素）
//    0..1  : "M" + 档位号（I_info_mode 0..5 → '0'..'5'，其它 → '?'）
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
    // ---- Logo 版面：默认右下角，右边距 16、下边距 16 ----
    parameter LOGO_X     = IMG_WIDTH  - 144,      // 1280-144 = 1136
    parameter LOGO_Y     = IMG_HEIGHT - 80,       // 720-80   = 640
    // ---- 文字版面：默认左下角，左边距 16、下边距 16 ----
    parameter TEXT_X     = 16,
    parameter TEXT_Y     = IMG_HEIGHT - 32,       // 720-32   = 688
    // ---- 颜色 ----
    parameter [23:0] OSD_LOGO_COLOR = 24'h00AAFF, // Logo 前景（与 my_logo_rom 默认一致）
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
    input  wire [10:0]  I_info_mode,   // 当前档位号 0..5
    input  wire [31:0]  I_info_fps,    // 帧率
    input  wire [10:0]  I_info_lat,    // 延迟（拍）
    input  wire [10:0]  I_info_x,      // 检测坐标
    input  wire [10:0]  I_info_y,
    input  wire [31:0]  I_info_cnt,    // 检测数量（本版不显示，见 §七.2）
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

localparam N_CHAR_MAX = 16;                             // 文字行最多 16 个字（版面限制）
localparam TEXT_W     = 16;                             // 单字像素宽
localparam TEXT_H     = 16;                             // 单字像素高

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
wire [3:0]  w_txt_row    = (w_y_base - TEXT_Y) & 4'hF;
wire        w_txt_inrow  = (w_y_base >= TEXT_Y) && (w_y_base < (TEXT_Y + TEXT_H));
wire        w_txt_incol  = (w_x_base >= TEXT_X) &&
                           (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)));

//------------------------------------------------------------------------------
// 3. 文字面拍级量（组合）
//
//  ⚠ 字内列基址必须取 dx[3:2]：dx = x - TEXT_X 恒为 4 的倍数，bit[1:0] 永远为 0；
//    早先错写成 dx[1:0]，基址恒 0，于是每一拍都去取点阵的 bit[15:12]，
//    屏幕上每个字只剩最左 4 列反复重画（实测 447/16384 像素不符）。
//------------------------------------------------------------------------------
wire [4:0] w_txt_ci       = w_txt_dx_txt[8:4];
wire [1:0] w_txt_col_base = w_txt_dx_txt[3:2];
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

always @ (posedge I_clk) begin
    if (!I_rst_n) begin
        r_info_mode <= 11'd0;
        r_info_fps  <= 32'd0;
        r_info_lat  <= 11'd0;
        r_info_x    <= 11'd0;
        r_info_y    <= 11'd0;
    end else begin
        r_info_mode <= I_info_mode;
        r_info_fps  <= I_info_fps;
        r_info_lat  <= I_info_lat;
        r_info_x    <= I_info_x;
        r_info_y    <= I_info_y;
    end
end

//------------------------------------------------------------------------------
// 5. 档位号 → "M<n>" 两个字符（16 bit = {第一个字符, 第二个字符}）
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
        default: w_mode_chars = 16'h4D3F;   // "M?"
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
wire [3:0]  w_x_th = (r_info_x >= 11'd1000) ? 4'd1 : 4'd0;
wire [10:0] w_x_r3 = r_info_x - ({7'd0, w_x_th} * 11'd1000);

wire [3:0] w_x_h = (w_x_r3 >= 11'd900) ? 4'd9 :
                   (w_x_r3 >= 11'd800) ? 4'd8 :
                   (w_x_r3 >= 11'd700) ? 4'd7 :
                   (w_x_r3 >= 11'd600) ? 4'd6 :
                   (w_x_r3 >= 11'd500) ? 4'd5 :
                   (w_x_r3 >= 11'd400) ? 4'd4 :
                   (w_x_r3 >= 11'd300) ? 4'd3 :
                   (w_x_r3 >= 11'd200) ? 4'd2 :
                   (w_x_r3 >= 11'd100) ? 4'd1 : 4'd0;

wire [10:0] w_x_r2 = w_x_r3 - ({7'd0, w_x_h} * 11'd100);

wire [3:0] w_x_t = (w_x_r2 >= 11'd90) ? 4'd9 :
                   (w_x_r2 >= 11'd80) ? 4'd8 :
                   (w_x_r2 >= 11'd70) ? 4'd7 :
                   (w_x_r2 >= 11'd60) ? 4'd6 :
                   (w_x_r2 >= 11'd50) ? 4'd5 :
                   (w_x_r2 >= 11'd40) ? 4'd4 :
                   (w_x_r2 >= 11'd30) ? 4'd3 :
                   (w_x_r2 >= 11'd20) ? 4'd2 :
                   (w_x_r2 >= 11'd10) ? 4'd1 : 4'd0;

wire [10:0] w_x_r1 = w_x_r2 - ({7'd0, w_x_t} * 11'd10);
wire [3:0]  w_x_o  = w_x_r1[3:0];

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

my_logo_rom u_logo0 (
    .I_x (w_logo_dx[10:0] + 11'd0), .I_y (w_logo_dy[10:0]),
    .O_hit (w_logo_hit0), .O_color (w_logo_col0)
);

my_logo_rom u_logo1 (
    .I_x (w_logo_dx[10:0] + 11'd1), .I_y (w_logo_dy[10:0]),
    .O_hit (w_logo_hit1), .O_color (w_logo_col1)
);

my_logo_rom u_logo2 (
    .I_x (w_logo_dx[10:0] + 11'd2), .I_y (w_logo_dy[10:0]),
    .O_hit (w_logo_hit2), .O_color (w_logo_col2)
);

my_logo_rom u_logo3 (
    .I_x (w_logo_dx[10:0] + 11'd3), .I_y (w_logo_dy[10:0]),
    .O_hit (w_logo_hit3), .O_color (w_logo_col3)
);

// O_hit = 1 才是"笔画"像素：只在命中处把原像素换成 Logo 的前景色；O_hit = 0
// 的像素保持原像素不变 —— Logo 是"贴"上去的图形，不是一个不透明色块。
// 命中判据完全由 ROM 的 O_hit 给出，RTL 不另造判据。

//------------------------------------------------------------------------------
// 11. 【v1.2 新增 · 第 1 级流水】把第 2 级要用到的**全部叶子值**寄存一拍
//
//  这一级就是老版本"组合到 w_mix 为止"的前半段：数字拆位、位置判据、Logo 查表
//  都在这一级算完（与 v1.1 逐 bit 相同），然后在同一个时钟沿把结果整体捕获
//  —— 即"把老版本 O_tdata 的整个输入锥体一起打一拍"。
//
//  ⚠ 合并点另一侧一个都不能漏，清单（共 264 bit）：
//      十进制各位 7x4 = 28  · FPS 半字节 8   · 档位 ASCII 16（来自端口！）
//      位置 13（inrow/incol/ci[4:0]/col_base[2]/row[4]）
//      Logo 4+96 = 100      · 原像素 96
//      （2026-09-16 修复前这里还有 r_vld2/r_tlast2/r_tuser2 三位控制，已删除：
//        它们让控制链比数据链多一拍，见 §13。）
//  本模块**不门控**这一级（与老版本输出级同语义）：有效与否只由控制位决定，
//  第 2 级在控制位为 0 时把 O_tdata 强制置 0 —— 所以气泡期捕获到什么值都不影响。
//------------------------------------------------------------------------------
reg [3:0]  r_x_th_p1, r_x_h_p1, r_x_t_p1, r_x_o_p1;         // I_info_x 的十进制各位
reg [3:0]  r_lat_h_p1, r_lat_t_p1, r_lat_o_p1;              // I_info_lat 的十进制各位
reg [3:0]  r_fps_hi_p1, r_fps_lo_p1;                        // I_info_fps 低字节的两个半字节
reg [15:0] r_mode_chars_p1;                                 // 端口 I_info_mode 的组合结果（活叶子）
reg        r_txt_inrow_p1, r_txt_incol_p1;                  // 文字面行/列区间
reg [4:0]  r_txt_ci_p1;                                     // 字符槽下标
reg [1:0]  r_txt_col_base_p1;                               // 字内列基址（一拍 4 像素）
reg [3:0]  r_txt_row_p1;                                    // 字模行号
reg        r_logo_hit0_p1, r_logo_hit1_p1,
           r_logo_hit2_p1, r_logo_hit3_p1;                  // Logo 命中（4 像素）
reg [23:0] r_logo_col0_p1, r_logo_col1_p1,
           r_logo_col2_p1, r_logo_col3_p1;                  // Logo 颜色（4 像素）
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
        r_fps_hi_p1 <= 4'd0;
        r_fps_lo_p1 <= 4'd0;
        r_mode_chars_p1 <= 16'd0;
        r_txt_inrow_p1  <= 1'b0;
        r_txt_incol_p1  <= 1'b0;
        r_txt_ci_p1     <= 5'd0;
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
        r_pix_data_p1   <= 96'd0;
    end else begin
        r_x_th_p1   <= w_x_th;
        r_x_h_p1    <= w_x_h;
        r_x_t_p1    <= w_x_t;
        r_x_o_p1    <= w_x_o;
        r_lat_h_p1  <= w_lat_h;
        r_lat_t_p1  <= w_lat_t;
        r_lat_o_p1  <= w_lat_o;
        r_fps_hi_p1 <= r_info_fps[7:4];
        r_fps_lo_p1 <= r_info_fps[3:0];
        r_mode_chars_p1 <= w_mode_chars;
        r_txt_inrow_p1  <= w_txt_inrow;
        r_txt_incol_p1  <= w_txt_incol;
        r_txt_ci_p1     <= w_txt_ci;
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
        r_pix_data_p1   <= I_tdata;
    end
end

//------------------------------------------------------------------------------
// 12. 【第 2 级】ASCII → 字符码 → 字库索引 → 点阵 → 逐像素命中 → 混合
//
//  输入**全部**来自 §11 的寄存器：这里不许再读任何端口或未寄存量。
//  与 v1.1 的对应关系（逐字）：
//      w_x_o/w_lat_h/... → r_x_o_p1/r_lat_h_p1/...   （十进制各位）
//      w_txt_ci          → r_txt_ci_p1                （case 的选择量）
//      w_txt_row         → r_txt_row_p1               （字模行号）
//      w_txt_col_base    → r_txt_col_base_p1          （字内列基址）
//      w_txt_inrow/incol → r_txt_inrow_p1/r_txt_incol_p1
//      w_logo_hit*/col*  → r_logo_hit*_p1/r_logo_col*_p1
//      I_tdata           → r_pix_data_p1
//------------------------------------------------------------------------------
// ---- 12.1 字符槽 ASCII（下标定义见文件头 §六，与 v1.1 完全一致）----
wire [7:0] w_ch_x_o   = {4'h0, r_x_o_p1}   + 8'h30;
wire [7:0] w_ch_x_t   = {4'h0, r_x_t_p1}   + 8'h30;
wire [7:0] w_ch_x_h   = {4'h0, r_x_h_p1}   + 8'h30;
wire [7:0] w_ch_x_th  = {4'h0, r_x_th_p1}  + 8'h30;
wire [7:0] w_ch_lat_o = {4'h0, r_lat_o_p1} + 8'h30;
wire [7:0] w_ch_lat_t = {4'h0, r_lat_t_p1} + 8'h30;
wire [7:0] w_ch_lat_h = {4'h0, r_lat_h_p1} + 8'h30;
// FPS 十六进制：半字节 0..9 → '0'..'9'，10..15 → ':'..'?'（可辨认；不做 A..F 映射以省 LUT）
wire [7:0] w_ch_fps_hi = 8'h30 + {4'h0, r_fps_hi_p1};
wire [7:0] w_ch_fps_lo = 8'h30 + {4'h0, r_fps_lo_p1};

reg [7:0] w_char_code;

always @ (*) begin
    case (r_txt_ci_p1)
        5'd0:    w_char_code = r_mode_chars_p1[15:8];   // 'M'
        5'd1:    w_char_code = r_mode_chars_p1[7:0];    // 档位数字
        5'd2:    w_char_code = 8'h20;                // 空格
        5'd3:    w_char_code = 8'h46;                // 'F'
        5'd4:    w_char_code = 8'h50;                // 'P'
        5'd5:    w_char_code = 8'h53;                // 'S'
        5'd6:    w_char_code = 8'h3A;                // ':'
        5'd7:    w_char_code = w_ch_fps_hi;
        5'd8:    w_char_code = w_ch_fps_lo;
        5'd9:    w_char_code = 8'h20;                // 空格
        5'd10:   w_char_code = 8'h4C;                // 'L'
        5'd11:   w_char_code = 8'h41;                // 'A'
        5'd12:   w_char_code = 8'h54;                // 'T'
        5'd13:   w_char_code = 8'h3A;                // ':'
        5'd14:   w_char_code = w_ch_lat_h;
        5'd15:   w_char_code = w_ch_lat_t;
        5'd16:   w_char_code = w_ch_lat_o;
        5'd17:   w_char_code = 8'h20;                // 空格
        5'd18:   w_char_code = 8'h58;                // 'X'
        5'd19:   w_char_code = 8'h3A;                // ':'
        5'd20:   w_char_code = w_ch_x_th;
        5'd21:   w_char_code = w_ch_x_h;
        5'd22:   w_char_code = w_ch_x_t;
        5'd23:   w_char_code = w_ch_x_o;
        5'd24:   w_char_code = 8'h59;                // 'Y'
        default: w_char_code = 8'h3F;                // '?'（占位，见 §六）
    endcase
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

// ---- 12.3 字库例化（自研原创素材；只读、组合读）
//      一拍 4 个像素共用同一行字模（字符下标与行号都是拍级量），所以只例化 1 个，
//      4 个像素各自从返回的 16 bit 里取自己那一位（§12.5）。
wire [15:0] w_glyph_bits;      // 该字符该行的点阵，bit[15] = 最左

my_charlib u_charlib (
    .I_index (w_rom_index),
    .I_row   (r_txt_row_p1),
    .O_bits  (w_glyph_bits)
);

// ---- 12.4 逐像素命中判据（文字面）
//      文字：本拍落在文字行/列范围内 && 该字该行该列的点阵 bit = 1 → 命中
//      字内列 = (x - TEXT_X) & 15 = {r_txt_col_base_p1, 2'b00} + k
//      字库 bit[15] 是最左像素，所以取 w_glyph_bits[15 - 列号]。
wire [3:0] w_txt_col0 = {r_txt_col_base_p1, 2'b00};
wire [3:0] w_txt_col1 = w_txt_col0 + 4'd1;
wire [3:0] w_txt_col2 = w_txt_col0 + 4'd2;
wire [3:0] w_txt_col3 = w_txt_col0 + 4'd3;

wire w_txt_hit0 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col0];
wire w_txt_hit1 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col1];
wire w_txt_hit2 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col2];
wire w_txt_hit3 = r_txt_inrow_p1 && r_txt_incol_p1 && w_glyph_bits[15 - w_txt_col3];

wire [3:0] w_pix_text_hit = {w_txt_hit3, w_txt_hit2, w_txt_hit1, w_txt_hit0};

// ---- 12.5 像素混合：文字 > Logo > 原像素（优先级与 v1.1 一字不改）
//      ⚠⚠ 下标必须是 k，**不是** 3-k：w_pix_text_hit = {hit3,hit2,hit1,hit0}，而
//         w_mixk 送的是原像素的第 k 个（pix0 = [95:72] = 最左，x 偏移 k）。
//         写成 3-k 会把一拍的 4 个像素整体镜像翻转（2026-09-14 已修，此处只是搬家）。
wire [23:0] w_mix0 = w_pix_text_hit[3] ? OSD_TEXT_COLOR :
                     (r_logo_hit0_p1   ? r_logo_col0_p1 : r_pix_data_p1[95:72]);
wire [23:0] w_mix1 = w_pix_text_hit[2] ? OSD_TEXT_COLOR :
                     (r_logo_hit1_p1   ? r_logo_col1_p1 : r_pix_data_p1[71:48]);
wire [23:0] w_mix2 = w_pix_text_hit[1] ? OSD_TEXT_COLOR :
                     (r_logo_hit2_p1   ? r_logo_col2_p1 : r_pix_data_p1[47:24]);
wire [23:0] w_mix3 = w_pix_text_hit[0] ? OSD_TEXT_COLOR :
                     (r_logo_hit3_p1   ? r_logo_col3_p1 : r_pix_data_p1[23:0]);

wire [95:0] w_mix = {w_mix0, w_mix1, w_mix2, w_mix3};

//------------------------------------------------------------------------------
// 13. 输出级（第 2 级寄存器）：4 路输出在同一级装载，且**控制与数据严格同拍**
//
//  ⚠⚠ 2026-09-16 修复（数据/控制 1 拍错位，v1.1 起就存在）：
//   修复前四路写的都是"再延一拍"的控制（r_vld2/r_tlast2/r_tuser2），而数据链只有
//   2 级 ⇒ 实测数据延迟 2 拍、控制延迟 3 拍。后果（sim\_skew_work 实测证据）：
//     · 输入 I_tuser=1 那一拍携带 beat 0，而 O_tuser=1 那一拍输出的是 beat 1
//       —— 整帧相对 tuser 错开 1 拍（= 4 像素），beat 0 从未以 O_tvalid=1 出现；
//     · O_tlast 同样晚 1 拍（输入 beat 31 的 tlast 落在携带 beat 32 的那一拍）；
//     · 段尾多出 1 拍"O_tvalid=1 却携带气泡期陈旧数据"（丢头 1 拍 + 补尾 1 拍垃圾）。
//   下游 data_96bit_to_128bit 按 tuser 复位打包，会因此整体错位。
//
//   修法：控制链去掉多出来的那一级，直接用 r_vld1/r_tlast/r_tuser ⇒ 四路同为延迟
//   2 拍；数据链一级不动，SWNS 4.115ns 的时序收益全部保留。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld1)
        O_tdata <= w_mix;
    else
        O_tdata <= 96'd0;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld1;             // = I_tvalid 延迟 2 拍，与 O_tdata 同拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tlast <= 1'b0;
    else
        O_tlast <= r_tlast;             // 与 O_tdata 同拍
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tuser <= 1'b0;
    else
        O_tuser <= r_tuser;             // 与 O_tdata 同拍
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
    r_info_y    = 11'd0;
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
    r_txt_inrow_p1  = 1'b0;
    r_txt_incol_p1  = 1'b0;
    r_txt_ci_p1     = 5'd0;
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
    r_pix_data_p1   = 96'd0;
    O_tdata     = 96'd0;
    O_tvalid    = 1'b0;
    O_tlast     = 1'b0;
    O_tuser     = 1'b0;
end
endmodule
