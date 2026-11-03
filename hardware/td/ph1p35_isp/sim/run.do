#==============================================================================
# run.do —— win3x3_96 · ModelSim 仿真脚本（S3）
#
# 用法（在 ASCII 工作目录下）：
#     vlib work
#     vlog tb_win3x3.v win3x3_96_sim.v
#     vsim -c -do run.do tb_win3x3
#
# 说明：win3x3_96_sim.v 是 S1 源码 win3x3_96.v 的 ASCII 路径副本，
#       拷贝时用 SHA256 校验过与源文件一致（中文路径下 ModelSim 10.3c 读不了）。
#==============================================================================

# 波形证据（比赛报告用）。必须在 run 之前建立。
vcd file win3x3.vcd
vcd add -r /tb_win3x3/dut/*

run -all

vcd flush
echo "=== run.do 结束，波形已写入 win3x3.vcd ==="
quit -f
