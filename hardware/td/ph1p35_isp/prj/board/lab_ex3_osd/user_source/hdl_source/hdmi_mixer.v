//=============================================================================
//  hdmi_mixer.v  ——  HDMI 输出级：DDR 读使能 + 视频时序对齐 + 像素直通
//-----------------------------------------------------------------------------
//  本文件是 HX1P35A 板级工程（lab_ex3_osd 派生）的输出末级。
//
//  【2026-09-14 原创性旁路】官方原版 hdmi_mixer.v 内含安路 Logo ROM
//  (anlogic_logo_rom) 与字符库 (osd_char_lib) 叠加逻辑，会在最后一级把官方
//  Logo 盖在整幅画面上。该叠加对本次参赛作品有两点不可接受：
//    (1) 原创性：官方 Logo/字符资产出现在我们的显示通路里；
//    (2) 时序：Logo 地址计算 S_logo_y*160+S_logo_x 引入了乘法器
//        (DSPMULT) 与 95 扇出的 ROM 地址网络，是官方基线里最差路径
//        （HDMI_PIXEL_CLK 75 MHz，setup WNS 仅 0.103 ns）的来源。
//
//  旁路做法：像素在最后一级直通，不再叠加任何图形。
//  本模组只保留两项职责：
//    A. DDR 读使能  O_video_rd_en = I_video_de（组合直通，与官方一致）
//    B. 视频时序与像素的 3 级流水对齐（与官方 DEBUG_MODE=0 正常通路逐拍等价）
//
//  设计自己的 OSD（文字/Logo/参数叠加）在上游 isp_top 内的 osd_mixer 完成，
//  随像素一起写入 DDR，再从 DDR 读出，因此不需要在本级重复叠加。
//
//  【等价性说明】官方原版在 DEBUG_MODE=0（板级实例化取 0）时，输出级为：
//        if (S_osd_hit) O_hdmi_data <= S_osd_color;
//        else           O_hdmi_data <= S_video_data_2d;
//  其余 DEBUG_MODE=1/2/3 为测试图案分支，板级不可达。本文件保留其 else 分支
//  的直通行为，逐拍时序完全一致：
//        vsync/hsync/de : I_video_* -> _1d -> _2d -> O_hdmi_*   （3 级）
//        data           : I_video_rd_data -> _1d -> _2d -> O_hdmi_data（3 级）
//  即输出相对输入的固定延迟为 3 个 I_clk 周期，de 与 data 严格对齐。
//
//  端口表保持与官方一致，design_top_wrapper.v 无需改动。
//=============================================================================

module hdmi_mixer #(
    // 以下 4 个参数在官方原版中即未被使用（仅声明），此处保留是为了
    // design_top_wrapper.v 里的具名参数传递不至于报错。
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    // 板级取 0。保留该参数仅为兼容实例化；本模组不再有测试图案分支。
    parameter integer DEBUG_MODE = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_video_vsync,
    input  wire        I_video_hsync,
    input  wire        I_video_de,
    input  wire        I_video_user,      // 旁路后未使用，保留端口以兼容上层
    input  wire        I_video_last,      // 旁路后未使用，保留端口以兼容上层

    input  wire [3:0]  I_debug_status,    // 旁路后未使用，保留端口以兼容上层

    output wire        O_video_rd_en,
    input  wire [23:0] I_video_rd_data,

    output reg         O_hdmi_vsync,
    output reg         O_hdmi_hsync,
    output reg         O_hdmi_de,
    output reg  [23:0] O_hdmi_data
);

    //-------------------------------------------------------------------------
    // A. DDR 读使能：与官方原版一致，组合直通，不受复位影响
    //-------------------------------------------------------------------------
    assign O_video_rd_en = I_video_de;

    //-------------------------------------------------------------------------
    // B. 时序 / 像素 3 级流水
    //-------------------------------------------------------------------------
    reg        S_video_vsync_1d;
    reg        S_video_vsync_2d;
    reg        S_video_hsync_1d;
    reg        S_video_hsync_2d;
    reg        S_video_de_1d;
    reg        S_video_de_2d;
    reg [23:0] S_video_data_1d;
    reg [23:0] S_video_data_2d;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0;
            S_video_vsync_2d <= 1'b0;
            S_video_hsync_1d <= 1'b0;
            S_video_hsync_2d <= 1'b0;
            S_video_de_1d    <= 1'b0;
            S_video_de_2d    <= 1'b0;
            S_video_data_1d  <= 24'd0;
            S_video_data_2d  <= 24'd0;
            O_hdmi_vsync     <= 1'b0;
            O_hdmi_hsync     <= 1'b0;
            O_hdmi_de        <= 1'b0;
            O_hdmi_data      <= 24'd0;
        end
        else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            O_hdmi_vsync     <= S_video_vsync_2d;

            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            O_hdmi_hsync     <= S_video_hsync_2d;

            S_video_de_1d    <= I_video_de;
            S_video_de_2d    <= S_video_de_1d;
            O_hdmi_de        <= S_video_de_2d;

            S_video_data_1d  <= I_video_rd_data;
            S_video_data_2d  <= S_video_data_1d;
            O_hdmi_data      <= S_video_data_2d;   // 直通，不再叠加官方 Logo/字符
        end
    end

endmodule
