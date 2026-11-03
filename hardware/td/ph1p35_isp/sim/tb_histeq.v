//==============================================================================
// tb_histeq.v —— alg_histeq_96 的 ModelSim 测试平台（参数化驱动 + 逐拍延迟断言）
//
// 【只按规格观测，不读 DUT 内部（除了 dump 里的输出端口本身）】
//   · 延迟 = LAT 拍：TB 内部维护一条**独立**的 I_tvalid/I_tlast/I_tuser 移存器，
//     逐拍与 O_tvalid/O_tlast/O_tuser 比对，不符就计数（这是"钉死拍数"的主判据）；
//     另外用一台独立计数器实测"输入 tuser 沿 → 输出 tuser 沿"的拍数，作为交叉佐证。
//   · 拍数守恒：输入有效拍数 == 输出有效拍数（尾拍不丢、不多吐）。
//   · 消隐合同：测"帧末有效拍 → 下一帧 tuser"的最小拍数，供判据核 1700 拍的门槛。
//
// 【TB 只管"什么时候送"，不管"送什么"】
//   像素内容全部来自 gen_stim_histeq.py 生成的 stim_he_<场景>.hex（每行一个 96bit 拍），
//   所以气泡/行消隐/帧消隐/使能都不影响数据本身 ⇒ 判据不需要建模时序。
//
// 【dump 格式】（空格分隔，每行一拍）
//   cyc i_valid i_last i_user i_data i_beat o_valid o_last o_user o_data i_en
//     cyc     : 时钟计数（复位释放前后都算）
//     i_beat  : TB 的输入拍序号；i_valid=1 时它就是"本拍"的序号，=0 时是"下一拍"的序号
//     i_data  : 输入拍数据；无效期驱动成 IDLE_WORD（非零垃圾值，便于看出旁路是不是真透传）
//   判据侧的配对规则：**cyc 为 c 的输出行 ↔ cyc 为 c-LAT 的输入行**（逐位比）。
//
// 【用法】vsim -c -lib work tb_histeq -gIMG_WIDTH=64 ... +STIM=stim_he_x.hex +DUMP=dump_he_x.txt \
//                -do "run -all; quit -f"
//==============================================================================
`timescale 1ns / 1ps

module tb_histeq;

    //--------------------------------------------------------------------
    // 场景参数（run_histeq.py 用 vsim -g 传进来）
    //--------------------------------------------------------------------
    parameter IMG_WIDTH   = 1280;
    parameter IMG_HEIGHT  = 720;
    parameter FRAMES      = 2;
    parameter GAP_CYC     = 3000;      // 帧末有效拍 → 下一帧 tuser 之间的空拍数
    parameter LGAP_CYC    = 0;         // 行末空拍数
    parameter BUB_PERIOD  = 0;         // 每 BUB_PERIOD 个有效拍插 BUB_LEN 个气泡（0=不插）
    parameter BUB_LEN     = 0;
    parameter EN_MASK     = 8'hFF;     // bit k = 第 k 帧的 I_en
    parameter DUMP_ALL    = 1;         // 1 = 每个时钟都 dump
    parameter DUMP_HEAD_B = 0;         // DUMP_ALL=0：每帧头这么多有效拍进 dump
    parameter DUMP_TAIL_B = 0;         //            每帧尾这么多有效拍进 dump
    parameter RST_CYC     = 6;
    parameter LAT         = 2;         // 规格延迟（拍）
    parameter HALF_NS     = 8;         // 半周期 8ns ⇒ 16ns 周期（≈62.5MHz，同量级）

    localparam BPL       = IMG_WIDTH >> 2;               // 每行拍数
    localparam BPF       = BPL * IMG_HEIGHT;             // 每帧拍数
    localparam NBEAT     = BPF * FRAMES;
    localparam START_CYC = 40;
    localparam TAIL_CYC  = 40;
    localparam BUB_CNT   = (BUB_PERIOD > 0) ? ((BPF / BUB_PERIOD) + 1) : 0;
    localparam CY_FRAME  = BPF + BUB_CNT * BUB_LEN + (IMG_HEIGHT + 1) * LGAP_CYC + GAP_CYC;
    localparam TOTAL_CYC = START_CYC + FRAMES * CY_FRAME + TAIL_CYC;
    localparam [95:0] IDLE_WORD = 96'hDEAD_BEEF_DEAD_BEEF_DEAD_BEEF;

    //--------------------------------------------------------------------
    // 时钟与复位
    //--------------------------------------------------------------------
    reg clk = 1'b0;
    always #HALF_NS clk = ~clk;

    reg rst_n;

    //--------------------------------------------------------------------
    // 激励存储与驱动
    //--------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] cyc;
    reg [31:0] beat_idx;      // 下一个要送的拍序号（i_valid=1 时就是本拍序号）
    reg [31:0] gap_left;      // 还要空多少拍
    reg [7:0]  frame_idx;     // 已经开始的帧数-1（tuser 处 +1）

    wire w_present = (cyc >= START_CYC) && (beat_idx < NBEAT) && (gap_left == 32'd0);

    wire w_is_line_last  = ((beat_idx % BPL) == (BPL - 1));
    wire w_is_frame_last = ((beat_idx % BPF) == (BPF - 1));
    wire w_is_bub        = (BUB_PERIOD != 0) && (((beat_idx + 1) % BUB_PERIOD) == 0);
    wire [31:0] w_next_gap = w_is_frame_last ? GAP_CYC :
                             w_is_line_last  ? LGAP_CYC :
                             w_is_bub        ? BUB_LEN   : 32'd0;

    wire [95:0] I_tdata;
    wire        I_tvalid;
    wire        I_tlast;
    wire        I_tuser;
    wire        I_en;

    assign I_tdata  = w_present ? stim[beat_idx] : IDLE_WORD;
    assign I_tvalid = w_present;
    assign I_tlast  = w_present && w_is_line_last;
    assign I_tuser  = w_present && ((beat_idx % BPF) == 0);
    // 使能按"本拍所属帧"给：tuser 拍已经属于新帧 ⇒ 用 +1 后的帧号
    // 本拍所属的帧号（0 起），直接喂给 EN_MASK 索引。
    //
    // ⚠ 2026-09-20 修（**测试台错位，不是 RTL 错**）：
    //   原写法 `w_frame_eff = I_tuser ? (frame_idx+1) : frame_idx`，而 frame_idx 在
    //   **tuser 那一拍**才 +1、初值又是 0 ⇒ 第 f 帧实际读到的是 **EN_MASK[f+1]**，
    //   整整错一位。实测（const 场景，EN_MASK=7=0b0111）：
    //       第 0 帧 I_en = EN_MASK[1] = 1
    //       第 1 帧 I_en = EN_MASK[2] = 1
    //       第 2 帧 I_en = EN_MASK[3] = 0   ← 位 3 正好是 0，于是整帧走旁路
    //   判据侧按 `(en_mask >> f) & 1` 算（= 规格），两边差一位 ⇒ 6 个场景的
    //   "逐像素比对"全红，而 RTL 其实是对的。
    //   修法：frame_idx 改成"**已完成的帧数**"——在本帧最后一拍 +1，帧内所有拍
    //   （含 tuser 拍）看到的都是本帧号，不再需要任何补偿。
    wire [7:0] w_frame_eff = frame_idx;
    assign I_en = EN_MASK[w_frame_eff[2:0]];

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc       <= 32'd0;
            beat_idx  <= 32'd0;
            gap_left  <= 32'd0;
            frame_idx <= 8'd0;
        end else begin            cyc <= cyc + 32'd1;
            if (w_present) begin
                beat_idx <= beat_idx + 32'd1;
                gap_left <= w_next_gap;
                if (w_is_frame_last)              // 本帧最后一拍 ⇒ 本帧"已完成"
                    frame_idx <= frame_idx + 8'd1;
            end else if (gap_left != 32'd0) begin
                gap_left <= gap_left - 32'd1;
            end
        end
    end

    //--------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------
    wire [95:0] O_tdata;
    wire        O_tvalid;
    wire        O_tlast;
    wire        O_tuser;
    wire        O_tready;

    alg_histeq_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) dut (
        .I_clk    (clk),
        .I_rst_n  (rst_n),
        .I_tdata  (I_tdata),
        .I_tvalid (I_tvalid),
        .I_tlast  (I_tlast),
        .I_tuser  (I_tuser),
        .I_tready (1'b1),
        .I_en     (I_en),
        .O_tdata  (O_tdata),
        .O_tvalid (O_tvalid),
        .O_tlast  (O_tlast),
        .O_tuser  (O_tuser),
        .O_tready (O_tready)
    );

    //--------------------------------------------------------------------
    // 延迟断言：独立移存器（不看 DUT 内部）
    //--------------------------------------------------------------------
    reg [LAT-1:0] s_vld;
    reg [LAT-1:0] s_last;
    reg [LAT-1:0] s_user;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_vld  <= {LAT{1'b0}};
            s_last <= {LAT{1'b0}};
            s_user <= {LAT{1'b0}};
        end else begin
            s_vld  <= {s_vld[LAT-2:0],  I_tvalid};
            s_last <= {s_last[LAT-2:0], I_tlast};
            s_user <= {s_user[LAT-2:0], I_tuser};
        end
    end

    wire w_exp_vld  = s_vld[LAT-1];
    wire w_exp_last = w_exp_vld && s_last[LAT-1];
    wire w_exp_user = w_exp_vld && s_user[LAT-1];

    //--------------------------------------------------------------------
    // 计数与汇总
    //--------------------------------------------------------------------
    reg [31:0] n_in_vld, n_out_vld, n_in_last, n_out_last, n_in_user, n_out_user;
    reg [31:0] n_ctl_err;         // 控制信号与"延迟 LAT 拍的输入"不符的拍数
    reg [31:0] n_x;               // 输出数据里出现 X/Z 的拍数
    reg [31:0] n_ph_err;          // 输出侧 tlast/tuser 出现在无效拍上的次数

    // 独立计数器实测延迟：输入 tuser 沿 → 输出 tuser 沿
    reg [15:0] r_lat_cnt;
    reg        r_lat_arm;
    reg [15:0] O_lat_meas;

    // 帧末有效拍 → 下一帧 tuser 的最小间隔
    reg [31:0] r_gap_cnt;
    reg        r_gap_arm;
    reg [31:0] O_min_gap;

    wire w_x = (^O_tdata === 1'bx);      // 任意一位是 X/Z

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_in_vld <= 0; n_out_vld <= 0; n_in_last <= 0; n_out_last <= 0;
            n_in_user <= 0; n_out_user <= 0; n_ctl_err <= 0; n_x <= 0; n_ph_err <= 0;
            r_lat_cnt <= 0; r_lat_arm <= 0; O_lat_meas <= 0;
            r_gap_cnt <= 0; r_gap_arm <= 0; O_min_gap <= 32'hFFFFFFFF;
        end else begin
            if (I_tvalid) n_in_vld <= n_in_vld + 32'd1;
            if (O_tvalid) n_out_vld <= n_out_vld + 32'd1;
            if (I_tvalid && I_tlast) n_in_last <= n_in_last + 32'd1;
            if (O_tvalid && O_tlast) n_out_last <= n_out_last + 32'd1;
            if (I_tvalid && I_tuser) n_in_user <= n_in_user + 32'd1;
            if (O_tvalid && O_tuser) n_out_user <= n_out_user + 32'd1;
            if (w_x) n_x <= n_x + 32'd1;
            if ((!O_tvalid) && (O_tlast || O_tuser)) n_ph_err <= n_ph_err + 32'd1;

            // 复位释放后 LAT 拍才开始比（移存器要先填满）
            if ((cyc > RST_CYC + LAT) &&
                ((O_tvalid !== w_exp_vld) || (O_tlast !== w_exp_last) || (O_tuser !== w_exp_user)))
                n_ctl_err <= n_ctl_err + 32'd1;

            if (I_tvalid && I_tuser && !r_lat_arm) begin
                r_lat_arm <= 1'b1;
                r_lat_cnt <= 16'd0;
            end else if (r_lat_arm) begin
                if (O_tvalid && O_tuser) begin
                    O_lat_meas <= r_lat_cnt + 16'd1;
                    r_lat_arm  <= 1'b0;
                end else if (r_lat_cnt != 16'hFFFF) begin
                    r_lat_cnt <= r_lat_cnt + 16'd1;
                end
            end

            if (I_tvalid && I_tlast && w_is_frame_last) begin
                r_gap_arm <= 1'b1;
                r_gap_cnt <= 32'd0;
            end else if (r_gap_arm) begin
                if (I_tvalid && I_tuser) begin
                    r_gap_arm <= 1'b0;
                    if ((r_gap_cnt + 32'd1) < O_min_gap)
                        O_min_gap <= r_gap_cnt + 32'd1;
                end else begin
                    r_gap_cnt <= r_gap_cnt + 32'd1;
                end
            end
        end
    end

    //--------------------------------------------------------------------
    // dump：DUMP_ALL=1 逐拍；=0 只 dump 每帧头 DUMP_HEAD_B / 尾 DUMP_TAIL_B 个有效拍
    //       以及其后 6 拍（覆盖 LAT=2 的输出行，判据按"cyc 配对"读）
    //--------------------------------------------------------------------
    reg [8*260-1:0] stim_file;
    reg [8*260-1:0] dump_file;
    integer fd;

    wire [31:0] w_bif   = beat_idx % BPF;
    wire        w_in_win = (w_bif < DUMP_HEAD_B) || (w_bif >= (BPF - DUMP_TAIL_B));

    reg [3:0] r_ext;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_ext <= 4'd0;
        else if (w_present && w_in_win) r_ext <= 4'd6;
        else if (r_ext != 4'd0) r_ext <= r_ext - 4'd1;
    end

    wire w_dump_now = (DUMP_ALL != 0) ? 1'b1 : ((w_present && w_in_win) || (r_ext != 4'd0));

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) begin
            $display("TB_FATAL missing +STIM");
            $finish;
        end
        if (!$value$plusargs("DUMP=%s", dump_file)) begin
            $display("TB_FATAL missing +DUMP");
            $finish;
        end
        fd = $fopen(dump_file, "w");
        if (fd == 0) begin
            $display("TB_FATAL cannot open dump file");
            $finish;
        end
        $readmemh(stim_file, stim);
        $display("TB: BPL=%0d BPF=%0d NBEAT=%0d FRAMES=%0d GAP=%0d LGAP=%0d BUB=%0d/%0d EN_MASK=%02h DUMP_ALL=%0d",
                 BPL, BPF, NBEAT, FRAMES, GAP_CYC, LGAP_CYC, BUB_PERIOD, BUB_LEN, EN_MASK, DUMP_ALL);
    end

    initial begin
        cyc       = 32'd0;          // 上电即确定，避免第一拍 dump 出 X（判据要逐行 parse）
        beat_idx  = 32'd0;
        gap_left  = 32'd0;
        frame_idx = 8'd0;
        rst_n     = 1'b0;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (w_dump_now)
            $fwrite(fd, "%0d %b %b %b %h %0d %b %b %b %h %b\n",
                    cyc, I_tvalid, I_tlast, I_tuser, I_tdata, beat_idx,
                    O_tvalid, O_tlast, O_tuser, O_tdata, I_en);
        if (cyc >= TOTAL_CYC) begin
            $fclose(fd);
            $display("TB_SUMMARY in_valid=%0d out_valid=%0d in_last=%0d out_last=%0d in_user=%0d out_user=%0d lat_meas=%0d ctl_err=%0d x_cnt=%0d ph_err=%0d min_gap=%0d cyc=%0d",
                     n_in_vld, n_out_vld, n_in_last, n_out_last, n_in_user, n_out_user,
                     O_lat_meas, n_ctl_err, n_x, n_ph_err, O_min_gap, cyc);
            $display("TB_DONE");
            $finish;
        end
    end

endmodule
