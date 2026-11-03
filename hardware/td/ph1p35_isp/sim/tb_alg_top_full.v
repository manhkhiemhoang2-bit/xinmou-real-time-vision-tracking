//==============================================================================
// tb_alg_top_full.v —— `alg_top` **全尺寸 1280x720** 集成验证的 ModelSim 测试平台
//
//   激励 : stim_top_full.hex（原始彩色拍流，FRAMES 帧 x 320 拍 x 720 行）
//   dump : dump_top_full.txt（每拍一行，空格分隔，ASCII）
//
// 与 tb_alg_top.v 的关系：**同一套约定，只是把几何放大到全尺寸**。
//   · 数据通路 96-bit AXI4-Stream，4 像素/拍，pix0 = I_tdata[95:72]（最左）；
//   · tlast = 行尾（EOL），每行 320 拍；tuser = 帧首拍；
//   · 默认激励 = 真实链路工况：每行 320 拍背靠背 + 行末 BLANK_CYC 拍 tvalid=0（行消隐）；
//   · 全尺寸**新增帧消隐**：每帧最后一个行消隐之后再补 EOF_BLANK_CYC 拍 tvalid=0；
//   · 档位/按键时序表与 gen_stim_top_full.py 逐条对应（前 10 帧与小图完全相同）；
//   · 本 TB **只产生激励 + 逐拍记录**，不做任何判定（判定全在 check_alg_top_full.py）。
//
// 为什么必须做全尺寸（小图 32x8 / BPL=8 根本碰不到的）：
//   · 行缓存寻址：320 深阵列的读地址 x_grp+1 / x_grp+2 取模回绕（LAST_BEAT=319）；
//   · 行内拍号 XW=9 位计数器的整行回绕；
//   · 行首/行尾的列 0 与列 1280 图外补 0；
//   · 掩蔽第 0 拍只屏蔽 4 个像素；
//   · 250 万级拍序上的帧边界、帧消隐与帧级统计换值时刻。
//
// 记录格式 dump_top_full.txt（每行一拍，18 列）：
//   0 cyc
//   1..4   I_tvalid I_tlast I_tuser I_tdata(24 hex)   —— I_tvalid=0 的拍 tdata 记 0
//   5..9   O_tvalid O_tlast O_tuser O_tdata(24 hex) O_mode
//   10..11 O_bbox_valid O_pix_count
//   12..15 O_bbox_x0 O_bbox_x1 O_bbox_y0 O_bbox_y1
//   16     O_color_class（0=R / 1=G / 2=B；2026-09-20 新增，扩展要求 2.4(2)）
//   17     O_track_id（跟踪编号；2026-09-20 新增，进阶要求 2.5(2)）
//   %h 会把 X/Z 原样显示成 x/z —— 这是 X 传播检查（判据 F）的依据。
//
//   ⚠ 第 16/17 列都是**追加在末尾**的：老 dump 只有 16 列，判据按"列数够不够"决定跳不跳，
//     所以历史 dump 仍然读得进来，不会因为加了列就全部作废。
//
// plusarg:
//   +frames=N   只跑前 N 帧（默认全部 FRAMES；用于冒烟与分段回归）
//   +noeofblank 关掉帧消隐（对照组）
//   +nokey      关掉按键（对照组）
//
// ⚠ 全部 $display / 注释用英文：ModelSim 10.3c 的 transcript 显示不了中文。
//   本文件必须是 **UTF-8 无 BOM** 且正文全 ASCII（安全起见只写 ASCII）。
//==============================================================================
`timescale 1ns / 1ps

module tb_alg_top_full;

    // 几何可由 vlog 宏覆盖（只用于**变异自证**的小尺寸快速跑；正式验证用默认 1280x720）
    `ifdef ALG_IMG_W
    localparam IMG_WIDTH   = `ALG_IMG_W;
    localparam IMG_HEIGHT  = `ALG_IMG_H;
    `else
    localparam IMG_WIDTH   = 1280;
    localparam IMG_HEIGHT  = 720;
    `endif
    `ifdef ALG_FRAMES
    localparam FRAMES      = `ALG_FRAMES;
    `else
    localparam FRAMES      = 12;                 // must match gen_stim_top_full.py
    `endif
    localparam BPL         = IMG_WIDTH / 4;      // 320 beats per line
    localparam BPF         = BPL * IMG_HEIGHT;   // 230400 beats per frame
    localparam NBEAT_ALL   = BPF * FRAMES;
    localparam RST_CYC     = 4;
    localparam START_CYC   = 6;
    localparam BLANK_CYC   = 20;                 // per-line blank, real-link value
    localparam EOF_BLANK   = 100;                // per-frame blank (full-size only)
    localparam LAT         = 5;                  // frozen total latency
    // tail = first cycle at which the LAST output beat (of the last input beat) is
    // valid, PLUS enough trailing tvalid=0 cycles that the checker's tail-blank
    // gate (>= BLANK_CYC cycles of tvalid=0 after the last input beat) is measurable.
    // Must be expressed with the SAME counters the always-block uses:
    //   last input beat (beat_idx hits BPF*nframes) -> TAIL_CYC starts counting
    //   its output beat is valid LAT cycles later
    localparam TAIL_CYC    = LAT + BLANK_CYC + 2;   // = 27
    localparam KEY_DIV_SIM = 32;

    //------------------------------------------------------------------
    // clock
    //------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                        // 10 ns

    //------------------------------------------------------------------
    // stimulus
    //------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT_ALL-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;
    reg [4:0]  fidx;                             // frame index (0..FRAMES-1)
    reg [31:0] bif;                              // beat-in-frame
    reg [31:0] bil;                              // beat-in-line
    reg        rst_n;

    integer nframes;
    reg en_eofblank, en_nokey;
    reg en_m67;                                  // 2026-09-20 全尺寸 M6/M7 专项跑
    reg en_m7out;                                // 2026-09-22 全尺寸 M7 切出专项跑

    localparam NBEAT = BPF * FRAMES;             // compile-time capacity

    initial begin
        en_eofblank = $test$plusargs("noeofblank") ? 1'b0 : 1'b1;
        en_nokey    = $test$plusargs("nokey")      ? 1'b1 : 1'b0;
        en_m67      = $test$plusargs("m67")        ? 1'b1 : 1'b0;
        en_m7out    = $test$plusargs("m7out")      ? 1'b1 : 1'b0;
        if (!$value$plusargs("frames=%d", nframes) || nframes < 1 || nframes > FRAMES)
            nframes = FRAMES;
        $display("TB: IMG=%0dx%0d BPL=%0d BPF=%0d frames=%0d eofblank=%0d nokey=%0d m67=%0d m7out=%0d",
                 IMG_WIDTH, IMG_HEIGHT, BPL, BPF, nframes, en_eofblank, en_nokey, en_m67, en_m7out);
    end

    //------------------------------------------------------------------
    // gap generator: one line blank after every BPL beats,
    //                one (line + frame) blank after the last line of a frame.
    //   valid beats are strictly back-to-back; gaps are pure tvalid=0.
    //
    // ⚠⚠ 2026-09-16 实测踩到的坑（上一次全尺寸 12 帧"跑飞"、dump 写到 6 GB 的真因）：
    //   旧写法用一个 eof_pending 标志把 gap_left 从 BLANK_CYC "延长" 到 EOF_BLANK：
    //       if (eof_pending && (gap_left == BLANK_CYC)) gap_left <= EOF_BLANK;
    //       else begin gap_left <= gap_left-1; if (gap_left==1) eof_pending <= 0; end
    //   而 gap_left 从 100 倒数回 20 时会**再次**命中 `gap_left == BLANK_CYC`，
    //   于是又被延长回 100 —— 死循环。drv_valid 永不恢复、beat_idx 冻在 BPF、
    //   收尾计数永不触发 ⇒ 仿真在**第一帧边界**上死锁（实测空跑到 5600 万拍）。
    //   1 帧跑能"通过"只是因为那时 beat_idx 已经到顶、收尾计数照常触发，掩盖了这个 bug。
    //   现在改成**一次性算总长度**（帧末直接给 BLANK_CYC + EOF_BLANK），没有状态位。
    //------------------------------------------------------------------
    reg [7:0] gap_left;      // cycles left in the current gap (0 = no gap)

    wire drv_run   = (cyc >= START_CYC) && (beat_idx < BPF * nframes);
    wire gap_now   = (gap_left != 8'd0);
    wire drv_valid = drv_run && !gap_now;

    always @ (posedge clk) begin
        if (!rst_n) begin
            gap_left <= 8'd0;
        end else if (gap_left != 8'd0) begin
            gap_left <= gap_left - 8'd1;
        end else if (drv_run && (bil == BPL - 1)) begin
            // 普通行末 -> BLANK_CYC 拍行消隐；本帧最后一行 -> 再补 EOF_BLANK 拍帧消隐
            gap_left <= ((bif == BPF - 1) && en_eofblank) ? (BLANK_CYC + EOF_BLANK)
                                                         : BLANK_CYC[7:0];
        end
    end

    //------------------------------------------------------------------
    // key schedule -- MUST match gen_stim_top_full.py
    //   the divide-by-2 is because valid beats come in groups of BPL (320);
    //   KEY_BIF/KEY_LEN are given in beats and are < BPL, so dividing by BPL
    //   still lands inside the correct line (line 0 of the frame).
    //
    //   ⚠ 2026-09-17 M6 / 2026-09-18 M7: two tables, selected by the geometry macro,
    //     and BOTH must match gen_stim_top_full.py's MODE_SCHED/MODE_SET_SCHED for
    //     the same geometry:
    //       · ALG_IMG_W defined (= small size, mutation self-proof): frame i
    //         uses mode i (M0..M7), and frame 7 is reached **through the key path**
    //         (I_mode_set drops to 0 after frame 6 and seven key presses inside
    //         frame 6 walk r_mode_hold up to 7).  That is the only geometry where
    //         the key-cycle upper bound (M6 -> M7) is actually exercised.
    //       · full size (1280x720): the frozen 12-frame table -- frames 0..5 =
    //         M0..M5, frame 6 = mid-frame mode change (stays M3), frames 7..11
    //         exercise the key/hold path.  DO NOT change: it corresponds to the
    //         already-generated stim_top_full.hex and the existing baseline.
    //       · full size + `+m67` (2026-09-20): 3-frame table [M0, M6, M7] with
    //         I_mode_set held at 1 -- closes the hole that M6/M7 had only ever
    //         been verified at 160x64.  The frozen table above is left untouched;
    //         this is a switch, not an edit.  Must stay in sync with
    //         gen_stim_top_full.py's ALG_MSCHED=m67 table (check_alg_top_full.py
    //         imports that one).  Runner: sim\run_m67_full.ps1.
    //------------------------------------------------------------------
    reg [2:0] drv_msel;
    reg       drv_mset;
    reg       drv_key;
    //------------------------------------------------------------------
    // 2026-09-24 修 bug：按键脉冲窗口原来用 `bil_k = bil / BPL`，而
    //   `bil` 的值域是 0..319、`BPL` = 320 ⇒ **`bil_k` 恒为 0**，
    //   于是条件 `bil_k >= 20` 恒假 ⇒ **全尺寸的按键脉冲从来没发出过**
    //   ⇒ frames 8/9/10 的 `r_mode_hold` 永远是 0 ⇒ 实测 O_mode 全是 M0。
    //
    //   证据（12 帧全尺寸实测，dump 逐帧提取 O_mode）：
    //     帧 7  = 5  ✅（靠 I_mode_sel，没走按键）
    //     帧 8  = 0  ❌（应为 1）
    //     帧 9  = 0  ❌（应为 2）
    //     帧 10 = 0  ❌（应为 2）
    //   小尺寸那条路不受影响 —— 它用的是 `bif` 派生的 k_off/k_slot/k_pos。
    //
    //   修法：改用**帧内拍号 `bif`**表达窗口（这才是"在帧 N 内按一下"的正确口径）。
    //     frame 7：bif ∈ [20, 68) 按一下
    //     frame 8：bif ∈ [20, 68) 再按一下
    //   ⇒ `r_mode_hold` 依次 0→1→2，与 Python 期望 [.., 1, 2, 2, 0] 对齐。
    //
    //   ⚠ 顺带更正：Python 的 MODE_SCHED 尾部第 10 帧写的 `5` 是**错的**，
    //     TB 表里写的 `2` 才是对的（frame 10 的 mode_set 已是 0，
    //     hold 停在 2 就不会再变）。改 TB 后必须把 Python 也改成 2。
    //
    //   保留 `bil_k` 的定义不动（防止别的引用），只是不再拿它当按键窗口。
    //------------------------------------------------------------------
    wire [31:0] bil_k = bil / BPL;               // always 0 in practice (KEY_BIF < BPL)
    // 按键窗口：用帧内拍号 bif（不是 bil/BPL）
    localparam [31:0] KWIN_LO = 32'd20;
    localparam [31:0] KWIN_HI = 32'd68;

`ifdef ALG_IMG_W
    // small-size key train: seven presses inside frame KEY_FRAME_S (6), each
    // KEY_LOW (40) beats long, KEY_PERIOD (160) beats apart -- must match
    // gen_stim_top_full.py's KEY_*_S constants.
    localparam KFRAME_S = 6;
    localparam KBIF_S   = 40;
    localparam KPERIOD  = 160;
    localparam KLOW     = 40;
    localparam KN_S     = 7;
    wire [31:0] k_off = bif - KBIF_S;
    wire [31:0] k_slot = k_off / KPERIOD;
    wire [31:0] k_pos  = k_off % KPERIOD;
    wire k_press = (fidx == KFRAME_S) && (bif >= KBIF_S) &&
                   (k_slot < KN_S) && (k_pos < KLOW);

    always @ (*) begin
        case (fidx)
            5'd0:    drv_msel = 3'd0;
            5'd1:    drv_msel = 3'd1;
            5'd2:    drv_msel = 3'd2;
            5'd3:    drv_msel = 3'd3;
            5'd4:    drv_msel = 3'd4;
            5'd5:    drv_msel = 3'd5;
            5'd6:    drv_msel = 3'd6;              // frame 6 = M6 (I_mode_sel still drives it)
            default: drv_msel = 3'd7;             // frame 7+ : don't care (mset = 0)
        endcase
        drv_mset = (fidx <= 5'd6);                // frame 7.. : mode comes from the key
        drv_key  = ~k_press;                      // low = pressed
    end
`else
    always @ (*) begin
        if (en_m67) begin
            // 2026-09-20 全尺寸 M6/M7 专项跑（+m67 开关）。
            //   三方必须一致：本表 / gen_stim_top_full.py 的 ALG_MSCHED=m67 表 /
            //   check_alg_top_full.py（它 import gen_stim_top_full 的 MODE_SCHED）。
            //   ⚠ M6 **不能排在第 1 帧**：判据 L 是 box_nonempty = (mb[fr-1] is not None)，
            //     即"M6 显示的红框 = 上一帧的运动框"，而第 0 帧运动图恒为全 0
            //     ⇒ M6 在第 1 帧时红框必空（实测报红，那是正常行为不是 bug）。
            //   f0=M0（参考帧 + 判据 K）、f1=M1（给 f2 的 M6 供上一帧运动框）、
            //   f2=M6、f3=M7；I_mode_set 恒 1、按键始终松开。
            case (fidx)
                5'd0:    drv_msel = 3'd0;
                5'd1:    drv_msel = 3'd1;
                5'd2:    drv_msel = 3'd6;
                default: drv_msel = 3'd7;
            endcase
            drv_mset = 1'b1;
            drv_key  = 1'b1;                     // 1 = 松开
        end else if (en_m7out) begin
            // 2026-09-22 全尺寸 **M7 切出**专项跑（+m7out 开关）。
            //   三方必须一致：本表 / gen_stim_top_full.py 的 ALG_MSCHED=m7out 表 /
            //   check_alg_top_full.py（它 import gen_stim_top_full 的 MODE_SCHED）。
            //   表 = [0, 1, 3, 7, 0]：f3=M7、**f4=M0** —— 切出 M7 就发生在 f3->f4 的
            //   帧边界上。要验的是 alg_top.v:679 那条换档沿只对"切进 M7"提前了 1 拍
            //   （w_sof_pre 项），对"切出 M7"没有对应处理。
            //   f2 特意排 M3：check_alg_top_full.py:993 用 MODE_SCHED.index(MODE_EDGE)，
            //   表里没有 M3 会直接抛 ValueError ⇒ 带上它，checker 一个字都不用改。
            //   I_mode_set 恒 1、按键始终松开（与 +m67 同款）。
            //   预期：若缺陷成立，f4 会少 1 个有效拍 + 少 1 个 tuser ⇒ 判据 J/D 报红。
            case (fidx)
                5'd0:    drv_msel = 3'd0;        // M0（判据 K 要一帧 M0 直通）
                5'd1:    drv_msel = 3'd1;        // M1 垫帧
                5'd2:    drv_msel = 3'd3;        // M3（判据 E 用）
                5'd3:    drv_msel = 3'd7;        // M7 ← 切进（这一步有保护）
                default: drv_msel = 3'd0;        // f4 = M0 ← **切出 M7**，本轮的主角
            endcase
            drv_mset = 1'b1;
            drv_key  = 1'b1;                     // 1 = 松开
        end else begin
            case (fidx)
                5'd0:    drv_msel = 3'd0;
                5'd1:    drv_msel = 3'd1;
                5'd2:    drv_msel = 3'd2;
                5'd3:    drv_msel = 3'd3;
                5'd4:    drv_msel = 3'd4;
                5'd5:    drv_msel = 3'd5;
                5'd6:    drv_msel = (bif < 32'd24) ? 3'd3 : 3'd5;  // mid-frame change; frame 6 stays M3
                5'd7:    drv_msel = 3'd5;
                5'd8:    drv_msel = 3'd1;
                5'd9:    drv_msel = 3'd2;
                5'd10:   drv_msel = 3'd2;
                default: drv_msel = 3'd0;                          // frame 11 -> M0
            endcase
            drv_mset = (fidx <= 5'd7);
            drv_key  = ~(((fidx == 5'd7) || (fidx == 5'd8)) &&
                         (bif >= KWIN_LO) && (bif < KWIN_HI));   // 2026-09-24 修：原用 bil_k 恒 0
        end
    end
`endif

    //------------------------------------------------------------------
    // input stream
    //------------------------------------------------------------------
    wire [95:0] I_tdata  = drv_valid ? stim[beat_idx] : 96'd0;
    wire        I_tvalid = drv_valid;
    // tlast = ROW end (320 beats/line, 720 times per frame) -- use beat-in-line
    wire        I_tlast  = drv_valid && (bil == BPL - 1);
    wire        I_tuser  = drv_valid && (bif == 0);
    wire        I_tready = 1'b1;                 // C-3: no back-pressure anywhere

    always @ (posedge clk) begin
        if (drv_valid) begin
            bil <= (bil == BPL - 1) ? 32'd0 : (bil + 32'd1);
            if (bif == BPF - 1) begin
                bif  <= 32'd0;
                fidx <= (fidx == FRAMES - 1) ? fidx : (fidx + 5'd1);
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
    wire [1:0]  O_color_class;      // 2026-09-20：颜色类别（扩展要求 2.4(2)）
    wire [7:0]  O_track_id;         // 2026-09-20：跟踪编号（进阶要求 2.5(2)）

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
        .O_color_class(O_color_class),
        .O_track_id (O_track_id),
        .O_tlast    (O_tlast),
        .O_tuser    (O_tuser),
        .O_tdata    (O_tdata),
        .O_tvalid   (O_tvalid),
        .O_tready   (O_tready)
    );

    //------------------------------------------------------------------
    // per-cycle dump
    //  NOTE: no DUT-internal probe is dumped -- expectations must come from the
    //  stimulus / golden model, never from the DUT (anti-circularity rule).
    //------------------------------------------------------------------
    integer fd;
    integer rfd;
    integer ii;
    integer rc;

    initial begin
        fd = $fopen("dump_top_full.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_top_full.txt");
            $finish;
        end
        // 只读 +frames 帧需要的那些拍（不要求文件写满 FRAMES 帧）。
        // 用 $fscanf 而不是 $readmemh：@frames=N 时只读 N*BPF 拍，省内存也省时间。
        rfd = $fopen("stim_top_full.hex", "r");
        if (rfd == 0) begin
            $display("FATAL: cannot open stim_top_full.hex");
            $finish;
        end
        for (ii = 0; ii < BPF * nframes; ii = ii + 1) begin
            rc = $fscanf(rfd, "%h\n", stim[ii]);
            if (rc != 1) begin
                $display("FATAL: stim_top_full.hex has only %0d beats, need %0d (+frames=%0d)",
                         ii, BPF * nframes, nframes);
                $finish;
            end
            if (^stim[ii] === 1'bx) begin
                $display("FATAL: stim[%0d] is X (hex char malformed)", ii);
                $finish;
            end
        end
        $fclose(rfd);
        $display("TB: %0d beats loaded from stim_top_full.hex (frames=%0d, BPL=%0d BPF=%0d)",
                 BPF * nframes, nframes, BPL, BPF);
    end

    initial begin
        cyc      = 32'd0;
        beat_idx = 32'd0;
        fidx     = 5'd0;
        bif      = 32'd0;
        bil      = 32'd0;
        rst_n    = 1'b0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    reg [31:0] tail_cnt;
    reg        done_seen;

    // TB self-check tally（计数在 dump 的同一个 always 里，见下方注释）
    integer n_out_beat, n_out_last, n_out_user;

    initial begin
        n_out_beat = 0;
        n_out_last = 0;
        n_out_user = 0;
    end

    always @ (posedge clk) begin
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %d %b %d %d %d %d %d %d %d\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata, O_mode,
                O_bbox_valid, O_pix_count,
                O_bbox_x0, O_bbox_x1, O_bbox_y0, O_bbox_y1,
                O_color_class, O_track_id);
        cyc <= cyc + 32'd1;
        if (drv_valid)
            beat_idx <= beat_idx + 32'd1;
        //------------------------------------------------------------------
        // TB self-check tally (2026-09-17, M6 integration contract)
        //   "under every mode -- M6 included -- the number of output beats must
        //    equal the number of input valid beats, and O_tlast / O_tuser must
        //    each appear exactly the expected number of times"
        //   Counted in **this** always block on purpose: the run terminates in this
        //   same block, so the tally and $finish cannot race.
        //   This is a redundant TB-level gate; the authoritative per-cycle
        //   judgement (O_tvalid[t] == I_tvalid[t-5], beat-for-beat) stays in
        //   check_alg_top_full.py judgements A/J/H/L -- expectations never come
        //   from the DUT.
        //------------------------------------------------------------------
        if (O_tvalid)            n_out_beat = n_out_beat + 1;
        if (O_tvalid && O_tlast) n_out_last = n_out_last + 1;
        if (O_tvalid && O_tuser) n_out_user = n_out_user + 1;
        // 终止条件：必须跑过"最后一拍输入 + LAT"，否则 dump 会在 O_tvalid 还没被
        // 采样到时就截断（实测 TAIL=32 时只写到 244819 拍，比"最后一拍的输入
        // 周期 + LAT"少 7 拍；改成按 TAIL_CYC 精确表达就与拍轴口径一致）。
        if (beat_idx >= BPF * nframes) tail_cnt <= tail_cnt + 32'd1;
        else                           tail_cnt <= 32'd0;
        if (tail_cnt >= TAIL_CYC) begin
            $fclose(fd);
            $display("TB: done, wrote %0d cycles, %0d valid beats, frames=%0d, tail_cyc=%0d",
                     cyc + 1, beat_idx, nframes, TAIL_CYC);
            $display("TB: selfcheck in_beats=%0d out_beats=%0d out_tlast=%0d out_tuser=%0d",
                     beat_idx, n_out_beat, n_out_last, n_out_user);
            $display("TB: selfcheck out_beats==in_beats (%0d==%0d) %s | out_tlast==%0d %s | out_tuser==%0d %s",
                     n_out_beat, beat_idx, (n_out_beat == beat_idx) ? "PASS" : "FAIL",
                     nframes * IMG_HEIGHT, (n_out_last == nframes * IMG_HEIGHT) ? "PASS" : "FAIL",
                     nframes, (n_out_user == nframes) ? "PASS" : "FAIL");
            if ((n_out_beat != beat_idx) || (n_out_last != nframes * IMG_HEIGHT)
                || (n_out_user != nframes))
                $display("TB: selfcheck RESULT=FAIL");
            else
                $display("TB: selfcheck RESULT=PASS");
            $finish;
        end
    end

endmodule
