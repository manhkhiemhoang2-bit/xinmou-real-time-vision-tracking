#==============================================================================
# nicewave.do -- 整理波形显示：分组 + 短标签 + 正确进制
#
# 用法（ModelSim 已加载仿真、波形窗口已打开的情况下）：
#     1. 在波形窗口里 Ctrl+A 全选，按 Delete 清空
#     2. 在底部 Transcript 窗口里敲：   do nicewave.do
#     3. 再敲：   wave zoom full     （看全貌）
#
# 说明：
#   · 本文件不含 vsim、也不含 run，什么时候跑都安全，不会动仿真状态。
#   · 标签一律用 ASCII。ModelSim 10.3c 对中文支持不好（transcript 里中文
#     会变成乱码），波形标签同理，所以不冒险用中文。
#   · -radix hex      = 十六进制，适合宽数据总线
#     -radix unsigned = 无符号十进制，适合计数器
#==============================================================================

# 时间轴改纳秒（默认是皮秒，数字太长）；名字列放宽一点
catch {configure wave -timelineunits ns}
catch {configure wave -signalnamewidth 2}

#------------------------------------------------------------------ 输入
add wave -divider "=== INPUT  (2 clocks EARLIER than output) ==="
add wave -label "I_tvalid"          /tb_win3x3/I_tvalid
add wave -label "I_tuser  SOF"      /tb_win3x3/I_tuser
add wave -label "I_tlast  EOL"      /tb_win3x3/I_tlast
add wave -label "I_tdata  96bit"    -radix hex /tb_win3x3/I_tdata

#------------------------------------------------------------------ 输出
add wave -divider "=== OUTPUT (exactly 2 clocks LATER) ==="
add wave -label "O_tvalid"          /tb_win3x3/O_tvalid
add wave -label "O_window_valid"    /tb_win3x3/O_window_valid
add wave -label "O_tlast"           /tb_win3x3/O_tlast
add wave -label "O_tuser"           /tb_win3x3/O_tuser
add wave -label "O_tdata  96bit"    -radix hex /tb_win3x3/O_tdata
add wave -label "O_window 288bit"   -radix hex /tb_win3x3/O_window

#------------------------------------------------ 计数器（十进制最好读）
add wave -divider "=== COUNTERS (decimal - read these two) ==="
add wave -label "beat  r_x"         -radix unsigned /tb_win3x3/dut/r_x
add wave -label "row   r_y"         -radix unsigned /tb_win3x3/dut/r_y

#------------------------------------------------ 灰度与行缓冲
add wave -divider "=== INTERNAL: gray and line buffers ==="
add wave -label "r_gray"            -radix hex /tb_win3x3/dut/r_gray
add wave -label "line1_mem0"        -radix hex /tb_win3x3/dut/r_line1_mem(0)
add wave -label "line2_mem0"        -radix hex /tb_win3x3/dut/r_line2_mem(0)

catch {wave zoom full}
echo "=== nicewave.do DONE ==="
