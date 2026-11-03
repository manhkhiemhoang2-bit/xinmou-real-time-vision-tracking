//==============================================================================
// tb_alg_top.v —— `alg_top` 集成验证的 ModelSim 测试平台
//
//   激励 : stim_top.hex（原始彩色拍流，10 帧 x 64 拍 = 640 个有效拍）
//   dump : dump_top.txt（每拍一行，空格分隔，ASCII）
//
// ⚠ 默认激励 = **真实链路工况**（2026-09-14 改造）：每行 BPL 拍背靠背，
//   行末一段 tvalid=0 的行消隐（长度 = 20 拍，与气泡模式同值）。
//   依据（已确证）：官方 zhenghe.v:137-146 —— demosaic 的 rd_valid 是 x_cnt 的函数，
//   而 x_cnt 在非有效期清零，所以每行都有一段 valid=0；这一段 gap 经 data128_96 / awb
//   （纯寄存器延迟、无门控）原样传到 alg_top 输入。也就是说**真实系统里根本不存在
//   "帧间无气泡"的激励**；改造前 check_alg_top.py 验的正是那个不存在的激励。
//     +noblank : 关掉行消隐（对照组）。check_bubble.py 的参考跑用它；
//                check_alg_top.py 会因此报错（它现在**要求**激励带行消隐）——
//                这是有意的：金标准必须在真实工况下才算验过。
//     +bubble  : 改造前的老开关，现在与默认等价（保留兼容）。
//
// 本 TB **只产生激励 + 逐拍记录**，不做任何判定；判定全部在 check_alg_top.py，
// 期望值来自 alg_ref.py 金标准 + 冻结文档，不依赖这份 RTL 的任何内部量。
//
// 记录格式 dump_top.txt（每行一拍）：
//   0 cyc
//   1..4   I_tvalid I_tlast I_tuser I_tdata
//   5..7   drv I_mode_set I_mode_sel           (TB 实际驱动的档位控制)
//   8..12  O_tvalid O_tlast O_tuser O_tdata O_mode
//   13..18 O_bbox_valid O_bbox_x0 O_bbox_x1 O_bbox_y0 O_bbox_y1 O_pix_count
//   19..21 dbg w_a0_ctl r_mask_d               (仅调试用，判定不读)
//   %h 会把 X/Z 原样显示成 x/z —— 这是 X 传播检查的依据。
//
// 气泡/消隐对照（check_bubble.py）的判据：同一份激励，有消隐跑与无消隐跑，
// **有效拍上的输出序列必须逐位相同**（拍序不变，只是被时间上拉长）。
//
// 为什么要关按键（plusarg +nokey）：I_key 的消抖是按时钟跑的（按键是实时事件，
// 这是对的），插消隐会让模式锁存合法地发生在不同的拍上。两边都关掉按键，控制
// 路径就只剩帧边界锁存（按有效拍），比较才干净。
//
// ⚠ 全部 $display / 注释用英文：ModelSim 10.3c 的 transcript 显示不了中文。
//==============================================================================
`timescale 1ns / 1ps

module tb_alg_top;

    localparam IMG_WIDTH   = 32;
    localparam IMG_HEIGHT  = 8;
    localparam BPL         = IMG_WIDTH / 4;      // 8 beats per line
    localparam FRAMES      = 10;
    localparam BPF         = BPL * IMG_HEIGHT;   // 64 beats per frame
    localparam NBEAT       = BPF * FRAMES;       // 640 beats
    localparam RST_CYC     = 4;
    localparam START_CYC   = 6;
    localparam TAIL_CYC    = 20;
    localparam KEY_DIV_SIM = 32;                 // debounce shortened for simulation

    //------------------------------------------------------------------
    // clock
    //------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                        // 10 ns

    //------------------------------------------------------------------
    // stimulus
    //------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg [3:0]  fidx;                             // frame index
    reg [31:0] bif;                              // beat-in-frame
    reg [31:0] bil;                              // beat-in-line
    reg        rst_n;

    //------------------------------------------------------------------
    // line blanking (default ON) / key disable (+nokey)
    //   en_blank 默认 1 = 真实链路工况（每行行末一段 tvalid=0 的行消隐，20 拍）
    //   +noblank 关掉它 -> 对照组（check_bubble.py 的参考跑）
    //------------------------------------------------------------------
    reg en_blank, en_nokey;
    reg [4:0] pause_len;     // cycles left in the current pause
    reg       blank_armed;   // one-shot: 本行已排过一次消隐停顿

    initial begin
        en_blank = $test$plusargs("noblank") ? 1'b0 : 1'b1;
        en_nokey = $test$plusargs("nokey")   ? 1'b1 : 1'b0;
        $display("TB: blank=%0d nokey=%0d (blank is default ON; +noblank disables)",
                 en_blank, en_nokey);
    end

    wire drv_run   = (cyc >= START_CYC) && (beat_idx < NBEAT);
    wire pause_now = en_blank && (pause_len != 4'd0);
    wire drv_valid = drv_run && !pause_now;

    always @ (posedge clk) begin
        if (!rst_n) begin
            pause_len   <= 5'd0;
            blank_armed <= 1'b0;
        end else if (pause_len != 5'd0) begin
            pause_len <= pause_len - 5'd1;
        end else if (drv_run && (bil == BPL - 1) && !blank_armed) begin
            // 真实链路模式：一行 BPL 拍背靠背，行末一个消隐停顿。
            // 依据：官方 zhenghe.v:137-146 —— rd_valid 是 x_cnt 的函数，而 x_cnt 在
            // 非有效期被清零，所以 demosaic 的输出 valid 每行都有一段为 0（行消隐）。
            // 这一段 gap 会原样经 data128_96 / awb（纯寄存器延迟）传到 alg_top 的输入。
            pause_len   <= 5'd20;
            blank_armed <= 1'b1;
        end else if (drv_run && (bil != BPL - 1)) begin
            blank_armed <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // mode schedule / key schedule -- MUST match gen_stim_top.py
    //------------------------------------------------------------------
    reg [2:0] drv_msel;
    reg       drv_mset;
    reg       drv_key;

    always @ (*) begin
        case (fidx)
            4'd0:    drv_msel = 3'd0;
            4'd1:    drv_msel = 3'd1;
            4'd2:    drv_msel = 3'd2;
            4'd3:    drv_msel = 3'd3;
            4'd4:    drv_msel = 3'd4;
            4'd5:    drv_msel = 3'd5;
            4'd6:    drv_msel = (bif < 32'd24) ? 3'd3 : 3'd5;  // mid-frame change: frame 6 must stay M3
            4'd7:    drv_msel = 3'd5;
            4'd8:    drv_msel = 3'd1;
            default: drv_msel = 3'd2;
        endcase
        drv_mset = (fidx <= 4'd7);
        drv_key  = ~(((fidx == 4'd7) || (fidx == 4'd8)) &&
                     (bif >= 32'd20) && (bif < 32'd68));
    end

    //------------------------------------------------------------------
    // input stream: control and data generated on the SAME edge/counter
    //------------------------------------------------------------------
    wire [95:0] I_tdata  = drv_valid ? stim[beat_idx] : 96'd0;
    wire        I_tvalid = drv_valid;
    // tlast = ROW end (320 拍/行，一帧 720 次)，不是帧末 —— 用行内拍号，别用帧内拍号
    wire        I_tlast  = drv_valid && (bil == BPL - 1);
    wire        I_tuser  = drv_valid && (bif == 0);
    wire        I_tready = 1'b1;                 // C-3: no back-pressure anywhere

    always @ (posedge clk) begin
        if (drv_valid) begin
            bil <= (bil == BPL - 1) ? 32'd0 : (bil + 32'd1);
            if (bif == BPF - 1) begin
                bif  <= 32'd0;
                fidx <= (fidx == FRAMES - 1) ? fidx : (fidx + 4'd1);
            end else begin
                bif <= bif + 32'd1;
            end
        end
    end

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire [95:0] O_tdata;
    wire        O_tvalid, O_tlast, O_tuser, O_tready;
    wire [2:0]  O_mode;
    wire [31:0] O_pix_count;
    wire [10:0] O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1;
    wire        O_bbox_valid;

    alg_top #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT),
        .KEY_DIV    (KEY_DIV_SIM)
    ) u_dut (
        .I_clk      (clk),
        .I_rst_n    (rst_n),
        .I_tlast    (I_tlast),
        .I_tuser    (I_tuser),
        .I_tdata    (I_tdata),
        .I_tvalid   (I_tvalid),
        .I_tready   (I_tready),
        .I_key      (en_nokey ? 1'b0 : drv_key),
        .I_mode_set (drv_mset),
        .I_mode_sel (drv_msel),
        .O_mode     (O_mode),
        .O_pix_count(O_pix_count),
        .O_bbox_x0  (O_bbox_x0),
        .O_bbox_x1  (O_bbox_x1),
        .O_bbox_y0  (O_bbox_y0),
        .O_bbox_y1  (O_bbox_y1),
        .O_bbox_valid(O_bbox_valid),
        .O_tlast    (O_tlast),
        .O_tuser    (O_tuser),
        .O_tdata    (O_tdata),
        .O_tvalid   (O_tvalid),
        .O_tready   (O_tready)
    );

    // debug-only probes (checks never read these two columns)
    wire [2:0] dbg_a0ctl = u_dut.w_a0_ctl;
    wire       dbg_mask  = u_dut.r_mask_d;

    //------------------------------------------------------------------
    // per-cycle dump (blocking $fwrite at the edge => settled values of this cycle)
    //------------------------------------------------------------------
    integer fd;
    integer ii;

    initial begin
        fd = $fopen("dump_top.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_top.txt");
            $finish;
        end
        $readmemh("stim_top.hex", stim);
        for (ii = 0; ii < NBEAT; ii = ii + 1)
            if (stim[ii] === 96'hxxxxxxxxxxxxxxxxxxxxxxxx) begin
                $display("FATAL: stim[%0d] is X -- stim_top.hex too short?", ii);
                $finish;
            end
        $display("TB: %0d beats loaded, BPL=%0d BPF=%0d FRAMES=%0d KEY_DIV=%0d",
                 NBEAT, BPL, BPF, FRAMES, KEY_DIV_SIM);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        fidx     = 4'd0;
        bif      = 32'd0;
        bil      = 32'd0;
        rst_n    = 1'b0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    reg [31:0] tail_cnt;

    always @ (posedge clk) begin
        // 21..26 只探不判：各档 valid 链的逐拍状态（气泡测试定位用；既有检查器只读 0..20）
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %b %b %b %h %d %b %d %d %d %d %d %b %b %b %b %b %b %b %b\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                drv_valid, drv_mset, drv_msel,
                O_tvalid, O_tlast, O_tuser, O_tdata, O_mode,
                O_bbox_valid, O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1, O_pix_count,
                dbg_a0ctl, dbg_mask,
                u_dut.w_g_val, u_dut.w_w_val, u_dut.w_wvalid,
                u_dut.w_b_val, u_dut.w_s_val, u_dut.w_m_val);
        cyc <= cyc + 32'd1;
        if (drv_valid)
            beat_idx <= beat_idx + 32'd1;
        // 终止条件：无消隐模式保持原来的「固定周期数」，这样既有的 noblank dump 与
        // 验证一字不变；含消隐时输入被时间拉长，只能按「最后一拍之后再走 TAIL_CYC 拍」收尾。
        if (beat_idx >= NBEAT) tail_cnt <= tail_cnt + 32'd1;
        else                   tail_cnt <= 32'd0;
        if (en_blank ? (tail_cnt >= TAIL_CYC)
                     : (cyc >= (START_CYC + NBEAT + TAIL_CYC))) begin
            $fclose(fd);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
