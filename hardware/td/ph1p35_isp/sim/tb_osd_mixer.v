//==============================================================================
// tb_osd_mixer.v —— osd_mixer 的 ModelSim 测试平台
//
// 只从**规格**推导激励与观测，不读实现：
//   契约 1：O_tdata/O_tvalid/O_tlast/O_tuser = 输入各自延迟 2 拍（同拍）
//   契约 2：OSD 命中处的像素 = OSD 颜色，没命中处 = 原像素（一个 bit 都不许动）
//   契约 3：区域外的像素 = 原像素
//   契约 4（v1.4）：优先级 文字 > 安路Logo > 自研Logo > 原像素；
//           安路官方 Logo 版面 (0,0) 160x160，几何随 dump 首行交给 Python 校验器。
//
//   ⚠ 本 TB 的画幅是 800x104，而安路 Logo 是 160x160 —— 它**盖住了整幅测试图**，
//     也就是把自研 Logo 面（40,8）整个罩在底下。这是故意的：真实版面（1280x720）
//     里两者互不重叠，但在测试里让它们重叠才能把"安路 > 自研"这条优先级逼出来。
//     需要"安路区外一个 bit 都不动"的干净证据时，用 sim/tb_osd_anlogo.v（独立画幅）。
//
// 做法：把每一拍的**全部信号**逐周期 dump 成文本，逐像素比对全部放到 Python
//       校验器里做（见 check_osd.py）。这里只负责产生激励和记录。
//
// 像素值图（严格单射，杜绝"混叠导致的假通过"）：
//   pix(beat,x,ch) = (beat << 7) | (x << 2) | ch，其中 x = beat % 32、ch = 0..3
//   ⇒ 唯一反解 beat = pix >> 7（x 是冗余的，只为让人读波形时看得出是哪一列）。
//   ⚠⚠ **位宽上限**：pix 只有 24 位，所以必须 `NBEAT << 7 < 2^24`（NBEAT ≤ 131071）。
//     2026-09-20 帧数 3 → 6 时正是踩到这条：3 帧 76800 拍（76800<<7 = 9.8M，够用），
//     6 帧 153600 拍（153600<<7 = 19.7M **溢出**）⇒ 拍号回卷成 beat%131072，
//     像素值开始互相撞车，判据大面积报红而 RTL 完全无辜。
//     改法是把**画幅高度 128 → 104**（200 拍/行 ×104 ×6 = 124800 拍，留 6% 余量），
//     而不是去动编码 —— 编码一改，TB 与判据两边都要跟着改，错一处就是新的假通过源。
//   → 任何被改动 / 错位 / 串行 / 通道交换的像素都能被反解出 (beat,x,ch)。
//
// 输出：dump_osd.txt
//   首行 H <W> <H> <LOGO_X> <LOGO_Y> <TEXT_X> <TEXT_Y> <MODE> <FPS> <LAT> <INF_X>
//          <ANLOGO_X> <ANLOGO_Y> <ANLOGO_W> <ANLOGO_H>      （后 4 个是 v1.4 新增）
//          <NFRAME> <MODE0> <MODE1> <MODE2>                 （后 4 个是 v1.5 档位扫描）
//   其后每拍：
//     cyc Iv Il Iu Id Ov Ol Ou Od logo0..3 txt0..3 rx ry
//   十六进制用 %h 打印，X/Z 会原样显示成 x/z —— 这是 X 传播检查的依据。
//==============================================================================
`timescale 1ns / 1ps

module tb_osd_mixer;

    // 2026-09-20：IMG_WIDTH 128 → 640。
    //   原因：osd_mixer 的 N_CHAR_MAX 由 16 放宽到 32 后，文字占
    //   x ∈ [TEXT_X, TEXT_X + 512)。128 宽的画面只放得下 7 个字，
    //   **根本区分不出 16 和 32**，改了等于没测。
    //   640 宽能完整放下 32 个字，于是排版表第 16~24 格
    //   （LAT 个位 / 空格 / "X:" / 四位坐标 / "Y"）**第一次真正画在屏上**
    //   并参与逐像素比对 —— 那几格的字符码此前从未上过屏。
    //   高度不动，Logo 与文字的面重叠关系（TEXT_Y=40 落在 Logo 带 8..71 内）保持原样。
    localparam IMG_WIDTH  = 800;
    // 2026-09-20：高度 128 → 104。**不是为了省仿真时间，是被上面那条位宽上限逼的**：
    //   帧数加到 6 之后，128 高会得到 153600 拍 > 131071，像素编码溢出。
    //   104 高 ⇒ 6 帧 124800 拍，编码不溢出；而总像素数 800x104x6 = 499200，
    //   比改前的 800x128x3 = 307200 **还多**，覆盖面是变大的。
    //   文字带 40..55、自研 Logo 带 8..71 全在 0..103 内，版面关系一个字没动。
    localparam IMG_HEIGHT = 104;
    localparam BPL        = IMG_WIDTH / 4;               // 200 拍/行
    localparam BPF        = BPL * IMG_HEIGHT;            // 20800 拍/帧
    // ⚠ 2026-09-17：帧数 1 → 3，用来**扫档位**（一帧一个档位），在屏上验证 "M6"/"M7"
    //   的字形（M6 = 帧差运动检测、M7 = 直方图均衡）。
    //   第 0 帧仍然用 INFO_MODE=3、激励与改造前逐 bit 相同 —— 零扰动等价性
    //   （gen_equiv_tb.py 会把帧数与档位表改回单帧）靠的就是这一点。
    // ⚠ 2026-09-20：帧数 3 → 6，为的是**一次跑完第 38~43 格的全部四种字**：
    //     f0 档位 3 但类别非零  → 必须仍显示 "TARGET"（证明"只在 COLOR 档报颜色"这条门控）
    //     f1 档位 6 / f2 档位 7 → "TARGET"
    //     f3 档位 5 类别 0      → "RED   "
    //     f4 档位 5 类别 1      → "GRN   "
    //     f5 档位 5 类别 2      → "BLU   "
    //   加 `+cnt0` 再跑一次 ⇒ 六帧全变 "NONE  "（第五种字）。
    //   合起来 = 五种显示情形**一次跑全**，不用为每个类别各跑一遍。
    localparam NFRAME     = 6;
    localparam FRAMES     = NFRAME;
    localparam NBEAT      = BPL * IMG_HEIGHT * FRAMES;   // 124800 拍（必须 < 131072，见文件头）
    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;
    localparam TAIL_CYC   = 16;

    // OSD 版面（必须与 Python 校验器一致；校验器从 dump 首行读取，不再写死）
    // ⚠ TEXT_Y 必须落在 Logo 带内（LOGO_Y=8 起、高 64 → 8..71），否则"文字优先于
    //   Logo"这条优先级规则永远不会被激发。原值 88 与 Logo 带不重叠，等于没测。
    localparam LOGO_X = 40;
    localparam LOGO_Y = 8;
    localparam TEXT_X = 0;
    localparam TEXT_Y = 40;                    // 落在 8..71 内，与 Logo 带重叠
    // 安路官方 Logo（v1.4/v1.5）：真实版面 (0,0) 160x160（ERAM 位图，见 alg_logo_eram.v）
    localparam ANLOGO_X = 0;
    localparam ANLOGO_Y = 0;
    localparam ANLOGO_W = 160;
    localparam ANLOGO_H = 160;

    // 档位表：第 0 帧用 INFO_MODE（=3，与改造前一致）；f1/f2 扫 M6 / M7；
    // f3~f5 是 COLOR（M5），用来把类别名的三种取值都画上屏。
    // 校验器从 dump 首行的档位表 + 类别表读到同一个调度，不需要额外的逐拍列。
    localparam INFO_MODE = 3;
    localparam [10:0] MODE_LIST0 = 11'd3;      // "M3"（与改造前的单帧逐 bit 相同）
    localparam [10:0] MODE_LIST1 = 11'd6;      // "M6" 帧差运动检测
    localparam [10:0] MODE_LIST2 = 11'd7;      // "M7" 直方图均衡
    localparam [10:0] MODE_LIST3 = 11'd5;      // "M5" 颜色目标检测（COLOR）
    // 逐帧的颜色类别（0=R / 1=G / 2=B）。f0 故意给非零，用来验证"非 COLOR 档不报颜色"。
    localparam [1:0]  CLS_LIST0 = 2'd2;
    localparam [1:0]  CLS_LIST1 = 2'd1;
    localparam [1:0]  CLS_LIST2 = 2'd2;
    localparam [1:0]  CLS_LIST3 = 2'd0;
    localparam [1:0]  CLS_LIST4 = 2'd1;
    localparam [1:0]  CLS_LIST5 = 2'd2;
    // 逐帧的**跟踪编号**（0..99）。故意取三个不同量级，把两位十进制的三条路径都走一遍：
    //   f3 = 1  → 显示 "01"（十位 = 0，最容易写错成空白）
    //   f4 = 12 → 显示 "12"（十位 = 1）
    //   f5 = 99 → 显示 "99"（十位 = 9，比较链的最后一档；也是 RTL 的饱和值）
    // ⚠ 只用 <= 99 的值：RTL 的契约就是 0..99（饱和在 99）。超过 99 的行为不在契约内，
    //   判据也不该假装能判它。
    localparam [7:0]  TID_LIST0 = 8'd0;
    localparam [7:0]  TID_LIST1 = 8'd0;
    localparam [7:0]  TID_LIST2 = 8'd0;
    localparam [7:0]  TID_LIST3 = 8'd1;
    localparam [7:0]  TID_LIST4 = 8'd12;
    localparam [7:0]  TID_LIST5 = 8'd99;
    localparam INFO_FPS  = 32'h0000_0042;      // 低字节 0x42 → 显示 '4''2'
    localparam INFO_LAT  = 11'd137;
    localparam INFO_X    = 11'd2047;
    localparam INFO_Y    = 11'd600;
    // 2026-09-20：localparam → parameter，为的是能 `vsim -gINFO_CNT=0` 覆盖。
    //   动机：屏上第 25~30 格现在显示 "TARGET"（命中数非零）或 "NONE"（为零），
    //   而原来命中数写死成 7 ⇒ **NONE 那一支从来没被激励过**，等于没验。
    //   改成参数后，默认值这一跑覆盖 TARGET，加一次 -gINFO_CNT=0 覆盖 NONE，
    //   两次合起来才算把这条通路验完。值会写进 dump 头，判据据此算期望，不靠猜。
    parameter INFO_CNT  = 32'h0000_0007;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [95:0] stim  [0:NBEAT-1];

    reg [31:0] cyc;
    reg        rst_n;

    // ⚠ 控制信号必须与数据**同一沿**产生，否则 TB 自己就把它们错开一拍，
    //   看上去像 DUT 的控制延迟不对（本 TB 踩过这个坑）。这里把 tvalid/tlast/tuser
    //   全部做成寄存器、与 I_tdata 的地址（r_beat）在同一沿更新，三者严格同拍。
    reg [31:0] r_beat;
    wire drv_valid = (cyc >= START_CYC) && (r_beat < NBEAT);

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    wire        I_tready;

    reg  [10:0] I_info_mode;
    reg  [31:0] I_info_fps;
    reg  [10:0] I_info_lat;
    reg  [10:0] I_info_x;
    reg  [10:0] I_info_y;
    reg  [31:0] I_info_cnt;
    reg  [1:0]  I_info_class;
    reg  [7:0]  I_info_tid;

    // 当前帧号（0..NFRAME-1）→ 本帧档位。校验器按 dump 首行的档位表复算同一个调度。
    // ⚠ 声明必须在引用它的 always 之前（Verilog-2001 不做前向引用）。
    wire [2:0]  w_frame_now = (r_beat / BPF);
    wire [10:0] w_mode_now  = (w_frame_now == 3'd1) ? MODE_LIST1 :
                              (w_frame_now == 3'd2) ? MODE_LIST2 :
                              (w_frame_now == 3'd3) ? MODE_LIST3 :
                              (w_frame_now == 3'd4) ? MODE_LIST3 :
                              (w_frame_now == 3'd5) ? MODE_LIST3 : MODE_LIST0;
    wire [1:0]  w_cls_now   = (w_frame_now == 3'd1) ? CLS_LIST1 :
                              (w_frame_now == 3'd2) ? CLS_LIST2 :
                              (w_frame_now == 3'd3) ? CLS_LIST3 :
                              (w_frame_now == 3'd4) ? CLS_LIST4 :
                              (w_frame_now == 3'd5) ? CLS_LIST5 : CLS_LIST0;
    wire [7:0]  w_tid_now   = (w_frame_now == 3'd1) ? TID_LIST1 :
                              (w_frame_now == 3'd2) ? TID_LIST2 :
                              (w_frame_now == 3'd3) ? TID_LIST3 :
                              (w_frame_now == 3'd4) ? TID_LIST4 :
                              (w_frame_now == 3'd5) ? TID_LIST5 : TID_LIST0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_beat  <= 32'd0;
            I_tdata <= 96'd0;
            I_tvalid <= 1'b0;
            I_tlast <= 1'b0;
            I_tuser <= 1'b0;
            I_info_mode <= MODE_LIST0;
            I_info_class <= CLS_LIST0;
            I_info_tid   <= TID_LIST0;
        end else if (drv_valid) begin
            r_beat   <= r_beat + 32'd1;
            I_tdata  <= stim[r_beat];
            I_tvalid <= 1'b1;
            I_tlast  <= ((r_beat % BPL) == (BPL - 1));
            I_tuser  <= ((r_beat % BPF) == 0);
            // 档位与类别随帧切换：与 I_tdata 同一沿更新（同一份 beat 的输入相位）
            I_info_mode  <= w_mode_now;
            I_info_class <= w_cls_now;
            I_info_tid   <= w_tid_now;
        end else begin
            I_tvalid <= 1'b0;
            I_tlast  <= 1'b0;
            I_tuser  <= 1'b0;
        end
    end

    // 当前总线上那一拍的编号：r_beat 与 I_tdata 在同一沿更新，dump 取沿前值，
    // 所以沿前的 r_beat 正是本拍总线上那份 stim 的编号（不再打拍，避免引入相位）。
    reg [31:0] beat_idx;
    always @(*) beat_idx = I_tvalid ? r_beat : 32'd0;

    wire [95:0] O_tdata;
    wire        O_tvalid;
    wire        O_tlast;
    wire        O_tuser;
    wire        O_tready;

    osd_mixer #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT),
        .ANLOGO_X   (ANLOGO_X),
        .ANLOGO_Y   (ANLOGO_Y),
        .LOGO_X     (LOGO_X),
        .LOGO_Y     (LOGO_Y),
        .TEXT_X     (TEXT_X),
        .TEXT_Y     (TEXT_Y)
    ) dut (
        .I_clk       (clk),
        .I_rst_n     (rst_n),
        .I_tdata     (I_tdata),
        .I_tvalid    (I_tvalid),
        .I_tlast     (I_tlast),
        .I_tuser     (I_tuser),
        .I_tready    (I_tready),
        .I_info_mode (I_info_mode),
        .I_info_fps  (I_info_fps),
        .I_info_lat  (I_info_lat),
        .I_info_x    (I_info_x),
        .I_info_y    (I_info_y),
        .I_info_cnt  (I_info_cnt),
        .I_info_class(I_info_class),
        .I_info_tid  (I_info_tid),
        .O_tdata     (O_tdata),
        .O_tvalid    (O_tvalid),
        .O_tlast     (O_tlast),
        .O_tuser     (O_tuser),
        .O_tready    (O_tready)
    );

    assign I_tready = 1'b1;                     // 全链路不反压

    integer fd;
    integer fp;
    integer i;

    // ---- 影子文字面：TB 侧独立算出"每拍 bus 上那份 stim 的坐标 + 规格命中" ----
    // stim[beat] 的像素 (x,y) 由 beat 唯一决定（单射值图）：y = beat/BPL，x = 4*(beat%BPL)
    // 这里把 spec_hit 打 6 拍，Python 端扫延迟即可定出 DUT 的真实相位。
    reg [5:0]  sh_hit  [0:6];
    reg [5:0]  sh_xb   [0:6];
    reg [10:0] sh_y    [0:6];
    integer    si;
    reg [10:0] tb_xb, tb_y;
    wire [3:0] tb_char_row = (tb_y - 11'd88) & 4'hF;

    always @ (*) begin
        tb_xb = ((beat_idx % BPL) << 2);
        tb_y  = beat_idx / BPL;
    end
    reg [23:0] p0, p1, p2, p3;
    reg [95:0] pw;

    // 像素值图（严格单射，且**每个像素自带拍号**，校验器可独立定位相位）：
    //     pix = (beat << 7) | (x[4:0] << 2) | ch        x = beat % 32 , ch = 0..3
    //   · beat 18 位（本 TB 共 124800 拍）、x 取 5 位（每行 200 拍 = 800 像素）、ch 2 位
    //     ⇒ (i<<7) 最大 124799*128 = 15974272 < 2^24 ✓ **不会溢出**。
    //       ⚠ 这条余量只剩 6%：**再加帧或加高之前，先算 NBEAT<<7 是否还装得下**。
    //       （2026-09-20 帧数 3→6 时就是这里溢出了，见文件头那条警告。）
    //     ⇒ 总宽 19 位，24 位足够，**不会溢出**（早期版本用 (beat<<7)|(x<<2)|ch
    //       但 x 取了 12 位，beat 稍大就溢出串位，导致模型与 DUT 假性不符 —— 已修）
    //   · 唯一反解：beat = pix >> 7（x = pix[6:2]，ch = pix[1:0]）
    //   · 全部用定宽移位/加法拼装：ModelSim 10.3c 对"含非 2 的幂宽度操作数的
    //     拼接"会静默算错（实测 {8'h40,8'h00,10'h000,4'h0} 求值成 0），故不写拼接。
    initial begin
        fd = $fopen("dump_osd.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_osd.txt");
            $finish;
        end
        fp = $fopen("probe_osd.txt", "w");
        if (fp == 0) begin
            $display("FATAL: cannot open probe_osd.txt");
            $finish;
        end
        for (i = 0; i < NBEAT; i = i + 1) begin
            p0 = (i << 7) + ((i % 32) << 2) + 24'd0;
            p1 = (i << 7) + ((i % 32) << 2) + 24'd1;
            p2 = (i << 7) + ((i % 32) << 2) + 24'd2;
            p3 = (i << 7) + ((i % 32) << 2) + 24'd3;
            pw = {p0, p1, p2, p3};
            stim[i] = pw;
        end
        $display("TB check: stim[0]=%h stim[1]=%h stim[NBEAT-1]=%h",
                 stim[0], stim[1], stim[NBEAT-1]);
        // 2026-09-20：末尾追加 INFO_CNT（第 19）与 INFO_Y（第 20）。判据要靠它们算
        //   屏上该显示什么（第 25~29 格是 Y 坐标、第 31~36 格是 TARGET/NONE）。
        //   **追加在末尾**，老 dump 少字段时判据取默认值，仍然能读。
        // 2026-09-20 再追加（第 21~27）：MODE_LIST3（= COLOR 档）与逐帧类别 CLS_LIST0..5。
        //   类别不再是"有没有"两态，而是 0/1/2 三态 + 档位门控，判据必须知道逐帧期望值。
        // 2026-09-20 再追加（第 28~33）：逐帧**跟踪编号** TID_LIST0..5（进阶 2.5(2)）。
        $fwrite(fd, "H %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                IMG_WIDTH, IMG_HEIGHT, LOGO_X, LOGO_Y, TEXT_X, TEXT_Y,
                INFO_MODE, INFO_FPS, INFO_LAT, INFO_X,
                ANLOGO_X, ANLOGO_Y, ANLOGO_W, ANLOGO_H,
                NFRAME, MODE_LIST0, MODE_LIST1, MODE_LIST2, INFO_CNT, INFO_Y,
                MODE_LIST3,
                CLS_LIST0, CLS_LIST1, CLS_LIST2, CLS_LIST3, CLS_LIST4, CLS_LIST5,
                TID_LIST0, TID_LIST1, TID_LIST2, TID_LIST3, TID_LIST4, TID_LIST5);
        $display("TB: loaded %0d beats, BPL=%0d BPF=%0d", NBEAT, BPL, BPF);
    end

    initial begin
        cyc         = 32'd0;
        rst_n       = 1'b0;
        I_info_mode = INFO_MODE[10:0];
        I_info_fps  = INFO_FPS;
        I_info_lat  = INFO_LAT;
        I_info_x    = INFO_X;
        I_info_y    = INFO_Y;
        // 2026-09-20：加 `+cnt0` 强制命中数为 0 ⇒ 激励屏上 "NONE" 那一支。
        //   为什么不用 `-gINFO_CNT=0` 覆盖参数：实测那个参数覆盖没生效
        //   （dump 头第 19 字段读出来是 9315，源里写的是 7，原因未查明）。
        //   plusarg 是本项目一直在用的机制（`+frames=` / `+mokey` / `+m67`），
        //   行为确定、不用猜。
        I_info_cnt  = $test$plusargs("cnt0") ? 32'd0 : INFO_CNT;
        I_info_class = CLS_LIST0;
        I_info_tid   = TID_LIST0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", cyc);
    end

    // 数据拍号：r_beat 就是"本拍总线上那份 stim 的编号"，dump 直接打印它
    // （沿前采样 = 该拍正在驱动的值），所以 beat 列与 I_tdata/I_tlast 天然同拍。
    // 列序：0 cyc | 1-4 输入控制/数据 | 5-8 输出控制/数据 | 9-16 命中探针
    //   | 17-18 r_x/r_y | 19-20 r_x_now/r_y_now | 21-22 计数器 | 23 beat
    //   | 24-25 判据坐标沿前副本 | 26 字库索引 | 27 字模行 | 28 字库位图
    wire [10:0] w_rx_pre = dut.r_x;
    wire [10:0] w_ry_pre = dut.r_y;

    always @(posedge clk) begin
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %b %b %b %b %b %b %b %b %h %h %h %h %h %h %0d %h %h %h %h %h\n",
                cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata,
                dut.w_logo_hit0, dut.w_logo_hit1, dut.w_logo_hit2, dut.w_logo_hit3,
                dut.w_pix_text_hit[3], dut.w_pix_text_hit[2],
                dut.w_pix_text_hit[1], dut.w_pix_text_hit[0],
                {5'b0, dut.r_x}, {5'b0, dut.r_y},
                {5'b0, dut.r_x_now}, {5'b0, dut.r_y_now},
                {2'b0, dut.r_x_grp}, {5'b0, dut.r_y_pos},
                beat_idx,
                {5'b0, w_rx_pre}, {5'b0, w_ry_pre},
                {8'h00, dut.w_rom_index}, {12'h000, dut.w_txt_row},
                dut.w_glyph_bits);
        // 诊断文件（不影响 dump_osd.txt 的列格式）：命中/列/字符/O_tdata 全量
        $fwrite(fp, "%0d %b %b %b %b %h %h %h %h %h %h %h %b %b %h %h %0d\n",
                cyc,
                dut.w_pix_text_hit[3], dut.w_pix_text_hit[2],
                dut.w_pix_text_hit[1], dut.w_pix_text_hit[0],
                {5'b0, dut.r_x}, {5'b0, dut.r_y},
                {4'b0, dut.w_txt_col0}, dut.w_glyph_bits,
                {2'b0, dut.w_txt_col_base},
                {5'b0, dut.w_txt_ci}, O_tdata,
                dut.w_txt_incol, dut.w_txt_inrow,
                {12'h000, dut.w_txt_row}, {8'h00, dut.w_rom_index},
                beat_idx);
        cyc <= cyc + 32'd1;
        if (cyc >= (START_CYC + NBEAT + TAIL_CYC)) begin
            $fclose(fd);
            $fclose(fp);
            $display("TB: done, wrote %0d cycles", cyc + 1);
            $finish;
        end
    end

endmodule
