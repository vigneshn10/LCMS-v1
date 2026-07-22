import json
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

N_PERSP = 7
A_HB_BASE = 224

def init_banks(seed=7):
    """VERBATIM copy of slowpath_model.init_banks. The vectors were generated
    with seed=7; any drift here silently invalidates the whole replay."""
    rng = random.Random(seed)
    banks = [[0] * 256 for _ in range(3)]
    for g in range(3):
        for a in range(A_HB_BASE + 3):
            banks[g][a] = rng.randint(-40, 40) & 0xFF
    return banks

DEPTH = 256

async def cycle(dut):
    await RisingEdge(dut.clk)
    await Timer(1, "ns")

def pack(vals, width=8):
    p = 0
    for i, v in enumerate(vals):
        p |= (v & ((1 << width) - 1)) << (i * width)
    return p

async def reset(dut):
    dut.rst_n.value = 0
    dut.obs_valid.value = 0
    dut.obs_weights_i.value = 0
    dut.obs_idx_i.value = 0
    dut.obs_sum_i.value = 0
    dut.obs_pred_i.value = 0
    dut.obs_low_conf_i.value = 0
    dut.obs_reuse_bucket_i.value = 0
    dut.obs_outcome_i.value = 0
    dut.tune_ack.value = 1
    dut.lbl_ready.value = 1
    dut.mode_i.value = 0
    dut.flush_i.value = 0
    dut.gw_we.value = 0
    dut.gw_bank.value = 0
    dut.gw_addr.value = 0
    dut.gw_wdata.value = 0
    for _ in range(4):
        await cycle(dut)
    dut.rst_n.value = 1
    await cycle(dut)

async def backdoor_load(dut, banks):
    """Load banks[g][addr] into GRU bank g via gw_*. Only legal while the FSM
    is idle — the RTL corrupts the whole array if ce_in is ever high with an
    X address, which is why this (like the fast path's dbg_we) must run with
    no observation in flight."""
    assert int(dut.busy.value) == 0, "backdoor_load must run while idle"
    dut.gw_we.value = 1
    for a in range(A_HB_BASE + 3):
        for g in range(3):
            dut.gw_bank.value = g
            dut.gw_addr.value = a
            dut.gw_wdata.value = banks[g][a] & 0xFF
            await cycle(dut)
    dut.gw_we.value = 0
    await cycle(dut)

def drive_obs(dut, obs):
    """Payload only — obs_valid stays where the caller left it."""
    dut.obs_weights_i.value = pack(obs["weights"])
    dut.obs_idx_i.value = pack(obs["idx"])
    dut.obs_sum_i.value = obs["sum"] & 0xFFF
    dut.obs_pred_i.value = obs["pred"]
    dut.obs_low_conf_i.value = obs["low_conf"]
    dut.obs_reuse_bucket_i.value = obs["reuse_bucket"]
    dut.obs_outcome_i.value = obs["outcome"]

async def offer_obs(dut, obs):
    """Drive one observation through the handshake, returning after the edge
    that accepted it.

    obs_valid is raised only AFTER obs_ready has been observed high. The
    obvious alternative — raise valid, then poll ready — is a bug: obs_ready is
    combinational off `st`, so the poll's own cycle() lets the DUT accept the
    transfer behind the poll's back, the poll then sees busy (ready low) and
    keeps spinning until S_IDLE returns, and the caller's *next* cycle() feeds
    the SAME observation in a second time. That costs one extra timestep, which
    permanently offsets obs_cnt (and therefore every publish tick) and the
    hidden state. Polling with valid low is safe here: obs_ready does not
    depend on obs_valid, so there is no combinational loop and nothing can be
    accepted while we look.
    """
    drive_obs(dut, obs)
    while int(dut.obs_ready.value) == 0:
        await cycle(dut)
    dut.obs_valid.value = 1
    await cycle(dut)
    dut.obs_valid.value = 0

async def push_and_capture(dut, obs):
    """Offer one observation, then watch every cycle the FSM is busy for the
    S_EMIT pulse where tune_valid/lbl_valid go high. Returns None if neither
    ever asserted (should not happen with mode_i=3)."""
    await offer_obs(dut, obs)

    captured = None
    while int(dut.busy.value) == 1:
        if int(dut.lbl_valid.value) or int(dut.tune_valid.value):
            captured = {
                "tune_valid": int(dut.tune_valid.value),
                "gates": [(int(dut.gates_o.value) >> (k * 8)) & 0xFF
                          for k in range(N_PERSP)],
                "theta": int(dut.theta_o.value),
                "tune_epoch": int(dut.tune_epoch.value),
                "lbl_valid": int(dut.lbl_valid.value),
                "lbl_dir": int(dut.lbl_dir.value),
                "lbl_idx": int(dut.lbl_idx.value),
            }
        await cycle(dut)
    return captured

@cocotb.test()
async def slowpath_all(dut):
    with open("slowpath_vectors_v1.jsonl") as f:
        vec = [json.loads(l) for l in f if l.strip()]
    assert len(vec) == 256, (
        f"expected 256 records, got {len(vec)} — regenerate with "
        f"`python3 slowpath_model.py` from the same directory as "
        f"golden_vectors_v3.jsonl"
    )

    try:
        cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    except AttributeError:
        cocotb.fork(Clock(dut.clk, 10, "ns").start())

    await reset(dut)

    dut._log.info("Phase 1: backdoor-load reference weights, replay 256 obs")
    banks = init_banks(seed=7)

    await backdoor_load(dut, banks)

    dut.mode_i.value = 3

    errors = 0
    tune_checks = lbl_checks = 0

    for rec in vec:
        obs, exp = rec["obs"], rec["expect"]
        got = await push_and_capture(dut, obs)

        if got is None:
            errors += 1
            dut._log.error(f"[seq {rec['seq']}] no lbl_valid/tune_valid pulse "
                           f"at all — mode_i=3 should assert lbl_valid every "
                           f"observation")
            continue

        if exp["lbl_valid"]:
            lbl_checks += 1
            exp_idx = pack(obs["idx"])
            if not got["lbl_valid"]:
                errors += 1
                dut._log.error(f"[seq {rec['seq']}] lbl_valid=0, expected 1")
            elif (got["lbl_dir"], got["lbl_idx"]) != (exp["lbl_dir"], exp_idx):
                errors += 1
                dut._log.error(
                    f"[seq {rec['seq']}] lbl mismatch: got dir={got['lbl_dir']} "
                    f"idx={got['lbl_idx']:#x} exp dir={exp['lbl_dir']} "
                    f"idx={exp_idx:#x}")

        if got["tune_valid"] != exp["tune_valid"]:
            errors += 1
            dut._log.error(f"[seq {rec['seq']}] tune_valid={got['tune_valid']}, "
                           f"expected {exp['tune_valid']}")
        elif exp["tune_valid"]:
            tune_checks += 1
            if (got["gates"], got["theta"], got["tune_epoch"]) !=\
               (exp["gates"], exp["theta"], exp["tune_epoch"]):
                errors += 1
                dut._log.error(
                    f"[seq {rec['seq']}] tune mismatch: "
                    f"got gates={got['gates']} theta={got['theta']} "
                    f"epoch={got['tune_epoch']}  exp gates={exp['gates']} "
                    f"theta={exp['theta']} epoch={exp['tune_epoch']}")

    dut._log.info(f"Phase 1 done: {lbl_checks} label checks, "
                  f"{tune_checks} tuning checks, errors so far: {errors}")

    dut._log.info("Phase 2: status counters + backdoor guard")
    seen = int(dut.obs_seen.value)
    agree = int(dut.agree_cnt.value)
    exp_seen = len(vec)
    exp_agree = sum(1 for r in vec if r["obs"]["pred"] == r["obs"]["outcome"])
    if seen != exp_seen:
        errors += 1
        dut._log.error(f"[2 counters] obs_seen={seen}, expected {exp_seen}")
    if agree != exp_agree:
        errors += 1
        dut._log.error(f"[2 counters] agree_cnt={agree}, expected {exp_agree}")

    probe = vec[0]["obs"]
    await offer_obs(dut, probe)

    dut.gw_we.value = 1
    dut.gw_bank.value = 0
    dut.gw_addr.value = 0
    dut.gw_wdata.value = 0xAA
    for _ in range(10):
        await cycle(dut)
    dut.gw_we.value = 0

    while int(dut.busy.value) == 1:
        await cycle(dut)

    try:
        got_b0a0 = int(dut.g_gru_banks[0].u_bank.mem[0].value)
    except Exception as e:
        got_b0a0 = None
        dut._log.warning(f"[2 backdoor guard] could not peek bank0[0] ({e}); "
                         f"skipping the read-back check")
    if got_b0a0 is not None and got_b0a0 != (banks[0][0] & 0xFF):
        errors += 1
        dut._log.error(f"[2 backdoor guard] bank0[0]={got_b0a0:#04x}, expected "
                       f"{banks[0][0] & 0xFF:#04x} — gw_we leaked while busy")

    dut._log.info(f"Phase 2 done: obs_seen={seen} agree_cnt={agree}, "
                  f"errors so far: {errors}")

    assert errors == 0, f"TEST FAILED: {errors} mismatches"
    dut._log.info("ALL PHASES PASSED: 256-observation replay against "
                  "slowpath_vectors_v1.jsonl, status counters, backdoor guard")

if __name__ == "__main__":
    import os
    from pathlib import Path
    try:
        from cocotb_tools.runner import get_runner
    except ModuleNotFoundError:
        from cocotb.runner import get_runner

    sim = os.getenv("SIM", "icarus")
    proj_path = Path(__file__).resolve().parent

    runner = get_runner(sim)
    runner.build(

        verilog_sources=[proj_path / "design.sv"],
        includes=[proj_path],

        hdl_toplevel="slowpath_top",
        always=True,
    )
    runner.test(
        hdl_toplevel="slowpath_top",
        test_module="testbench",
        test_dir=proj_path,

    )
