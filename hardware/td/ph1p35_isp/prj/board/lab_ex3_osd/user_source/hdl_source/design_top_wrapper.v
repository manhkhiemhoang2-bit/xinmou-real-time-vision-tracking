

module design_top_wrapper (
    input wire        I_sys_clk,
    input wire        I_rst_n,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    // ★2026-10-02 [2]=KEY4(C7)：M5 颜色档位切换。低=按下（板上 10K 上拉），与 [0]/[1] 同语义。
    inout wire [2:0]  I_button,
    // ★2026-10-02 深夜：板载拨码 SW1 = A4（官方 key_sw.adc key[4]）。低=拨下=AUTO，高=固定红。
    input wire        I_gear_sw,
    // ★2026-10-03 夜：拨码 SW3 = E11（官方 key_sw.adc key[5]）：上=关AE，下=开AE
    input wire        I_ae_sw,
input wire        I_gim_en,   // ★SW2(B4)：高=允许舵机牵引，低=只识别不牵引

    // ---- 三轴云台（2026-09-23 加；扩展要求 2.4(3)「机电联动控制」）--------------
    //   ★★ 2026-09-28 更正：脚位依据**官方《新HX1P35A开发板手册-HDL版2604.pdf》**
    //     已逐球核对：这 5 个球号【全部只出现在手册的 J1 表里，一个都不在 J2 表】
    //     ⇒ **云台接扩展口 J1（板左侧那个 40 芯座）**，不是 J2（板右侧）：
    //        第 14 脚 = 球 J13（SCL）      第 23 脚 = 球 K13（SDA）
    //        第 15 脚 = 球 J14（pan）      第 24 脚 = 球 L15（tilt）
    //        第 25 脚 = 球 L16（roll）
    //     电源：同口 第 11 脚 = VCC5V、第 12 脚 = GND、第 29 脚 = 3.3V、第 30 脚 = GND
    //
    //   ⚠⚠ 原写 "J2 第 13~17 脚 / GPIOB_12~16" **是错的**，两个错叠在一起：
    //     · **球号 J14 长得像"座子 J、第 14 脚"**，被误读成了脚位号 ——
    //       但球号是 FPGA 芯片的焊球（J 列 14 行），跟排针脚号无关。
    //     · 手册**通篇没有 GPIOB**，这 5 个球在手册里都归在与 J1 同表的那一组。
    //   完整对照表与证据等级见 `pin.adc` 的云台注释段。
    //   ⚠ 上板第一件事：先在 第15脚(J14) 出一路 PWM 确认舵机动，再用万用表通断档
    //     逐个验：第14脚↔J13、第15脚↔J14、第23脚↔K13、第24脚↔L15、第25脚↔L16。
    //   IMU 的 I2C 两线（J1 第 14 / 23 脚）。总线上**必须有上拉电阻**：
    //   模块自带 4.7k 就用模块的，没有的话在模块侧补两个 4.7k 到 3V3。
 output wire       O_mcu_pwm_yaw,     // MCU GPIO0 -> yaw 舵机（J14）
      output wire       O_mcu_pwm_pitch,   // MCU GPIO1 -> pitch 舵机（L15）
      output wire       O_mcu_pwm_roll,    // MCU GPIO2 -> roll 舵机（L16）
      output wire       O_mcu_uart0_tx,    // UART0 TX -> H1
      input  wire       I_mcu_uart0_rx,    // UART0 RX <- J1
      inout  wire       IO_mcu_i2c_scl,    // J13（⚠ 前提 I2C_Available=1）
      inout  wire       IO_mcu_i2c_sda,    // K13
    output wire       O_screen_pwm,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n,

    output wire[3:0]  O_led,
    output wire       O_buzzer
);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
    wire S_isp_ae_req; wire [15:0] S_isp_ae, S_isp_ag;   // ★2026-10-03 后端 AE 三线
	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	wire [10:0]	S_ISP_O_bbox_x0;
	wire [10:0]	S_ISP_O_bbox_x1;
wire [10:0]	S_gim_bw;                       // ★目标宽 = x1-x0+1（valid=0 时为 0）
wire [10:0]	S_gim_bh;                       // ★目标高
wire [1:0] 	S_gim_cls;                      // ★颜色类别（来自 ISP 的 O_color_class）
wire [10:0]	S_gim_roi_x0, S_gim_roi_x1, S_gim_roi_y0, S_gim_roi_y1;
wire        	S_gim_roi_en;
wire        	S_isp_auto;   // ★AUTO 子档标志（isp_top 输出）

	wire [10:0]	S_ISP_O_bbox_y0;
	wire [10:0]	S_ISP_O_bbox_y1;
	wire 			S_ISP_O_bbox_valid;
// ★2026-10-22 由 bbox 导出宽高（无效时给 0，MCU 据此判"目标太大/太小"）
//   bbox 无效时 x0 是哨兵 11'h7FF、x1 为 0，直接相减会回绕 ⇒ 用 valid 门控。
assign S_gim_bw = (S_ISP_O_bbox_valid && (S_ISP_O_bbox_x1 >= S_ISP_O_bbox_x0))
                ? (S_ISP_O_bbox_x1 - S_ISP_O_bbox_x0 + 11'd1) : 11'd0;
assign S_gim_bh = (S_ISP_O_bbox_valid && (S_ISP_O_bbox_y1 >= S_ISP_O_bbox_y0))
                ? (S_ISP_O_bbox_y1 - S_ISP_O_bbox_y0 + 11'd1) : 11'd0;
//   颜色类别：isp_top 目前没有引出 O_color_class，先固定 0（红族）；
//   以后要"只追指定颜色"再把该信号引上来。
assign S_gim_cls = 2'd0;
	wire [31:0]	S_ISP_O_pix_count;
	wire [ 3:0]	S_ISP_O_mode;

	// ★2026-10-20 I2C 坐标通路：Fabric I2C 从机（gim_i2c_slave @0x50）与 ps_wrapper 之间的观测网
	//   S_i2c_*_obs    : ps_wrapper 引出的 I2C pad 电平观测（从机只采样，绝不驱动 SCL）
	//   S_fpga_sda_pull: 从机的开漏拉低请求，送回 ps_wrapper 与 MCU 的 sda_sel 线或
	wire		S_i2c_scl_obs;
	wire		S_i2c_sda_obs;
	wire		S_fpga_sda_pull;
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;

// ★★2026-10-24 采集→显示总延迟：把 HDMI 侧帧首转成"每帧翻转一次"的单比特信号，
//   送给 isp_top 里的 e2e_lat（那边用两级触发器同步后取沿）。
//   为什么只传翻转而不传脉冲：跨时钟域传窄脉冲会丢，传慢速翻转最稳。
reg  r_disp_tgl = 1'b0;
wire w_disp_tgl;

always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n)     r_disp_tgl <= 1'b0;
    else if (S_hdmi_user)  r_disp_tgl <= ~r_disp_tgl;
end
assign w_disp_tgl = r_disp_tgl;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    wire[3:0]   S_hdmi_debug_status;
    wire        S_lane_error_any;


    assign O_screen_pwm = 1'b1;
    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_video_out_vsync)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    assign S_hdmi_debug_status = {
        (|S_ddr_user_rd_data),
        S_ddr_user_rd_valid,
        S_vo_ddr_rd_en,
        S_vi_ddr_wr_en
    };
	
	assign O_cam_rst 	= 1'b1;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  
  ae_set u_ae_set (
      .I_clk(S_24m_clk),
      .I_rst(~S_rst_n),
      // ⚠ 2026-09-17：原来这里接 {I_button,2'b11}，把 KEY1(A9)/KEY2(B9) 拿去手动
      //   加减 AE/AG。但 ae_set 内部**没有消抖**（r_button_0 <= ~I_btn 直接两级打拍，
      //   按下期间每个时钟都在加减），手一按就会把 r_ag_set 一路压到下限 16，
      //   画面瞬间变暗——现场演示是地雷。而且这两只键现在要用来切档位/开关，
      //   所以把 I_btn 恒置 1（等于"从没按过"），AE/AG 回到上电默认值 3000/80。
      //   AE/AWB 的自动调节在传感器配置 IP 里，不受此处影响。
      .I_btn(4'b1111),
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      .O_ae_req(),      // ★2026-10-03 摘线：官方 ae_set(纯手动、I_btn 恒 1 从不触发) 让位
      .O_ae(),          //   给后端自动 AE；实例保留作恢复参考，杜绝双环同驱隐患。
      .O_ag()           // (摘线同上)
  );
  
    uicfgcs500_720p #(
      .CLK_DIV(24000000 / 100000 - 1)
  ) u_uicfgcs500 (
      .I_clk(S_24m_clk),  //系统时钟输入
      .I_rst_n(S_rst_n),  //系统复位输入
      .I_ae_req(S_isp_ae_req ),   // ★2026-10-03 由 isp_top 内后端 AE 驱动
      .I_ae   (S_isp_ae    ),
      .I_ag   (S_isp_ag    ),
      .O_cam_scl(O_cam_scl),  //I2C总线，SCL时钟
      .IO_cam_sda(IO_cam_sda),  //I2C总线，SDA数据
      .O_cfg_done(S_cam_cfg_done),  //摄像头寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done)  //AE配置完成
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "0dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// 原厂HD模式直接输出1280x720 RAW10，不再进行FPGA固定窗口裁剪。
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tuser  = S_axis_tuser;


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


//ISP算法顶层模块
isp_top u_isp_top (
.I_roi_en  (S_gim_roi_en ),
.I_disp_tgl(w_disp_tgl   ),   // ★HDMI 帧首翻转（跨时钟域单比特）
.O_geo_auto (S_isp_auto    ),
.I_roi_x0  (S_gim_roi_x0 ),
.I_roi_x1  (S_gim_roi_x1 ),
.I_roi_y0  (S_gim_roi_y0 ),
.I_roi_y1  (S_gim_roi_y1 ),
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_rst_n),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (),
.O_tready        (S_ISP_O_tready),
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.I_tready        (),
.O_bbox_x0       (S_ISP_O_bbox_x0),
.O_bbox_x1       (S_ISP_O_bbox_x1),
.O_bbox_y0       (S_ISP_O_bbox_y0),
.O_bbox_y1       (S_ISP_O_bbox_y1),
.O_bbox_valid    (S_ISP_O_bbox_valid),
.O_pix_count     (S_ISP_O_pix_count),
.O_mode          (S_ISP_O_mode),
.I_mode_key      (I_button[1] & I_button[2]),   // KEY3(B9) 或 KEY4(C7)：按下切下一档（alg_top 内部消抖）
                                              //   ★2026-10-05 十八修：KEY4 原悬空，与 KEY3 并接；低有效 ⇒ 用 &。
.I_he_key        (I_button[0]     ),   // 2026-09-20 直方图均衡开关：A9（板上丝印 KEY2）
      .I_gear_sw       (I_gear_sw       ),   // ★深夜改拨码 SW1(A4)：用户要求开关不是按键
      .I_ae_cfg_done(S_ae_cfg_done ),   // ★2026-10-03 后端 AE：官方 done 反馈给 isp 内 u_ae
      .O_ae_req      (S_isp_ae_req  ),   // ★后端 AE 三输出
      .O_ae          (S_isp_ae      ),
      .O_ag          (S_isp_ag      ),
      .I_ae_sw       (I_ae_sw       ),   // ★AE 使能拨码
.I_ref_clk       (S_24m_clk       )    // ★ 2026-10-01 诊断：拿 24MHz 当尺子量 MIPI 域真实时钟
  );


//检测结果外部控制：目标象限 LED + 蜂鸣器（扩展要求 2.4(3)）
// ⚠ 蜂鸣器极性（2026-09-17 对抗审查后改）：板上 Q9 = **PNP9012**，接法是
//   VCC_3V3 → Q9(发射极) → R38 15R → LS1(蜂鸣器) → GND，基极经 R33 2K2 到 BUZZER
//   网络，D1 4148 续流。PNP 高边驱动 ⇒ **基极拉低才导通** ⇒ 低有效。
//   旁证：pin.adc 给 O_buzzer 设了 PULLTYPE=PULLUP（配置/复位期间为高 = 不响），
//   与"低有效"自洽。所以这里显式把 BUZZ_ACT_LOW 置 1，不再用默认值。
//   若上板发现相反（一直响、有目标反而停），把这一个参数改回 1'b0 即可。
ext_ctrl #(
.BUZZ_ACT_LOW (1'b1)
) u_ext_ctrl (
.I_clk        (S_csi_rx_clk     ),
.I_rst_n      (S_rst_n         ),
.I_frame      (S_ISP_O_tuser   ),   // 每帧 1 拍；不可与 tvalid 相与（见 ext_ctrl 文件头）
.I_bbox_x0    (S_ISP_O_bbox_x0 ),
.I_bbox_x1    (S_ISP_O_bbox_x1 ),
.I_bbox_y0    (S_ISP_O_bbox_y0 ),
.I_bbox_y1    (S_ISP_O_bbox_y1 ),
.I_bbox_valid (S_ISP_O_bbox_valid),
.I_pix_count  (S_ISP_O_pix_count),
.O_led        (O_led           ),
.O_buzzer     (O_buzzer        )
  );

wire S_mcu_core_clk, S_mcu_timer_clk, S_mcu_pll_lock;
pll_mcua u_pll_mcua (
    .refclk    ( I_sys_clk       ),   // 板载晶振 C4
    .reset     ( ~I_rst_n        ),
    .clk0_out  ( S_mcu_core_clk  ),   // → MCU core_clk（300MHz）
    .clk1_out  ( S_mcu_timer_clk ),   // → MCU timer_clk（100MHz）
    .lock      ( S_mcu_pll_lock  )    // → 复位链
);

    // ★2026-10-05：旧 FPGA 云台（gim_top / gim_pwm3 / gim_imu_i2c / gim_imu_roll /
    //   gim_vis_ctl）已整体移除——三轴云台改由内嵌 RISC-V MCU 驱动，见下方 §MCU 云台段。



    //==========================================================================
    // 三轴云台 —— MCU 路线（RISC-V 硬核）：FPGA 检测 bbox → I2C 从机(0x50) → MCU → GPIO PWM
    //   ★2026-10-20：APB 路线已实测证伪（MCU 的 CPU 访问不到 Fabric APB），坐标改经
    //   I2C 总线（与 MPU6050 @0x68 共线）传给 MCU；三路舵机 PWM 全部由 MCU 产生，
    //   FPGA 侧不再有任何舵机/追踪控制逻辑（追踪控制律在 MCU 固件里）。
    //==========================================================================
    // MCU 复位链（高有效）：PLL lock 后再压 256 拍释放，否则 JTAG 连不上
    reg [7:0] r_mcu_por_cnt;
    reg       S_mcu_rst;
    always @(posedge I_sys_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            r_mcu_por_cnt <= 8'd0;
            S_mcu_rst     <= 1'b1;
        end else if (!S_mcu_pll_lock) begin
            r_mcu_por_cnt <= 8'd0;
            S_mcu_rst     <= 1'b1;
        end else if (r_mcu_por_cnt != 8'hFF) begin
            r_mcu_por_cnt <= r_mcu_por_cnt + 8'd1;
            S_mcu_rst     <= 1'b1;
        end else begin
            S_mcu_rst     <= 1'b0;
        end
    end

    // APB 总线（MCU 主）：★2026-10-20 从设备 gim_reg_apb 已移除 → 本段末尾给默认应答
    wire [19:0] S_apb_paddr;
    wire        S_apb_psel, S_apb_penable, S_apb_pwrite;
    wire [31:0] S_apb_pwdata, S_apb_prdata;
    wire [3:0]  S_apb_pstrobe;
    wire [2:0]  S_apb_pprot;
    wire        S_apb_pready, S_apb_pslverr;

    // ⚠ 当前 MCU IP（RISCV_F6F1D1P0_0）MCU_JTAG_SEL=0：JTAG 走板载 PAD 路径，
    //   不导出 jtag 到 Fabric，因此 ps_wrapper 没有 JTAG/UART1/GPIO3~7 端口。
    ps_wrapper u_ps (
        .I_core_clk     (S_mcu_core_clk ),
        .I_timer_clk    (S_mcu_timer_clk),
        .I_rst          (S_mcu_rst      ),

        .I_apb_clk      (I_sys_clk      ),   // APB 时钟 = 50MHz（手册 §4）
        .I_apb_rst      (S_mcu_rst      ),
        .O_apb_paddr    (S_apb_paddr    ),
        .O_apb_psel     (S_apb_psel     ),
        .O_apb_penable  (S_apb_penable  ),
        .O_apb_pwrite   (S_apb_pwrite   ),
        .O_apb_pwdata   (S_apb_pwdata   ),
        .O_apb_pstrobe  (S_apb_pstrobe  ),
        .O_apb_pprot    (S_apb_pprot    ),
        .I_apb_prdata   (S_apb_prdata   ),
        .I_apb_pready   (S_apb_pready   ),
        .I_apb_pslverr  (S_apb_pslverr  ),

        .O_uart0_tx     (O_mcu_uart0_tx ),
        .I_uart0_rx     (I_mcu_uart0_rx ),

        // ★2026-10-20 混合架构回撤：三路舵机恢复 MCU 直通（ps_wrapper 内无任何 mux）：
        //     gpio0(yaw/J14)   gpio1(pitch/L15)   gpio2(roll/L16)
        //   每个引脚唯一驱动源 = MCU GPIO；追踪控制律移到 MCU 固件，
        //   坐标由下面的 u_gim_i2c_slave 经 I2C 总线送出。
        .IO_gpio0       (O_mcu_pwm_yaw  ),
        .IO_gpio1       (O_mcu_pwm_pitch),
        .IO_gpio2       (O_mcu_pwm_roll ),

        .IO_i2c_scl     (IO_mcu_i2c_scl),
        .IO_i2c_sda     (IO_mcu_i2c_sda),

        // Fabric I2C 从机（@0x50）：pad 电平观测引出 + 开漏拉低请求送回
        .I_fpga_sda_pull (S_fpga_sda_pull),
        .O_i2c_scl_in    (S_i2c_scl_obs  ),
        .O_i2c_sda_in    (S_i2c_sda_obs  )
    );

    //==========================================================================
    // ★2026-10-20 I2C 坐标从机（gim_i2c_slave @0x50）：FPGA→MCU 唯一数据通路
    //   像素域：S_csi_rx_clk / S_rst_n / S_ISP_O_tuser + bbox 五根 + mode
    //   50MHz 域：I_sys_clk；SCL/SDA 观测来自 ps_wrapper，拉低请求送回 ps_wrapper
    //   （原 u_gim_track / u_gim_reg 例化已随 gim_track_top / gim_vis_ctl /
    //     gim_pwm3 / gim_reg_apb 移除，文件移入 bak_20261020_fpga_servo_removed/）
    //==========================================================================
    gim_i2c_slave #(
        .SLAVE_ADDR     (7'h50              )   // 写 0xA0 / 读 0xA1；与 MPU6050 @0x68 共线
    ) u_gim_i2c_slave (
        // ★2026-10-22 质量信息（MCU 做尺寸门/置信度门）
        .I_bbox_w      (S_gim_bw      ),
        .I_bbox_h      (S_gim_bh      ),
        .I_pix_cnt     (S_ISP_O_pix_count[15:0]),
        .I_auto_mode  (S_isp_auto    ),
        .I_track_en   (I_gim_en      ),
        .I_color_cls   (S_gim_cls     ),
        .O_roi_x0      (S_gim_roi_x0  ),
        .O_roi_x1      (S_gim_roi_x1  ),
        .O_roi_y0      (S_gim_roi_y0  ),
        .O_roi_y1      (S_gim_roi_y1  ),
        .O_roi_en      (S_gim_roi_en  ),
        .I_clk          (I_sys_clk          ),   // 50MHz（I2C 状态机域）
        .I_rst_n        (S_rst_n            ),

        .I_scl          (S_i2c_scl_obs      ),   // 只采样，绝不驱动
        .I_sda_in       (S_i2c_sda_obs      ),
        .O_sda_pull     (S_fpga_sda_pull    ),   // 开漏拉低请求 → ps_wrapper 线或

        .I_pix_clk      (S_csi_rx_clk       ),
        .I_pix_rst_n    (S_rst_n            ),
        .I_pix_frame    (S_ISP_O_tuser      ),   // 每帧一拍
        .I_bbox_x0      (S_ISP_O_bbox_x0    ),
        .I_bbox_x1      (S_ISP_O_bbox_x1    ),
        .I_bbox_y0      (S_ISP_O_bbox_y0    ),
        .I_bbox_y1      (S_ISP_O_bbox_y1    ),
        .I_bbox_valid   (S_ISP_O_bbox_valid ),
        .I_mode         (S_ISP_O_mode       )
    );

    // APB 从设备已移除（gim_reg_apb）：给 MCU 主机"数据 0、零等待、无错误"的默认应答，
    // 避免 prdata/pready/pslverr 悬空。CPU 本来就访问不到这条 APB，tie-off 无功能影响。
    assign S_apb_prdata  = 32'd0;
    assign S_apb_pready  = 1'b1;
    assign S_apb_pslverr = 1'b0;


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        .I_camera_frame_start ( S_ISP_O_tuser  ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    assign S_video_out_rst_n = S_hdmi_rst_n;

    video_out u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
.V_FrameSize  ( 750  ),   // ★ 2026-10-01 回退：757 导致显示器判"无 HDMI 信号"
    //   720p60 是 CEA 标准时序，垂直总数必须=750；很多显示器对标准模式严格比对，
    //   改成 757(60.0456Hz) 就认不出来 => 黑屏。
    //   ⇒ 锁相要反过来做：让【摄像头】去对齐显示器的 60.6061Hz（改 PLL 分频），
    //     显示器的时序保持标准不动。见 PLL CLKC1_DIV 的取值。
    
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    )
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_debug_status  ( S_hdmi_debug_status),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_hdmi_out_vsync  ),
        .I_video_in_de      ( S_hdmi_out_de     ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_hdmi_out_data   ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    
endmodule
