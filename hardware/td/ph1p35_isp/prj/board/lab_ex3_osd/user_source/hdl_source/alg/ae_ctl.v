//==============================================================================
// 文件名   : ae_ctl.v
// 模块名   : ae_ctl
// 日期     : 2026-10-03
// 版本     : v1.1
// 描述     : 后端慢速自动曝光/增益（AEC/AGC）控制器——SC500CS 手册 §2.2.1 点名的
//            "后端平台实现"补课件（传感器无内置环路、官方例程也没做，只给了
//            ae_set 手动按钮 + uics500regAE/SC500GainTbl 的写入骨架）。
//
//  【一、数据通路】
//   输入 = ISP 链上的 96bit RGB 流（4 像素/拍，pix0=[95:72]，与本仓其它算法模块同口径）。
//   Y 近似 = (R + 2G + B) / 4（权重 .25/.5/.25 的快速近似；AE 只需要"整体明暗"的
//   单调量。实现上累加"未除 4 的总和"，与 4× 阈值带比较，除法零成本）。
//   饱和判据 = max(R,G,B) >= 250（近顶通道 = 高光危险区）。
//   每帧在 I_tuser 界锁存上一帧 (sum4, sat_n)，控制律消费锁存值。
//
//  【二、控制律（手册 §2.2.1 原文策略，逐字对照）】
//   达标带：SUM_LO*4 <= sum4 <= SUM_HI*4（默认对应均值 100..180）；
//   高光一票否决：sat_n > SAT_LIM（默认 3%）直接按"过亮"处理。
//     过暗 → 先加曝光（×9/8），曝光顶到 EXP_MAX 后再 +16 档增益；
//     过亮 → 先 -16 档增益，增益到 AG_MIN 后再减曝光（×7/8）——手册 L1291"过亮时
//     优先关闭增益，所有增益关闭图像仍旧过亮，则降低曝光时间"逐字落实。
//   慢速纪律：SETTLE 帧只测不动（初值生效要 N+2 帧，8 帧裕量远大于 2）；
//   之后每 PERIOD 帧最多一次；带内什么都不做（带宽=死区，无额外迟滞）。
//   ⇒ 与 M6/NORM 共存：改动 ≤0.5 次/秒、步长 ≤12.5%，M6 归一化的 IIR 实测能吃
//   30% 一步跳只留两帧尾巴（tb_m6_norm），本环路温和得多。
//
//  【三、写通路握手（对齐官方骨架的两个已知脾气）】
//   语义 = 官方 ae_set 的 O_ae_req/O_ae/O_ag（ag 是 SC500GainTbl 索引+16，
//   96 = 表 80 = 0x0F30 = 6.000x；143 = 0x1F3F = 15.750x 模拟顶）。
//   uicfgcs500_720p 状态机的两条脾气决定了握手形状：
//     ① 它在空闲态**每拍**都重看 I_ae_req —— req 保持高会让写表【反复重启】；
//     ② 但它只在回到 state0 的那拍采样——req 单拍脉冲又可能被写表间隙错过。
//   解法=三段显式握手：置 req → 等看到 done 落下（=它接住了）→ 撤 req → 等 done
//   回升（=5 寄存器写完）。任何时刻 req 都不在 done=0 期间保持。done 来自 24MHz
//   域，电平量 2FF 同步进本域。
//
//  【四、边界与不做的东西（如实）】
//   · 统计覆盖整帧（无区域权重）：中央重点/高光压缩留 v2。
//   · 不碰数字增益（AG_MAX=143 = 模拟段顶，手册"数字最后用"，宁可不进数字段）。
//   · 曝光写入落在帧任意时刻——传感器对曝光寄存器 N+2 帧生效（手册 L1322），
//     官方 ae_set 同样任意时刻发 req，无额外风险。
//   · I2C 若被上层其它逻辑并发使用需仲裁——当前 uicfgcs500 只有本 req 一个触发源。
//
//  【五、编码规范】Verilog-2001；无 latch；复位低有效异步；r_/w_ 前缀；
//   表达式折行处不放行内注释（本仓血泪规）。
//==============================================================================

module ae_ctl #(
    parameter [31:0] N_PIX     = 32'd921600,      // 一帧统计像素数（1280*720）
    parameter [31:0] MEAN_LO   = 32'd90,         // 达标均值下限
    parameter [31:0] MEAN_HI   = 32'd200,         // 达标均值上限
    parameter [23:0] SAT_PCT   = 24'd15,           // 饱和占比红线（百分数）
    parameter [15:0] EXP_INIT  = 16'd4200,        // = 上电 init 表值，起点一致
    parameter [15:0] EXP_MIN   = 16'd200,
    parameter [15:0] EXP_MAX   = 16'd5200,        // 满限 5382 留 180 保护带
    parameter [15:0] AG_INIT   = 16'd96,          // 96 → 表索引 80 = 0x0F30 = 6.000x
    parameter [15:0] AG_MIN    = 16'd16,          // 表索引 0 = 1.000x
    parameter [15:0] AG_MAX    = 16'd112,         // ★五修：112=表索引96=0x1F20=8.000x 封顶（12x/15.75x 实测过亮+噪点重）
    parameter [7:0]  PERIOD    = 8'd16,            // 每 32 帧最多一次（~0.5 次/s）
    parameter [7:0]  SETTLE    = 8'd8              // 前 8 帧只测不动
)(
    input  wire         I_clk,                     // = axi4s_video_aclk（相机域）
    input  wire         I_rst_n,
    // ---- ISP 流（与算法链同一份像素）----
    input  wire [95:0]  I_tdata,
    input  wire         I_tvalid,
    input  wire         I_tuser,                   // 帧首拍
    // ---- 写通路握手（uicfgcs500_720p 侧）----
    input  wire         I_ae_cfg_done,             // 24MHz 域电平
    input  wire         I_ae_en,                   // ★0=关闭环（保持当前曝光/不再发写请求）；1=开

    output reg          O_ae_req,
    output reg  [15:0]  O_ae,
    output reg  [15:0]  O_ag
);

//------------------------------------------------------------------------------
// 0. 阈值常量（均值带 → 总和×4 带；饱和占比 → 计数）
//------------------------------------------------------------------------------
localparam [47:0] SUM_LO_X4 = ({2'b00, N_PIX} * MEAN_LO) << 2;
localparam [47:0] SUM_HI_X4 = ({2'b00, N_PIX} * MEAN_HI) << 2;
localparam [47:0] SAT_LIM48 = (({1'b0, N_PIX} * SAT_PCT) / 32'd100);
localparam [47:0] SAT_LIM   = SAT_LIM48;

//------------------------------------------------------------------------------
// 1. 逐拍统计（4 像素并行）
//------------------------------------------------------------------------------
wire [7:0] w_r0 = I_tdata[95:88], w_g0 = I_tdata[87:80], w_b0 = I_tdata[79:72];
wire [7:0] w_r1 = I_tdata[71:64], w_g1 = I_tdata[63:56], w_b1 = I_tdata[55:48];
wire [7:0] w_r2 = I_tdata[47:40], w_g2 = I_tdata[39:32], w_b2 = I_tdata[31:24];
wire [7:0] w_r3 = I_tdata[23:16], w_g3 = I_tdata[15:8],  w_b3 = I_tdata[7:0];

wire [9:0] w_y0 = {1'b0, w_r0} + {w_g0, 1'b0} + {1'b0, w_b0};
wire [9:0] w_y1 = {1'b0, w_r1} + {w_g1, 1'b0} + {1'b0, w_b1};
wire [9:0] w_y2 = {1'b0, w_r2} + {w_g2, 1'b0} + {1'b0, w_b2};
wire [9:0] w_y3 = {1'b0, w_r3} + {w_g3, 1'b0} + {1'b0, w_b3};
wire [11:0] w_y4 = {2'b00, w_y0} + {2'b00, w_y1} + {2'b00, w_y2} + {2'b00, w_y3};

wire w_sat0 = (w_r0 >= 8'hFE) || (w_g0 >= 8'hFE) || (w_b0 >= 8'hFE);
wire w_sat1 = (w_r1 >= 8'hFE) || (w_g1 >= 8'hFE) || (w_b1 >= 8'hFE);
wire w_sat2 = (w_r2 >= 8'hFE) || (w_g2 >= 8'hFE) || (w_b2 >= 8'hFE);
wire w_sat3 = (w_r3 >= 8'hFE) || (w_g3 >= 8'hFE) || (w_b3 >= 8'hFE);
wire [2:0] w_sat_b = {2'b00, w_sat0} + {2'b00, w_sat1}
                   + {2'b00, w_sat2} + {2'b00, w_sat3};

reg  [47:0] r_sum4,  r_sum4_l;
reg  [23:0] r_satn,  r_satn_l;
reg         r_frame_end;            // tuser 拍：上一帧统计已锁进 *_l

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_sum4 <= 48'd0; r_satn <= 24'd0;
        r_sum4_l <= 48'd0; r_satn_l <= 24'd0; r_frame_end <= 1'b0;
    end else begin
        r_frame_end <= 1'b0;
        if (I_tvalid && I_tuser) begin
            r_sum4_l    <= r_sum4;
            r_satn_l    <= r_satn;
            r_sum4      <= {36'd0, w_y4};
            r_satn      <= {21'd0, w_sat_b};
            r_frame_end <= 1'b1;
        end else if (I_tvalid) begin
            r_sum4 <= r_sum4 + {36'd0, w_y4};
            r_satn <= r_satn + {21'd0, w_sat_b};
        end
    end
end

//------------------------------------------------------------------------------
// 2. done 2FF 同步（24MHz 域电平 → 本域）
//------------------------------------------------------------------------------
// ★2026-10-03 夜三修：AE 开关拨回(1→0)时传感器还停在被 AE 压暗的值上——
//   必须主动写一次【初始值】。否则板上现象 = "拨回开关没反应"。
reg        r_en_prev;                        // I_ae_en 打一拍，用来抓下降沿
reg        r_restore;                        // 待写的"回初始值"请求（等写表机空闲再发）
wire       w_en_fall = r_en_prev & ~I_ae_en;

reg [1:0] r_dsync;
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) r_dsync <= 2'b00;
    else          r_dsync <= {r_dsync[0], I_ae_cfg_done};
end
wire w_done = r_dsync[1];

//------------------------------------------------------------------------------
// 3. 控制状态机（IDLE → 置 req → 等 done 落 → 撤 req → 等 done 升）
//------------------------------------------------------------------------------
localparam [1:0] ST_IDLE  = 2'd0,   // 空闲，可以评估
             ST_WAIT_CATCH = 2'd1,   // req 已置 1，等写表机"接住"（done 落 0）
             ST_WAIT_BACK  = 2'd2;   // req 已撤，等 5 寄存器写完（done 回 1）

reg [1:0]  r_state;
reg [7:0]  r_settle_c;              // SETTLE 期帧计数（饱和保留）
reg [7:0]  r_wait;                  // 距下次评估的帧数
reg [15:0] r_exp, r_ag;
reg [21:0] r_wdt;                  // ★五修看门狗（2^22@74.25M≈56ms > 一笔写~8ms）

wire w_dark  = (r_sum4_l < SUM_LO_X4);
wire w_bright= (r_sum4_l > SUM_HI_X4) || ({24'd0, r_satn_l} > SAT_LIM);
wire [15:0] w_ag_next  = (r_ag + 16'd8 > AG_MAX) ? AG_MAX : (r_ag + 16'd8);   // ★五修步进16->8
wire [15:0] w_ag_prev  = (r_ag > (AG_MIN + 16'd8)) ? (r_ag - 16'd8) : AG_MIN;   // ★五修步进16->8
wire [15:0] w_exp_up   = (r_exp + (r_exp >> 3) > EXP_MAX) ? EXP_MAX : (r_exp + (r_exp >> 3));
wire [15:0] w_exp_dn   = (r_exp > (EXP_MIN + (r_exp >> 3))) ? (r_exp - (r_exp >> 3)) : EXP_MIN;
// 本帧评估会不会真变（用于跳过"双端已到顶/到底"的空转）：
wire w_change_dark = w_dark && ((r_exp != EXP_MAX) || (r_ag != AG_MAX));
wire w_change_brt  = w_bright && ((r_ag != AG_MIN) || (r_exp != EXP_MIN));
wire w_eval_due    = w_change_dark || w_change_brt;
// 评估沿提交的新目标值（单一来源，O_ae/O_ag 与 r_exp/r_ag 从这里取，杜绝新旧混拍）
wire [15:0] w_exp_nx = w_change_dark ? ((r_exp != EXP_MAX) ? w_exp_up : r_exp)
                                     : ((r_ag != AG_MIN)   ? r_exp    : w_exp_dn);
wire [15:0] w_ag_nx  = w_change_dark ? ((r_exp != EXP_MAX) ? r_ag     : w_ag_next)
                                     : ((r_ag != AG_MIN)   ? w_ag_prev : r_ag);

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_state <= ST_IDLE;
        r_settle_c <= 8'd0;
        r_wait  <= PERIOD;
        r_exp   <= EXP_INIT;
        r_ag    <= AG_INIT;
        O_ae_req  <= 1'b0;
        O_ae      <= EXP_INIT;
        O_ag      <= AG_INIT;
        r_en_prev <= 1'b1;
        r_restore <= 1'b0;
        r_wdt   <= 22'd0;
    end else begin
        r_en_prev <= I_ae_en;
        if (w_en_fall) r_restore <= 1'b1;   // 记下待写请求（此刻可能正忙，等回 IDLE 再发）
        case (r_state)
        ST_IDLE: begin
            if (r_restore && w_done) begin          // ★先把"开关拨回 → 写回初始值"办掉
                r_exp     <= EXP_INIT;
                r_ag      <= AG_INIT;
                O_ae      <= EXP_INIT;
                O_ag      <= AG_INIT;
                O_ae_req  <= 1'b1;
                r_restore <= 1'b0;
                r_state   <= ST_WAIT_CATCH;
            end
            else if (r_frame_end) begin
                if (r_settle_c < SETTLE)
                    r_settle_c <= r_settle_c + 8'd1;          // 预热期：只数帧
                else if (r_wait != 8'd0)
                    r_wait     <= r_wait - 8'd1;              // 周期计数
                else if (I_ae_en && w_done && w_eval_due) begin   // ★en=0 整条评估冻结          // r_wait==0：评估沿
                    r_exp    <= w_exp_nx;
                    r_ag     <= w_ag_nx;
                    O_ae     <= w_exp_nx;
                    O_ag     <= w_ag_nx;
                    O_ae_req <= 1'b1;
                    r_state  <= ST_WAIT_CATCH;
                    r_wait   <= PERIOD;
                end
                // r_wait==0 但本帧无可变（带内/已到顶）：保持 0，下一帧再查
            end
        end
        ST_WAIT_CATCH: begin
            if (!w_done) begin        // 写表机接住了（done 落）→ 立刻撤 req，防重启
                O_ae_req <= 1'b0;
                r_state  <= ST_WAIT_BACK;
                r_wdt    <= 22'd0;
            end
            else if (&r_wdt) begin    // ★五修看门狗：req 发了写表机没接住（跨时钟域漏采样）
                O_ae_req <= 1'b0;     //   → 撤 req 回 IDLE，8 帧后重试；r_restore 不清，回写必达
                r_state  <= ST_IDLE;
                r_wdt    <= 22'd0;
                r_wait   <= 8'd8;
            end
            else r_wdt <= r_wdt + 22'd1;
        end
        ST_WAIT_BACK: begin
            if (w_done) begin         // 5 寄存器写完
                r_state <= ST_IDLE;
                r_wdt   <= 22'd0;
            end
            else if (&r_wdt) begin    // ★五修看门狗：done 迟迟不回 → 放弃本次回 IDLE，之后有机会再发
                r_state <= ST_IDLE;
                r_wdt   <= 22'd0;
                r_wait  <= 8'd16;
            end
            else r_wdt <= r_wdt + 22'd1;
        end
        default: r_state <= ST_IDLE;
        endcase
    end
end

//------------------------------------------------------------------------------
// 4. 上电初值（仿真；与复位分支逐项一致）
//------------------------------------------------------------------------------
initial begin
    r_sum4 = 48'd0; r_satn = 24'd0;
    r_sum4_l = 48'd0; r_satn_l = 24'd0; r_frame_end = 1'b0;
    r_dsync = 2'b00;
    r_state = ST_IDLE; r_settle_c = 8'd0; r_wait = PERIOD;
    r_en_prev = 1'b1; r_restore = 1'b0; r_wdt = 22'd0;
    r_exp = EXP_INIT; r_ag = AG_INIT;
    O_ae_req = 1'b0; O_ae = EXP_INIT; O_ag = AG_INIT;
end

endmodule
