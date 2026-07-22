# STA constraints for orchestrator_top - synthesized netlist, pre-layout, TT 0.7V 25C
# Best-case methodology: ideal interconnect, ideal clock. No false-path
# waivers; async-reset recovery/removal are timed and included.
set sdc_version 2.0
set_units -time ps -resistance kOhm -capacitance fF -voltage V -current mA

create_clock -name clk -period 5500 [get_ports clk]
set_clock_uncertainty -setup 110.0 [get_clocks clk]
set_clock_uncertainty -hold 10 [get_clocks clk]

# inputs: registered upstream, adequately buffered (50 ps transition)
set_input_delay -max 100 -clock clk [all_inputs -no_clocks]
set_input_delay -min  50 -clock clk [all_inputs -no_clocks]
set_input_transition 50 [all_inputs -no_clocks]

# outputs: 100 ps external setup, 10 fF pin load
set_output_delay -max 100 -clock clk [all_outputs]
set_output_delay -min   0 -clock clk [all_outputs]
set_load -pin_load 0.01 [all_outputs]
