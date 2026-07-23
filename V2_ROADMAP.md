# V2 Roadmap — dual-path cache-management block
*(fast path → latency, slow path → throughput)*

Written 2026-07-22. Every feasibility verdict below was made by reading the
actual RTL under `RTL/`, then challenged in AI-assisted review passes using
**Anthropic Claude Opus 4.8** and **OpenAI GPT-5.6 Sol (through Codex)**. A
claim was retained only when it could be confirmed in source, simulation, or
generated reports; model agreement alone was not treated as verification. See
the main README’s alphabetical [research and model references](README.md#research-lineage-and-verification-disclosure).
Baseline numbers are measured, not estimated.

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

| # | technique | expected gain |
|---|---|---|
| 1 | Slow: **deep pipelining** (split act cones) | ~315 → **~385 MHz** (Fix 1, ~72 flops); further fixes → fastpath-limited wall |
| 2 | **Hierarchical synthesis** (drop `-flatten`) | closes the −174 ps @ 333 MHz via path groups + per-module Vt |
| 3 | Fast: **placement prioritization** | +30–50 % over 250 MHz, zero latency cost; macro names already survive the flatten — no resynth needed for Phase A |
| 4 | **Multicycle/false paths** | Phase 1 (false-path `bd_*`/`csr_*`/status ports) frees ~130 over-constrained paths — free hygiene |
| 5 | Fast: **flatten logic trees** (CSA-fuse adder tree) | ~150–350 ps off the Stage-2 cone, only if timing autopsy shows carry chains dominate |
| 6 | Slow: **unrolling / banking** | 1.8–2.2× observation throughput — only if `st_drop`/`obs_dropped` show real starvation |


## 4. Platform decision for v2

**PDK: sky130hd** (ORFS bottom-up hierarchical flow, on the existing
local OpenROAD build), with fastpath and slowpath hardened as separate macros on
their own clocks.

**Expectation reset:** ~390 MHz ASAP7 numbers become ~50–100 MHz on sky130. What carries
over is the *architecture*: the fast:slow clock ratio, the latency contract, 
and the hierarchical/CDC methodology. State results in those terms, not absolute MHz.

## 5. UVM strategy for v2

**hybrid, with SV-UVM on Xcelium (ASU) as the deliverable of record from day one.**

- **Locally (macOS):** restructure of the existing cocotb bench into **pyuvm** —
  same UVM architecture (agents/drivers/monitors/scoreboard/sequences), seconds-fast
  iteration, existing cocotb checks become the reference model. This is the
  learning + regression layer.
- **Xcelium:** the real SV-UVM environment — factory, sequences, phasing,
  **covergroups and concurrent SVA**.


