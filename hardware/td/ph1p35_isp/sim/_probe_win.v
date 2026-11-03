//==============================================================================
// _probe_win.v -- one-shot diagnostic TB (NOT a deliverable).
//
// Purpose: print the absolute (row, column) that each of the 15 window taps
// actually sampled, so the real dy/dx geometry is read off numbers instead of
// inferred from the timing of the RTL.
//
// Trick: pixel (y,x) is encoded as
//     B = x & 0xFF        (low byte  = column of that pixel)
//     G = y & 0xFF        (middle    = row of that pixel)
//     R = 0xFF            (high      = mark that this pixel exists)
// The pixel is black only if R != 0xFF, i.e. real image pixels are WHITE with
// R=0xFF; out-of-image padding and untouched line-buffer content read as black.
// The RGB value IS the coordinate, so the printed hex of a tap is the answer.
//==============================================================================
`timescale 1ns / 1ps

module _probe_win;

    localparam IMG_WIDTH  = 16;     // 4 beats per line
    localparam IMG_HEIGHT = 6;
    localparam BPL        = IMG_WIDTH / 4;
    localparam BPF        = BPL * IMG_HEIGHT;
    localparam NBEAT      = BPF * 2;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [31:0] cyc;
    reg        rst_n;
    reg [31:0] beat;
    reg [95:0] I_tdata;
    reg        I_tvalid, I_tlast, I_tuser;
    wire       I_tready;

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

    // pixel k of the beat carries column = 4*grp + k, row = the beat's row.
    wire [7:0] w_grp = (beat % BPL);
    wire [7:0] w_row = ((beat / BPL) % IMG_HEIGHT);
    function [23:0] pix_of;
        input [7:0] col;
        begin
            pix_of = {8'hFF, w_row, col};
        end
    endfunction

    always @(*) begin
        I_tvalid = rst_n && (beat < NBEAT) && (cyc >= 6);
        I_tlast  = I_tvalid && ((beat % BPL) == BPL - 1);
        I_tuser  = I_tvalid && ((beat % BPF) == 0);
        I_tdata  = { pix_of(4*w_grp + 8'd0), pix_of(4*w_grp + 8'd1),
                     pix_of(4*w_grp + 8'd2), pix_of(4*w_grp + 8'd3) };
    end

    initial begin
        cyc = 32'd0; beat = 32'd0; rst_n = 1'b0;
        #1; repeat (4) @(posedge clk); rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && dut.r_vld2 && dut.w_win_valid) begin
            $display("c=%0d beat=%0d r_x=%0d r_y=%0d T=%h,%h,%h,%h,%h,%h M=%h,%h,%h,%h,%h,%h B=%h,%h,%h,%h,%h,%h",
                cyc, beat, dut.r_x, dut.r_y,
                dut.w_top_m1, dut.w_top_0, dut.w_top_1, dut.w_top_2, dut.w_top_3, dut.w_top_4,
                dut.w_mid_m1, dut.w_mid_0, dut.w_mid_1, dut.w_mid_2, dut.w_mid_3, dut.w_mid_4,
                dut.w_bot_m1, dut.w_bot_0, dut.w_bot_1, dut.w_bot_2, dut.w_bot_3, dut.w_bot_4);
        end
        cyc <= cyc + 32'd1;
        if (I_tvalid) begin
            beat <= beat + 32'd1;
        end
        if (beat >= NBEAT) $finish;          // <- fires even if tvalid stops
    end

endmodule
