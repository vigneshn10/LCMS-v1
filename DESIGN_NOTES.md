# Design notes

Reference material for anyone modifying the RTL. The source files are kept
terse; the constraints that are not obvious from reading the code live here.

---

## Fast ↔ slow path interface contract

**Tuning (slow → fast): `gates_o/theta_o` → `gates_i/theta_i`**
The fast path consumes these combinationally in its gating stage and knows
nothing about where they come from — a GRU, a CSR, or a testbench are all the
same to it. *When* they may change is the orchestrator's problem. Do not add a
`tune_valid`/`tune_ready` handshake to the fast path.

Format is bit-identical on both sides: 7 × Q1.7 gates (`8'h80` = 1.0) plus an
11-bit unsigned theta. The orchestrator wires them across unchanged.

**Observation (fast → slow): `obs_weights`, `obs_idx`**
Valid in the same cycle as `out_valid`. Two rules that are easy to get wrong:

1. `obs_weights` carries the **pre-gate** weights. The learner's job is to learn
   `gates_i[k]`, so it must see perspective *k*'s evidence *before* `gates_i[k]`
   has scaled it. Feeding it the post-gate `term[]` would be circular and the
   learning would not converge.
2. It is **fire-and-forget on purpose** — there is deliberately no `obs_ready`.
   The fast path must never stall on the learner. The slow path *does*
   handshake, because backpressure is harmless there: `obs_ready` low **is** the
   sampling policy. Never let that handshake propagate back into the fast path.

**Teacher labels (slow → fast): `lbl_dir`, `lbl_idx`**
Maps 1:1 onto `train_dir`/`train_idx_i`/`train_ready`, for DAgger-style
retraining with the GRU as the expert. Gate it off with `mode_i` if ground truth
trains the perceptron directly instead.

## Why a sampler table and not a FIFO

An observation is born at prediction time; its outcome arrives at reuse or
eviction, thousands of cycles later and **out of order**. A FIFO cannot perform
that join. The orchestrator allocates a sampler-table entry on predict and
completes it on outcome, matching by partial address tag — the training-queue
idiom from sampling-based dead-block prediction (Khan et al., MICRO 2010).

## Mode FSM: why there is a warm-up phase

`OFF → OBSERVE → TUNE+LABEL`. A zero-initialised GRU hidden state produces an
unreliable transient for its first several timesteps. Those outputs must be
discarded, not applied to the fast path. `WARMUP_OBS = 32` observations.

## Tuning latch: why a single register is enough

`gates_i`/`theta_i` are pure combinational inputs to the fast path's gating
stage. They must be stable only for the one cycle in which a given prediction's
sum is formed, and they touch neither the hashing nor the training datapath.
A plain register loaded on the tune handshake is sufficient — no double
buffering. **Any** change here (a multicycle path on `gates_i`, a clock-domain
split) must preserve single-cycle-consistent application of gates *and* theta
together; a prediction that sees old gates with new theta is a real bug.

## Fixed point

| quantity | format | note |
|---|---|---|
| SRAM weights, biases | signed Q2.6 | value = byte / 64 |
| `x[]`, `h[]`, `n` | signed Q1.7 | value = byte / 128 |
| `z`, `r` | unsigned Q1.7 | 0..128, 128 = 1.0 |
| accumulators | signed Q3.13, `ACC_W` bits | |
| perceptron weights | raw signed int8 → Q1.7 | reinterpreted, no arithmetic |

Accumulator sizing: worst case `|acc| = 24·127·128 + (127<<7) = 406400`, which
needs 20 bits including sign. `ACC_W = 24` leaves 4 bits of headroom.

Perceptron weights arriving as raw signed int8 and being *reinterpreted* as Q1.7
**is** the normalisation — w/128 lands in [−1, 1) with no operation.

In the fast path's gated dot product, each `prod = gate(9b) × weight(8b)` is
rescaled by `>>> 7` to undo the Q1.7 gate before the adder tree. The tree is
hand-balanced (7 terms → 3 levels, not 6) because it sits on the critical cone.

## SRAM semantics the design is built around

From `fakeram7_256x8.v`:

1. `rd_out` is valid **one cycle** after `addr_in`, and only if `ce_in` was high.
   The entire two-stage structure of the fast path assumes exactly this 1-cycle
   read latency.
2. `ce_in` low ⇒ `rd_out <= 'x`. Never consume a byte from a cycle where the
   bank was disabled.
3. **`ce_in` high with an X address corrupts the whole array.** Every enabled
   cycle drives the address from a reset-to-zero counter, so it is never X.
   This is also why the debug backdoor is **quiescent-only** — a backdoor write
   while the FSM is busy is rejected by design, and there is a cocotb test that
   asserts the write does not land.

## Slow-path bank map

3 × `fakeram7_256x8`, one per GRU gate — the same macro as the fast path's
weight banks, so the whole design carries exactly one macro type through P&R.

```
bank 0 = z-gate params + head rows 0..2   (gates 0,1,2)
bank 1 = r-gate params + head rows 3..5   (gates 3,4,5)
bank 2 = n-gate params + head rows 6..8   (gate 6, theta, teacher logit)

addr   0..127  W[h][d]     h = addr[6:4], d = addr[3:0]
addr 128..191  U[h][j]     h = addr[5:3], j = addr[2:0]   (offset 128)
addr 192..199  b[h]
addr 200..223  Wo[row][j]  row = local 0..2, j = 0..7
addr 224..226  bo[row]
addr 227..255  unused                      -> 227 of 256 bytes per bank
```

The map is deliberately a **linear ramp**: every phase just streams addresses
(0..199, then 128..191 again, then 200..226) and one counter drives all three
banks. The consumer decodes what a returned byte means from the delayed address.
That is why there is no per-phase addressing logic — do not add any.

## Hash perspectives

Bit-exact mirror of the golden model's `_fold`/`hash_perspectives`. `fold32`
XOR-folds a 32-bit value to 8 bits. All hash inputs are 32-bit views because the
Python golden model masks to 32 bits inside `_fold`.

```
0: pc>>2                         4: pc_hist
1: (pc>>2) ^ (addr>>6)           5: (pc_hist<<3) ^ (addr>>6)
2: addr>>6                       6: (reuse_bucket<<5) ^ (pc>>2) ^ set_idx
3: (addr>>12) ^ set_idx
```

Any change here breaks bit-exactness with the golden vectors.

## Port arbitration

Per cycle, per bank: **debug backdoor > prediction read > update FSM**. A
prediction is never stalled by training. Training events (7 indices + direction)
queue in a 4-deep FIFO and drain as read-modify-write pairs on bank-idle cycles;
sustained back-to-back predictions starve training indefinitely, at which point
`train_ready` backpressures. That is intended behaviour, not a bug.

## Status of the slow path

`X_DIM`/`H_DIM`, the quantisation, and the featurizer are a **proposal** and have
not been reconciled with golden model v2. The module has a passing 256-observation
cocotb replay against `slowpath_model.py`, so it does what its RTL says — but
that it computes the *intended* thing is not yet established. The fast path
earned its correctness by mirroring the golden model bit-exactly; the slow path
has not yet had that chance. Reconcile before relying on its numerics, and
before pipelining it in v2.

## One SRAM model

`fakeram7_256x8.v` is the unmodified FakeRAM2.0 output (Verilog-1995 style).
It is `include`-guarded and pulled in by the RTL, so simulation and synthesis
read the **same** file. An earlier revision had a hand-pasted inline copy using
an ANSI-style port list that referenced `BITS`/`ADDR_WIDTH` before declaring
them — illegal per the LRM, tolerated by Icarus 12, correctly rejected by the
stricter Icarus in oss-cad-suite. Never retype this model into another file.
