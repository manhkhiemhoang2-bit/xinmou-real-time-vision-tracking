#==============================================================================
# view.do —— 打开 win3x3.wlf 并自动摆好波形
#
# 用法：双击同目录下的「打开波形.bat」，或者手工：
#     modelsim.exe -view win3x3.wlf -do view.do
#
# 注意：ModelSim 的波形窗口**只认 WLF 格式**，不认 VCD。
#       所以 win3x3.vcd 要先转：
#           vcd2wlf win3x3.vcd win3x3.wlf
#==============================================================================

# ---- 输入侧 ----
add wave -divider "输入 (I_*)"
add wave -label "I_tvalid"        /tb_win3x3/I_tvalid
add wave -label "I_tuser"         /tb_win3x3/I_tuser
add wave -label "I_tlast"         /tb_win3x3/I_tlast
add wave -label "I_tdata" -radix hex /tb_win3x3/I_tdata

# ---- 输出侧 ----
add wave -divider "输出 (O_*)  —— 应比输入晚 2 拍"
add wave -label "O_tvalid"        /tb_win3x3/O_tvalid
add wave -label "O_window_valid"  /tb_win3x3/O_window_valid
add wave -label "O_tlast"         /tb_win3x3/O_tlast
add wave -label "O_tuser"         /tb_win3x3/O_tuser
add wave -label "O_tdata" -radix hex /tb_win3x3/O_tdata
add wave -label "O_window" -radix hex /tb_win3x3/O_window

# ---- 内部信号（想往下钻的时候看这些）----
add wave -divider "内部：坐标与流水"
add wave -label "r_x (拍号)" -radix unsigned /tb_win3x3/dut/r_x
add wave -label "r_y (行号)" -radix unsigned /tb_win3x3/dut/r_y
add wave -label "r_gray" -radix hex /tb_win3x3/dut/r_gray

add wave -divider "内部：行缓冲（前几拍应为 X）"
add wave -label "r_line1_mem[0]" -radix hex /tb_win3x3/dut/r_line1_mem[0]
add wave -label "r_line2_mem[0]" -radix hex /tb_win3x3/dut/r_line2_mem[0]

wave refresh
echo "=== 波形已加载。点工具栏 Zoom Full 看全貌；拖光标可逐拍对照。 ==="
