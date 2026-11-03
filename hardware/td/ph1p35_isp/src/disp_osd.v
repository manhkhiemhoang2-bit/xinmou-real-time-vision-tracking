//==============================================================================
// 文件名   : disp_osd.v
// 模块名   : disp_osd
// 日期     : 2026-10-02
// 版本     : v1.0
// 描述     : 显示域（DDR 之后、HDMI 时序一侧）的 OSD 叠加层——文字行 + 自研 Logo。
//
//  【一、为什么要这个模块（结构对齐官方）】
//  官方链路是 `uivtc → hdmi_mixer(+OSD：Logo/字符/动态区，屏幕坐标) → hdmi_tx`
//  （官方例程学习笔记 第 7 节 + 🟡#5；官方设计参考文档笔记 结论 2）。
//  我们此前把 OSD 画在相机域（DDR 之前），于是文字跟着相机/显示拍频滑、
//  算法延迟一变版面就要重对齐，才引出 NORM / w_disp_tuser 那一串补丁。
//  本模块把"文字行 + 自研 Logo"搬回显示域：坐标就是屏幕坐标，逐像素扫描，
//  结构上不可能再与显示时序错位。安路 Logo 层（静态图，从未出问题）留在相机域，
//  烧在视频像素里；本层的文字/Logo 画在视频之上，版面区域互不重叠。
//
//  【二、延迟契约】
//  输入像素 I_vdata(t) → 输出 O_oedata 在 t+2 有效（恒 2 拍）：
//    t    ：r_x/r_y 与 I_vdata 同拍（计数见 §三）；字库/Logo ROM 的地址由组合
//           逻辑给出（"这一拍的像素该查哪个点"）。
//    t+1  ：ROM 的点阵位出来（my_charlib/my_logo_rom 都是"地址进→下一拍数据出"
//           的寄存输出）；同一拍 r_d1 里装的正是 t 拍那个像素 ⇒ 判据与像素在此
//           相遇。r_cx_d1/r_win*_d1 就是 t 拍坐标的延迟副本（⚠ 直接用本拍 cx 会
//           右移一个字内列——这正是相机域版 §12.3 踩过的坑，这里用打拍坐标避开）。
//    t+2  ：O_oedata 寄存输出。
//  集成时 hdmi_mixer 直通版内部本来就有 3 级流水，插入点选在这里保证逐拍等价。
//
//  【三、坐标产生】
//  I_user：帧首（本拍即 (0,0)，与 uivtc 的 O_vtc_user 同义）；I_last：行末有效拍。
//  r_x 在 de 内每拍 +1、I_user 归 0；r_y 在"de 且 I_last"的下一拍 +1、帧首归 0。
//  与官方 hdmi_mixer 的计数口径一致（官方在消隐期保持计数）。
//
//  【四、跨时钟域（本模块唯一的异步点）】
//  I_info_* 来自相机域，只在相机帧边界整批更新（60.8Hz），显示帧消隐 230 拍
//  （1650-1280 @75MHz≈3.07µs）内总线必然稳定。保护做法：**只在 !I_de（消隐期）
//  做"连续两拍采样相等才锁存"**；消隐期约 145 拍，两拍一致的窗口出现约 72 次，
//  亚稳总线被锁进去的概率再乘两次采样撞在翻转沿上的窗口（<1/60 帧）——
//  这就是多比特跨域的经典"稳定性过滤"方案，不需要 FIFO/握手。
//  显示值在整帧内恒定 ⇒ 屏幕上不存在"半新半旧"的字。
//
//  【五、版面与优先级】
//  · 文字行：48 格 × 16px 宽，(TEXT_X,TEXT_Y)=(16, 720-32)，白字（OSD_TEXT_COLOR）。
//    内容 = 相机域 osd_mixer §六 的 pos 表逐格照搬（名字/编号/FPS hex/LAT/X/Y/
//    NONE|TARGET|RED nn|GRN nn|BLU nn），一个字都不改，保证屏上信息口径连续。
//  · 自研 Logo：128×64，(LOGO_X,LOGO_Y)=(1280-144, 720-80)，颜色取自 my_logo_rom。
//  · 优先级：文字 > 自研 Logo > 视频。（安路面在视频里，区域不重叠，无需参与。）
//  · 十进制拆位用常数比较链（与相机域同法），无除法器无 DSP。
//
//  【六、编码规范】Verilog-2001；端口 I_/O_，寄存器 r_，线网 w_；
//  复位低有效异步；无 latch；一个 always 只干一件事。
//==============================================================================

module disp_osd #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    parameter TEXT_X     = 16,
    parameter TEXT_Y     = IMG_HEIGHT - 32,
    parameter N_CHAR_MAX = 48,
    parameter LOGO_X     = IMG_WIDTH  - 144,
    parameter LOGO_Y     = IMG_HEIGHT - 80,
    parameter [23:0] OSD_TEXT_COLOR = 24'hFFFFFF
)(
    input  wire         I_clk,          // = S_hdmi_pixel_clk (75MHz)
    input  wire         I_rst_n,
    // ---- 显示时序（来自 uivtc / 直通 mixer 的同源信号）----
    input  wire         I_de,
    input  wire         I_user,         // 帧首拍（本拍就是 (0,0)）
    input  wire         I_last,         // 行末有效拍
    // ---- 视频像素（DDR 读出，与 de 同拍）----
    input  wire [23:0]  I_vdata,
    output reg  [23:0]  O_oedata,
    // ---- 相机域信息总线（只在相机帧边界整批更新，见 §四）----
    input  wire [10:0]  I_info_mode,
    input  wire [31:0]  I_info_fps,
    input  wire [10:0]  I_info_lat,
    input  wire [10:0]  I_info_x,
    input  wire [10:0]  I_info_y,
    input  wire [31:0]  I_info_cnt,
    input  wire [1:0]   I_info_class,
    input  wire [7:0]   I_info_tid
);

//------------------------------------------------------------------------------
// 1. 坐标计数器（§三）
//------------------------------------------------------------------------------
reg [10:0] r_x;
reg [10:0] r_y;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)            r_x <= 11'd0;
    else if (!I_de)          r_x <= r_x;                 // 消隐期保持（官方口径）
    else if (I_user)         r_x <= 11'd0;               // 帧首拍就是 (0,0)
    else                     r_x <= r_x + 11'd1;
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)                r_y <= 11'd0;
    else if (I_user && I_de)     r_y <= 11'd0;           // 新帧开始
    else if (I_de && I_last)     r_y <= (r_y == IMG_HEIGHT-1) ? 11'd0 : (r_y + 11'd1);
end

//------------------------------------------------------------------------------
// 2. 信息总线跨域锁存（§四：消隐期两拍一致才更新）
//------------------------------------------------------------------------------
reg [10:0] r_mode_s,  r_mode_a;
reg [31:0] r_fps_s,   r_fps_a;
reg [10:0] r_lat_s,   r_lat_a;
reg [10:0] r_ix_s,    r_ix_a;
reg [10:0] r_iy_s,    r_iy_a;
reg [31:0] r_cnt_s,   r_cnt_a;
reg [1:0]  r_cls_s,   r_cls_a;
reg [7:0]  r_tid_s,   r_tid_a;

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_mode_s <= 11'd0;  r_mode_a <= 11'd0;
        r_fps_s  <= 32'd0;  r_fps_a  <= 32'd0;
        r_lat_s  <= 11'd0;  r_lat_a  <= 11'd0;
        r_ix_s   <= 11'd0;  r_ix_a   <= 11'd0;
        r_iy_s   <= 11'd0;  r_iy_a   <= 11'd0;
        r_cnt_s  <= 32'd0;  r_cnt_a  <= 32'd0;
        r_cls_s  <= 2'd0;   r_cls_a  <= 2'd0;
        r_tid_s  <= 8'd0;   r_tid_a  <= 8'd0;
    end else if (!I_de) begin                 // 只在消隐期采样
        r_mode_s <= I_info_mode;  if (I_info_mode == r_mode_s) r_mode_a <= I_info_mode;
        r_fps_s  <= I_info_fps;   if (I_info_fps  == r_fps_s)  r_fps_a  <= I_info_fps;
        r_lat_s  <= I_info_lat;   if (I_info_lat  == r_lat_s)  r_lat_a  <= I_info_lat;
        r_ix_s   <= I_info_x;     if (I_info_x    == r_ix_s)   r_ix_a   <= I_info_x;
        r_iy_s   <= I_info_y;     if (I_info_y    == r_iy_s)   r_iy_a   <= I_info_y;
        r_cnt_s  <= I_info_cnt;   if (I_info_cnt  == r_cnt_s)  r_cnt_a  <= I_info_cnt;
        r_cls_s  <= I_info_class; if (I_info_class== r_cls_s)  r_cls_a  <= I_info_class;
        r_tid_s  <= I_info_tid;   if (I_info_tid  == r_tid_s)  r_tid_a  <= I_info_tid;
    end
end

//------------------------------------------------------------------------------
// 3. 字符表（pos 0..43 逐格照搬相机域 osd_mixer §12 的 case）
//    拆位用常数比较链。fps 十六进制；lat 三位十进制；x/y 四位十进制；tid 两位。
//------------------------------------------------------------------------------
wire        w_hit   = (r_cnt_a != 32'd0);
wire        w_iscol = (r_mode_a == 11'd5);

// ---- 十六进制字符 ----
function [7:0] f_hex;
    input [3:0] n;
    f_hex = (n < 4'd10) ? (8'h30 + {4'h0, n}) : (8'h37 + {4'h0, n});
endfunction
wire [7:0] w_ch_fps_hi = f_hex(r_fps_a[7:4]);
wire [7:0] w_ch_fps_lo = f_hex(r_fps_a[3:0]);

// ---- 三位十进制（lat，>999 千位截断显示——与相机域口径一致）----
wire [10:0] w_lv = (r_lat_a >= 11'd1000) ? (r_lat_a - 11'd1000) : r_lat_a;
wire [3:0]  w_lat_h = (w_lv>=11'd900)?4'd9:(w_lv>=11'd800)?4'd8:(w_lv>=11'd700)?4'd7:
                      (w_lv>=11'd600)?4'd6:(w_lv>=11'd500)?4'd5:(w_lv>=11'd400)?4'd4:
                      (w_lv>=11'd300)?4'd3:(w_lv>=11'd200)?4'd2:(w_lv>=11'd100)?4'd1:4'd0;
wire [10:0] w_lat_h100 = (w_lat_h<<6)+(w_lat_h<<5)+(w_lat_h<<2);       // ×100
wire [10:0] w_lat_r = w_lv - w_lat_h100;
wire [3:0]  w_lat_t = (w_lat_r>=11'd90)?4'd9:(w_lat_r>=11'd80)?4'd8:(w_lat_r>=11'd70)?4'd7:
                      (w_lat_r>=11'd60)?4'd6:(w_lat_r>=11'd50)?4'd5:(w_lat_r>=11'd40)?4'd4:
                      (w_lat_r>=11'd30)?4'd3:(w_lat_r>=11'd20)?4'd2:(w_lat_r>=11'd10)?4'd1:4'd0;
wire [10:0] w_lat_o = w_lat_r - ((w_lat_t<<3)+(w_lat_t<<1));

// ---- 四位十进制（x）----
wire [10:0] w_xv  = r_ix_a;
wire [3:0]  w_x_th = (w_xv>=11'd1000)?4'd1:4'd0;
wire [10:0] w_x_r1 = w_xv - (w_x_th ? 11'd1000 : 11'd0);
wire [3:0]  w_x_h  = (w_x_r1>=11'd900)?4'd9:(w_x_r1>=11'd800)?4'd8:(w_x_r1>=11'd700)?4'd7:
                     (w_x_r1>=11'd600)?4'd6:(w_x_r1>=11'd500)?4'd5:(w_x_r1>=11'd400)?4'd4:
                     (w_x_r1>=11'd300)?4'd3:(w_x_r1>=11'd200)?4'd2:(w_x_r1>=11'd100)?4'd1:4'd0;
wire [10:0] w_x_h100 = (w_x_h<<6)+(w_x_h<<5)+(w_x_h<<2);
wire [10:0] w_x_r2 = w_x_r1 - w_x_h100;
wire [3:0]  w_x_t  = (w_x_r2>=11'd90)?4'd9:(w_x_r2>=11'd80)?4'd8:(w_x_r2>=11'd70)?4'd7:
                     (w_x_r2>=11'd60)?4'd6:(w_x_r2>=11'd50)?4'd5:(w_x_r2>=11'd40)?4'd4:
                     (w_x_r2>=11'd30)?4'd3:(w_x_r2>=11'd20)?4'd2:(w_x_r2>=11'd10)?4'd1:4'd0;
wire [10:0] w_x_o  = w_x_r2 - ((w_x_t<<3)+(w_x_t<<1));

// ---- 四位十进制（y）----
wire [10:0] w_yv  = r_iy_a;
wire [3:0]  w_y_th = (w_yv>=11'd1000)?4'd1:4'd0;
wire [10:0] w_y_r1 = w_yv - (w_y_th ? 11'd1000 : 11'd0);
wire [3:0]  w_y_h  = (w_y_r1>=11'd900)?4'd9:(w_y_r1>=11'd800)?4'd8:(w_y_r1>=11'd700)?4'd7:
                     (w_y_r1>=11'd600)?4'd6:(w_y_r1>=11'd500)?4'd5:(w_y_r1>=11'd400)?4'd4:
                     (w_y_r1>=11'd300)?4'd3:(w_y_r1>=11'd200)?4'd2:(w_y_r1>=11'd100)?4'd1:4'd0;
wire [10:0] w_y_h100 = (w_y_h<<6)+(w_y_h<<5)+(w_y_h<<2);
wire [10:0] w_y_r2 = w_y_r1 - w_y_h100;
wire [3:0]  w_y_t  = (w_y_r2>=11'd90)?4'd9:(w_y_r2>=11'd80)?4'd8:(w_y_r2>=11'd70)?4'd7:
                     (w_y_r2>=11'd60)?4'd6:(w_y_r2>=11'd50)?4'd5:(w_y_r2>=11'd40)?4'd4:
                     (w_y_r2>=11'd30)?4'd3:(w_y_r2>=11'd20)?4'd2:(w_y_r2>=11'd10)?4'd1:4'd0;
wire [10:0] w_y_o  = w_y_r2 - ((w_y_t<<3)+(w_y_t<<1));

// ---- tid 两位 ----
wire [7:0] w_tidv = r_tid_a;
wire [3:0] w_tid_t = (w_tidv>=8'd90)?4'd9:(w_tidv>=8'd80)?4'd8:(w_tidv>=8'd70)?4'd7:
                     (w_tidv>=8'd60)?4'd6:(w_tidv>=8'd50)?4'd5:(w_tidv>=8'd40)?4'd4:
                     (w_tidv>=8'd30)?4'd3:(w_tidv>=8'd20)?4'd2:(w_tidv>=8'd10)?4'd1:4'd0;
wire [7:0] w_tid_o = w_tidv - ((w_tid_t<<3)+(w_tid_t<<1));

// ---- 算法名（相机域 §12.1 的表逐字照抄）----
reg [39:0] w_mode_name;
always @(*) begin
    case (r_mode_a)
        11'd0:   w_mode_name = {8'h52, 8'h41, 8'h57, 8'h20, 8'h20};   // "RAW  "
        11'd1:   w_mode_name = {8'h47, 8'h52, 8'h41, 8'h59, 8'h20};   // "GRAY "
        11'd2:   w_mode_name = {8'h42, 8'h49, 8'h4E, 8'h20, 8'h20};   // "BIN  "
        11'd3:   w_mode_name = {8'h45, 8'h44, 8'h47, 8'h45, 8'h20};   // "EDGE "
        11'd4:   w_mode_name = {8'h42, 8'h4C, 8'h55, 8'h52, 8'h20};   // "BLUR "
        11'd5:   w_mode_name = {8'h43, 8'h4F, 8'h4C, 8'h4F, 8'h52};   // "COLOR"
        11'd6:   w_mode_name = {8'h4D, 8'h4F, 8'h56, 8'h45, 8'h20};   // "MOVE "
        11'd7:   w_mode_name = {8'h46, 8'h49, 8'h4C, 8'h4C, 8'h20};   // "FILL "
        default: w_mode_name = {8'h20, 8'h20, 8'h20, 8'h20, 8'h20};
    endcase
end

// ---- 检测结果 6 字（相机域 §12.1a 逐字照抄）----
reg [47:0] w_det_chars;
always @(*) begin
    if (!w_hit)
        w_det_chars = {8'h4E, 8'h4F, 8'h4E, 8'h45, 8'h20, 8'h20};                    // "NONE  "
    else if (w_iscol) begin
        case (r_cls_a)
            2'd0:    w_det_chars = {8'h52, 8'h45, 8'h44, 8'h20, 8'h30+{4'h0,w_tid_t}, 8'h30+{4'h0,w_tid_o[3:0]}}; // "RED nn"
            2'd1:    w_det_chars = {8'h47, 8'h52, 8'h4E, 8'h20, 8'h30+{4'h0,w_tid_t}, 8'h30+{4'h0,w_tid_o[3:0]}}; // "GRN nn"
            default: w_det_chars = {8'h42, 8'h4C, 8'h55, 8'h20, 8'h30+{4'h0,w_tid_t}, 8'h30+{4'h0,w_tid_o[3:0]}}; // "BLU nn"
        endcase
    end
    else
        w_det_chars = {8'h54, 8'h41, 8'h52, 8'h47, 8'h45, 8'h54};                    // "TARGET"
end

//------------------------------------------------------------------------------
// 4. 文字面命中（§二相位：t 拍算地址，t+1 拍用延迟副本判位）
//------------------------------------------------------------------------------
localparam TXT_SPAN = N_CHAR_MAX * 16;

wire [11:0] w_dx = (r_x >= TEXT_X) ? (r_x - TEXT_X) : 12'hFFF;
wire [11:0] w_dy = (r_y >= TEXT_Y) ? (r_y - TEXT_Y) : 12'hFFF;
wire        w_in_txt = (r_x >= TEXT_X) && (r_x < (TEXT_X + TXT_SPAN)) &&
                       (r_y >= TEXT_Y) && (r_y < (TEXT_Y + 16));
wire [5:0]  w_ci  = w_dx[7:4];                       // /16
wire [3:0]  w_cx  = w_dx[3:0];                       // %16
wire [3:0]  w_row = w_dy[3:0];

reg  [5:0]  r_ci_d1, r_cx_d1, r_row_d1;
reg         r_in_d1;
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_ci_d1 <= 6'd0; r_cx_d1 <= 4'd0; r_row_d1 <= 4'd0; r_in_d1 <= 1'b0;
    end else begin
        r_ci_d1 <= w_ci; r_cx_d1 <= w_cx; r_row_d1 <= w_row; r_in_d1 <= w_in_txt;
    end
end

reg  [7:0] w_char_code;
always @(*) begin
    case (w_ci)
        6'd0:    w_char_code = w_mode_name[39:32];
        6'd1:    w_char_code = w_mode_name[31:24];
        6'd2:    w_char_code = w_mode_name[23:16];
        6'd3:    w_char_code = w_mode_name[15:8];
        6'd4:    w_char_code = w_mode_name[7:0];
        6'd5:    w_char_code = 8'h20;
        6'd6:    w_char_code = 8'h4D;                                  // 'M'
        6'd7:    w_char_code = 8'h30 + {4'h0, r_mode_a[2:0]};          // 档位数字
        6'd8:    w_char_code = 8'h20;
        6'd9:    w_char_code = 8'h46;                                  // 'F'
        6'd10:   w_char_code = 8'h50;                                  // 'P'
        6'd11:   w_char_code = 8'h53;                                  // 'S'
        6'd12:   w_char_code = 8'h3A;                                  // ':'
        6'd13:   w_char_code = w_ch_fps_hi;
        6'd14:   w_char_code = w_ch_fps_lo;
        6'd15:   w_char_code = 8'h20;
        6'd16:   w_char_code = 8'h4C;                                  // 'L'
        6'd17:   w_char_code = 8'h41;                                  // 'A'
        6'd18:   w_char_code = 8'h54;                                  // 'T'
        6'd19:   w_char_code = 8'h3A;                                  // ':'
        6'd20:   w_char_code = 8'h30 + {4'h0, w_lat_h};
        6'd21:   w_char_code = 8'h30 + {4'h0, w_lat_t};
        6'd22:   w_char_code = 8'h30 + {4'h0, w_lat_o[3:0]};
        6'd23:   w_char_code = 8'h20;
        6'd24:   w_char_code = 8'h58;                                  // 'X'
        6'd25:   w_char_code = 8'h3A;
        6'd26:   w_char_code = 8'h30 + {4'h0, w_x_th};
        6'd27:   w_char_code = 8'h30 + {4'h0, w_x_h};
        6'd28:   w_char_code = 8'h30 + {4'h0, w_x_t};
        6'd29:   w_char_code = 8'h30 + {4'h0, w_x_o[3:0]};
        6'd30:   w_char_code = 8'h20;
        6'd31:   w_char_code = 8'h59;                                  // 'Y'
        6'd32:   w_char_code = 8'h3A;
        6'd33:   w_char_code = 8'h30 + {4'h0, w_y_th};
        6'd34:   w_char_code = 8'h30 + {4'h0, w_y_h};
        6'd35:   w_char_code = 8'h30 + {4'h0, w_y_t};
        6'd36:   w_char_code = 8'h30 + {4'h0, w_y_o[3:0]};
        6'd37:   w_char_code = 8'h20;
        6'd38:   w_char_code = w_det_chars[47:40];
        6'd39:   w_char_code = w_det_chars[39:32];
        6'd40:   w_char_code = w_det_chars[31:24];
        6'd41:   w_char_code = w_det_chars[23:16];
        6'd42:   w_char_code = w_det_chars[15:8];
        6'd43:   w_char_code = w_det_chars[7:0];
        default: w_char_code = 8'h3F;                                  // '?'
    endcase
end

// ---- ASCII → 字库索引（osd_mixer §12.2 同款映射，逐条照抄）----
//   数字 0x30..0x39 → 0..9；大写字母 → -0x37（A→10）；空格=39 ':'=36 '.'=37 '/'=38；
//   未定义 → 39（空格兜底）。⚠ 不能把 ASCII 直接喂 my_charlib——它的 I_index 是索引。
reg [7:0] w_rom_index;
always @(*) begin
    if      ((w_char_code >= 8'h30) && (w_char_code <= 8'h39)) w_rom_index = w_char_code - 8'h30;
    else if ((w_char_code >= 8'h41) && (w_char_code <= 8'h5A)) w_rom_index = w_char_code - 8'h37;
    else if (w_char_code == 8'h20)                             w_rom_index = 8'd39;
    else if (w_char_code == 8'h3A)                             w_rom_index = 8'd36;
    else if (w_char_code == 8'h2E)                             w_rom_index = 8'd37;
    else if (w_char_code == 8'h2F)                             w_rom_index = 8'd38;
    else                                                       w_rom_index = 8'd39;
end

wire [15:0] w_bits;
my_charlib u_lib (
    .I_index (w_rom_index),
    .I_row   (w_row),
    .O_bits  (w_bits)
);

wire w_txt_hit = r_in_d1 && w_bits[15 - r_cx_d1];

//------------------------------------------------------------------------------
// 5. 自研 Logo 面（128x64，逐像素接口）
//------------------------------------------------------------------------------
wire        w_in_logo = (r_x >= LOGO_X) && (r_x < (LOGO_X + 128)) &&
                        (r_y >= LOGO_Y) && (r_y < (LOGO_Y + 64));
wire [10:0] w_lx = w_in_logo ? (r_x - LOGO_X) : 11'd0;
wire [10:0] w_ly = w_in_logo ? (r_y - LOGO_Y) : 11'd0;
wire        w_logo_hit;
wire [23:0] w_logo_color;
my_logo_rom u_logo (
    .I_x    (w_lx),
    .I_y    (w_ly),
    .O_hit  (w_logo_hit),
    .O_color(w_logo_color)
);
reg r_logo_in_d1;
always @(posedge I_clk or negedge I_rst_n)
    if (!I_rst_n) r_logo_in_d1 <= 1'b0;
    else          r_logo_in_d1 <= w_in_logo;
wire w_logo_hit_al = r_logo_in_d1 && w_logo_hit;

//------------------------------------------------------------------------------
// 6. 输出级（§二：数据与判据同拍相遇，恒 2 拍延迟）
//------------------------------------------------------------------------------
reg [23:0] r_d1;
always @(posedge I_clk or negedge I_rst_n)
    if (!I_rst_n) r_d1 <= 24'd0;
    else          r_d1 <= I_vdata;

always @(posedge I_clk or negedge I_rst_n)
    if (!I_rst_n) O_oedata <= 24'd0;
    else begin
        if (w_txt_hit)       O_oedata <= OSD_TEXT_COLOR;
        else if (w_logo_hit_al) O_oedata <= w_logo_color;
        else                 O_oedata <= r_d1;
    end

//------------------------------------------------------------------------------
// 7. 上电初值（与复位分支逐项一致）
//------------------------------------------------------------------------------
initial begin
    r_x = 11'd0; r_y = 11'd0;
    r_mode_s = 11'd0; r_mode_a = 11'd0;
    r_fps_s  = 32'd0; r_fps_a  = 32'd0;
    r_lat_s  = 11'd0; r_lat_a  = 11'd0;
    r_ix_s   = 11'd0; r_ix_a   = 11'd0;
    r_iy_s   = 11'd0; r_iy_a   = 11'd0;
    r_cnt_s  = 32'd0; r_cnt_a  = 32'd0;
    r_cls_s  = 2'd0;  r_cls_a  = 2'd0;
    r_tid_s  = 8'd0;  r_tid_a  = 8'd0;
    r_ci_d1  = 6'd0;  r_cx_d1  = 4'd0; r_row_d1 = 4'd0; r_in_d1 = 1'b0;
    r_logo_in_d1 = 1'b0;
    r_d1     = 24'd0;
    O_oedata = 24'd0;
end

endmodule
