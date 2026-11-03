#==============================================================================
# waves.do -- add waves, then run.  There is deliberately NO "vsim" here.
#
# Launch:   modelsim.exe tb_win3x3 -do waves.do
#
# NOTE 1  Never call "vsim" inside a do-file launched via "-do <thisfile>":
#         ModelSim passes the original -do argument down and this file would
#         be executed a second time.
# NOTE 2  Keep every echo ASCII-only.  ModelSim 10.3c garbles Chinese text in
#         the transcript window.
# NOTE 3  "run -all" runs into the testbench's $finish, which makes ModelSim
#         pop up "Are you sure you want to finish?".  So run a fixed 1400 ns
#         instead.  That covers every beat (60..1330 ns) and every output
#         (80..1350 ns) and never reaches $finish.
# NOTE 4  onfinish stop is a safety net for the case where someone presses
#         "Run -All" by hand afterwards.
#==============================================================================

onfinish stop

add wave -divider "INPUT I_*  -- 2 clocks EARLIER than output"
add wave -label "I_tvalid" /tb_win3x3/I_tvalid
add wave -label "I_tuser"  /tb_win3x3/I_tuser
add wave -label "I_tlast"  /tb_win3x3/I_tlast
add wave -label "I_tdata"  -radix hex /tb_win3x3/I_tdata

add wave -divider "OUTPUT O_*  -- exactly 2 clocks behind input"
add wave -label "O_tvalid"       /tb_win3x3/O_tvalid
add wave -label "O_window_valid" /tb_win3x3/O_window_valid
add wave -label "O_tlast"        /tb_win3x3/O_tlast
add wave -label "O_tuser"        /tb_win3x3/O_tuser
add wave -label "O_tdata"  -radix hex /tb_win3x3/O_tdata
add wave -label "O_window" -radix hex /tb_win3x3/O_window

add wave -divider "DUT INTERNAL -- counters"
add wave -label "r_x beat"  -radix unsigned /tb_win3x3/dut/r_x
add wave -label "r_y row"   -radix unsigned /tb_win3x3/dut/r_y
add wave -label "r_gray"    -radix hex      /tb_win3x3/dut/r_gray

add wave -divider "DUT INTERNAL -- line buffers (start as X)"
add wave -label "line1_mem_0" -radix hex /tb_win3x3/dut/r_line1_mem(0)
add wave -label "line2_mem_0" -radix hex /tb_win3x3/dut/r_line2_mem(0)

echo "=== adding waves ... ==="

run 1400ns

echo "=== DONE: waveform ready, no finish dialog. Click Zoom Full to fit. ==="
