fastpath_golden.zip — EDA Playground bundle (fast path)

WHERE EACH FILE GOES
  design.sv                RIGHT pane (Design), main tab
  fakeram7_256x8.v         RIGHT pane, add with "+"
  testbench.py             LEFT  pane (Testbench), main tab
  golden_vectors_v3.jsonl  LEFT  pane, add with "+"

  Settings: "Testbench + Design" = Python + Verilog/SystemVerilog

WHY fakeram7_256x8.v NEEDS THE "+" TAB
  EDA Playground only auto-compiles tabs literally named design.* and
  testbench.*. Everything else is ignored unless `include-d. design.sv already
  has `include "fakeram7_256x8.v" at the top, so the tab just has to exist.
  Do NOT paste the SRAM module into design.sv — a hand-pasted copy is what
  caused the "Unable to bind parameter `BITS'" elaboration failure.

WHAT RUNS
  Two cocotb tests:
    fastpath_all       256-vector golden replay (zero weights), random-preload
                       mirror replay, training/saturation/stash, theta bounds
    observation_ports  obs_weights / obs_idx correctness + cycle alignment

OTHER FLOWS — same single file list
  iverilog -g2012 -s fastpath_top design.sv
  yosys -p "read_verilog -sv design.sv; hierarchy -top fastpath_top; ..."
  (fakeram7_256x8.v has an include guard, so passing it explicitly too is safe)

GOLDEN VECTORS
  Regenerated deterministically from VECTOR_SEED. Unlike the old notebook's
  shared global rng, this does not depend on which cells you ran first.
