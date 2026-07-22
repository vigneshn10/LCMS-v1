# RTL

Three directories, each self-contained and independently simulatable with
cocotb + Icarus Verilog.

| directory | top module | testbench |
|---|---|---|
| `Fastpath/` | `fastpath_top` | 256-vector golden replay + observation ports |
| `Slowpath/` | `slowpath_top` | golden vector replay |
| `Cache/` | `orchestrator_top` | 9 suites, integrated |

Each contains its own copy of `fakeram7_256x8.v` (the SRAM behavioural model),
its golden vectors as `.jsonl`, and a `run.sh`. `results.xml` is the cocotb
JUnit output from the last run — all suites pass.

`Fastpath/golden/` is a standalone EDA Playground bundle containing the
reference model (`design.sv`) that the RTL is checked against; see the
`README.txt` inside it for pane-by-pane setup.

`Cache/` carries its own copies of `fastpath.sv` and `slowpath.sv` so the
integrated testbench runs without reaching outside its directory. They are
identical to the per-path copies.

## Running

```bash
cd RTL/Cache && ./run.sh
```

Needs `cocotb` and `iverilog` (Icarus 12+; the oss-cad-suite build is stricter
about the SRAM model's port declarations and is the one these were validated
against).
