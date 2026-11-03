#==============================================================================
# run_alg.do -- ModelSim run script for M2/M3/M4 window operators
#   usage:  vsim -c -do run_alg.do tb_alg_ops
#   ASCII only: ModelSim 10.3c transcript cannot show Chinese.
#==============================================================================
vcd file alg_ops.vcd
vcd add -r /tb_alg_ops/u_bin/*
vcd add -r /tb_alg_ops/u_sob/*
vcd add -r /tb_alg_ops/u_smo/*
run -all
vcd flush
echo "=== run_alg.do done, waveform -> alg_ops.vcd ==="
quit -f
