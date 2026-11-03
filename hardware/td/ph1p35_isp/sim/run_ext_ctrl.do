#==============================================================================
# run_ext_ctrl.do —— ModelSim 波形脚本（可选）
#   用法： vsim -c -do run_ext_ctrl.do -work work_ext tb_ext_ctrl
#   只记录关键信号，避免 400k 拍计数器把 VCD 撑爆。
#==============================================================================
vcd file ext_ctrl.vcd
vcd add /tb_ext_ctrl/u_dut/I_frame
vcd add /tb_ext_ctrl/u_dut/r_val
vcd add /tb_ext_ctrl/u_dut/r_x0
vcd add /tb_ext_ctrl/u_dut/r_x1
vcd add /tb_ext_ctrl/u_dut/r_y0
vcd add /tb_ext_ctrl/u_dut/r_y1
vcd add /tb_ext_ctrl/u_dut/r_gap_cnt
vcd add /tb_ext_ctrl/u_dut/r_beep_on
vcd add /tb_ext_ctrl/u_dut/O_led
vcd add /tb_ext_ctrl/u_dut/O_buzzer

run -all

vcd flush
echo "=== run_ext_ctrl.do done, waveform -> ext_ctrl.vcd ==="
quit -f
