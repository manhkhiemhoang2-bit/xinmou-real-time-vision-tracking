module isp_top (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input 			O_tready		,
    input 			I_ref_clk		,
    output [127:0] 	O_tdata			,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output 			I_tready		,
    output [10:0] 	O_bbox_x0		,
    output [10:0] 	O_bbox_x1		,
    output [10:0] 	O_bbox_y0		,
    output [10:0] 	O_bbox_y1		,
    output 			O_bbox_valid	,
    output [31:0] 	O_pix_count		,
    output [ 3:0] 	O_mode			,
    input 			I_mode_key,
    input 			I_he_key,
    input 			I_gear_sw,
    input  wire         I_ae_cfg_done,
    output wire         O_ae_req,
    output wire [15:0]  O_ae,
    output wire [15:0]  O_ag,
    output wire         O_geo_auto,
    input  wire         I_ae_sw,
    input  wire         I_roi_en,
    input  wire [10:0]  I_roi_x0,
    input  wire [10:0]  I_roi_x1,
    input  wire [10:0]  I_roi_y0,
    input  wire [10:0]  I_roi_y1,
    input  wire         I_disp_tgl
);
 
  wire         m_aixs_tvalid;  //synthesis keep 
  wire [127:0] m_aixs_tdata;   //synthesis keep 
  wire         m_aixs_tuser;   //synthesis keep 
  wire         m_aixs_tlast;   //synthesis keep 
  wire         m_aixs_tready;  //synthesis keep 
  
  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep 

  wire         awb_O_tlast;   //synthesis keep 
  wire         awb_O_tuser;   //synthesis keep 
  wire [ 95:0] awb_O_tdata;   //synthesis keep 
  wire         awb_O_tvalid;  //synthesis keep 
  wire         awb_O_tready;  //synthesis keep 

  wire         w_norm_tvalid;
  wire         w_norm_tuser;
  wire         w_norm_tlast;

  wire         awb_O_tuser_128;   //synthesis keep 
  wire         awb_O_tvalid_128;  //synthesis keep 
  wire [127:0] awb_O_tdata_128;   //synthesis keep 

  wire         alg_O_tlast;    //synthesis keep
  wire         alg_O_tuser;    //synthesis keep
  wire [ 95:0] alg_O_tdata;    //synthesis keep
  wire         alg_O_tvalid;   //synthesis keep
  wire [  3:0] alg_O_mode;     //synthesis keep
  wire [ 31:0] alg_O_cnt;      //synthesis keep
  wire [ 10:0] alg_x0, alg_x1, alg_y0, alg_y1;  //synthesis keep
  wire         alg_bbox_v;     //synthesis keep
  wire [  1:0] alg_cls;        //synthesis keep
  wire [  7:0] alg_tid;        //synthesis keep
  wire [2:0] alg_fam_valid;
  wire [32:0] alg_fam_cx,alg_fam_cy;
  wire         osd_O_tlast;    //synthesis keep
  wire         osd_O_tuser;    //synthesis keep
  wire [ 95:0] osd_O_tdata;    //synthesis keep
  wire         osd_O_tvalid;   //synthesis keep

  wire [ 7:0]  info_fps_bcd;   //synthesis keep
  wire [10:0]  info_lat_clk;   // LAT 拍数（M8 恢复：接 lat_measure 输出）

  lat_measure #(
      .CLK_HZ (18886000)
  ) u_lat_measure (
      .I_clk        (axi4s_video_aclk),
      .I_rst_n      (I_rst_n   ),
      .I_in_tvalid  (w_norm_tvalid),
      .I_in_tuser   (w_norm_tuser ),
      .I_out_tvalid (osd_O_tvalid),
      .I_out_tuser  (osd_O_tuser ),
      .O_frame_cnt  (),
      .O_fps_bcd    (info_fps_bcd),
      .O_lat_clk    (info_lat_clk)
  );

  assign awb_O_tready = O_tready;
  assign O_tdata  = awb_O_tdata_128;
  assign O_tlast  = awb_O_tlast    ;
  assign O_tuser  = awb_O_tuser_128;
  assign O_tvalid = awb_O_tvalid_128;

  assign O_bbox_x0    = alg_x0    ;  //synthesis keep
  assign O_bbox_x1    = alg_x1    ;  //synthesis keep
  assign O_bbox_y0    = alg_y0    ;  //synthesis keep
  assign O_bbox_y1    = alg_y1    ;  //synthesis keep
  assign O_bbox_valid = alg_bbox_v;  //synthesis keep
  assign O_pix_count  = alg_O_cnt ;  //synthesis keep
  assign O_mode       = alg_O_mode;  //synthesis keep
 
demosaic #(
    .IMG_HEIGHT          (720 ),
    .IMG_WIDTH           (1280),
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
) u_demosaic (
    .I_clk   			(axi4s_video_aclk)	,
    .I_rst_n 			(I_rst_n)	,
    .axi4s_video_tdata 	(I_tdata)	,
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,
    .axi4s_video_tvalid	(I_tvalid)	,
    .axi4s_video_tuser 	(I_tuser)	,
    .axi4s_video_tready	(I_tready)	,
    .O_tlast  			(m_aixs_tlast)	,
    .O_tuser  			(m_aixs_tuser)	,
    .O_tdata  			(m_aixs_tdata)	,
    .O_tvalid 			(m_aixs_tvalid)	,
    .O_tready   		(m_aixs_tready)
);
 
data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(720 ),
    .IMG_WIDTH (1280)
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_tready(awb_O_tready)
);

    wire         he_O_tlast, he_O_tuser, he_O_tvalid;
    wire [ 95:0] he_O_tdata;

    localparam [15:0] HE_DEB = 16'd50000;
    reg [15:0] r_he_cnt;
    reg        r_he_key_d;
    reg        r_he_en;

    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_he_cnt   <= 16'd0;
            r_he_key_d <= 1'b1;
            r_he_en    <= 1'b0;
        end else begin
            r_he_key_d <= I_he_key;
            if (r_he_cnt != 16'd0)
                r_he_cnt <= r_he_cnt - 16'd1;
            else if ((!I_he_key) && r_he_key_d) begin
                r_he_en  <= ~r_he_en;
                r_he_cnt <= HE_DEB;
            end
        end
    end

//------------------------------------------------------------------------------
// M5 颜色档位由板载拨码开关 SW1(A4) 决定：拨下(0)=AUTO 多色识别，拨上(1)=固定红
//------------------------------------------------------------------------------
reg [1:0] r_sw_d;
always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if (!I_rst_n) r_sw_d <= 2'b11;
    else          r_sw_d <= {r_sw_d[0], I_gear_sw};
end
wire        w_gear_auto = ~r_sw_d[1];
wire [1:0]  w_cmode     = w_gear_auto ? 2'd3 : 2'd0;
assign O_geo_auto       = w_gear_auto;

//------------------------------------------------------------------------------
// 屏上 X/Y 读数（框中心 + IIR 平滑，仅用于 OSD 数字显示，不影响云台 I2C 低延迟坐标）
//------------------------------------------------------------------------------
wire [11:0] w_bb_cx_raw = (alg_bbox_v && (alg_x0 <= alg_x1)) ? (({1'b0, alg_x0} + {1'b0, alg_x1}) >> 1) : 12'd0;
wire [11:0] w_bb_cy_raw = (alg_bbox_v && (alg_y0 <= alg_y1)) ? (({1'b0, alg_y0} + {1'b0, alg_y1}) >> 1) : 12'd0;
reg  [11:0] r_smx, r_smy;
reg  [3:0]  r_sm_lost;
always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_smx <= 12'd640; r_smy <= 12'd360; r_sm_lost <= 4'd15;
    end else if (!alg_bbox_v) begin
        r_smx <= 12'd640; r_smy <= 12'd360;
        if (r_sm_lost != 4'hF) r_sm_lost <= r_sm_lost + 4'd1;
    end else begin
        r_sm_lost <= 4'd0;
        if (r_sm_lost >= 4'd4) begin
            r_smx <= w_bb_cx_raw;  r_smy <= w_bb_cy_raw;
        end else begin
            if (w_bb_cx_raw >= r_smx) r_smx <= r_smx + ((w_bb_cx_raw - r_smx) >> 2);
            else                      r_smx <= r_smx - ((r_smx - w_bb_cx_raw + 12'd3) >> 2);
            if (w_bb_cy_raw >= r_smy) r_smy <= r_smy + ((w_bb_cy_raw - r_smy) >> 2);
            else                      r_smy <= r_smy - ((r_smy - w_bb_cy_raw + 12'd3) >> 2);
        end
    end
end

    localparam [8:0]  NORM_BPL  = 9'd320;
    localparam [18:0] NORM_BPF  = 19'd230400;
    localparam [18:0] NORM_SEED = 19'd0;

    reg  [8:0]  r_norm_idx;
    reg  [18:0] r_nb;
    reg         r_nsync;
    reg         r_tuser_d;

    wire        w_tuser_rise = awb_O_tuser & ~r_tuser_d;
    assign w_norm_tvalid = awb_O_tvalid;
    assign w_norm_tuser  = w_norm_tvalid & r_nsync & (r_nb == 19'd0);
    assign w_norm_tlast  = w_norm_tvalid & (r_norm_idx == NORM_BPL - 9'd1);

    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_tuser_d <= 1'b0;
        else
            r_tuser_d <= awb_O_tuser;
    end

    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_norm_idx <= 9'd0;
            r_nb       <= 19'd0;
            r_nsync    <= 1'b0;
        end else if (w_tuser_rise) begin
            r_norm_idx <= NORM_SEED[8:0];
            r_nb       <= NORM_SEED;
            r_nsync    <= 1'b1;
        end else if (w_norm_tvalid) begin
            r_nb       <= (r_nb >= NORM_BPF - 19'd1) ? 19'd0 : (r_nb + 19'd1);
            r_norm_idx <= (r_norm_idx == NORM_BPL - 9'd1) ? 9'd0 : (r_norm_idx + 9'd1);
        end
    end

    reg [14:0] r_ref_cnt;
    reg        r_ref_tog;
    always @(posedge I_ref_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_ref_cnt <= 15'd0;
            r_ref_tog <= 1'b0;
        end else if (r_ref_cnt == 15'd23999) begin
            r_ref_cnt <= 15'd0;
            r_ref_tog <= ~r_ref_tog;
        end else begin
            r_ref_cnt <= r_ref_cnt + 15'd1;
        end
    end

    reg r_tog_d0, r_tog_d1, r_tog_d2;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_tog_d0 <= 1'b0; r_tog_d1 <= 1'b0; r_tog_d2 <= 1'b0;
        end else begin
            r_tog_d0 <= r_ref_tog; r_tog_d1 <= r_tog_d0; r_tog_d2 <= r_tog_d1;
        end
    end
    wire w_ref_edge = r_tog_d1 ^ r_tog_d2;

    reg [17:0] r_clk_cnt;
    reg [10:0] r_dbg_clk_mhz;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_clk_cnt     <= 18'd0;
            r_dbg_clk_mhz <= 11'd0;
        end else if (w_ref_edge) begin
            r_dbg_clk_mhz <= r_clk_cnt[17:10];
            r_clk_cnt     <= 18'd0;
        end else begin
            r_clk_cnt     <= r_clk_cnt + 18'd1;
        end
    end

ae_ctl #(
    .MEAN_HI (32'd190),
    .SAT_PCT (24'd15),
    .AG_MIN  (16'd48),
    .AG_MAX  (16'd143),
    .EXP_MIN (16'd400),
    .EXP_INIT(16'd2400),
    .EXP_MAX (16'd3900)
) u_ae (
    .I_clk        (axi4s_video_aclk     ),
    .I_rst_n      (I_rst_n              ),
    .I_tdata      (awb_O_tdata          ),
    .I_tvalid     (awb_O_tvalid         ),
    .I_tuser      (w_norm_tuser         ),
    .I_ae_cfg_done(I_ae_cfg_done        ),
    .I_ae_en      (~I_ae_sw             ),
    .O_ae_req     (O_ae_req             ),
    .O_ae         (O_ae                 ),
    .O_ag         (O_ag                 )
);

    alg_histeq_96 #(
        .IMG_WIDTH (1280),
        .IMG_HEIGHT(720 )
    ) u_histeq (
        .I_clk    (axi4s_video_aclk),
        .I_rst_n  (I_rst_n   ),
        .I_tlast  (w_norm_tlast ),
        .I_tuser  (w_norm_tuser ),
        .I_tdata  (awb_O_tdata ),
        .I_tvalid (w_norm_tvalid),
        .I_tready (O_tready  ),
        .I_en     (r_he_en   ),
        .O_tlast  (he_O_tlast ),
        .O_tuser  (he_O_tuser ),
        .O_tdata  (he_O_tdata ),
        .O_tvalid (he_O_tvalid),
        .O_tready ()
    );

    alg_top #(
        .IMG_WIDTH  (1280),
        .IMG_HEIGHT (720 ),
        .TGT_TOL    (8'd96  ),
        // ★M6 运动检测：阈值由 40 调至 16，配合 8×8 整块高亮与相邻格抗噪滤波，运动响应清晰明显
        .M6_DIFF_TH (8'd16  ),
        .M6_NORM    (1'b1   ),
        // ★M5 颜色识别：高鲁棒相对色度门 + 四族独立二维连通游程包围盒
        .DOM_MODE   (1'b1   ),
        .SAT_TH     (8'd80  ),
        .SAT_MIN    (8'd50  ),
        .COLOR_GAP  (9'd40  ),
        .MIN_PIX    (32'd360),
        .REL_MODE   (1'b1   ),
        .REL_ABS_MIN(8'd45  ),
        .REL_SAT_MIN(8'd30  ),
        .REL_MARGIN (8'd12  ),
        .RL_EN      (1'b1   ),
        .RL_MIN_RUN (11'd28 ),
        .RL_GAP_MAX (8'd2   ),
        .RL_MIN_ROWS(16'd6  ),
        .DOM_MIN    (8'd64  ),
        .DOM_MARGIN (8'd40  ),
        .BBOX_COLOR (24'hFF0000),
        .AUTO_Y     (1'b0   ),
        .SAT_TH_B   (8'd30  ),
        .DOM_MIN_B  (8'd20  ),
        .GREEN_M    (8'd10  ),
        .SAT_TH_G   (8'd30  ),
        .SAT_TH_R   (8'd40  ),
        .DOM_MIN_R  (8'd20  ),
        .DOM_MIN_G  (8'd20  ),
        .FAM_MIN    (32'd180),
        // ★M3 白边纯黑底（对标官方 PPT） + M7 二维形态学无条纹区域填充
        .TH_SCALE   (3      ),
        .PURE_BW    (1'b1   ),
        .MORPH_FILL (1'b1   ),
        .EDGE_K     (9'd128 ),
        .EDGE_BG    (8'd0   ),
        .SMOOTH_BOX (1'b1   ),
        .BIN_GLOBAL (1'b1   )
    ) u_alg_top (
        .I_clk        (axi4s_video_aclk),
        .I_roi_en     (I_roi_en ),
        .I_roi_x0     (I_roi_x0 ),
        .I_roi_x1     (I_roi_x1 ),
        .I_roi_y0     (I_roi_y0 ),
        .I_roi_y1     (I_roi_y1 ),
        .I_rst_n      (I_rst_n   ),
        .I_tlast      (he_O_tlast ),
        .I_tuser      (he_O_tuser ),
        .I_tdata      (he_O_tdata ),
        .I_tvalid     (he_O_tvalid),
        .I_tready     (O_tready  ),
        .I_key        (I_mode_key),
        .I_mode_set   (1'b0      ),
        .I_mode_sel   (4'd0      ),
        .I_color_mode (w_cmode   ),
        .O_mode       (alg_O_mode),
        .O_pix_count  (alg_O_cnt ),
        .O_bbox_x0    (alg_x0), .O_bbox_x1(alg_x1),
        .O_bbox_y0    (alg_y0), .O_bbox_y1(alg_y1),
        .O_bbox_valid (alg_bbox_v),
        .O_color_class(alg_cls),
        .O_track_id   (alg_tid),
        .O_fam_valid(alg_fam_valid),.O_fam_cx(alg_fam_cx),.O_fam_cy(alg_fam_cy),
        .O_tlast      (alg_O_tlast ),
        .O_tuser      (alg_O_tuser ),
        .O_tdata      (alg_O_tdata ),
        .O_tvalid     (alg_O_tvalid),
        .O_tready     ()
    );

    wire [15:0] w_stat_hpx, w_stat_vln, w_stat_frm, w_stat_sec;
    wire [5:0]  w_stat_idx;

    frame_stat #(.PX_PER_BEAT(4), .H_W(11), .V_W(11), .F_W(16), .FPS_NOM(30)) u_frame_stat (
        .I_clk    (axi4s_video_aclk),
        .I_rst_n  (I_rst_n         ),
        .I_tvalid (alg_O_tvalid    ),
        .I_tlast  (alg_O_tlast     ),
        .I_tuser  (alg_O_tuser     ),
        .O_h_px   (w_stat_hpx      ),
        .O_v_lines(w_stat_vln      ),
        .O_frames (w_stat_frm      ),
        .O_secs   (w_stat_sec      ),
        .O_sec_idx(w_stat_idx      )
    );

    wire [9:0]  w_e2e_lat_ms;
    wire [15:0] w_e2e_raw_ms;

    e2e_lat #(
        .CLK_HZ  (39660000),
        .BIAS_MS (33      ),
        .AVG_SH  (7       )
    ) u_e2e_lat (
        .I_clk       (axi4s_video_aclk),
        .I_rst_n     (I_rst_n         ),
        .I_cap_tuser (m_aixs_tuser    ),
        .I_disp_tgl  (I_disp_tgl      ),
        .O_lat_ms    (w_e2e_lat_ms    ),
        .O_raw_ms    (w_e2e_raw_ms    )
    );

    osd_mixer #(
        .IMG_WIDTH (1280),
        .IMG_HEIGHT(720 )
    ) u_osd_mixer (
        .I_clk       (axi4s_video_aclk),
        .I_rst_n     (I_rst_n   ),
        .I_tdata     (alg_O_tdata ),
        .I_tvalid    (alg_O_tvalid),
        .I_tlast     (alg_O_tlast ),
        .I_tuser     (alg_O_tuser ),
        .I_tready    (O_tready  ),
        .I_info_mode (w_gear_auto && (alg_O_mode == 4'd5) ? 11'd13 : {7'd0, alg_O_mode}),
        .I_info_fps  ({24'd0, info_fps_bcd}),
        .I_info_lat  (info_lat_clk),
        .I_info_x    ((alg_O_mode == 4'd5 || alg_O_mode == 4'd6 || alg_O_mode == 4'd7) ? r_smx[10:0] : 11'd640),
        .I_info_y    ((alg_O_mode == 4'd5 || alg_O_mode == 4'd6 || alg_O_mode == 4'd7) ? r_smy[10:0] : 11'd360),
        .I_info_nov  (1'b0),
        .I_info_cnt  (alg_O_cnt ),
        .I_info_hpx  (w_stat_hpx  ),
        .I_info_vln  (w_stat_vln  ),
        .I_info_latms(w_e2e_lat_ms),
        .I_info_idx  (w_stat_idx  ),
        .I_info_class(alg_cls     ),
        .I_info_tid  (alg_tid     ),
        .I_info_fam_valid(alg_fam_valid),.I_info_fam_cx(alg_fam_cx),.I_info_fam_cy(alg_fam_cy),
        .I_info_auto(w_gear_auto),
        .O_tdata     (osd_O_tdata ),
        .O_tvalid    (osd_O_tvalid),
        .O_tlast     (osd_O_tlast ),
        .O_tuser     (osd_O_tuser ),
        .O_tready    ()
    );

    reg [8:0] r_disp_user_sr;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n)
            r_disp_user_sr <= 9'd0;
        else
            r_disp_user_sr <= {r_disp_user_sr[7:0], awb_O_tuser};
    end
    wire w_disp_tuser = r_disp_user_sr[8];

    data_96bit_to_128bit u_data_96bit_to_128bit(
        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),
        .I_96b_frame_start  ( w_disp_tuser      ),
        .I_96b_valid        ( osd_O_tvalid      ),
        .I_96b_data         ( osd_O_tdata       ),
        .O_128b_frame_start ( awb_O_tuser_128   ),
        .O_128b_valid       ( awb_O_tvalid_128  ),
        .O_128b_data        ( awb_O_tdata_128   )
    );

endmodule
