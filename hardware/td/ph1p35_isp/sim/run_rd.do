#==============================================================================
# run_rd.do —— rgb_row_delay_96 · ModelSim 仿真脚本
#
# 用法（在 sim 目录下）：
#     vlib work
#     vlog tb_rgb_row_delay.v ../src/rgb_row_delay_96.v
#     vsim -c -do run_rd.do tb_rgb_row_delay
#
# English only in this file: ModelSim 10.3c transcript cannot show Chinese.
#==============================================================================

vcd file row_delay.vcd
vcd add -r /tb_rgb_row_delay/dut/*

run -all

vcd flush
echo "=== run_rd.do done, waveform written to row_delay.vcd ==="
quit -f
