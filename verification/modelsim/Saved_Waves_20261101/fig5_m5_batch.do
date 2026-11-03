onerror {quit -code 2 -f}
transcript on
if {![file exists {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig5_m5}]} {vlib {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig5_m5}}
vmap savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig5_m5}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/src/alg_color_gate.v}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/src/alg_runlen_bbox.v}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/tb/tb_fig5_m5_color_bbox.v}
vsim -voptargs=+acc -wlf {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig5_m5.wlf} savedwork.tb_fig5_m5_color_bbox
log -r /*
vcd file {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig5_m5.vcd}
vcd add -r /*
run 2500 ns
set failed 0
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_valid]
puts "CHECK bbox_valid: actual=$actual expected=1"
if {$actual ne "1"} {incr failed}
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_rows]
puts "CHECK bbox_rows: actual=$actual expected=6"
if {$actual ne "6"} {incr failed}
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_x0]
puts "CHECK bbox_x0: actual=$actual expected=460"
if {$actual ne "460"} {incr failed}
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_x1]
puts "CHECK bbox_x1: actual=$actual expected=503"
if {$actual ne "503"} {incr failed}
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_y0]
puts "CHECK bbox_y0: actual=$actual expected=10"
if {$actual ne "10"} {incr failed}
set actual [examine -radix unsigned /tb_fig5_m5_color_bbox/bbox_y1]
puts "CHECK bbox_y1: actual=$actual expected=15"
if {$actual ne "15"} {incr failed}
vcd flush
if {$failed > 0} {puts "VERIFIED_CHECKS_FAILED=$failed"; quit -code 3 -f}
puts "VERIFIED_ALL_CHECKS_PASS"
quit -code 0 -f
