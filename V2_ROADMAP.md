# V2 Roadmap — dual-path cache-management block
*(fast path → latency, slow path → throughput)*

Written 2026-07-22. Every feasibility verdict below was made by reading the
actual RTL under `RTL/`, then challenged in AI-assisted review passes using
Anthropic Claude and OpenAI Codex. A claim was retained only when it could be
confirmed in source, simulation, or generated reports; model agreement alone
was not treated as verification. See the main README’s [verification
disclosure](README.md#research-lineage-and-verification-disclosure). Baseline
numbers are measured, not estimated.

---

## 1. V1 baseline (measured today, CTS-stage characterization)

`Timing/scripts/run_cts.sh` — floorplan → place → CTS → post-CTS optimization,
ASAP7, 4000 ps target:

| metric | value |
|---|---|
| setup WNS / TNS | **+1051.5 ps / 0** (met) |
| worst reg-reg cone | ~2.84 ns → **fmax ≈ 339 MHz** post-CTS |
| hold WNS | +3.2 ps (30 hold buffers) |
| clock tree | 10,398 sinks, 749 buffers, depth 5–6 |
| power @ 250 MHz, 20 % act. | **24.8 mW** (macro 32.5 %, comb 33 %, seq 22 %, clock 12.5 %; leakage 5.3 %) |
| die / instances | 207 × 207 µm, 64.5 k insts, 8 845 µm² cell area |

Prior routed data: clean close @ 250 MHz; 333 MHz attempt WNS −174 ps; routed
critical cone ~3.4–3.6 ns → routed fmax ~280–315 MHz.

## 2. The finding that reorders the whole plan

**The fmax limiter is NOT the fastpath dot product.** Routed-netlist STA on the
333 MHz run shows the fastpath Stage-2 cone (SRAM → multiply → adder tree →
compare) holding **+922 ps of slack**, while **all 91 violating endpoints belong
to the slowpath activation chains** (`act_f` sigmoid-LUT + interpolation multiply
→ `rh_mul` / `blend` cones, `slowpath.sv:211-243, 615-631`). Today's CTS run
corroborates the ~2.8–2.9 ns cone class.

Second structural fact: **the fastpath is already latency-optimal.** Its only
pipeline boundary is the SRAM's internal synchronous-read register — hash-in and
dot-product-out are already combinational (`fastpath.sv:119-137, 313-345`).
1-cycle prediction is the floor for this memory type; there is no stage to remove.

So v2's "optimize fast for latency" is achieved by **protecting** the 1-cycle
contract while raising fmax, and the fmax work happens mostly **in the slowpath**.

## 3. Technique verdicts (all adversarially verified, none refuted)

| # | technique | verdict | expected gain | call |
|---|---|---|---|---|
| 1 | Slow: **deep pipelining** (split act cones) | **yes** | ~315 → **~385 MHz** (Fix 1, ~72 flops); further fixes → fastpath-limited wall | **DO FIRST** |
| 2 | **Hierarchical synthesis** (drop `-flatten`) | **yes** | closes the −174 ps @ 333 MHz via path groups + per-module Vt | **DO** (enabler) |
| 3 | Fast: **placement prioritization** | **yes** | +30–50 % over 250 MHz, zero latency cost; macro names already survive the flatten — no resynth needed for Phase A | **DO** |
| 4 | **Multicycle/false paths** | partial | Phase 1 (false-path `bd_*`/`csr_*`/status ports) frees ~130 over-constrained paths — free hygiene | **DO Phase 1** |
| 5 | Fast: **flatten logic trees** (CSA-fuse adder tree) | partial | ~150–350 ps off the Stage-2 cone, only if timing autopsy shows carry chains dominate | conditional |
| 6 | Slow: **unrolling / banking** | partial | 1.8–2.2× observation throughput — only if `st_drop`/`obs_dropped` show real starvation | conditional |
| 7 | **Async FIFO / split clock domains** | partial | ~0 fmax gain (limiter is intra-fast-domain); boundary is unusually CDC-clean so it's *feasible*, just not *useful* for timing | defer |
| 8 | Fast: **remove pipeline stages** | **no** | zero — already at the 1-cycle floor for sync-read SRAM | skip |
| 9 | Slow: **register retiming** | **no** | structurally inert: every flop is async-reset + enable-recirculated; `yosys abc -dff` silently skips them | skip |

Details per technique (evidence file:line, risks, effort) are in the study output;
the three most load-bearing caveats:

- **`slowpath.sv`'s featurizer and quantization are unreconciled.** Its header
  (lines 84-90) flags `X_DIM`/`H_DIM`/quantisation and the featurizer as "a
  PROPOSAL" not yet reconciled with golden model v2. The header also says the
  file "has not been simulated" — that line is **stale**: `RTL/Slowpath/` has a
  passing 256-observation cocotb replay against `slowpath_model.py`. So the
  module is verified to do what its RTL says, but not yet validated to compute
  the *intended* thing. Pipelining a module whose numerics are still a proposal
  bakes in whatever is wrong → reconciliation is a *prerequisite*, not parallel work.
- The **tune-latch atomicity contract** (`orchestrator_top.sv:288-294`,
  `fastpath.sv` header 27-34): any MCP on `gates_i/theta_i`, and any CDC split,
  must preserve single-cycle-consistent application of gates+theta.
- Fence-*exactly*-`u_fast` at P&R is a trap: the critical endpoints (8.8 k
  sampler-table flops) live in the *orchestrator*, so the placement group must
  include them, not just `u_fast`.

## 4. Platform decision for v2

**Recommendation: sky130hd** (ORFS bottom-up hierarchical flow, on the existing
local OpenROAD build), with fastpath and slowpath hardened as separate macros on
their own clocks.

Why it beats the alternatives (full scoring in study output):
- Only open, *manufacturable* PDK with a solved SRAM story: pre-hardened
  efabless/VLSIDA `sky130_sram_macros` + two generators (OpenRAM, SRAM22) that can
  produce a true 256×8 1RW.
- ORFS supports multi-clock SDC and documented bottom-up macro hardening — exactly
  the flatten+single-clock blocker v1 hit.
- Reuses the local toolchain investment (OpenROAD/KLayout/macOS) — no license walls.
- IHP SG13G2: real foundry SRAMs but wrong configs (no 256×8) + 2025 GDS-merge
  rough edges. FPGA (ECP5/Artix): solves memory via BRAM and gives hardware
  bring-up, but teaches FPGA not ASIC hierarchy — worth doing as an **adjunct**
  (yosys+nextpnr runs natively on this Mac) if time allows, not as the target.

**Expectation reset:** 130 nm is slow — the ~390 MHz ASAP7 numbers become
~50–100 MHz on sky130. What carries over is the *architecture*: the fast:slow
clock ratio, the latency contract, and the hierarchical/CDC methodology. State
results in those terms, not absolute MHz.

## 5. UVM strategy for v2

**Recommendation: hybrid, with SV-UVM on Xcelium (ASU) as the deliverable of
record from day one.**

- **Locally (macOS):** restructure the existing cocotb bench into **pyuvm** —
  same UVM architecture (agents/drivers/monitors/scoreboard/sequences), seconds-fast
  iteration, existing cocotb checks become the reference model. This is the
  learning + regression layer.
- **At ASU (Xcelium):** the real SV-UVM environment — factory, sequences,
  phasing, **covergroups and concurrent SVA**. This is where CDC verification has
  to live: as of mid-2026 Verilator's native UVM still excludes covergroups and
  only began landing 4-state support in April 2026 (Antmicro milestones), so
  async-FIFO gray-code/handshake SVA checkers and X-prop reset checks are
  Xcelium-only work.
- Guard against the known failure mode: don't let the pyuvm layer grow past
  driver/monitor/scoreboard parity — the SV-UVM bench is the resume/lab artifact.

## 6. Milestone plan and exit gates

The work is ordered by technical dependency, not by calendar. A milestone is
complete only when its exit gate is met; conditional optimizations stay out of
scope until measurements justify them.

### Milestone A — baseline integrity and decision measurements

1. Split the 333 MHz routed-netlist WNS into macro-Tcq, logic, and net delay to
   decide whether CSA fusion is justified.
2. Run the representative workload and inspect `st_drop` and `obs_dropped` to
   decide whether slow-path banking or unrolling is justified.
3. Correct the SDC treatment of asynchronous debug, CSR, and status ports, then
   regenerate the baseline reports.

**Exit gate:** the baseline is reproducible, each conditional optimization has
a measured trigger, and constraints pass an explicit sanity review.

### Milestone B — numerical reconciliation and slow-path pipelining

1. Reconcile the slow-path featurizer, `X_DIM`/`H_DIM`, and quantization against
   golden model v2. The 256-observation replay proves RTL/model equivalence but
   does not yet prove that the model expresses the intended algorithm.
2. Split the `act_f→rh_mul` and `act_f→blend` cones across two cycles while
   preserving observation, tune, and label handshakes.
3. Refactor the shared activation unit only if the new timing report identifies
   the `S_ACTO` cone as the next limiter.
4. Re-run `Timing/scripts/run_cts.sh` after each structural change.

**Exit gate:** golden replay remains bit-exact, protocol assertions pass, and
the shared-clock implementation reaches its measured post-pipeline target.

### Milestone C — hierarchy and physical-design controls

1. Preserve module hierarchy in synthesis and re-run logical-equivalence and
   gate-level simulation checks.
2. Add path groups and contract-safe timing exceptions; encode per-module cell
   intent without weakening the one-cycle fast-path or atomic tuning contracts.
3. Place the seven fast-path SRAMs with the orchestrator sampler flops they
   communicate with, then apply pin constraints.
4. Compare the new result with the prior −174 ps result at 333 MHz.

**Exit gate:** 333 MHz closes on the ASAP7 characterization flow with all
exceptions reviewed and no functional regression.

### Milestone D — manufacturable platform and verification structure

1. Generate or qualify a sky130hd 256×8 1RW SRAM, preferring OpenRAM or SRAM22
   and using a pre-hardened compatible macro if generation is not viable.
2. Port hierarchical synthesis and the ORFS bottom-up flow, hardening `fastpath`
   first because it has the smallest and clearest interface contract.
3. Restructure the local cocotb environment into pyuvm agents, monitors,
   sequences, and a scoreboard while retaining the current reference models.
4. Establish the SV-UVM environment on Xcelium with matching transactions and
   scoreboards before adding coverage-specific features.

**Exit gate:** the fast path hardens with a qualified SRAM, and the pyuvm and
SV-UVM environments agree on the same smoke-test transactions.

### Milestone E — integration and qualification

1. Harden `slowpath` and assemble the sky130 top. Introduce separate fast and
   slow clocks only if the earlier measurements show that the pipelined slow path
   still limits the required fast clock.
2. Add covergroups and concurrent assertions for tune-latch atomicity,
   valid/ready protocols, reset behavior, and FIFO gray-code rules if CDC exists.
3. Run functional regression, gate-level checks, CDC/reset analysis where
   applicable, and physical characterization.
4. Compare v2 with the §1 baseline using latency, throughput, frequency ratio,
   area, power, drop rate, and coverage—not raw frequency alone.

**Exit gate:** v2 meets its functional contracts, has reviewable coverage and
timing evidence, and its results are reported with reproducible commands.

## 7. Explicitly not doing (and why — so it doesn't get re-litigated)

- **Removing fastpath pipeline stages** — nothing to remove; 1 cycle is the floor.
- **Automated retiming** — structurally inert on this RTL (async-reset +
  enable-recirculated flops; abc -dff skips them silently).
- **Clock-domain split as a timing lever** — attacks the wrong problem (~0 fmax);
  revisit only for power or if fast-clock targets exceed ~290 MHz *after* the
  Stage-2/slowpath fixes land. The boundary is CDC-clean; the option stays open.
- **Full-design flatten in v2 synthesis** — the single biggest v1 self-own;
  hierarchy is the enabler for everything in §3.
