onerror {quit -code 2 -f}
transcript on
if {![file exists {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig7_awb_i2c}]} {vlib {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig7_awb_i2c}}
vmap savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/work_fig7_awb_i2c}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/src/awb_div20_core.v}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/src/gim_i2c_slave.v}
vlog -work savedwork {C:/Users/29072/Desktop/ModelSim_RTL_Sim/tb/tb_fig7_awb_and_i2c.v}
vsim -voptargs=+acc -wlf {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig7_awb_i2c.wlf} savedwork.tb_fig7_awb_and_i2c
log -r /*
vcd file {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig7_awb_i2c.vcd}
vcd add -r /*
run 38800 ns
set failed 0
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/in_r_r1]
puts "CHECK in_r_r1: actual=$actual expected=85196"
if {$actual ne "85196"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/in_b_r1]
puts "CHECK in_b_r1: actual=$actual expected=74711"
if {$actual ne "74711"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_cx_l]
puts "CHECK rd_cx_l: actual=$actual expected=232"
if {$actual ne "232"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_cx_h]
puts "CHECK rd_cx_h: actual=$actual expected=1"
if {$actual ne "1"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_cy_l]
puts "CHECK rd_cy_l: actual=$actual expected=25"
if {$actual ne "25"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_cy_h]
puts "CHECK rd_cy_h: actual=$actual expected=1"
if {$actual ne "1"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_valid_on]
puts "CHECK rd_valid_on: actual=$actual expected=1"
if {$actual ne "1"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_valid_off]
puts "CHECK rd_valid_off: actual=$actual expected=0"
if {$actual ne "0"} {incr failed}
set actual [examine -radix unsigned /tb_fig7_awb_and_i2c/rd_ver]
puts "CHECK rd_ver: actual=$actual expected=90"
if {$actual ne "90"} {incr failed}
vcd flush
if {$failed > 0} {puts "VERIFIED_CHECKS_FAILED=$failed"; quit -code 3 -f}
puts "VERIFIED_ALL_CHECKS_PASS"
quit -code 0 -f
