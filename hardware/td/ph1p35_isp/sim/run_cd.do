#==============================================================================
# run_cd.do —— alg_color_detect_96 (M5) · ModelSim 仿真脚本
#
# 用法（在 sim 目录下）：
#     vlib work
#     vlog tb_alg_color_detect_96.v ../src/alg_color_detect_96.v
#     vsim -c -do run_cd.do tb_alg_color_detect
#
# English only in this file: ModelSim 10.3c transcript cannot show Chinese.
#==============================================================================

vcd file color_detect.vcd
vcd add -r /tb_alg_color_detect/dut/*

run -all

vcd flush
echo "=== run_cd.do done, waveform written to color_detect.vcd ==="
quit -f
