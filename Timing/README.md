# Timing

## STA_synthesized_netlist/ — the signoff result

Pre-layout static timing analysis on the synthesized gate netlist.
**Zero violations**: setup, hold, recovery and removal all met, with no
false-path waivers anywhere in the SDC.

| file | contents |
|---|---|
| `orchestrator_top.sdc` | the exact constraints used (generated, then read back) |
| `orchestrator_top.summary.rpt` | methodology + headline numbers |
| `orchestrator_top.setup.rpt` | worst setup paths, expanded clock detail |
| `orchestrator_top.hold.rpt` | worst hold paths |
| `orchestrator_top.setup_endpoints.rpt` | 50 worst endpoints per path group |
| `orchestrator_top.hold_endpoints.rpt` | same, hold |
| `orchestrator_top.check_setup.rpt` | constraint sanity check |
| `sta_run.log` | full tool log |

> `check_setup.rpt` is **empty by design** — OpenSTA prints nothing when there
> are no unclocked registers and no unconstrained endpoints. An empty file is
> the passing result.

Scope: this certifies timing (setup/hold/recovery/removal). Electrical-rule
closure (max-cap / max-slew) is an implementation-stage task and is out of
scope for netlist STA — the raw netlist has not been buffered or resized yet.
The resulting fanout loading is still fully reflected in the reported cell
delays, so the timing numbers are conservative rather than optimistic.

## CTS_characterization/ — what implementation buys

The same design taken through floorplan → placement → clock-tree synthesis →
post-CTS optimization, to measure the gap between the raw netlist and an
implemented one. Timing here uses placement-estimated parasitics.

Critical path 2948.5 ps (~339 MHz), hold +3.2 ps, clock tree of 10,398 sinks /
749 buffers / depth 5–6, skew 27.7 ps, 24.8 mW at 250 MHz.

`drv.rpt` in this directory does contain max-transition violations, and they
are real: they are dominated by the async reset (`rst_n`) fanning out to ~1,600
flops with no reset tree built — clock-tree synthesis builds the clock tree
only. Fixing that is reset-buffering work at the implementation stage; it does
not affect the setup/hold results above, which are clean.

## scripts/

`run_sta.sh` / `run_sta.tcl` and `run_cts.sh` / `run_cts.tcl` regenerate
everything here. They need a kit directory (`$KIT`) with the OpenROAD binary,
ASAP7 LEF/Liberty, and the synthesized netlist; neither the PDK nor the tool
binary is redistributed in this repository.
