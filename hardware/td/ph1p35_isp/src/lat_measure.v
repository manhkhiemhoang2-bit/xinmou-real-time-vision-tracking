//==============================================================================
// lat_measure.v —— 帧率(FPS) / 流水线延迟(LAT) 真测
//------------------------------------------------------------------------------
// 【一、为什么要有这个模块】
//   osd_mixer 的 I_info_fps / I_info_lat 原来是 isp_top_alg.v 里写死的常数
//   （32'd60 / 11'd7），屏幕上那两个数字是"假"的。本模块用两条真实存在的
//   tuser 事件把它们测出来：
//     · 输入侧 tuser —— isp_top 输入侧（MIPI 侧）那条 96bit 流的帧首
//     · 输出侧 tuser —— isp_top 输出侧（送 DDR/HDMI）那条 96bit 流的帧首
//   本模块工作在 MIPI_RX_BYTE_CLK = 59.995MHz（周期 16.668ns）域。
//
// 【二、三个输出的口径（"延迟口径"在这里定义）】
//   1. O_frame_cnt —— 每见到一个 I_in_tuser（一个输入帧首）加 1；32 位不回绕
//      （720p60 下 2^32 帧约 2.3 年）。
//      ※ 判帧是**电平口径**：tuser 为高的每一个采样沿都算一个帧首（不做边沿检测）。
//        前提是上游 tuser 是**单拍脉冲** —— 本项目就是这样用的：rgb_row_delay_96.v
//        第 196 行 `if (I_tuser) r_x_grp <= 1`（多拍会把拍号钉死在行首），
//        alg_top.v 也用同一口径。若将来上游 tuser 宽于 1 拍，这里必须补一级边沿检测。
//      ※ 判帧**不按 I_tvalid 门控**。依据：本项目 alg_top.v 第 164~182 行明确写了
//        tuser/tvalid 是同装一个控制字、不按 tvalid 门控的（停顿/气泡时按 tvalid
//        门控会漏帧）。I_in_tvalid / I_out_tvalid 端口为兼容建议接口保留，不参与判帧。
//   2. O_fps_bcd —— 帧率，**两位 BCD**（十位在高半字节）：60 → 8'h60、5 → 8'h05，
//      正好是 osd_mixer 的 I_info_fps[7:0] 需要的格式（它内部按两个半字节 + '0'
//      查字库，喂二进制会在屏上出现乱码）。
//      测量口径：记 C = 相邻两个输入帧首之间相隔的 I_clk 拍数（把帧首那一拍算作
//      间隔的最后一拍，即相邻两次 tuser 采样沿之间的时钟数，最小 1），
//      则 FPS = round(CLK_HZ / C) —— **四舍五入到整数**：被除数取 CLK_HZ + C/2
//      再做整数除法（C 为奇数时 floor(C/2) 与"半整数进位"完全等价）。
//      为什么不用截断：真实 720p60 传感可能是 59.94fps（C ≈ 1,000,917 @59.995MHz），
//      截断会算成 59.94 → 屏上显示 59，"60fps 系统显示 59"会被当成 bug；
//      四舍五入对 60.000fps 与 59.94fps 两种源都显示 60。
//      ※ 位宽前提：CLK_HZ + C/2 按 32 位运算，**仅在 CLK_HZ < 2^31 时成立**
//        （本参数是常量 60e6，C/2 < 2^23，和 < 2^27，不会回绕）。
//      · FPS 只按**整数**显示（没有小数位），只有 1..99 有效：算出 0 或 >=100 时
//        输出 8'h00（安全确定值，绝不是 X）。
//      · 还没测到两个帧首（只来了一帧）时输出 8'h00。
//      · C 超过 PERIOD_MAX（默认 2^24-1，@60MHz 约 0.28s，即 FPS < 3.6）时判无效，
//        同样输出 8'h00 —— 宁可显示 0，也不显示由饱和计数算出来的假数字。
//   3. O_lat_clk —— 流水线延迟（拍），二进制，直接喂 osd_mixer 的 I_info_lat
//      （osd_mixer 内部自己做十进制拆位，不要在这里转 BCD）。
//      口径：**同一帧**的输入帧首采样沿 → 该帧对应的输出帧首采样沿之间的 I_clk
//      拍数。设输入 tuser 在 A 拍被采到、输出 tuser 在 B 拍被采到，则
//      O_lat_clk = B - A（真实通路是 5+2 拍量级，最小 1；0 表示"还没测到"）。
//      每来一个新输入帧首就重新起表，所以显示的永远是最近一帧的实测值，
//      而不是某个写死的常数。
//      计数饱和在 2047：只有输出侧长时间不来 tuser 才可能撞上（通路断了），
//      正常流水线个位数拍，不可能到。
//
// 【三、为什么这样实现（关键取舍）】
//   · 除法**不能**用 "/" 交给综合：60MHz 域现在 slack 只有 3.342ns，组合除法器
//     要么被塞进 DSP、要么把关键路径拉爆。本模块用**一拍一位的恢复余数法
//     （restoring divider）**：一帧只做一次除法，一帧有约 100 万拍预算，慢一点
//     完全无所谓。32 位被除数 → 32 次迭代 + 握手，start 到 done 共 33 拍。
//   · BCD 拆分（帧率/10 与 帧率%10）**复用同一台除法器**再算一次，而不是写
//     10 级常数比较链：省逻辑、组合路径更短，代价只是再花 33 拍。
//   · 模块内没有任何逻辑在像素通路上（三个输出只喂 OSD 的字库查表），但最深的
//     组合路径仍控制在"25 位比较 + 25 位减法"这一级，不会污染 60MHz 域时序。
//   · 除法器一次测量最多被触发两次，其余时间整机静止；帧首请求在除法器忙时会被
//     丢弃（不排队）—— 正常帧周期 >> 70 拍，不会发生。
//
// 【四、编码纪律】
//   · Verilog-2001，单文件单模块，UTF-8 无 BOM；I_/O_/r_/w_ 前缀。
//   · 低有效异步复位；无 latch；不含任何仿真专用的过程结构（子程序、并行块、
//     阻塞等待、强制赋值、延时控制 —— 一个都没有，纯可综合子集）。
//   · 一个 always 只干一件事（帧计数 / 周期计数 / 除法引擎 / FPS 时序 / 延迟测量）。
//   · initial 上电初值与复位分支逐一相同。
//==============================================================================
`timescale 1ns / 1ps

module lat_measure #(
    parameter CLK_HZ     = 60_000_000,   // I_clk 标称频率(Hz)，只参与 FPS 计算
    parameter PERIOD_MAX = 24'hFFFFFF    // 帧周期计数上限，超过即判本次测量无效
                                         // （TB 里会调小，以便用小周期覆盖饱和边界）
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_in_tvalid,      // 输入流 tvalid（本版不参与判帧，见 §二.1）
    input  wire        I_in_tuser,       // 输入帧首
    input  wire        I_out_tvalid,     // 输出流 tvalid（同上，不参与判帧）
    input  wire        I_out_tuser,      // 输出帧首
    output reg  [31:0] O_frame_cnt,      // 帧计数
    output reg  [7:0]  O_fps_bcd,        // 帧率，两位 BCD（十位在高半字节）
    output reg  [10:0] O_lat_clk         // 流水线延迟（拍）
);

//------------------------------------------------------------------------------
// 常量
//------------------------------------------------------------------------------
localparam [1:0]  S_IDLE = 2'd0;      // 空闲：等下一个输入帧首
localparam [1:0]  S_FPS  = 2'd1;      // 第一次除法：CLK_HZ / C → 帧率
localparam [1:0]  S_TENS = 2'd2;      // 第二次除法：帧率 / 10 → 十位、个位
localparam [1:0]  S_PUB  = 2'd3;      // 发布 BCD
localparam [10:0] LAT_MAX = 11'h7FF;  // 延迟计数饱和值

//------------------------------------------------------------------------------
// 内部寄存器
//------------------------------------------------------------------------------
// 帧计数 / 周期计数
reg  [24:0] r_per_cnt;                // 距上一个输入帧首的拍数（25 位：饱和时不回绕）
reg  [23:0] r_per_cap;                // 帧首处锁存的"本帧周期"
reg         r_per_over;               // 该周期是否超量程
reg         r_per_new;                // 测量请求脉冲，宽 1 拍
reg         r_frm_seen;               // 已经见过至少一个输入帧首

// 除法引擎（一拍一位恢复余数法）
reg         r_div_busy;               // 引擎忙
reg  [4:0]  r_div_idx;                // 当前处理的被除数位号，31 → 0
reg  [24:0] r_div_rem;                // 部分余数（25 位 = 除数 24 位 + 1）
reg  [31:0] r_div_quot;               // 商
reg  [31:0] r_div_dvd;                // 本次被除数
reg  [24:0] r_div_dvs;                // 本次除数（25 位，高位补 0）
reg         r_div_done;               // 结果有效脉冲，宽 1 拍

// FPS 测量时序
reg  [1:0]  r_meas_state;             // 见 S_* 常量
reg  [31:0] r_dvd_in;                 // 交给引擎的被除数
reg  [23:0] r_dvs_in;                 // 交给引擎的除数
reg         r_div_start;              // 启动引擎脉冲，宽 1 拍
reg  [7:0]  r_bcd_pre;                // 待发布的 BCD

// 延迟测量
reg  [10:0] r_lat_cnt;                // 帧内延迟计数
reg         r_lat_arm;                // 正在测本帧延迟

//------------------------------------------------------------------------------
// 组合辅助（深度：25 位比较 / 25 位减法，均不在像素通路上）
//------------------------------------------------------------------------------
wire        w_in_frame  = I_in_tuser;                 // 判帧口径见 §二.1
wire [24:0] w_per_lim   = {1'b0, PERIOD_MAX};
wire [24:0] w_per_now   = r_per_cnt + 25'd1;          // 本帧周期（拍）
wire        w_per_over  = (w_per_now > w_per_lim);    // 超量程 → 本次测量无效
wire [24:0] w_per_next  = (r_per_cnt >= w_per_lim) ? r_per_cnt : w_per_now;
wire [24:0] w_rem_shift = {r_div_rem[23:0], r_div_dvd[r_div_idx]};

//------------------------------------------------------------------------------
// 1) 帧计数：一个输入帧首 +1。只干这一件事，与除法/延迟互不干扰。
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)          O_frame_cnt <= 32'd0;
    else if (w_in_frame)   O_frame_cnt <= O_frame_cnt + 32'd1;
end

//------------------------------------------------------------------------------
// 2) 帧周期计数：数"两个输入帧首之间有多少拍"，帧首处锁存并给出测量请求。
//    · 第一个帧首只给计数器起表、**不发测量请求** —— C 的定义需要两个帧首，
//      若拿"复位到第一个帧首"当周期，会算出一个假帧率（TB 里抓到过这个 59）。
//    · 计数器到 PERIOD_MAX 就停住不再加（25 位寄存器不会回绕），
//      于是 w_per_now 恒等于"至少 PERIOD_MAX+1 拍"，超量程可被无歧义地判出来。
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_per_cnt  <= 25'd0;
        r_per_cap  <= 24'd0;
        r_per_over <= 1'b0;
        r_per_new  <= 1'b0;
        r_frm_seen <= 1'b0;
    end else if (w_in_frame) begin
        r_per_cap  <= w_per_over ? PERIOD_MAX : w_per_now[23:0];
        r_per_over <= w_per_over;
        r_per_new  <= r_frm_seen;     // 第二个帧首起才发测量请求
        r_per_cnt  <= 25'd0;
        r_frm_seen <= 1'b1;
    end else begin
        r_per_new  <= 1'b0;
        r_per_cnt  <= w_per_next;
    end
end

//------------------------------------------------------------------------------
// 3) 除法引擎：一拍处理一位的恢复余数法（restoring division）。
//    每次操作的时序：r_div_start 拉高 1 拍 → 下一拍装载被除数/除数、busy 拉高
//    → 连做 32 拍（位 31 → 位 0）→ r_div_done 拉高 1 拍，商/余数有效。
//    即 start 到 done 共 33 拍。没有 DSP、没有单周期组合除法。
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_div_busy <= 1'b0;
        r_div_idx  <= 5'd0;
        r_div_rem  <= 25'd0;
        r_div_quot <= 32'd0;
        r_div_dvd  <= 32'd0;
        r_div_dvs  <= 25'd0;
        r_div_done <= 1'b0;
    end else begin
        r_div_done <= 1'b0;                       // 默认：done 只宽 1 拍
        if (r_div_busy) begin
            // 余数左移一位、补入当前被除数位，够减就减并给商 1
            if (w_rem_shift >= r_div_dvs) begin
                r_div_rem  <= w_rem_shift - r_div_dvs;
                r_div_quot <= {r_div_quot[30:0], 1'b1};
            end else begin
                r_div_rem  <= w_rem_shift;
                r_div_quot <= {r_div_quot[30:0], 1'b0};
            end
            if (r_div_idx == 5'd0) begin          // 最低位处理完 → 结束
                r_div_busy <= 1'b0;
                r_div_done <= 1'b1;
            end else begin
                r_div_idx  <= r_div_idx - 5'd1;
            end
        end else if (r_div_start) begin
            r_div_busy <= 1'b1;
            r_div_idx  <= 5'd31;
            r_div_rem  <= 25'd0;
            r_div_quot <= 32'd0;
            r_div_dvd  <= r_dvd_in;
            r_div_dvs  <= {1'b0, r_dvs_in};
        end
    end
end

//------------------------------------------------------------------------------
// 4) FPS 测量时序：一个输入帧首触发一次测量（一帧只做一次除法）。
//    S_IDLE → S_FPS(算 CLK_HZ/C) → S_TENS(算 帧率/10) → S_PUB(发布 BCD)
//    帧率不在 1..99 时直接发布 0，不做第二次除法。
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_meas_state <= S_IDLE;
        r_dvd_in     <= 32'd0;
        r_dvs_in     <= 24'd0;
        r_div_start  <= 1'b0;
        r_bcd_pre    <= 8'd0;
        O_fps_bcd    <= 8'h00;
    end else begin
        r_div_start <= 1'b0;                      // 默认：start 只宽 1 拍
        case (r_meas_state)
            S_IDLE: begin
                if (r_per_new) begin
                    if (r_per_over) begin
                        // 周期超量程：不测，直接给安全值 0
                        r_bcd_pre    <= 8'h00;
                        r_meas_state <= S_PUB;
                    end else begin
                        // 被除数 = CLK_HZ + C/2 → 整除结果即"四舍五入到整数"的帧率。
                        // 位宽：32 位加法，仅在 CLK_HZ < 2^31 时成立（见文件头 §二.2）。
                        r_dvd_in     <= CLK_HZ + {7'd0, r_per_cap[23:1]};
                        r_dvs_in     <= r_per_cap;   // 除数 = 实测帧周期
                        r_div_start  <= 1'b1;
                        r_meas_state <= S_FPS;
                    end
                end
            end
            S_FPS: begin
                if (r_div_done) begin
                    if ((r_div_quot >= 32'd1) && (r_div_quot <= 32'd99)) begin
                        // 有效帧率：同一台除法器再算一次 帧率/10 得到十位与个位
                        r_dvd_in     <= r_div_quot;
                        r_dvs_in     <= 24'd10;
                        r_div_start  <= 1'b1;
                        r_meas_state <= S_TENS;
                    end else begin
                        r_bcd_pre    <= 8'h00;       // 0 或 >=100 → 安全值
                        r_meas_state <= S_PUB;
                    end
                end
            end
            S_TENS: begin
                if (r_div_done) begin
                    r_bcd_pre    <= {r_div_quot[3:0], r_div_rem[3:0]};
                    r_meas_state <= S_PUB;
                end
            end
            S_PUB: begin
                O_fps_bcd    <= r_bcd_pre;           // 唯一写 O_fps_bcd 的地方
                r_meas_state <= S_IDLE;
            end
            default: begin
                r_meas_state <= S_IDLE;
            end
        endcase
    end
end

//------------------------------------------------------------------------------
// 5) 流水线延迟：输入帧首起表，该帧对应的输出帧首落地时锁存 B-A。
//    r_lat_cnt 在帧首拍为 0，此后每拍 +1；输出帧首到来那拍为 k-1，
//    所以锁存 r_lat_cnt + 1 = k（= 两次采样沿之间的拍数，口径见 §二.3）。
//------------------------------------------------------------------------------
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_lat_cnt <= 11'd0;
        r_lat_arm <= 1'b0;
        O_lat_clk <= 11'd0;
    end else if (w_in_frame) begin
        r_lat_cnt <= 11'd0;                       // 新帧首：重新起表
        r_lat_arm <= 1'b1;
    end else if (r_lat_arm) begin
        if (I_out_tuser) begin
            O_lat_clk <= (r_lat_cnt == LAT_MAX) ? LAT_MAX : (r_lat_cnt + 11'd1);
            r_lat_arm <= 1'b0;                    // 本帧测完，等下一个帧首
        end else if (r_lat_cnt != LAT_MAX) begin
            r_lat_cnt <= r_lat_cnt + 11'd1;
        end
    end
end

//------------------------------------------------------------------------------
// 上电初值：与上面每个复位分支逐一相同（TD/仿真上电即可确定，不依赖复位沿）
//------------------------------------------------------------------------------
initial begin
    O_frame_cnt  = 32'd0;
    O_fps_bcd    = 8'h00;
    O_lat_clk    = 11'd0;
    r_per_cnt    = 25'd0;
    r_per_cap    = 24'd0;
    r_per_over   = 1'b0;
    r_per_new    = 1'b0;
    r_frm_seen   = 1'b0;
    r_div_busy   = 1'b0;
    r_div_idx    = 5'd0;
    r_div_rem    = 25'd0;
    r_div_quot   = 32'd0;
    r_div_dvd    = 32'd0;
    r_div_dvs    = 25'd0;
    r_div_done   = 1'b0;
    r_meas_state = S_IDLE;
    r_dvd_in     = 32'd0;
    r_dvs_in     = 24'd0;
    r_div_start  = 1'b0;
    r_bcd_pre    = 8'h00;
    r_lat_cnt    = 11'd0;
    r_lat_arm    = 1'b0;
end

endmodule
