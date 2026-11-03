#==============================================================================
# run_hdmi_mixer.do -- vsim batch script for tb_hdmi_mixer
#
#   usage (from the sim directory):
#       vsim -c -lib work_mixer -wlf hdmi_mixer.wlf -l vsim_hdmi_mixer.log \
#            tb_hdmi_mixer -do run_hdmi_mixer.do
#
# VCD evidence: only the ports / reference registers are dumped (the official
# DUT is a full OSD cone -- a recursive dump would be tens of MB for nothing).
#==============================================================================

vcd file hdmi_mixer.vcd
vcd add /tb_hdmi_mixer/clk
vcd add /tb_hdmi_mixer/rst_n
vcd add /tb_hdmi_mixer/cyc
vcd add /tb_hdmi_mixer/I_vsync
vcd add /tb_hdmi_mixer/I_hsync
vcd add /tb_hdmi_mixer/I_de
vcd add /tb_hdmi_mixer/I_user
vcd add /tb_hdmi_mixer/I_last
vcd add /tb_hdmi_mixer/I_data
vcd add -r /tb_hdmi_mixer/u_new/*
vcd add /tb_hdmi_mixer/O_off_rd_en
vcd add /tb_hdmi_mixer/O_off_vsync
vcd add /tb_hdmi_mixer/O_off_hsync
vcd add /tb_hdmi_mixer/O_off_de
vcd add /tb_hdmi_mixer/O_off_data
vcd add /tb_hdmi_mixer/u_official/S_osd_hit

# WLF evidence: log the TB scope only (both DUTs' ports are visible as TB wires);
# a recursive log would drag the whole official OSD cone into the dataset.
log /tb_hdmi_mixer/*

run -all

vcd flush
echo "=== run_hdmi_mixer.do done, waveform in hdmi_mixer.vcd ==="
quit -f
