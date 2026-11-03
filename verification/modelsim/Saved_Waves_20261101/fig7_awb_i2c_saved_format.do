onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -divider {1. AWB_20_Iter_Restoring_Divider (awb_div20_core)}
add wave -noupdate -color Green -label pix_clk /tb_fig7_awb_and_i2c/pix_clk
add wave -noupdate -color Yellow -label I_tvalid_r1 /tb_fig7_awb_and_i2c/awb_trig
add wave -noupdate -label {div_cnt[4:0]} -radix unsigned /tb_fig7_awb_and_i2c/div_cnt
add wave -noupdate -label {quo_r[19:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/quo_r
add wave -noupdate -label {quo_b[19:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/quo_b
add wave -noupdate -color Cyan -label div_done /tb_fig7_awb_and_i2c/div_done
add wave -noupdate -label {in_r_r1[19:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/in_r_r1
add wave -noupdate -label {in_b_r1[19:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/in_b_r1
add wave -noupdate -divider {2. I2C_Slave_CDC_&_B4_Gate (gim_i2c_slave : 0x50)}
add wave -noupdate -color Green -label clk_50m /tb_fig7_awb_and_i2c/clk_50m
add wave -noupdate -color Yellow -label I_pix_frame /tb_fig7_awb_and_i2c/pix_frame
add wave -noupdate -color Cyan -label w_upd /tb_fig7_awb_and_i2c/u_i2c_slave/w_upd
add wave -noupdate -label {r_cx_s[11:0]} -radix unsigned /tb_fig7_awb_and_i2c/u_i2c_slave/r_cx_s
add wave -noupdate -label {r_cy_s[11:0]} -radix unsigned /tb_fig7_awb_and_i2c/u_i2c_slave/r_cy_s
add wave -noupdate -color Orange -label I_track_en(B4) /tb_fig7_awb_and_i2c/track_en_b4
add wave -noupdate -color Red -label r_trk_s /tb_fig7_awb_and_i2c/u_i2c_slave/r_trk_s
add wave -noupdate -divider {3. I2C_Burst_Read_&_B4_Stop_Verification}
add wave -noupdate -color Green -label I_scl /tb_fig7_awb_and_i2c/i2c_scl
add wave -noupdate -color Cyan -label sda_bus /tb_fig7_awb_and_i2c/sda_bus
add wave -noupdate -label {r_state[2:0]} -radix unsigned /tb_fig7_awb_and_i2c/u_i2c_slave/r_state
add wave -noupdate -label {r_ptr[7:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/u_i2c_slave/r_ptr
add wave -noupdate -label {r_rdata[7:0]} -radix hexadecimal /tb_fig7_awb_and_i2c/u_i2c_slave/r_rdata
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ps} 0}
quietly wave cursor active 0
configure wave -namecolwidth 235
configure wave -valuecolwidth 90
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {0 ps} {40740 ns}
