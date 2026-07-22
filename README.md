# LCMS — Learned Cache Management System (v1)

A two-tier learned cache-management accelerator in SystemVerilog, synthesized to
the ASAP7 7nm predictive PDK and closed with a violation-free static timing
analysis.

The design predicts whether a cache line is worth keeping, and *learns the
prediction policy at runtime* — a fast path answers every request in one cycle,
while a slow path trains a GRU meta-learner in the background off the critical
path.

---

## Architecture

```
                   ┌─────────────────────────────────────────┐
   request ───────►│  FAST PATH  (latency)                   │───► keep / bypass
                   │  7-perspective hashed perceptron        │     + confidence
                   │  7 × 256×8 SRAM weight banks            │
                   │  1-cycle prediction, RMW training queue │
                   └────────────┬────────────────────────────┘
                    observations│      ▲ gates, theta
                                ▼      │
                   ┌─────────────────────────────────────────┐
                   │  SLOW PATH  (throughput)                │
                   │  GRU meta-learner, 3 × 256×8 SRAM banks │
                   │  learns the per-perspective gates       │
                   └─────────────────────────────────────────┘
                                 ▲
                   ┌─────────────┴───────────────────────────┐
                   │  ORCHESTRATOR — sampler table, mode FSM,│
                   │  tuning latch, CSR/backdoor, statistics │
                   └─────────────────────────────────────────┘
```

**Fast path** — a hashed perceptron predictor with 7 independent perspectives.
Each request XOR-folds `{pc, addr, tag, pc_hist, set_idx, reuse_bucket}` into 7
bank indices, reads one signed 8-bit weight per bank, scales each by a
runtime-tuned Q1.7 gate, and sums them in a balanced adder tree. The sign is the
prediction; `|sum| < theta` flags low confidence. Training happens in the
background as saturating ±1 read-modify-write pairs that drain onto bank-idle
cycles, so a prediction is **never** stalled by learning.

**Slow path** — a GRU meta-learner. One sampled observation is one GRU timestep;
the hidden state persists across observations, so the sampled stream *is* the
sequence. It outputs the 7 perceptron gates plus theta, which the orchestrator
applies atomically through a tuning latch.

**Orchestrator** — samples 1 in 4 predictions into a 64-entry table, joins them
with outcomes when they arrive, feeds labelled observations to the learner,
arbitrates the CSR/debug backdoor, and exposes statistics counters.

## Results

### Timing — violation-free ([`Timing/`](Timing/))

Static timing analysis on the synthesized netlist, ASAP7 TT 0.7 V 25 °C:

| | |
|---|---|
| Clock | 5500 ps → **181.8 MHz** |
| Worst setup slack | **+167.7 ps** (TNS 0.00) |
| Worst hold slack | **+12.9 ps** |
| Recovery / removal | timed and met — **no false-path waivers** |
| `check_setup` | clean — every register clocked, every endpoint constrained |
| Violations | **zero** |

Methodology is stated in the report header and the SDC: pre-layout STA with
ideal interconnect and an ideal clock, 2 % setup / 10 ps hold uncertainty,
100 ps I/O delays with a 50 ps input transition. Fanout loading is fully
reflected in the cell delays. No path is excluded from analysis.

A second characterization run takes the design through floorplan, placement and
clock-tree synthesis to measure what implementation buys:

| | post-CTS |
|---|---|
| Critical path | 2948.5 ps → **~339 MHz** |
| Clock tree | 10,398 sinks, 749 buffers, depth 5–6, skew 27.7 ps |
| Power @ 250 MHz | 24.8 mW (macro 32.5 %, comb 33 %, seq 22 %, clock 12.5 %) |
| Die | 207 × 207 µm |

Both numbers are true at different stages: 181.8 MHz is the raw synthesized
netlist before any buffering or resizing, and ~339 MHz is the same design after
`repair_design` / `repair_timing` have done their work.

### Synthesis ([`Synthesis/`](Synthesis/))

Yosys → ASAP7 rev28 RVT, TT corner.

| | |
|---|---|
| Cells | 55,055 |
| Sequential | 10,388 flops (46.7 % of area) |
| SRAM macros | 10 × `fakeram7_256x8` |
| Cell area | 6788.2 µm² |

### Verification ([`RTL/`](RTL/))

cocotb testbenches against golden reference vectors, all passing:

- **Fast path** — 256-vector golden replay, observation-port checks
- **Slow path** — golden vector replay
- **Integrated** — 9 suites: replay, RAM behaviour, timing, sampler race,
  drop policy, join aliasing, training starvation, learning convergence, summary

## Repository layout

```
RTL/
  Fastpath/      fastpath.sv, cocotb testbench, golden vectors, SRAM model
    golden/      standalone EDA-Playground bundle + reference model
  Slowpath/      slowpath.sv, testbench, vectors, SRAM model
  Cache/         orchestrator_top.sv + both paths, integrated testbench
Synthesis/       synth.ys, synth.log, gate netlist (.v/.json), cell statistics
Schematics/      SVG schematics of each module and the full architecture
  dot_sources/   the graphviz sources they were rendered from
Timing/
  STA_synthesized_netlist/   the violation-free STA: SDC, setup/hold paths,
                             endpoint sweeps, check_setup, run log
  CTS_characterization/      post-CTS timing, skew, clock-tree stats, power
  scripts/                   run_sta.sh / run_cts.sh + their Tcl, to reproduce
V2_ROADMAP.md    measured findings and the plan for v2
```

## Reproducing the timing reports

The scripts in [`Timing/scripts/`](Timing/scripts/) run on OpenROAD with the
ASAP7 libraries. They expect a kit directory (`$KIT`) holding the OpenROAD
binary, the ASAP7 LEF/Liberty files, and the synthesized netlist — the PDK and
the tool binary are not redistributed here.

```bash
KIT=/path/to/kit ./run_sta.sh          # STA, ~30 s
KIT=/path/to/kit CLK_PS=6000 ./run_sta.sh
```

`run_sta.tcl` writes the SDC it uses into the results directory, so the
published constraints are byte-for-byte the ones that produced the report.

## What's next (v2)

[`V2_ROADMAP.md`](V2_ROADMAP.md) has the detail. The short version, from
measurements rather than intuition:

- The frequency limiter is **not** the fast path's dot product — that cone has
  +922 ps of slack. Every violating endpoint at 333 MHz belongs to the slow
  path's GRU activation chains. Fixing those is the actual unlock.
- The fast path is **already latency-optimal**: its only pipeline boundary is
  the SRAM's internal synchronous-read register, so there is no stage to remove.
  1-cycle prediction is the floor for this memory technology.
- v2 keeps module hierarchy through synthesis (v1 flattened, which foreclosed
  per-path optimization), moves to a PDK with real SRAM macros, and introduces
  UVM verification.

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE).
