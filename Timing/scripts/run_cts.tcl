# =============================================================================
#  CTS-ONLY flow: floorplan -> placement -> CTS -> post-CTS opt -> ESTIMATES.
#  No routing, no GDS. This is the v1 baseline characterization run:
#  timing + power + clock-tree stats at the CTS stage, to compare v2 against.
#
#  Numbers here use placement-estimated parasitics (Innovus "trial route" epoch,
#  i.e. timeDesign -postCTS). Expect post-route timing to be a few % worse and
#  power a few % higher once real wires exist - the 333 MHz APR run measured
#  routed WNS about 5-10% worse than its post-CTS estimate.
#
#  env: DESIGN (default orchestrator_top), CLK_PS (default = design DEF_PERIOD)
# =============================================================================
set K   $::env(KIT)
set TOP [expr {[info exists ::env(DESIGN)] ? $::env(DESIGN) : "orchestrator_top"}]
source $K/designs/$TOP.tcl
set P   [expr {[info exists ::env(CLK_PS)] ? $::env(CLK_PS) : $DEF_PERIOD}]
set RES $K/results/${TOP}_cts
file mkdir $RES

puts "#############################################################"
puts "#  CTS-only characterization : $TOP @ $P ps ([format %.1f [expr {1.0e6/$P}]] MHz)"
puts "#############################################################"

# ---- inputs (identical to run_pnr.tcl) --------------------------------------
read_lef $K/inputs/plat/asap7_tech_1x_201209.lef
read_lef $K/inputs/plat/asap7sc7p5t_28_R_1x_220121a.lef
read_lef $K/inputs/plat/asap7sc7p5t_28_L_1x_220121a.lef
read_lef $K/inputs/plat/asap7sc7p5t_28_SL_1x_220121a.lef
foreach f $EXTRA_LEF { read_lef $f }
foreach f [glob $K/inputs/plat/lib/*.lib] { read_liberty $f }
foreach f $EXTRA_LIB { read_liberty $f }
read_verilog $NETLIST
link_design $TOP

# ---- constraints (same generated-SDC style as run_pnr.tcl) ------------------
set UNC  [expr {max(20.0, 0.02*$P)}]
set IO   [expr {0.20*$P}]
set TRAN 100
set FO   16
set fh [open $RES/$TOP.sdc w]
puts $fh "set sdc_version 2.0"
puts $fh "set_units -time ps -resistance kOhm -capacitance fF -voltage V -current mA"
puts $fh "create_clock -name clk -period $P \[get_ports $CLK_PORT\]"
# uncertainty split: 2%-of-period is a SETUP margin. Applying it to hold too
# (what a bare set_clock_uncertainty does) manufactured 9746 fake hold
# violations at 4000ps -> 13k+ hold buffers -> RSZ-0060 abort. Hold margin
# models jitter+residual skew and stays fixed, not period-scaled.
puts $fh "set_clock_uncertainty -setup $UNC \[get_clocks clk\]"
puts $fh "set_clock_uncertainty -hold 10 \[get_clocks clk\]"
puts $fh "set_max_fanout $FO \[current_design\]"
puts $fh "set_max_transition $TRAN \[current_design\]"
puts $fh "set_driving_cell -lib_cell INVx3_ASAP7_75t_R -pin Y \[all_inputs -no_clocks\]"
puts $fh "set_load -pin_load 0.01 \[all_outputs\]"
puts $fh "set_input_delay  $IO -clock clk \[all_inputs -no_clocks\]"
puts $fh "set_output_delay $IO -clock clk \[all_outputs\]"
close $fh
read_sdc $RES/$TOP.sdc
set_dont_use { *x1p*_ASAP7* *xp*_ASAP7* SDF* ICG* }
source $K/inputs/plat/setRC.tcl

# ---- floorplan + placement --------------------------------------------------
initialize_floorplan -site asap7sc7p5t -utilization $UTIL -aspect_ratio 1.0 -core_space $CORE_SPACE
source $K/inputs/plat/openRoad/make_tracks.tcl
insert_tiecells TIEHIx1_ASAP7_75t_R/H -prefix "TIEHI_"
insert_tiecells TIELOx1_ASAP7_75t_R/L -prefix "TIELO_"
if {$HAS_MACROS} {
  if {[catch { rtl_macro_placer -halo_width 2 -halo_height 2 } e]} { puts "WARN macro placer: $e" }
}
place_pins -hor_layers M4 -ver_layers M5
tapcell -distance 25 -tapcell_master TAPCELL_ASAP7_75t_R
# no PDN: power stripes have zero effect on pre-route timing/power estimates,
# and pdngen on the real design costs minutes we don't need to spend here.

global_placement -density $DENSITY -routability_driven -timing_driven -pad_left 1 -pad_right 1
estimate_parasitics -placement
repair_design
detailed_placement

# ---- CTS + post-CTS optimization (Innovus: ccopt_design + optDesign -postCTS)
clock_tree_synthesis \
  -buf_list {BUFx2_ASAP7_75t_R BUFx3_ASAP7_75t_R BUFx4_ASAP7_75t_R BUFx5_ASAP7_75t_R \
             BUFx8_ASAP7_75t_R BUFx10_ASAP7_75t_R BUFx12_ASAP7_75t_R BUFx24_ASAP7_75t_R} \
  -root_buf BUFx4_ASAP7_75t_R \
  -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_timing -setup
# catch-wrapped: if hold repair exhausts its buffer budget (RSZ-0060) that is a
# result to REPORT (remaining hold WNS shows below), not a reason to abort the
# whole characterization and lose every report.
if {[catch { repair_timing -hold -max_buffer_percent 30 } e]} { puts "WARN hold repair: $e" }
if {[catch { detailed_placement } e]} {
  puts "WARN detailed_placement retry: $e"
  detailed_placement -max_displacement {1000 200}
}
check_placement

# ---- reports ----------------------------------------------------------------
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded -digits 3 -group_count 5 > $RES/$TOP.setup.rpt
report_checks -path_delay min -format full_clock_expanded -digits 3 -group_count 5 > $RES/$TOP.hold.rpt
report_check_types -max_slew -max_capacitance -max_fanout -violators > $RES/$TOP.drv.rpt
catch { report_clock_skew > $RES/$TOP.skew.rpt }
catch { report_cts -out_file $RES/$TOP.cts_stats.rpt }

catch {
  set_power_activity -input -activity 0.2 -duty 0.5
  report_power -digits 4 > $RES/$TOP.power.rpt
}

# area from odb (report_design_area ignores "> file" redirection)
set blk [ord::get_db_block] ; set dbu [$blk getDefUnits]
set die [$blk getDieArea]   ; set core [$blk getCoreArea]
set die_w  [expr {([$die  xMax]-[$die  xMin])/double($dbu)}]
set die_h  [expr {([$die  yMax]-[$die  yMin])/double($dbu)}]
set core_w [expr {([$core xMax]-[$core xMin])/double($dbu)}]
set core_h [expr {([$core yMax]-[$core yMin])/double($dbu)}]
set cell_area 0.0 ; set n_cells 0
foreach inst [$blk getInsts] {
  set m [$inst getMaster] ; set t [$m getType]
  if {$t eq "CORE_SPACER" || $t eq "CORE_WELLTAP"} { continue }
  incr n_cells
  set cell_area [expr {$cell_area + [$m getWidth]*[$m getHeight]/double($dbu*$dbu)}]
}

# fmax estimate from post-CTS worst slack.
# NB: sta::worst_slack -max returns ps (display units); sta::worst_slack_cmd
# returns SECONDS - using the latter silently gives "0.0 ps" slack. Verified.
set fmax_line "fmax estimate     : (see setup.rpt - slack API unavailable)"
if {![catch { set ws [sta::worst_slack -max] }]} {
  set eff [expr {$P - $ws}]
  if {$eff > 0} {
    set fmax_line [format "fmax estimate     : %.1f MHz  (period %s ps - worst slack %.1f ps = %.1f ps critical path)" \
                   [expr {1.0e6/$eff}] $P $ws $eff]
  }
}

set fh [open $RES/$TOP.summary.rpt w]
puts $fh "============ CTS CHARACTERIZATION : $TOP ============"
puts $fh "stage             : post-CTS (placement parasitics - NOT routed)"
puts $fh "clock period      : $P ps ([format %.1f [expr {1.0e6/$P}]] MHz)"
puts $fh "clock uncertainty : $UNC ps"
puts $fh $fmax_line
puts $fh "----------------------------------------------------"
puts $fh [format "die  %.2f x %.2f um   core %.2f x %.2f um" $die_w $die_h $core_w $core_h]
puts $fh [format "cell area %.2f um^2   (%d functional instances)" $cell_area $n_cells]
puts $fh "----------------------------------------------------"
close $fh
report_worst_slack -max >> $RES/$TOP.summary.rpt
report_worst_slack -min >> $RES/$TOP.summary.rpt
report_tns              >> $RES/$TOP.summary.rpt

write_verilog $RES/$TOP.cts.v
write_db      $RES/$TOP.cts.odb

puts "===== POST-CTS TIMING ====="
report_worst_slack -max
report_worst_slack -min
puts "===== CTS CHARACTERIZATION COMPLETE ($TOP @ ${P}ps) ====="
