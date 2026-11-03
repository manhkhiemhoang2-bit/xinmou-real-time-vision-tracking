view wave
delete wave *

add wave -divider "1. AWB_20_Iter_Restoring_Divider (awb_div20_core)"
add wave -color "Green"  -label {pix_clk}          /tb_fig7_awb_and_i2c/pix_clk
add wave -color "Yellow" -label {I_tvalid_r1}      /tb_fig7_awb_and_i2c/awb_trig
add wave -radix unsigned -label {div_cnt[4:0]}     /tb_fig7_awb_and_i2c/div_cnt
add wave -radix hex      -label {quo_r[19:0]}      /tb_fig7_awb_and_i2c/quo_r
add wave -radix hex      -label {quo_b[19:0]}      /tb_fig7_awb_and_i2c/quo_b
add wave -color "Cyan"   -label {div_done}         /tb_fig7_awb_and_i2c/div_done
add wave -radix hex      -label {in_r_r1[19:0]}    /tb_fig7_awb_and_i2c/in_r_r1
add wave -radix hex      -label {in_b_r1[19:0]}    /tb_fig7_awb_and_i2c/in_b_r1

add wave -divider "2. I2C_Slave_CDC_&_B4_Gate (gim_i2c_slave : 0x50)"
add wave -color "Green"  -label {clk_50m}          /tb_fig7_awb_and_i2c/clk_50m
add wave -color "Yellow" -label {I_pix_frame}      /tb_fig7_awb_and_i2c/pix_frame
add wave -color "Cyan"   -label {w_upd}            /tb_fig7_awb_and_i2c/u_i2c_slave/w_upd
add wave -radix unsigned -label {r_cx_s[11:0]}     /tb_fig7_awb_and_i2c/u_i2c_slave/r_cx_s
add wave -radix unsigned -label {r_cy_s[11:0]}     /tb_fig7_awb_and_i2c/u_i2c_slave/r_cy_s
add wave -color "Orange" -label {I_track_en(B4)}   /tb_fig7_awb_and_i2c/track_en_b4
add wave -color "Red"    -label {r_trk_s}          /tb_fig7_awb_and_i2c/u_i2c_slave/r_trk_s

add wave -divider "3. I2C_Burst_Read_&_B4_Stop_Verification"
add wave -color "Green"  -label {I_scl}            /tb_fig7_awb_and_i2c/i2c_scl
add wave -color "Cyan"   -label {sda_bus}          /tb_fig7_awb_and_i2c/sda_bus
add wave -radix unsigned -label {r_state[2:0]}     /tb_fig7_awb_and_i2c/u_i2c_slave/r_state
add wave -radix hex      -label {r_ptr[7:0]}       /tb_fig7_awb_and_i2c/u_i2c_slave/r_ptr
add wave -radix hex      -label {r_rdata[7:0]}     /tb_fig7_awb_and_i2c/u_i2c_slave/r_rdata

configure wave -namecolwidth 235
configure wave -valuecolwidth 90
configure wave -timelineunits ns

