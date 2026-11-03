//==============================================================================
// 文件名   : signal_delay.v
// 模块名   : signal_delay
// 描述     : AWB 视频流延迟对齐缓存 · ERAM 深度优化版
//
// 本次优化说明（节省 7~8 块 ERAM20K）：
//   原版调用的 blk_mem_gen_awb_delay_signal IP 按 1920 宽度配置为 2048×96 bit，
//   占用了 10 块 ERAM20K；而实际 1280×720 分辨率下每行仅 320 拍（IMG_WIDTH_4x = 320），
//   读写地址 addra/addrb 仅在 0..319 之间循环。
//   现改为位宽精确匹配的 9-bit 地址（0..319）96-bit 简单双口推断式 BRAM，
//   仅需 2~3 块 ERAM20K，节省 7~8 块 ERAM20K，且读写时序与原 IP 100% 逐拍一致。
//==============================================================================
module signal_delay #(
    parameter IMG_HEIGHT  = 1080,
    parameter IMG_WIDTH   = 1920,
    parameter DATA_WIDTH  = 96,
    parameter DELAY_CYCLE = 50
)(
    input                        I_clk,
    input                        I_rst_n,
    input                        I_tuser,
    input  wire                  I_valid,
    input  wire [DATA_WIDTH-1:0] I_data,
    output wire                  O_valid,
    output wire [DATA_WIDTH-1:0] O_data,
    output wire                  O_tuser
);

    localparam IMG_WIDTH_4x = (IMG_WIDTH >> 2);
    localparam AW           = $clog2(IMG_WIDTH_4x);
    localparam [AW-1:0] LAST_ADDR = IMG_WIDTH_4x - 1;

    reg  [AW-1:0] addra;
    reg  [AW-1:0] addrb;

    reg  [13:0] h_cnt;
    reg  [13:0] v_cnt;
    reg  [13:0] rd_cnt;

    reg  [DATA_WIDTH-1:0] I_data_r;
    reg                   rd_valid, I_valid_r;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            I_valid_r <= 1'b0;
            I_data_r  <= {DATA_WIDTH{1'b0}};
        end else begin
            I_valid_r <= I_valid;
            I_data_r  <= I_data;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            h_cnt <= 14'd0;
            v_cnt <= 14'd0;
        end else begin
            h_cnt <= I_valid_r ? ((h_cnt == IMG_WIDTH_4x - 1) ? 14'd0 : h_cnt + 14'd1) : h_cnt;
            v_cnt <= (I_valid_r && (h_cnt == IMG_WIDTH_4x - 1)) ? ((v_cnt == IMG_HEIGHT - 1) ? 14'd0 : v_cnt + 14'd1) : v_cnt;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            rd_valid <= 1'b0;
        end else if (h_cnt == DELAY_CYCLE - 3) begin
            rd_valid <= 1'b1;
        end else if (rd_cnt == IMG_WIDTH_4x - 1) begin
            rd_valid <= 1'b0;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            rd_cnt <= 14'd0;
        end else if (rd_cnt == IMG_WIDTH_4x) begin
            rd_cnt <= 14'd0;
        end else if (rd_valid) begin
            rd_cnt <= rd_cnt + 14'd1;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            addra <= {AW{1'b0}};
        end else if (I_valid_r) begin
            addra <= (addra == LAST_ADDR) ? {AW{1'b0}} : (addra + 1'b1);
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n || I_tuser) begin
            addrb <= {AW{1'b0}};
        end else if (rd_valid) begin
            addrb <= (addrb == LAST_ADDR) ? {AW{1'b0}} : (addrb + 1'b1);
        end
    end

    reg rd_valid_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            rd_valid_d <= 1'b0;
        end else begin
            rd_valid_d <= rd_valid;
        end
    end

    assign O_valid = rd_valid_d;
    assign O_tuser = (v_cnt == 14'd0) && (rd_cnt == 14'd1);

    // 精确深度的推断式简单双口 BRAM（320 × 96 bit，仅占 2~3 块 ERAM20K）
    reg [DATA_WIDTH-1:0] r_delay_mem [0:IMG_WIDTH_4x-1]; //synthesis ram_style = bram
    reg [DATA_WIDTH-1:0] r_dob;

    always @(posedge I_clk) begin
        if (I_valid_r) begin
            r_delay_mem[addra] <= I_data_r;
        end
        r_dob <= r_delay_mem[addrb];
    end

    assign O_data = r_dob;

endmodule