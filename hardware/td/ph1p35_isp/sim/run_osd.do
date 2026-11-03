#==============================================================================
# run_osd.do —— osd_mixer · ModelSim 仿真脚本
#
# 用法（在本目录下）：
#     vlib work
#     vlog -sv tb_osd_mixer.v ../src/osd_mixer.v ../src/my_logo_rom.v ../src/my_charlib.v \
#          ../prj/board/lab_ex3_osd/user_source/hdl_source/anlogic_logo_rom.v
#     vsim -c -do run_osd.do tb_osd_mixer
#
# ⚠ 2026-09-17（G1）：osd_mixer v1.4 起例化了官方 anlogic_logo_rom（比赛基础要求
#   (4)「画面须含安路标识」），**编译清单必须带上那个文件**，否则报模块未定义。
#
# 说明：-sv 只是为了让仿真器接受更宽的语法集合；RTL 本身是纯 Verilog-2001。
#       波形证据写到 osd_mixer.vcd，dump_osd.txt 交给 check_osd.py 断言。
#==============================================================================

vcd file osd_mixer.vcd
vcd add -r /tb_osd_mixer/dut/*

run -all

vcd flush
echo "=== run_osd.do done, waveform in osd_mixer.vcd ==="
quit -f
