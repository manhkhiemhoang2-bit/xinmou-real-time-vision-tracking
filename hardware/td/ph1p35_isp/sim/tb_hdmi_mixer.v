//==============================================================================
// tb_hdmi_mixer.v —— 改写版 hdmi_mixer  vs  官方原版 hdmi_mixer_official 逐拍对比
//-----------------------------------------------------------------------------
// 被验证对象（同一份激励、同一个 I_clk、同一时刻复位）：
//   u_new      : hdmi_mixer            <- prj\...\hdl_source\hdmi_mixer.v（改写版）
//   u_official : hdmi_mixer_official   <- sim\hdmi_mixer_official.v（官方改名副本）
//
// 【纪律】所有期望值只由**本 TB 自己的激励序列**推导（3/2/4 拍移位寄存器），
//         绝不引用 DUT 内部信号来构造期望值。唯一引用 DUT 内部信号的地方是
//         "官方 OSD 是否命中"这个**分类**信号（题目要求以 u_official.S_osd_hit
//         为准），它只决定把这一拍归入 A6(a) 还是 A6(b)，不充当期望值。
//
// 【画面】每行 248 拍 = 16 同步 + 24 后沿 + 200 有效 + 8 前沿
//         每帧 216 行 =  4 同步 +  8 后沿 + 200 有效 + 4 前沿
//         官方 Logo 区 x<160,y<160 完全落在有效区内 => 满足"至少 200 行 x
//         200 像素"，且每行有消隐期；I_video_last 在每行最后一个 de 拍拉高，
//         I_video_user 在每帧第一个 de 拍拉高。
//
// 【像素图案】可预测、非恒定、且**构造上不可能等于任何官方 OSD 颜色**：
//         I_video_rd_data = { 8'h01 + vp[3:0] , lfsr16 }
//         低 16 位是 16 位最大长度 LFSR（x^16+x^14+x^13+x^11+1）；
//         高字节恒落在 [0x01,0x10]；官方 OSD 颜色高字节只可能是 >=0x1c
//         （anlogic_logo_rom 全部 579 种颜色）或 0xff（COLOR_DYN_TEXT=0xfff200）
//         —— 区间不相交。前提由 prep_hdmi_mixer.py 每次运行复核。
//         => A6(b)"命中像素上两版必然不同"是构造保证，不是碰运气。
//
// 【采样语义】所有检查都在 always @(posedge clk) 里读**沿前值**：
//         O_hdmi_x 沿前值 = 该寄存器上一沿写入的值，与移位寄存器 de_d3 沿前值
//         （= 3 拍前的 I_video_de）严格同拍，因此"恰好 3 拍"可直接逐拍比对。
//==============================================================================
`timescale 1ns/1ps

module tb_hdmi_mixer;

    //--------------------------------------------------------------------------
    // 1. 画面时序参数
    //--------------------------------------------------------------------------
    localparam H_ACTIVE  = 200;
    localparam H_SYNC    = 16;
    localparam H_BP      = 24;
    localparam H_FP      = 8;
    localparam H_TOTAL   = H_SYNC + H_BP + H_ACTIVE + H_FP;   // 248
    localparam H_A0      = H_SYNC + H_BP;                     // 40

    localparam V_ACTIVE  = 200;
    localparam V_SYNC    = 4;
    localparam V_BP      = 8;
    localparam V_FP      = 4;
    localparam V_TOTAL   = V_SYNC + V_BP + V_ACTIVE + V_FP;   // 216
    localparam V_A0      = V_SYNC + V_BP;                     // 12

    localparam FRAMES    = 2;                                 // 2 帧：多一组 vsync 沿 + 帧边界重启
    localparam N_CYC     = H_TOTAL * V_TOTAL * FRAMES;        // 107136 拍
    localparam RST_CYC   = 8;                                 // 复位保持 8 拍
    localparam CHK_START = RST_CYC + 6;                       // 14：等官方版未复位的
                                                              //     data 流水线把 X 冲干净
    localparam CYC_END   = RST_CYC + N_CYC + 8;

    localparam LFSR_SEED = 16'hACE1;

    //--------------------------------------------------------------------------
    // 2. 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    initial begin
        rst_n = 1'b1;
        #1 rst_n = 1'b0;                 // 产生一个真实的 negedge，异步复位 DUT
        repeat (RST_CYC) @(posedge clk);
        #1 rst_n = 1'b1;                 // 错开时钟沿 1ns，避免同拍竞争
    end

    //--------------------------------------------------------------------------
    // 3. 激励信号（两个 DUT 共用同一份）
    //--------------------------------------------------------------------------
    reg        I_vsync, I_hsync, I_de, I_user, I_last;
    reg  [3:0] I_dbg;
    reg  [23:0] I_data;

    reg [31:0] cyc;                      // 已采样的拍号（沿前值 = 本拍编号）
    reg [3:0]  rcnt;                     // 复位期拍计数
    reg [15:0] hp, vp;                   // 本拍要驱动的坐标（与激励同拍一致）
    reg [15:0] lfsr;

    wire [15:0] hp_n = (hp == H_TOTAL - 1) ? 16'd0 : hp + 16'd1;
    wire [15:0] vp_n = (hp == H_TOTAL - 1) ? ((vp == V_TOTAL - 1) ? 16'd0 : vp + 16'd1) : vp;

    wire        c_hsync = (hp_n < H_SYNC);
    wire        c_act_h = (hp_n >= H_A0) && (hp_n < H_A0 + H_ACTIVE);
    wire        c_vsync = (vp_n < V_SYNC);
    wire        c_act_v = (vp_n >= V_A0) && (vp_n < V_A0 + V_ACTIVE);
    wire        c_de    = c_act_v && c_act_h;
    // I_video_user 必须在**每帧第一拍**拉高（= 第一个有效行的第一个有效像素）。
    // 注意：早期版本漏了 vp_n==V_A0，结果每行都发一次 user，官方版 S_y 每行被清零，
    //       Logo 行（y>=34）永远到不了，A6b 集合为空 —— 已由 _probe_mixer.v 定位并修复。
    wire        c_user  = (vp_n == V_A0) && (hp_n == H_A0);
    wire        c_last  = c_de && (hp_n == H_A0 + H_ACTIVE - 1);

    wire [15:0] lfsr_n = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    wire [23:0] c_data = { (8'h01 + {4'd0, vp_n[3:0]}), lfsr_n };

    //--------------------------------------------------------------------------
    // 4. 两个 DUT
    //--------------------------------------------------------------------------
    wire        O_new_rd_en;
    wire        O_new_vsync, O_new_hsync, O_new_de;
    wire [23:0] O_new_data;

    wire        O_off_rd_en;
    wire        O_off_vsync, O_off_hsync, O_off_de;
    wire [23:0] O_off_data;

    hdmi_mixer #(
        .H_OFFSET   (128),
        .V_OFFSET   (60),
        .IMG_WIDTH  (1280),
        .IMG_HEIGHT (720),
        .DEBUG_MODE (0)
    ) u_new (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_video_vsync  (I_vsync),
        .I_video_hsync  (I_hsync),
        .I_video_de     (I_de),
        .I_video_user   (I_user),
        .I_video_last   (I_last),
        .I_debug_status (I_dbg),
        .O_video_rd_en  (O_new_rd_en),
        .I_video_rd_data(I_data),
        .O_hdmi_vsync   (O_new_vsync),
        .O_hdmi_hsync   (O_new_hsync),
        .O_hdmi_de      (O_new_de),
        .O_hdmi_data    (O_new_data)
    );

    hdmi_mixer_official #(
        .H_OFFSET   (128),
        .V_OFFSET   (60),
        .IMG_WIDTH  (1280),
        .IMG_HEIGHT (720),
        .DEBUG_MODE (0)
    ) u_official (
        .I_clk          (clk),
        .I_rst_n        (rst_n),
        .I_video_vsync  (I_vsync),
        .I_video_hsync  (I_hsync),
        .I_video_de     (I_de),
        .I_video_user   (I_user),
        .I_video_last   (I_last),
        .I_debug_status (I_dbg),
        .O_video_rd_en  (O_off_rd_en),
        .I_video_rd_data(I_data),
        .O_hdmi_vsync   (O_off_vsync),
        .O_hdmi_hsync   (O_off_hsync),
        .O_hdmi_de      (O_off_de),
        .O_hdmi_data    (O_off_data)
    );

    //--------------------------------------------------------------------------
    // 5. 参考移位寄存器（期望值的唯一来源）
    //--------------------------------------------------------------------------
    reg        de_d1, de_d2, de_d3, de_d4;
    reg        hs_d1, hs_d2, hs_d3, hs_d4;
    reg        vs_d1, vs_d2, vs_d3, vs_d4;
    reg [23:0] dt_d1, dt_d2, dt_d3, dt_d4;
    reg        hit_d1;                   // 官方 S_osd_hit 打一拍，与 O_hdmi_data 对齐

    //--------------------------------------------------------------------------
    // 6. 断言计数器
    //--------------------------------------------------------------------------
    integer a1a_chk, a1a_err, a1a_de_hi;         // 复位期 rd_en 组合直通
    integer a1b_chk, a1b_err;                    // 复位期 O_hdmi_* 全 0
    integer a2_chk,  a2_err;                     // 全程 rd_en == de（同拍）
    integer a3_chk,  a3_err, a3_n2, a3_n4;       // de   延迟恰好 3 拍 + 2/4 拍反证
    integer a4v_chk, a4v_err, a4v_n2, a4v_n4;    // vsync 延迟恰好 3 拍 + 2/4 拍反证
    integer a4h_chk, a4h_err, a4h_n2, a4h_n4;    // hsync 延迟恰好 3 拍 + 2/4 拍反证
    integer a5_chk,  a5_err, a5_n2, a5_n4;       // data  延迟恰好 3 拍 + 2/4 拍反证
    integer a6a_chk, a6a_err;                    // 官方未命中像素：两版必须相同
    integer a6b_chk, a6b_err;                    // 官方命中像素  ：两版必须不同
    integer a6x_chk, a6x_err;                    // 对照：两版控制信号必须相同
    integer hit_x, hit_de_bad;                   // 分类信号自身健全性
    integer de_edges, hs_edges, vs_edges, dt_edges;   // 激励丰富度
    integer a6b_eq_example;                      // 命中却相等的次数（只用于报错样本）
    reg     pass;

    //--------------------------------------------------------------------------
    // 7. 激励 + 采样 + 检查（同一沿，读沿前值；激励用 NBA 在沿后生效）
    //--------------------------------------------------------------------------
    always @(posedge clk) begin

        // ---------------- 7.1 激励 ----------------
        if (!rst_n) begin
            rcnt <= rcnt + 4'd1;
            hp   <= H_TOTAL - 1;          // 复位释放后正好从 (0,0) 开一帧
            vp   <= V_TOTAL - 1;
            lfsr <= LFSR_SEED;
            I_vsync <= 1'b1;
            I_hsync <= (rcnt < 4) ? 1'b1 : 1'b0;
            I_de    <= (rcnt >= 4);       // 复位期也拉高 de：证明 rd_en 不受复位影响
            I_user  <= 1'b0;
            I_last  <= 1'b0;
            I_data  <= 24'h123456 + {20'd0, rcnt};   // 复位期数据非零
        end
        else begin
            hp      <= hp_n;
            vp      <= vp_n;
            lfsr    <= lfsr_n;
            I_vsync <= c_vsync;
            I_hsync <= c_hsync;
            I_de    <= c_de;
            I_user  <= c_user;
            I_last  <= c_last;
            I_data  <= c_data;
        end

        // ---------------- 7.2 参考移位寄存器（只看激励序列） ----------------
        de_d1 <= I_de;    de_d2 <= de_d1;    de_d3 <= de_d2;    de_d4 <= de_d3;
        hs_d1 <= I_hsync; hs_d2 <= hs_d1;    hs_d3 <= hs_d2;    hs_d4 <= hs_d3;
        vs_d1 <= I_vsync; vs_d2 <= vs_d1;    vs_d3 <= vs_d2;    vs_d4 <= vs_d3;
        dt_d1 <= I_data;  dt_d2 <= dt_d1;    dt_d3 <= dt_d2;    dt_d4 <= dt_d3;

        // 分类信号：官方版 S_osd_hit 打一拍。
        //   O_hdmi_data 沿前值 = f(S_osd_hit 上一沿的沿前值)，
        //   hit_d1      沿前值 =   S_osd_hit 上一沿的沿前值  -> 严格同拍，无相位假设。
        hit_d1 <= u_official.S_osd_hit;

        // ---------------- 7.3 A1：复位期行为 ----------------
        if (!rst_n) begin
            a1a_chk = a1a_chk + 1;
            if (I_de) a1a_de_hi = a1a_de_hi + 1;
            if (O_new_rd_en !== I_de) begin
                a1a_err = a1a_err + 1;
                if (a1a_err <= 3)
                    $display("[A1a-ERR] cyc=%0d rst_n=0 exp rd_en=%b got=%b", cyc, I_de, O_new_rd_en);
            end
            a1b_chk = a1b_chk + 1;
            if (O_new_vsync !== 1'b0 || O_new_hsync !== 1'b0 ||
                O_new_de    !== 1'b0 || O_new_data  !== 24'd0) begin
                a1b_err = a1b_err + 1;
                if (a1b_err <= 3)
                    $display("[A1b-ERR] cyc=%0d rst_n=0 O_hdmi vsync=%b hsync=%b de=%b data=%h (exp 0000)",
                             cyc, O_new_vsync, O_new_hsync, O_new_de, O_new_data);
            end
            // 官方版同样检查（同一份激励、同一复位）
            if (O_off_rd_en !== I_de) begin
                a1a_err = a1a_err + 1;
                if (a1a_err <= 3)
                    $display("[A1a-ERR/off] cyc=%0d exp rd_en=%b got=%b", cyc, I_de, O_off_rd_en);
            end
        end

        // ---------------- 7.4 A2：rd_en 同拍组合直通（全程，含复位期） ----------------
        a2_chk = a2_chk + 1;
        if (O_new_rd_en !== I_de) begin
            a2_err = a2_err + 1;
            if (a2_err <= 3)
                $display("[A2-ERR] cyc=%0d exp O_video_rd_en=%b got=%b", cyc, I_de, O_new_rd_en);
        end

        // ---------------- 7.5 A3~A6：检查窗口 ----------------
        if (rst_n && (cyc >= CHK_START) && (cyc < CYC_END)) begin

            //--- 激励丰富度（跳变计数，0 跳变 = 测试无效） ---
            if (I_de    !== de_d1) de_edges = de_edges + 1;
            if (I_hsync !== hs_d1) hs_edges = hs_edges + 1;
            if (I_vsync !== vs_d1) vs_edges = vs_edges + 1;
            if (I_data  !== dt_d1) dt_edges = dt_edges + 1;

            //--- A3：O_hdmi_de 恰好 = I_video_de 延迟 3 拍 ---
            a3_chk = a3_chk + 1;
            if (O_new_de !== de_d3) begin
                a3_err = a3_err + 1;
                if (a3_err <= 3)
                    $display("[A3-ERR] cyc=%0d exp(de@-3)=%b got=%b  (de@-2=%b de@-4=%b)",
                             cyc, de_d3, O_new_de, de_d2, de_d4);
            end
            if (de_d2 !== O_new_de) a3_n2 = a3_n2 + 1;    // 延迟 2 拍的反例数
            if (de_d4 !== O_new_de) a3_n4 = a3_n4 + 1;    // 延迟 4 拍的反例数

            //--- A4：O_hdmi_vsync / O_hdmi_hsync 恰好延迟 3 拍 ---
            a4v_chk = a4v_chk + 1;
            if (O_new_vsync !== vs_d3) begin
                a4v_err = a4v_err + 1;
                if (a4v_err <= 3)
                    $display("[A4v-ERR] cyc=%0d exp(vs@-3)=%b got=%b (vs@-2=%b vs@-4=%b)",
                             cyc, vs_d3, O_new_vsync, vs_d2, vs_d4);
            end
            if (vs_d2 !== O_new_vsync) a4v_n2 = a4v_n2 + 1;
            if (vs_d4 !== O_new_vsync) a4v_n4 = a4v_n4 + 1;

            a4h_chk = a4h_chk + 1;
            if (O_new_hsync !== hs_d3) begin
                a4h_err = a4h_err + 1;
                if (a4h_err <= 3)
                    $display("[A4h-ERR] cyc=%0d exp(hs@-3)=%b got=%b (hs@-2=%b hs@-4=%b)",
                             cyc, hs_d3, O_new_hsync, hs_d2, hs_d4);
            end
            if (hs_d2 !== O_new_hsync) a4h_n2 = a4h_n2 + 1;
            if (hs_d4 !== O_new_hsync) a4h_n4 = a4h_n4 + 1;

            //--- A5：O_hdmi_data 恰好 = I_video_rd_data 延迟 3 拍 ---
            a5_chk = a5_chk + 1;
            if (O_new_data !== dt_d3) begin
                a5_err = a5_err + 1;
                if (a5_err <= 3)
                    $display("[A5-ERR] cyc=%0d exp(data@-3)=%h got=%h (data@-2=%h data@-4=%h)",
                             cyc, dt_d3, O_new_data, dt_d2, dt_d4);
            end
            if (dt_d2 !== O_new_data) a5_n2 = a5_n2 + 1;
            if (dt_d4 !== O_new_data) a5_n4 = a5_n4 + 1;

            //--- A6：官方版 vs 改写版逐拍对比 ---
            //   分类信号健全性：S_osd_hit 命中必然伴随 de 有效（同源门控）
            if (hit_d1 === 1'bx) hit_x = hit_x + 1;
            if ((hit_d1 === 1'b1) && (O_off_de !== 1'b1)) hit_de_bad = hit_de_bad + 1;

            if (hit_d1 === 1'b1) begin
                a6b_chk = a6b_chk + 1;
                if (O_new_data === O_off_data) begin
                    a6b_err = a6b_err + 1;
                    if (a6b_err <= 3)
                        $display("[A6b-ERR] cyc=%0d 官方命中却两版相同: new=%h off=%h (S_osd_hit=1)",
                                 cyc, O_new_data, O_off_data);
                end
            end
            else if (hit_d1 === 1'b0) begin
                a6a_chk = a6a_chk + 1;
                if (O_new_data !== O_off_data) begin
                    a6a_err = a6a_err + 1;
                    if (a6a_err <= 3)
                        $display("[A6a-ERR] cyc=%0d 官方未命中却两版不同: new=%h off=%h",
                                 cyc, O_new_data, O_off_data);
                end
            end

            //--- A6 对照：控制信号两版必须逐拍相同 ---
            a6x_chk = a6x_chk + 1;
            if (O_new_vsync !== O_off_vsync || O_new_hsync !== O_off_hsync ||
                O_new_de    !== O_off_de    || O_new_rd_en !== O_off_rd_en) begin
                a6x_err = a6x_err + 1;
                if (a6x_err <= 3)
                    $display("[A6x-ERR] cyc=%0d ctrl differ: new(v=%b h=%b de=%b rd=%b) off(v=%b h=%b de=%b rd=%b)",
                             cyc, O_new_vsync, O_new_hsync, O_new_de, O_new_rd_en,
                             O_off_vsync, O_off_hsync, O_off_de, O_off_rd_en);
            end
        end

        // ---------------- 7.6 拍号推进 ----------------
        cyc <= cyc + 32'd1;

        // ---------------- 7.7 汇总并结束 ----------------
        if (cyc >= CYC_END) begin
            pass = 1'b1;
            if (a1a_chk == 0 || a1a_err != 0)                                    pass = 1'b0;
            if (a1a_de_hi == 0)                                                  pass = 1'b0;
            if (a1b_chk == 0 || a1b_err != 0)                                    pass = 1'b0;
            if (a2_chk  == 0 || a2_err  != 0)                                    pass = 1'b0;
            if (a3_chk  == 0 || a3_err  != 0 || a3_n2  == 0 || a3_n4  == 0)      pass = 1'b0;
            if (a4v_chk == 0 || a4v_err != 0 || a4v_n2 == 0 || a4v_n4 == 0)      pass = 1'b0;
            if (a4h_chk == 0 || a4h_err != 0 || a4h_n2 == 0 || a4h_n4 == 0)      pass = 1'b0;
            if (a5_chk  == 0 || a5_err  != 0 || a5_n2  == 0 || a5_n4  == 0)      pass = 1'b0;
            if (a6a_chk == 0 || a6a_err != 0)                                    pass = 1'b0;
            if (a6b_chk == 0 || a6b_err != 0)                                    pass = 1'b0;
            if (a6x_chk == 0 || a6x_err != 0)                                    pass = 1'b0;
            if (hit_x != 0 || hit_de_bad != 0)                                   pass = 1'b0;
            if (de_edges == 0 || hs_edges == 0 || vs_edges == 0 || dt_edges == 0) pass = 1'b0;

            $display("");
            $display("==============================================================");
            $display(" tb_hdmi_mixer  assertion summary");
            $display(" frame: %0d active lines x %0d active px, line=%0d cyc, frame=%0d lines",
                     V_ACTIVE, H_ACTIVE, H_TOTAL, V_TOTAL);
            $display(" check window: cyc %0d .. %0d  (every I_clk)", CHK_START, CYC_END - 1);
            $display("--------------------------------------------------------------");
            $display(" ID   assertion                                       checks       errs");
            $display(" A1a  rst_n=0: O_video_rd_en == I_video_de         %8d %10d", a1a_chk, a1a_err);
            $display(" A1b  rst_n=0: O_hdmi_{vsync,hsync,de,data} == 0   %8d %10d", a1b_chk, a1b_err);
            $display(" A2   O_video_rd_en == I_video_de (same cycle)     %8d %10d", a2_chk,  a2_err);
            $display(" A3   O_hdmi_de    == I_video_de    delay 3        %8d %10d", a3_chk,  a3_err);
            $display(" A4v  O_hdmi_vsync == I_video_vsync delay 3        %8d %10d", a4v_chk, a4v_err);
            $display(" A4h  O_hdmi_hsync == I_video_hsync delay 3        %8d %10d", a4h_chk, a4h_err);
            $display(" A5   O_hdmi_data  == I_video_rd_data delay 3      %8d %10d", a5_chk,  a5_err);
            $display(" A6a  official NOT hit: both O_hdmi_data EQUAL     %8d %10d", a6a_chk, a6a_err);
            $display(" A6b  official HIT    : both O_hdmi_data DIFFER    %8d %10d", a6b_chk, a6b_err);
            $display(" A6x  ctrl signals equal between the two DUTs      %8d %10d", a6x_chk, a6x_err);
            $display("--------------------------------------------------------------");
            $display(" falsification of the wrong delays (must be > 0)");
            $display(" A3-de   delay2 counterexamples %8d   delay4 counterexamples %8d", a3_n2,  a3_n4);
            $display(" A4v-vs  delay2 counterexamples %8d   delay4 counterexamples %8d", a4v_n2, a4v_n4);
            $display(" A4h-hs  delay2 counterexamples %8d   delay4 counterexamples %8d", a4h_n2, a4h_n4);
            $display(" A5-data delay2 counterexamples %8d   delay4 counterexamples %8d", a5_n2,  a5_n4);
            $display("--------------------------------------------------------------");
            $display(" stimulus richness (inside window)");
            $display(" I_video_de    transitions %8d", de_edges);
            $display(" I_video_hsync transitions %8d", hs_edges);
            $display(" I_video_vsync transitions %8d", vs_edges);
            $display(" I_video_rd_data transitions %8d", dt_edges);
            $display(" reset cycles with I_video_de=1 %8d (a1a_de_hi, must be > 0)", a1a_de_hi);
            $display("--------------------------------------------------------------");
            $display(" classification sanity (from u_official.S_osd_hit)");
            $display(" hit cycles (A6b set) %8d   non-hit cycles (A6a set) %8d", a6b_chk, a6a_chk);
            $display(" S_osd_hit == X cycles %8d   hit while O_hdmi_de=0 %8d", hit_x, hit_de_bad);
            $display("==============================================================");
            if (pass) $display(" RESULT: PASS");
            else      $display(" RESULT: FAIL");
            $display("==============================================================");
            $finish;
        end
    end

    //--------------------------------------------------------------------------
    // 8. 初始化
    //--------------------------------------------------------------------------
    initial begin
        cyc = 32'd0;  rcnt = 4'd0;
        hp  = 16'd0;  vp   = 16'd0;
        lfsr = LFSR_SEED;
        I_vsync = 1'b1; I_hsync = 1'b1; I_de = 1'b0;
        I_user = 1'b0;  I_last = 1'b0;  I_dbg = 4'b1010;
        I_data = 24'h000000;

        a1a_chk = 0; a1a_err = 0; a1a_de_hi = 0;
        a1b_chk = 0; a1b_err = 0;
        a2_chk = 0;  a2_err = 0;
        a3_chk = 0;  a3_err = 0;  a3_n2 = 0;  a3_n4 = 0;
        a4v_chk = 0; a4v_err = 0; a4v_n2 = 0; a4v_n4 = 0;
        a4h_chk = 0; a4h_err = 0; a4h_n2 = 0; a4h_n4 = 0;
        a5_chk = 0;  a5_err = 0;  a5_n2 = 0;  a5_n4 = 0;
        a6a_chk = 0; a6a_err = 0;
        a6b_chk = 0; a6b_err = 0;
        a6x_chk = 0; a6x_err = 0;
        hit_x = 0; hit_de_bad = 0;
        de_edges = 0; hs_edges = 0; vs_edges = 0; dt_edges = 0;
        a6b_eq_example = 0;
        pass = 1'b0;

        $display("TB: tb_hdmi_mixer start  H_TOTAL=%0d V_TOTAL=%0d N_CYC=%0d RST_CYC=%0d CHK_START=%0d",
                 H_TOTAL, V_TOTAL, N_CYC, RST_CYC, CHK_START);
        $display("TB: pixel = {8'h01 + vp[3:0], lfsr16} -> top byte in [0x01,0x10], never an OSD colour");
    end

endmodule
