#==============================================================================
# run_lat.do -- lat_measure standalone self-checking testbench
#
# usage (in sim dir):
#     vlib work_lat
#     vlog -work work_lat tb_lat_measure.v ../src/lat_measure.v
#     vsim -c -do run_lat.do work_lat.tb_lat_measure
#
# English only in this file: ModelSim 10.3c transcript cannot show Chinese.
# The TB finishes itself ($finish); quit -f guarantees no stray vsim process.
#==============================================================================

run -all

quit -f
