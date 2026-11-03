quit -sim
if {[catch {dataset open {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig7_awb_i2c.wlf} sim} err]} {puts $err}
do {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig7_awb_i2c_signals.do}
wave zoom full
