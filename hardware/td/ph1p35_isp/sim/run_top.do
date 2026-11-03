#==============================================================================
# run_top.do -- ModelSim run script for alg_top integration test
#   usage:  vsim -c -do run_top.do tb_alg_top
#   ASCII only: ModelSim 10.3c transcript cannot show Chinese.
#==============================================================================
vcd file alg_top.vcd
vcd add -r /tb_alg_top/u_dut/*
run -all
vcd flush
echo "=== run_top.do done, waveform -> alg_top.vcd ==="
quit -f
