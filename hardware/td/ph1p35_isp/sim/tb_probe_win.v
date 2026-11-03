//==============================================================================
// tb_probe_win.v -- one-shot geometry probe TB (NOT a deliverable).
// Drives _probe_stim.hex (sparse dot lattice) and prints the 18 window taps as
// bits for every assembled window, prefixed with "W " so a script can parse it.
//==============================================================================
`timescale 1ns / 1ps

module tb_probe_win;

    localparam IMG_WIDTH  = 16;
    localparam IMG_HEIGHT = 6;
    localparam BPL        = IMG_WIDTH / 4;
    localparam BPF        = BPL * IMG_HEIGHT;
    localparam NBEAT      = BPF * 2;
    localparam START_CYC  = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [95:0] stim [0:NBEAT-1];
    reg [31:0] cyc;
    reg [31:0] beat;
    reg        rst_n;

    wire w_drv = (cyc >= START_CYC) && (beat < NBEAT);

    reg  [95:0] I_tdata;
    reg         I_tvalid, I_tlast, I_tuser;
    wire        I_tready;

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

    always @(*) begin
        I_tdata  = w_drv ? stim[beat] : 96'd0;
        I_tvalid = w_drv;
        I_tlast  = w_drv && ((beat % BPL) == BPL - 1);
        I_tuser  = w_drv && ((beat % BPF) == 0);
    end

    initial begin
        cyc = 32'd0; beat = 32'd0; rst_n = 1'b0;
        $readmemh("_probe_stim.hex", stim);
        #1; repeat (4) @(posedge clk); rst_n = 1'b1;
    end

    integer fd;
    initial fd = $fopen("_probe_win.txt", "w");

    always @(posedge clk) begin
        if (rst_n && dut.r_vld2 && dut.w_win_valid) begin
            $fwrite(fd, "W c=%0d beat=%0d rx=%0d ry=%0d T=%b%b%b%b%b%b M=%b%b%b%b%b%b B=%b%b%b%b%b%b\n",
                cyc, beat, dut.r_x, dut.r_y,
                dut.w_top_m1, dut.w_top_0, dut.w_top_1, dut.w_top_2, dut.w_top_3, dut.w_top_4,
                dut.w_mid_m1, dut.w_mid_0, dut.w_mid_1, dut.w_mid_2, dut.w_mid_3, dut.w_mid_4,
                dut.w_bot_m1, dut.w_bot_0, dut.w_bot_1, dut.w_bot_2, dut.w_bot_3, dut.w_bot_4);
        end
        cyc <= cyc + 32'd1;
        if (w_drv) beat <= beat + 32'd1;
        if (beat >= NBEAT) begin
            $fclose(fd);
            $display("probe done");
            $finish;
        end
    end

endmodule
