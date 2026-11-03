#==============================================================================
# gui.do —— 在 ModelSim 图形界面里直接跑仿真并摆好波形
#
# 为什么不用 VCD/WLF：
#   1. VCD 不是 ModelSim 波形窗口的原生格式，要先转 WLF，多一道手续
#   2. 之前的 run.do 只录了 /tb_win3x3/dut/*，测试平台自己的信号没录进去
#   直接在 GUI 里跑活的仿真，任何层次的信号都能加，没有这些问题。
#
# 用法：双击同目录下的「看波形.bat」
#==============================================================================

# 切到工作目录（必须用 cd，否则 ModelSim 会把绝对路径当相对路径拼到安装目录后面）
cd {C:/Users/29072/deepseek_harness_workspace/sim_win3x3}

vlib work
vlog tb_win3x3.v win3x3_96_sim.v

vsim tb_win3x3

# ---- 输入侧（测试平台产生）----
add wave -divider "输入 I_*  —— 应比输出早 2 拍"
add wave -label "I_tvalid"  /tb_win3x3/I_tvalid
add wave -label "I_tuser"   /tb_win3x3/I_tuser
add wave -label "I_tlast"   /tb_win3x3/I_tlast
add wave -label "I_tdata"   -radix hex /tb_win3x3/I_tdata

# ---- 输出侧（DUT 输出）----
add wave -divider "输出 O_*  —— 与输入恒差 2 拍"
add wave -label "O_tvalid"        /tb_win3x3/O_tvalid
add wave -label "O_window_valid"  /tb_win3x3/O_window_valid
add wave -label "O_tlast"         /tb_win3x3/O_tlast
add wave -label "O_tuser"         /tb_win3x3/O_tuser
add wave -label "O_tdata"  -radix hex /tb_win3x3/O_tdata
add wave -label "O_window" -radix hex /tb_win3x3/O_window

# ---- DUT 内部：坐标与流水 ----
add wave -divider "DUT 内部：坐标"
add wave -label "r_x (拍号)"  -radix unsigned /tb_win3x3/dut/r_x
add wave -label "r_y (行号)"  -radix unsigned /tb_win3x3/dut/r_y
add wave -label "r_gray"      -radix hex      /tb_win3x3/dut/r_gray

# ---- DUT 内部：行缓冲（前几拍应为 X）----
add wave -divider "DUT 内部：行缓冲（开头是 X）"
add wave -label "r_line1_mem\[0\]" -radix hex /tb_win3x3/dut/r_line1_mem\[0\]
add wave -label "r_line2_mem\[0\]" -radix hex /tb_win3x3/dut/r_line2_mem\[0\]

# ---- 跑 ----
run -all
wave refresh
echo "=== 波形已就绪。点 Zoom Full 看全貌；拖光标可逐拍对照。 ==="
