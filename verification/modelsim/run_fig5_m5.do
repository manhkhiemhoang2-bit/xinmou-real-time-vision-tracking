#===============================================================================
# ModelSim Auto-Run Script for Figure 5 (alg_color_gate + alg_runlen_bbox)
# Usage in ModelSim Transcript: do run_fig5_m5.do
#===============================================================================
quit -sim
if {[file exists work]} {
    vdel -lib work -all
}
vlib work
vmap work work

vlog -work work src/alg_color_gate.v
vlog -work work src/alg_runlen_bbox.v
vlog -work work tb/tb_fig5_m5_color_bbox.v

vsim -voptargs="+acc" work.tb_fig5_m5_color_bbox

view wave
delete wave *

add wave -divider "1. Pixel_Domain_Input (44.996MHz)"
add wave -color "Green"  -label "clk"              /tb_fig5_m5_color_bbox/clk
add wave -color "Yellow" -label "frame_start"      /tb_fig5_m5_color_bbox/frame_start
add wave -color "Cyan"   -label "pix_valid"        /tb_fig5_m5_color_bbox/pix_valid
add wave -radix unsigned -label "row_y[10:0]"      /tb_fig5_m5_color_bbox/row_y
add wave -radix unsigned -label "x_base[10:0]"     /tb_fig5_m5_color_bbox/x_base

add wave -divider "2. Relative_Color_Gate (alg_color_gate : REL_MODE=1)"
add wave -radix unsigned -label "I_r[7:0]"         /tb_fig5_m5_color_bbox/in_r
add wave -radix unsigned -label "I_g[7:0]"         /tb_fig5_m5_color_bbox/in_g
add wave -radix unsigned -label "I_b[7:0]"         /tb_fig5_m5_color_bbox/in_b
add wave -color "Orange" -label "w_rel_base"       /tb_fig5_m5_color_bbox/u_color_gate/w_rel_base
add wave -color "Red"    -label "O_hit_r"          /tb_fig5_m5_color_bbox/hit_r

add wave -divider "3. RunLen_Bridge_&_2D_Band (alg_runlen_bbox)"
add wave -color "Green"   -label "r_run_on"        /tb_fig5_m5_color_bbox/u_runlen_bbox/r_run_on
add wave -radix unsigned  -label "r_gap[7:0]"      /tb_fig5_m5_color_bbox/u_runlen_bbox/r_gap
add wave -color "Magenta" -label "w_gap_out"       /tb_fig5_m5_color_bbox/u_runlen_bbox/w_gap_out
add wave -radix unsigned  -label "w_run_len[10:0]" /tb_fig5_m5_color_bbox/u_runlen_bbox/w_run_len
add wave -radix unsigned  -label "r_best_len[10:0]" /tb_fig5_m5_color_bbox/u_runlen_bbox/r_best_len
add wave -color "Cyan"    -label "b_active"        /tb_fig5_m5_color_bbox/u_runlen_bbox/b_active
add wave -radix unsigned  -label "b_rows[15:0]"    /tb_fig5_m5_color_bbox/u_runlen_bbox/b_rows

add wave -divider "4. Frame_Latched_BBox_Output"
add wave -color "Yellow" -label "O_valid"          /tb_fig5_m5_color_bbox/bbox_valid
add wave -radix unsigned -label "O_rows[15:0]"     /tb_fig5_m5_color_bbox/bbox_rows
add wave -radix unsigned -label "O_x0[10:0]"       /tb_fig5_m5_color_bbox/bbox_x0
add wave -radix unsigned -label "O_x1[10:0]"       /tb_fig5_m5_color_bbox/bbox_x1
add wave -radix unsigned -label "O_y0[10:0]"       /tb_fig5_m5_color_bbox/bbox_y0
add wave -radix unsigned -label "O_y1[10:0]"       /tb_fig5_m5_color_bbox/bbox_y1

configure wave -namecolwidth 230
configure wave -valuecolwidth 90
configure wave -timelineunits ns

run -all
wave zoom full
