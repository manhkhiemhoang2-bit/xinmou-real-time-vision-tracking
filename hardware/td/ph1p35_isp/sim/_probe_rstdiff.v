//==============================================================================
// _probe_rstdiff.v —— 临时诊断用（非交付物）
//   目的：定量说明"改写版额外给 S_video_data_1d/2d 加了复位"到底造成多大差异。
//   两个 DUT 同一激励、同一复位；逐拍检查两版 O_hdmi_data 是否一个 X 一个非 X，
//   以及 X 出现在复位释放后的第几拍到第几拍、那几拍的 O_hdmi_de 是否为 0。
//==============================================================================
`timescale 1ns/1ps

module tb_probe_rstdiff;
    localparam RST_CYC = 8;
    localparam H_TOTAL = 248;
    localparam V_TOTAL = 216;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n;
    initial begin
        rst_n = 1'b1;
        #1 rst_n = 1'b0;
        repeat (RST_CYC) @(posedge clk);
        #1 rst_n = 1'b1;
    end

    reg I_vsync = 1'b1, I_hsync = 1'b1, I_de = 1'b0, I_user = 1'b0, I_last = 1'b0;
    reg [3:0] I_dbg = 4'b1010;
    reg [23:0] I_data = 24'h000000;
    reg [31:0] cyc = 0;

    // 简化激励：复位期间 de=1 且数据非零，复位释放后一直给变化的数据
    always @(posedge clk) begin
        cyc <= cyc + 1;
        I_data <= I_data + 24'h010203;
        I_de   <= (cyc >= 4);
        I_hsync <= (cyc < 2);
        I_vsync <= (cyc < 6);
    end

    wire        Oa_rd, Ob_rd, Oa_vs, Ob_vs, Oa_hs, Ob_hs, Oa_de, Ob_de;
    wire [23:0] Oa_data, Ob_data;

    hdmi_mixer #(.H_OFFSET(128), .V_OFFSET(60), .IMG_WIDTH(1280),
                 .IMG_HEIGHT(720), .DEBUG_MODE(0)) u_new (
        .I_clk(clk), .I_rst_n(rst_n), .I_video_vsync(I_vsync), .I_video_hsync(I_hsync),
        .I_video_de(I_de), .I_video_user(I_user), .I_video_last(I_last),
        .I_debug_status(I_dbg), .O_video_rd_en(Oa_rd), .I_video_rd_data(I_data),
        .O_hdmi_vsync(Oa_vs), .O_hdmi_hsync(Oa_hs), .O_hdmi_de(Oa_de), .O_hdmi_data(Oa_data));

    hdmi_mixer_official #(.H_OFFSET(128), .V_OFFSET(60), .IMG_WIDTH(1280),
                          .IMG_HEIGHT(720), .DEBUG_MODE(0)) u_official (
        .I_clk(clk), .I_rst_n(rst_n), .I_video_vsync(I_vsync), .I_video_hsync(I_hsync),
        .I_video_de(I_de), .I_video_user(I_user), .I_video_last(I_last),
        .I_debug_status(I_dbg), .O_video_rd_en(Ob_rd), .I_video_rd_data(I_data),
        .O_hdmi_vsync(Ob_vs), .O_hdmi_hsync(Ob_hs), .O_hdmi_de(Ob_de), .O_hdmi_data(Ob_data));

    integer x_only_new, x_only_off, eq_cycles, ne_cycles;
    integer first_x, last_x;
    wire a_is_x = (Oa_data === 24'hxxxxxx);   // 24 位全 X
    wire b_is_x = (Ob_data === 24'hxxxxxx);

    initial begin
        x_only_new = 0; x_only_off = 0; eq_cycles = 0; ne_cycles = 0;
        first_x = -1; last_x = -1;
    end

    always @(posedge clk) begin
        if (cyc >= RST_CYC && cyc <= RST_CYC + 10)
            $display("D cyc=%0d rst=%b I_de=%b | new: de=%b data=%h | off: de=%b data=%h",
                     cyc, rst_n, I_de, Oa_de, Oa_data, Ob_de, Ob_data);
        if (cyc >= RST_CYC) begin
            if (a_is_x && !b_is_x)
                x_only_new = x_only_new + 1;
            if (!a_is_x && b_is_x) begin
                x_only_off = x_only_off + 1;
                if (first_x < 0) first_x = cyc;
                last_x = cyc;
            end
            if (Oa_data === Ob_data) eq_cycles = eq_cycles + 1; else ne_cycles = ne_cycles + 1;
        end
        if (cyc == RST_CYC + 20) begin
            $display("RSTDIFF: after reset release -> only_official_is_X cycles=%0d (cyc %0d..%0d)",
                     x_only_off, first_x, last_x);
            $display("RSTDIFF: only_new_is_X cycles=%0d", x_only_new);
            $display("RSTDIFF: equal cycles=%0d  unequal cycles=%0d", eq_cycles, ne_cycles);
            $finish;
        end
    end
endmodule
