# LCMS — Learned Cache Management System (v1)

A two-tier learned cache-management accelerator in SystemVerilog, synthesized to
the ASAP7 7nm predictive PDK and closed with a violation-free static timing
analysis.

The design predicts whether a cache line is worth keeping and adapts the
prediction policy at runtime. A fast path answers every request in one cycle,
while a slow path runs a GRU meta-controller in the background, off the critical
path. The GRU parameters are loaded before operation; the RTL performs recurrent
inference and hidden-state adaptation, not gradient-based training of those
parameters.

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

## Methodology

### 1. Model initialization and operating assumptions

LCMS is a policy accelerator, not a complete cache. A cache controller supplies
the request context (`pc`, 48-bit address, set index, PC history, and a reuse
bucket), consumes the keep/bypass prediction, and later returns the observed
outcome for the same address. Before traffic starts, the controller must use the
quiescent backdoor to initialize the seven fast-path weight SRAMs and the three
GRU parameter SRAMs. The behavioral SRAM intentionally powers up unknown, so an
uninitialized simulation is not a meaningful model run.

All logic is in one clock domain in v1. The fast path is allowed to drop or defer
learning work but is never allowed to delay a prediction. The slow path therefore
operates as a best-effort consumer whose pressure is visible through counters.

### 2. One-cycle prediction

For every accepted request, the fast path derives seven 8-bit indices by
XOR-folding different views of the request: PC, PC/address, address, tag/set,
PC history, history/address, and reuse-bucket/PC/set. Each index addresses an
independent 256×8 signed-weight SRAM. The SRAMs provide their registered read
outputs one cycle later.

Each signed weight is multiplied by its unsigned Q1.7 gate, shifted back by
seven fractional bits, and added through a balanced three-level tree. A
non-negative sum predicts keep/reuse; a negative sum predicts bypass/dead. The
absolute sum is compared with the 11-bit `theta` value to mark low-confidence
decisions. The same cycle also exports the raw, pre-gate weights and the exact
indices used, preserving the evidence needed for later learning.

### 3. Sampling and delayed-label association

Outcomes may arrive thousands of cycles after prediction and out of order, so a
FIFO cannot associate them correctly. The orchestrator samples every fourth
completed fast-path prediction into a 64-entry direct-indexed table. An entry
stores a partial address tag, the seven weights and indices, prediction sum,
prediction, confidence flag, and reuse bucket. When an outcome arrives, its
folded address selects the entry and the partial tag confirms the match.

A collision replaces the older sample and increments the eviction counter. A
matching outcome is consumed only when the slow path is ready; otherwise it is
dropped and counted. This bounded, explicitly lossy scheme protects prediction
latency while making sampling pressure and aliasing measurable rather than
implicit.

### 4. Recurrent meta-control

An accepted labelled observation becomes a 16-element fixed-point feature
vector: seven raw perspective weights, the scaled prediction sum, prediction,
low-confidence flag, outcome, agreement flag, reuse bucket, a constant feature,
and two reserved zeros. The 8-hidden-unit GRU streams its parameters from three
256×8 SRAM banks. Its serialized FSM computes reset/update gates, the candidate
state, the recurrent-state blend, and a nine-output head.

The first seven head outputs become perspective gates, output eight becomes
`theta`, and output nine becomes a teacher direction for fast-path perceptron
updates. Hidden state persists across accepted observations, so the sampled
runtime stream is the sequence. The normal mode progression is
`OFF → OBSERVE → TUNE+LABEL`: 32 observations warm the recurrent state, then a
new gate/theta bundle is emitted every 64 accepted observations. Gates and theta
are captured atomically so a prediction cannot mix epochs.

### 5. Background perceptron updates

Teacher events carry the original seven indices plus an increment/decrement
direction into a four-entry fast-path queue. Each event becomes a saturating
signed-8-bit ±1 read-modify-write across all seven SRAM banks. Arbitration is
strictly `debug > prediction > update`; updates use only cycles on which the
banks are not serving a request. Sustained request traffic can therefore
backpressure training indefinitely, but it cannot stall inference.

### 6. Numerical method

The design uses integer-only fixed point. GRU weights and biases are signed
Q2.6; features, hidden state, and candidate state are signed Q1.7; sigmoid
outputs use unsigned Q1.7; and 24-bit accumulators provide four guard bits over
the calculated worst case. Sigmoid and tanh use a bounded lookup table with
interpolation. Fast-path perceptron bytes are reinterpreted as Q1.7 before gate
scaling. The complete bit-level contract and SRAM map are recorded in
[`DESIGN_NOTES.md`](DESIGN_NOTES.md).

### 7. Verification and implementation method

Verification is layered. The fast and slow blocks replay deterministic JSONL
vectors against independent Python reference models. The integrated bench then
checks RAM behavior, latency, sampler allocation/completion races, deliberate
drop behavior, aliasing, training starvation, tuning activity, and counters.
The integrated “learning” test proves that the adaptation path executes; it is
not a statistical claim that accuracy converges or improves on a workload.

Synthesis uses Yosys with ASAP7 rev28 RVT cells and ten black-box-compatible
256×8 FakeRAM macros. The published STA is pre-layout, with ideal interconnect
and clock, while the separate CTS characterization adds placement-estimated
parasitics, clock-tree synthesis, and timing repair. These are reproducible
engineering characterizations, not silicon measurements; the exact constraints
and reports are checked in under [`Timing/`](Timing/).

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
  drop policy, join aliasing, training starvation, learning activity, summary

### Reproduce the RTL verification

Requirements are Python 3.9–3.13, Icarus Verilog, and the pinned Python
dependency in [`requirements.txt`](requirements.txt). cocotb 2.0.1 does not
support Python 3.14. From the repository root:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements.txt
./RTL/run_all.sh
```

Set `PYTHON` to a different interpreter or `SIM` to another cocotb-supported
simulator if needed. Each suite can also be run directly, for example
`./RTL/Cache/run.sh`. The same aggregate command runs in GitHub Actions on every
push and pull request.

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

## Research lineage and verification disclosure

LCMS is an original RTL integration, not a reproduction of one paper. Its
closest research lineage is listed below. The sampler/table association follows
sampling dead-block prediction; the seven hashed perspectives and signed online
updates follow perceptron and multiperspective reuse prediction; the recurrent
controller draws on GRUs and learned optimizers; and the teacher-label loop is
related to dataset aggregation. Belady's optimal policy, DIP, RRIP, early
dead-block prediction, perceptron branch prediction, SHiP, Hawkeye, and LeCaR
provide the foundational or neighboring work used to compare and sanity-check
the design choices.

### Research references (alphabetical by first author)

1. M. Andrychowicz, M. Denil, S. Gómez, M. W. Hoffman, D. Pfau, T. Schaul,
   B. Shillingford, and N. de Freitas, “Learning to Learn by Gradient Descent
   by Gradient Descent,” *NeurIPS 29*, 2016.
   [Proceedings](https://proceedings.neurips.cc/paper_files/paper/2016/hash/fb87582825f9d28a8d42c5e5e5e8b23d-Abstract.html)
2. L. A. Belady, “A Study of Replacement Algorithms for a Virtual-Storage
   Computer,” *IBM Systems Journal*, vol. 5, no. 2, pp. 78–101, 1966.
   [doi:10.1147/sj.52.0078](https://doi.org/10.1147/sj.52.0078)
3. K. Cho, B. van Merriënboer, Ç. Gülçehre, D. Bahdanau, F. Bougares,
   H. Schwenk, and Y. Bengio, “Learning Phrase Representations using RNN
   Encoder–Decoder for Statistical Machine Translation,” *EMNLP*, pp.
   1724–1734, 2014. [arXiv:1406.1078](https://arxiv.org/abs/1406.1078)
4. S. Hochreiter, A. S. Younger, and P. R. Conwell, “Learning to Learn Using
   Gradient Descent,” *ICANN*, pp. 87–94, 2001.
   [doi:10.1007/3-540-44668-0_13](https://doi.org/10.1007/3-540-44668-0_13)
5. A. Jain and C. Lin, “Back to the Future: Leveraging Belady’s Algorithm for
   Improved Cache Replacement,” *ISCA-43*, pp. 78–89, 2016.
   [doi:10.1109/ISCA.2016.17](https://doi.org/10.1109/ISCA.2016.17)
6. A. Jaleel, K. B. Theobald, S. C. Steely Jr., and J. Emer, “High Performance
   Cache Replacement Using Re-Reference Interval Prediction (RRIP),” *ISCA-37*,
   pp. 60–71, 2010.
   [doi:10.1145/1816038.1815971](https://doi.org/10.1145/1816038.1815971)
7. D. A. Jiménez and C. Lin, “Dynamic Branch Prediction with Perceptrons,”
   *HPCA-7*, pp. 197–206, 2001.
   [doi:10.1109/HPCA.2001.903263](https://doi.org/10.1109/HPCA.2001.903263)
8. D. A. Jiménez and E. Teran, “Multiperspective Reuse Prediction,” *MICRO-50*,
   pp. 436–448, 2017.
   [doi:10.1145/3123939.3123942](https://doi.org/10.1145/3123939.3123942)
9. S. M. Khan, Y. Tian, and D. A. Jiménez, “Sampling Dead Block Prediction for
   Last-Level Caches,” *MICRO-43*, pp. 175–186, 2010.
   [doi:10.1109/MICRO.2010.24](https://doi.org/10.1109/MICRO.2010.24)
10. A.-C. Lai, C. Fide, and B. Falsafi, “Dead-Block Prediction & Dead-Block
    Correlating Prefetchers,” *ISCA-28*, pp. 144–154, 2001.
    [doi:10.1145/379240.379259](https://doi.org/10.1145/379240.379259)
11. M. K. Qureshi, A. Jaleel, Y. N. Patt, S. C. Steely Jr., and J. Emer,
    “Adaptive Insertion Policies for High Performance Caching,” *ISCA-34*,
    pp. 381–391, 2007.
    [doi:10.1145/1250662.1250709](https://doi.org/10.1145/1250662.1250709)
12. S. Ross, G. Gordon, and D. Bagnell, “A Reduction of Imitation Learning and
    Structured Prediction to No-Regret Online Learning,” *AISTATS*, PMLR 15,
    pp. 627–635, 2011. [PMLR](https://proceedings.mlr.press/v15/ross11a.html)
13. E. Teran, Z. Wang, and D. A. Jiménez, “Perceptron Learning for Reuse
    Prediction,” *MICRO-49*, pp. 1–12, 2016.
    [doi:10.1109/MICRO.2016.7783705](https://doi.org/10.1109/MICRO.2016.7783705)
14. G. Vietri et al., “Driving Cache Replacement with ML-based LeCaR,”
    *HotStorage ’18*, 2018.
    [USENIX](https://www.usenix.org/conference/hotstorage18/presentation/vietri)
15. C.-J. Wu, A. Jaleel, W. Hasenplaugh, M. Martonosi, S. C. Steely Jr., and
    J. Emer, “SHiP: Signature-based Hit Predictor for High Performance Caching,”
    *MICRO-44*, pp. 430–441, 2011.
    [doi:10.1145/2155620.2155671](https://doi.org/10.1145/2155620.2155671)

### AI-assisted verification references (alphabetical by organization)

AI-assisted code and documentation review used **Anthropic Claude Opus 4.8**
and **OpenAI GPT-5.6 Sol (through Codex)**. Their output was treated as a
hypothesis source, not proof: source-path fixes were checked on a clean clone,
RTL claims were checked against the implementation, and behavioral claims were
accepted only when reproduced by the cocotb suites.

1. Anthropic, “Claude Opus 4.8 System Card,” 2026.
   [System card](https://www-cdn.anthropic.com/0b4915911bb0d19eca5b5ee635c80fef830a37ea/Claude%20Opus%204.8%20System%20Card.pdf)
2. OpenAI, “GPT-5.6 Sol Model,” 2026.
   [Official model documentation](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
