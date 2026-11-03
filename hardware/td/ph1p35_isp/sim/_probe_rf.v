//==============================================================================
// _probe_rf.v —— 一次性诊断 TB：手工在固定拍上拉 tlast/tuser，观察 O_* 的拍位。
// 不属于交付物，只用来定位"O_tlast 看起来被 held"的问题。
//==============================================================================
`timescale 1ns / 1ps

module _probe_rf;

    localparam IMG_WIDTH  = 8;      // 2 拍/行
    localparam IMG_HEIGHT = 4;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [31:0] cyc;
    reg        rst_n;
    reg [95:0] I_tdata;
    reg        I_tvalid;
    reg        I_tlast;
    reg        I_tuser;

    wire [95:0] O_tdata;
    wire        O_tvalid, O_tlast, O_tuser, O_tready;

    alg_region_fill_96 #(.IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tready(I_tready),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tready(O_tready)
    );
    assign I_tready = 1'b1;

    // 手工时序：拍 0..3 = 第 0 行的 2 拍 + 第 1 行的 2 拍（每行 2 拍）
    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 32'd0;
        end else begin
            cyc <= cyc + 32'd1;
            $display("cyc=%0d Iv=%b Il=%b Iu=%b | Ov=%b Ol=%b Ou=%b", cyc,
                     I_tvalid, I_tlast, I_tuser, O_tvalid, O_tlast, O_tuser);
            case (cyc)
                32'd0: begin I_tvalid <= 1'b1; I_tuser <= 1'b1; I_tlast <= 1'b0; end
                32'd1: begin I_tvalid <= 1'b1; I_tuser <= 1'b0; I_tlast <= 1'b1; end
                32'd2: begin I_tvalid <= 1'b1; I_tuser <= 1'b0; I_tlast <= 1'b0; end
                32'd3: begin I_tvalid <= 1'b1; I_tuser <= 1'b0; I_tlast <= 1'b1; end
                32'd4: begin I_tvalid <= 1'b0; I_tuser <= 1'b0; I_tlast <= 1'b0; end
                32'd12: $finish;
            endcase
        end
    end

    initial begin
        cyc = 32'd0;
        rst_n = 1'b0;
        I_tdata = 96'd0; I_tvalid = 1'b0; I_tlast = 1'b0; I_tuser = 1'b0;
        #1;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

endmodule
