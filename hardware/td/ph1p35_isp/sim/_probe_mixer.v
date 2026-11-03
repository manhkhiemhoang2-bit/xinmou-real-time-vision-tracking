//==============================================================================
// _probe_mixer.v —— 临时诊断用（非交付物）：只跑官方版，统计 Logo 命中链上的
//   每一个环节，用来定位"为什么 S_osd_hit 全程为 0"。
//   激励帧格式与 tb_hdmi_mixer.v 完全一致。
//==============================================================================
`timescale 1ns/1ps

module tb_probe_mixer;
    localparam H_ACTIVE  = 200;
    localparam H_SYNC    = 16;
    localparam H_BP      = 24;
    localparam H_FP      = 8;
    localparam H_TOTAL   = H_SYNC + H_BP + H_ACTIVE + H_FP;
    localparam H_A0      = H_SYNC + H_BP;
    localparam V_ACTIVE  = 200;
    localparam V_SYNC    = 4;
    localparam V_BP      = 8;
    localparam V_FP      = 4;
    localparam V_TOTAL   = V_SYNC + V_BP + V_ACTIVE + V_FP;
    localparam V_A0      = V_SYNC + V_BP;
    localparam N_CYC     = H_TOTAL * V_TOTAL;
    localparam RST_CYC   = 8;
    localparam LFSR_SEED = 16'hACE1;
    localparam TRACE_LO  = 1000;
    localparam TRACE_HI  = 1060;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    initial begin
        rst_n = 1'b1;
        #1 rst_n = 1'b0;
        repeat (RST_CYC) @(posedge clk);
        #1 rst_n = 1'b1;
    end

    reg         I_vsync, I_hsync, I_de, I_user, I_last;
    reg  [3:0]  I_dbg;
    reg  [23:0] I_data;
    reg  [31:0] cyc;
    reg  [3:0]  rcnt;
    reg  [15:0] hp, vp, lfsr;

    wire [15:0] hp_n = (hp == H_TOTAL-1) ? 16'd0 : hp + 16'd1;
    wire [15:0] vp_n = (hp == H_TOTAL-1) ? ((vp == V_TOTAL-1) ? 16'd0 : vp + 16'd1) : vp;
    wire c_hsync = (hp_n < H_SYNC);
    wire c_act_h = (hp_n >= H_A0) && (hp_n < H_A0 + H_ACTIVE);
    wire c_vsync = (vp_n < V_SYNC);
    wire c_act_v = (vp_n >= V_A0) && (vp_n < V_A0 + V_ACTIVE);
    wire c_de    = c_act_v && c_act_h;
    wire c_user  = (vp_n == V_A0) && (hp_n == H_A0);
    wire c_last  = c_de && (hp_n == H_A0 + H_ACTIVE - 1);
    wire [15:0] lfsr_n = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    wire [23:0] c_data = { (8'h01 + {4'd0, vp_n[3:0]}), lfsr_n };

    wire        O_rd_en, O_vsync, O_hsync, O_de;
    wire [23:0] O_data;

    hdmi_mixer_official #(.H_OFFSET(128), .V_OFFSET(60), .IMG_WIDTH(1280),
                          .IMG_HEIGHT(720), .DEBUG_MODE(0)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_vsync(I_vsync), .I_video_hsync(I_hsync), .I_video_de(I_de),
        .I_video_user(I_user), .I_video_last(I_last), .I_debug_status(I_dbg),
        .O_video_rd_en(O_rd_en), .I_video_rd_data(I_data),
        .O_hdmi_vsync(O_vsync), .O_hdmi_hsync(O_hsync),
        .O_hdmi_de(O_de), .O_hdmi_data(O_data)
    );

    integer n_de, n_de2, n_box, n_hit, n_user, n_last;
    integer max_sy, max_sy2, max_sx, max_sx2;
    integer max_addr, min_addr_inbox, max_addr_inbox, n_addr_inbox;
    integer n_rom_hit_bit;
    reg [15:0] prev_de, prev_last, prev_user;

    initial begin
        cyc = 0; rcnt = 0; hp = 0; vp = 0; lfsr = LFSR_SEED;
        I_vsync = 1; I_hsync = 1; I_de = 0; I_user = 0; I_last = 0;
        I_dbg = 4'b1010; I_data = 0;
        n_de = 0; n_de2 = 0; n_box = 0; n_hit = 0; n_user = 0; n_last = 0;
        max_sy = 0; max_sy2 = 0; max_sx = 0; max_sx2 = 0;
        max_addr = 0; min_addr_inbox = 999999; max_addr_inbox = -1; n_addr_inbox = 0;
        n_rom_hit_bit = 0;
        prev_de = 0; prev_last = 0; prev_user = 0;
        $display("PROBE: start");
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rcnt <= rcnt + 4'd1;
            hp <= H_TOTAL-1; vp <= V_TOTAL-1; lfsr <= LFSR_SEED;
            I_vsync <= 1'b1; I_hsync <= (rcnt < 4) ? 1'b1 : 1'b0;
            I_de <= (rcnt >= 4); I_user <= 1'b0; I_last <= 1'b0;
            I_data <= 24'h123456 + {20'd0, rcnt};
        end else begin
            hp <= hp_n; vp <= vp_n; lfsr <= lfsr_n;
            I_vsync <= c_vsync; I_hsync <= c_hsync; I_de <= c_de;
            I_user <= c_user; I_last <= c_last; I_data <= c_data;
        end

        // ---- 统计（读沿前值） ----
        if (I_de    !== prev_de)   begin n_de   = n_de + 1;   prev_de   <= I_de;   end
        if (I_user  !== prev_user) begin n_user = n_user + 1; prev_user <= I_user; end
        if (I_last  !== prev_last) begin n_last = n_last + 1; prev_last <= I_last; end

        if (rst_n && cyc >= 10) begin
            if (dut.S_video_de_2d) n_de2 = n_de2 + 1;
            if (dut.S_y  > max_sy)  max_sy  = dut.S_y;
            if (dut.S_y_2d > max_sy2) max_sy2 = dut.S_y_2d;
            if (dut.S_x  > max_sx)  max_sx  = dut.S_x;
            if (dut.S_x_2d > max_sx2) max_sx2 = dut.S_x_2d;
            if (dut.S_logo_addr > max_addr) max_addr = dut.S_logo_addr;
            if (dut.S_video_de_2d && dut.S_x_2d < 160 && dut.S_y_2d < 160) begin
                n_addr_inbox = n_addr_inbox + 1;
                if (dut.S_logo_addr < min_addr_inbox) min_addr_inbox = dut.S_logo_addr;
                if (dut.S_logo_addr > max_addr_inbox) max_addr_inbox = dut.S_logo_addr;
                if (dut.S_logo_pixel[24]) n_rom_hit_bit = n_rom_hit_bit + 1;
            end
            if (dut.S_osd_hit) n_hit = n_hit + 1;

            if (cyc >= TRACE_LO && cyc <= TRACE_HI)
                $display("P cyc=%0d de=%b de2=%b x=%0d x2=%0d y=%0d y2=%0d lx=%0d ly=%0d addr=%0d px24=%b px=%h hit=%b",
                         cyc, I_de, dut.S_video_de_2d, dut.S_x, dut.S_x_2d, dut.S_y, dut.S_y_2d,
                         dut.S_logo_x, dut.S_logo_y, dut.S_logo_addr,
                         dut.S_logo_pixel[24], dut.S_logo_pixel, dut.S_osd_hit);
        end

        cyc <= cyc + 1;
        if (cyc >= RST_CYC + N_CYC + 4) begin
            $display("PROBE SUMMARY");
            $display("  de_transitions=%0d user_transitions=%0d last_transitions=%0d", n_de, n_user, n_last);
            $display("  de2_cycles=%0d  max_sx=%0d max_sy=%0d max_sx2=%0d max_sy2=%0d",
                     n_de2, max_sx, max_sy, max_sx2, max_sy2);
            $display("  max_logo_addr=%0d", max_addr);
            $display("  in_box_cycles=%0d  addr_in_box=[%0d,%0d]  rom_hit_bit_cycles=%0d",
                     n_addr_inbox, min_addr_inbox, max_addr_inbox, n_rom_hit_bit);
            $display("  S_osd_hit_cycles=%0d", n_hit);
            $finish;
        end
    end
endmodule
