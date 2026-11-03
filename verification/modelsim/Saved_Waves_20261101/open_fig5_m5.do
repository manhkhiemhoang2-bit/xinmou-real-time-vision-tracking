quit -sim
if {[catch {dataset open {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig5_m5.wlf} sim} err]} {puts $err}
do {C:/Users/29072/Desktop/ModelSim_RTL_Sim/Saved_Waves_20261101/fig5_m5_signals.do}
wave zoom full
