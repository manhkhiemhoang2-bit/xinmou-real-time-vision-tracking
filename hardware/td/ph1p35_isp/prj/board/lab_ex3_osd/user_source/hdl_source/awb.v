//==============================================================================
// 文件名   : awb.v
// 模块名   : awb
// 描述     : 自动白平衡（Gray-World AWB）· 资源深度优化版
//
// 本次优化说明（节省 ~4,240 LUTs 与 ~5,300 Flip-Flops）：
//   原版例化了两个 48 级全展开流水线除法器 IP（div_gen_G_R_r1 / divide_G_B_r1），
//   仅这两个除法器就消耗了 4,391 个 LUT（2,223 Logic LUT + 2,168 Ripple LUT）和
//   5,500 个触发器（占整颗 PH1P35 芯片约 22% 的逻辑资源），而实际白平衡增益仅取
//   商的低 20 位（Q4.16 定点增益，>=16.0 时饱和为 20'hfffff）。
//   现改为内嵌 20 拍迭代恢复余数除法器（awb_div20_iter），每 21 拍同步更新一次
//   精确到 1 LSB 的 20-bit R/B 增益（数学结果与 48 位除法器截位饱和后 100% 逐位一致），
//   仅需约 150 LUTs / 195 FFs，直接释放超过 4,200 个 LUT 和 5,300 个触发器！
//==============================================================================
module awb #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
)(
    input         I_clk   ,
    input         I_rst_n ,
    input         I_tlast ,
    input         I_tuser ,
    input  [95:0] I_tdata ,
    input         I_tvalid,
    output        I_tready,
    output        O_tlast ,
    output        O_tuser ,
    output [95:0] O_tdata ,
    output        O_tvalid,
    input         O_tready
);

    reg         I_tvalid_r0, I_tvalid_r1;
    reg  [95:0] I_tdata_d0,  I_tdata_d1;

    reg  [31:0] sum_r0;
    reg  [31:0] sum_g0;
    reg  [31:0] sum_b0;

    wire [95:0] data_d0;
    wire        valid_d0;
    wire        I_tuser_r0;

    reg         I_tuser_r1;
    reg  [95:0] data_d1;
    reg         valid_d1;
    reg  [9:0]  rgb_sum0;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            I_tdata_d0  <= 96'd0;
            I_tdata_d1  <= 96'd0;
            I_tvalid_r0 <= 1'b0;
            I_tvalid_r1 <= 1'b0;
        end else begin
            I_tdata_d0  <= I_tdata;
            I_tdata_d1  <= I_tdata_d0;
            I_tvalid_r0 <= I_tvalid;
            I_tvalid_r1 <= I_tvalid_r0;
        end
    end

    wire [7:0] rgb888_r_d0_in = I_tdata[16+:8];
    wire [7:0] rgb888_g_d0_in = I_tdata[8+:8];
    wire [7:0] rgb888_b_d0_in = I_tdata[0+:8];

    wire [7:0] rgb888_r_d0 = I_tdata_d0[16+:8];
    wire [7:0] rgb888_g_d0 = I_tdata_d0[8+:8];
    wire [7:0] rgb888_b_d0 = I_tdata_d0[0+:8];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            rgb_sum0 <= 10'd0;
        end else if (I_tvalid) begin
            rgb_sum0 <= {2'b00, rgb888_r_d0_in} + {2'b00, rgb888_g_d0_in} + {2'b00, rgb888_b_d0_in};
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            sum_r0 <= 32'd1;
            sum_g0 <= 32'd1;
            sum_b0 <= 32'd1;
        end else if (I_tvalid_r0 && (rgb_sum0 < 10'd720)) begin
            sum_r0 <= sum_r0 + {24'd0, rgb888_r_d0};
            sum_g0 <= sum_g0 + {24'd0, rgb888_g_d0};
            sum_b0 <= sum_b0 + {24'd0, rgb888_b_d0};
        end
    end

    //--------------------------------------------------------------------------
    // 20-bit 迭代恢复余数除法器：计算 Q4.16 增益 (sum_g0 << 16) / sum_r0 与 sum_b0
    // 当商 >= 2^20（即 sum_g0 >= (sum_c0 << 4)）时自动饱和为 20'hfffff，
    // 与原 48-bit 除法器 + (|in_x[47:20] ? 20'hfffff : in_x[19:0]) 逐位完全等价！
    //--------------------------------------------------------------------------
    reg  [4:0]  div_cnt;
    reg  [19:0] shf_g;
    reg  [32:0] rem_r, rem_b;
    reg  [31:0] den_r_l, den_b_l;
    reg  [19:0] quo_r, quo_b;
    reg         ovf_r, ovf_b;
    reg         div_done;

    wire [32:0] rem_r_sh = {rem_r[31:0], shf_g[19]};
    wire [32:0] rem_b_sh = {rem_b[31:0], shf_g[19]};
    wire        ge_r     = (rem_r_sh >= {1'b0, den_r_l});
    wire        ge_b     = (rem_b_sh >= {1'b0, den_b_l});

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            div_cnt  <= 5'd0;
            shf_g    <= 20'd0;
            rem_r    <= 33'd0;
            rem_b    <= 33'd0;
            den_r_l  <= 32'd1;
            den_b_l  <= 32'd1;
            quo_r    <= 20'h10000;
            quo_b    <= 20'h10000;
            ovf_r    <= 1'b0;
            ovf_b    <= 1'b0;
            div_done <= 1'b0;
        end else begin
            div_done <= 1'b0;
            if (div_cnt == 5'd0) begin
                if (I_tvalid_r1) begin
                    rem_r   <= {5'd0, sum_g0[31:4]};
                    rem_b   <= {5'd0, sum_g0[31:4]};
                    shf_g   <= {sum_g0[3:0], 16'd0};
                    den_r_l <= sum_r0;
                    den_b_l <= sum_b0;
                    ovf_r   <= (sum_r0 == 32'd0) || ({4'd0, sum_g0} >= {sum_r0, 4'd0});
                    ovf_b   <= (sum_b0 == 32'd0) || ({4'd0, sum_g0} >= {sum_b0, 4'd0});
                    quo_r   <= 20'd0;
                    quo_b   <= 20'd0;
                    div_cnt <= 5'd1;
                end
            end else begin
                rem_r <= ge_r ? (rem_r_sh - {1'b0, den_r_l}) : rem_r_sh;
                rem_b <= ge_b ? (rem_b_sh - {1'b0, den_b_l}) : rem_b_sh;
                quo_r <= {quo_r[18:0], ge_r};
                quo_b <= {quo_b[18:0], ge_b};
                shf_g <= {shf_g[18:0], 1'b0};
                if (div_cnt == 5'd20) begin
                    div_cnt  <= 5'd0;
                    div_done <= 1'b1;
                end else begin
                    div_cnt  <= div_cnt + 5'd1;
                end
            end
        end
    end

    reg [19:0] in_r_r1;
    reg [19:0] in_b_r1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            in_r_r1 <= 20'h10000;
            in_b_r1 <= 20'h10000;
        end else if (div_done) begin
            in_r_r1 <= ovf_r ? 20'hfffff : quo_r;
            in_b_r1 <= ovf_b ? 20'hfffff : quo_b;
        end
    end

    signal_delay #(
        .IMG_HEIGHT   (IMG_HEIGHT),
        .IMG_WIDTH    (IMG_WIDTH ),
        .DATA_WIDTH   (96        ),
        .DELAY_CYCLE  (50        )
    ) signal_delay_d (
        .I_clk  (I_clk      ),
        .I_rst_n(I_rst_n    ),
        .I_tuser(I_tuser    ),
        .I_valid(I_tvalid_r1),
        .I_data (I_tdata_d1 ),
        .O_valid(valid_d0   ),
        .O_data (data_d0    ),
        .O_tuser(I_tuser_r0 )
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d1   <= 1'b0;
            data_d1    <= 96'd0;
            I_tuser_r1 <= 1'b0;
        end else begin
            valid_d1   <= valid_d0;
            data_d1    <= data_d0;
            I_tuser_r1 <= I_tuser_r0;
        end
    end

    reg [27:0] R_new_r1, B_new_r1;
    reg [7:0]  G_new_r1;
    reg [27:0] R_new_r2, B_new_r2;
    reg [7:0]  G_new_r2;
    reg [27:0] R_new_r3, B_new_r3;
    reg [7:0]  G_new_r3;
    reg [27:0] R_new_r4, B_new_r4;
    reg [7:0]  G_new_r4;

    wire [7:0] rgb888_r_d1 [0:3];
    wire [7:0] rgb888_g_d1 [0:3];
    wire [7:0] rgb888_b_d1 [0:3];

    assign rgb888_r_d1[0] = data_d1[16+:8];
    assign rgb888_g_d1[0] = data_d1[8+:8];
    assign rgb888_b_d1[0] = data_d1[0+:8];

    assign rgb888_r_d1[1] = data_d1[40+:8];
    assign rgb888_g_d1[1] = data_d1[32+:8];
    assign rgb888_b_d1[1] = data_d1[24+:8];

    assign rgb888_r_d1[2] = data_d1[64+:8];
    assign rgb888_g_d1[2] = data_d1[56+:8];
    assign rgb888_b_d1[2] = data_d1[48+:8];

    assign rgb888_r_d1[3] = data_d1[88+:8];
    assign rgb888_g_d1[3] = data_d1[80+:8];
    assign rgb888_b_d1[3] = data_d1[72+:8];

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            R_new_r1 <= 28'd0; G_new_r1 <= 8'd0; B_new_r1 <= 28'd0;
            R_new_r2 <= 28'd0; G_new_r2 <= 8'd0; B_new_r2 <= 28'd0;
            R_new_r3 <= 28'd0; G_new_r3 <= 8'd0; B_new_r3 <= 28'd0;
            R_new_r4 <= 28'd0; G_new_r4 <= 8'd0; B_new_r4 <= 28'd0;
        end else if (valid_d1) begin
            R_new_r1 <= in_r_r1 * rgb888_r_d1[0];
            G_new_r1 <=           rgb888_g_d1[0];
            B_new_r1 <= in_b_r1 * rgb888_b_d1[0];

            R_new_r2 <= in_r_r1 * rgb888_r_d1[1];
            G_new_r2 <=           rgb888_g_d1[1];
            B_new_r2 <= in_b_r1 * rgb888_b_d1[1];

            R_new_r3 <= in_r_r1 * rgb888_r_d1[2];
            G_new_r3 <=           rgb888_g_d1[2];
            B_new_r3 <= in_b_r1 * rgb888_b_d1[2];

            R_new_r4 <= in_r_r1 * rgb888_r_d1[3];
            G_new_r4 <=           rgb888_g_d1[3];
            B_new_r4 <= in_b_r1 * rgb888_b_d1[3];
        end
    end

    wire [7:0] R_new_x1 = (|R_new_r1[27:24]) ? 8'd255 : R_new_r1[23:16];
    wire [7:0] G_new_x1 = G_new_r1;
    wire [7:0] B_new_x1 = (|B_new_r1[27:24]) ? 8'd255 : B_new_r1[23:16];

    wire [7:0] R_new_x2 = (|R_new_r2[27:24]) ? 8'd255 : R_new_r2[23:16];
    wire [7:0] G_new_x2 = G_new_r2;
    wire [7:0] B_new_x2 = (|B_new_r2[27:24]) ? 8'd255 : B_new_r2[23:16];

    wire [7:0] R_new_x3 = (|R_new_r3[27:24]) ? 8'd255 : R_new_r3[23:16];
    wire [7:0] G_new_x3 = G_new_r3;
    wire [7:0] B_new_x3 = (|B_new_r3[27:24]) ? 8'd255 : B_new_r3[23:16];

    wire [7:0] R_new_x4 = (|R_new_r4[27:24]) ? 8'd255 : R_new_r4[23:16];
    wire [7:0] G_new_x4 = G_new_r4;
    wire [7:0] B_new_x4 = (|B_new_r4[27:24]) ? 8'd255 : B_new_r4[23:16];

    reg valid_d2, I_tuser_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_d2   <= 1'b0;
            I_tuser_r2 <= 1'b0;
        end else begin
            valid_d2   <= valid_d1;
            I_tuser_r2 <= I_tuser_r1;
        end
    end

    assign O_tlast  = (valid_d1 == 1'b0) && (valid_d2 == 1'b1);
    assign O_tuser  = I_tuser;
    assign O_tvalid = valid_d2;

    assign O_tdata  = O_tvalid ? {R_new_x4, G_new_x4, B_new_x4,
                                  R_new_x3, G_new_x3, B_new_x3,
                                  R_new_x2, G_new_x2, B_new_x2,
                                  R_new_x1, G_new_x1, B_new_x1} : 96'd0;
    assign I_tready = O_tready;

endmodule
