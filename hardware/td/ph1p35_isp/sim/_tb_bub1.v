//==============================================================================
// tb_region_fill.v -- ModelSim testbench for alg_region_fill_96 (small size, 7 frames)
//
// Derived from the SPEC only (never from the DUT implementation):
//   C1 latency : O_tvalid / O_tlast / O_tuser must equal I_tvalid / I_tlast /
//                I_tuser delayed by LAT = 6 cycles.  Measured with an INDEPENDENT
//                shift chain in this file (never reading DUT internals), except for
//                the read-only probe r_inside (see below).
//   C2 same-cycle: O_tdata must be valid in exactly the same cycle as O_tvalid.
//   C3 beat count: number of output valid beats == number of input valid beats.
//   C4 value range: every 24-bit pixel of a valid beat must be FFFFFF or 000000.
//
// Stimulus : stim_rf.hex  (from gen_stim_region_fill.py, one 96-bit beat per line,
//            pix0 = most significant 24 bits = leftmost pixel of the beat)
// Bubble   : I_tvalid is de-asserted while (tb_flat % BUB_PERIOD) < BUB_SKIP
//            (frame-start beat excepted) -- proves stalls do not change the beat
//            count and do not misalign the scanline "inside" state.
// Dump     : dump_rf.txt, one line per clock:
//              cyc Iv Il Iu Id Ov Ol Ou Od r_inside r_tlast r_tuser r_vld2
//
// NOTE: the delay assertions must be evaluated at **negedge**.  Inside a posedge
// block, O_* still holds the value from before this edge while the shift chain has
// already advanced -- comparing them there reports false failures (the first version
// of this TB did exactly that).
//
// Usage (from sim/):
//     vlib work
//     vlog tb_region_fill.v ../src/alg_region_fill_96.v
//     vsim -c -do "run -all; quit -f" tb_region_fill
// English only in $display: ModelSim 10.3c transcript cannot show Chinese.
//==============================================================================
`timescale 1ns / 1ps

module tb_region_fill;

    //--------------------------------------------------------------------------
    // Size / frames -- must match gen_stim_region_fill.py: small_frames()
    //--------------------------------------------------------------------------
    localparam IMG_WIDTH  = 32;
    localparam IMG_HEIGHT = 10;
    localparam BPL        = IMG_WIDTH / 4;          // 8 beats per line
    localparam FRAMES     = 8;
    localparam BPF        = BPL * IMG_HEIGHT;       // 80 beats per frame
    localparam NBEAT      = BPF * FRAMES;           // 640 beats
    localparam LAT        = 3;                      // module latency (RTL section 14)

    localparam BUB_PERIOD = 37;                     // insert a bubble every 37 flat cycles
    localparam BUB_SKIP   = 1;                      // bubble length in cycles

    localparam RST_CYC    = 4;
    localparam START_CYC  = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // Stimulus
    //--------------------------------------------------------------------------
    reg [95:0] stim [0:NBEAT-1];

    reg [31:0] tb_cyc;        // clock cycle counter
    reg [31:0] tb_flat;       // flat cycle counter (increments every cycle)
    reg [31:0] tb_beat;       // index of the beat to send == beats handed to DUT
    reg        rst_n;

    wire w_allow = (((tb_beat % BPF) == 0) || ((tb_flat % BUB_PERIOD) >= BUB_SKIP));
    wire w_drv   = (tb_cyc >= START_CYC) && (tb_beat < NBEAT) && w_allow;

    reg  [95:0] I_tdata;
    reg         I_tvalid;
    reg         I_tlast;
    reg         I_tuser;
    wire        I_tready;

    always @ (*) begin
        I_tdata  = w_drv ? stim[tb_beat] : 96'd0;
        I_tvalid = w_drv;
        I_tlast  = w_drv && (((tb_beat % BPL) == (BPL - 1)));
        I_tuser  = w_drv && (((tb_beat % BPF) == 0));
    end

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    wire [95:0] O_tdata;
    wire        O_tvalid;
    wire        O_tlast;
    wire        O_tuser;
    wire        O_tready;

    alg_region_fill_96 #(
        .IMG_WIDTH  (IMG_WIDTH),
        .IMG_HEIGHT (IMG_HEIGHT)
    ) dut (
        .I_clk    (clk),
        .I_rst_n  (rst_n),
        .I_tdata  (I_tdata),
        .I_tvalid (I_tvalid),
        .I_tlast  (I_tlast),
        .I_tuser  (I_tuser),
        .I_tready (I_tready),
        .O_tdata  (O_tdata),
        .O_tvalid (O_tvalid),
        .O_tlast  (O_tlast),
        .O_tuser  (O_tuser),
        .O_tready (O_tready)
    );

    assign I_tready = 1'b1;

    //--------------------------------------------------------------------------
    // Read-only internal probes (never feed back into the DUT)
    //   r_inside : scanline parity at the entry of the beat -- the ONLY way to catch
    //              a "compute the 4 pixels of a beat in parallel" mutation, because
    //              such a mutation is output-equivalent (see RTL section 11).
    //--------------------------------------------------------------------------
    wire w_probe_inside = dut.r_inside;
    wire w_probe_tlast  = dut.r_tlast;
    wire w_probe_tuser  = dut.r_tuser;
    wire w_probe_vld2   = dut.r_vld1;

    //--------------------------------------------------------------------------
    // Independent delay chain (never reads DUT internals)
    //--------------------------------------------------------------------------
    reg [LAT-1:0] vsr;        // I_tvalid delay chain
    reg [LAT-1:0] lsr;        // I_tlast  delay chain (ANDed with valid)
    reg [LAT-1:0] usr;        // I_tuser  delay chain (ANDed with valid)

    always @ (posedge clk) begin
        if (!rst_n) begin
            vsr <= {LAT{1'b0}};
            lsr <= {LAT{1'b0}};
            usr <= {LAT{1'b0}};
        end else begin
            vsr <= {vsr[LAT-2:0], I_tvalid};
            lsr <= {lsr[LAT-2:0], I_tvalid && I_tlast};
            usr <= {usr[LAT-2:0], I_tvalid && I_tuser};
        end
    end

    integer n_in_vld;         // number of input valid beats
    integer n_out_vld;        // number of output valid beats
    integer n_lat_err;        // latency mismatches
    integer n_last_err;       // tlast mismatches
    integer n_user_err;       // tuser mismatches
    integer n_valid_err;      // tvalid mismatches
    integer n_value_err;      // valid-beat pixels that are neither FFFFFF nor 000000
    integer last_drv_cyc;

    initial begin
        n_in_vld     = 0;
        n_out_vld    = 0;
        n_lat_err    = 0;
        n_last_err   = 0;
        n_user_err   = 0;
        n_valid_err  = 0;
        n_value_err  = 0;
        last_drv_cyc = 0;
    end

    function automatic w_pix_legal;
        input [23:0] p;
        reg         a;
        reg         b;
        begin
            a = (p === 24'hFFFFFF);
            b = (p === 24'h000000);
            w_pix_legal = a | b;
        end
    endfunction

    integer fd;

    initial begin
        fd = $fopen("dump_rf.txt", "w");
        if (fd == 0) begin
            $display("FATAL: cannot open dump_rf.txt");
            $finish;
        end
        $readmemh("stim_rf.hex", stim);
        $display("TB: loaded %0d beats, BPL=%0d BPF=%0d FRAMES=%0d", NBEAT, BPL, BPF, FRAMES);
    end

    initial begin
        tb_cyc  = 32'd0;
        tb_flat = 32'd0;
        tb_beat = 32'd0;
        rst_n   = 1'b0;
        #1;
        repeat (RST_CYC) @(posedge clk);
        rst_n = 1'b1;
        $display("TB: reset released at cycle %0d", tb_cyc);
    end

    always @(posedge clk) begin
        $fwrite(fd, "%0d %b %b %b %h %b %b %b %h %b %b %b %b\n",
                tb_cyc,
                I_tvalid, I_tlast, I_tuser, I_tdata,
                O_tvalid, O_tlast, O_tuser, O_tdata,
                w_probe_inside, w_probe_tlast, w_probe_tuser, w_probe_vld2);

        if (I_tvalid)  n_in_vld  = n_in_vld + 1;
        if (O_tvalid)  n_out_vld = n_out_vld + 1;
        if (w_drv)     last_drv_cyc = tb_cyc;

        tb_cyc  <= tb_cyc + 32'd1;
        tb_flat <= tb_flat + 32'd1;
        if (w_drv)
            tb_beat <= tb_beat + 32'd1;

        if ((tb_beat >= NBEAT) && (tb_cyc >= (last_drv_cyc + LAT + 20))) begin
            $fclose(fd);
            $display("ASSERT in_vld=%0d out_vld=%0d  (must be equal)", n_in_vld, n_out_vld);
            $display("ASSERT lat_err=%0d last_err=%0d user_err=%0d valid_err=%0d xz_or_illegal=%0d",
                     n_lat_err, n_last_err, n_user_err, n_valid_err, n_value_err);
            if ((n_in_vld != n_out_vld) || (n_lat_err != 0) || (n_last_err != 0) ||
                (n_user_err != 0) || (n_valid_err != 0) || (n_value_err != 0))
                $display("TB-RESULT: FAIL");
            else
                $display("TB-RESULT: PASS");
            $finish;
        end
    end

    //--------------------------------------------------------------------------
    // Latency / same-cycle assertions at NEGEDGE (all NBAs of this posedge settled)
    //--------------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && (tb_cyc >= (START_CYC + LAT + 2))) begin
            if (O_tvalid !== vsr[LAT-1]) n_valid_err = n_valid_err + 1;
            if (O_tlast  !== lsr[LAT-1]) n_last_err  = n_last_err + 1;
            if (O_tuser  !== usr[LAT-1]) n_user_err  = n_user_err + 1;
            if (O_tvalid === 1'b1) begin
                if (!w_pix_legal(O_tdata[95:72])) n_value_err = n_value_err + 1;
                if (!w_pix_legal(O_tdata[71:48])) n_value_err = n_value_err + 1;
                if (!w_pix_legal(O_tdata[47:24])) n_value_err = n_value_err + 1;
                if (!w_pix_legal(O_tdata[23: 0])) n_value_err = n_value_err + 1;
            end
        end
    end

endmodule
