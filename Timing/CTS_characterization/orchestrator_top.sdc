set sdc_version 2.0
set_units -time ps -resistance kOhm -capacitance fF -voltage V -current mA
create_clock -name clk -period 4000 [get_ports clk]
set_clock_uncertainty -setup 80.0 [get_clocks clk]
set_clock_uncertainty -hold 10 [get_clocks clk]
set_max_fanout 16 [current_design]
set_max_transition 100 [current_design]
set_driving_cell -lib_cell INVx3_ASAP7_75t_R -pin Y [all_inputs -no_clocks]
set_load -pin_load 0.01 [all_outputs]
set_input_delay  800.0 -clock clk [all_inputs -no_clocks]
set_output_delay 800.0 -clock clk [all_outputs]
