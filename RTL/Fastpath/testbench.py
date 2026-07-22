import json
import random
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

N_PERSP, DEPTH = 7, 256

VECTORS = Path(__file__).resolve().parent / "golden_vectors_v3.jsonl"
W_MIN, W_MAX = -128, 127

def fold32(x):
    x &= 0xFFFFFFFF
    return (x ^ (x >> 8) ^ (x >> 16) ^ (x >> 24)) & 0xFF

def hash_perspectives(pc, addr, set_idx, pc_hist, reuse_bucket):
    tag = addr >> 12
    return [
        fold32(pc >> 2),
        fold32((pc >> 2) ^ (addr >> 6)),
        fold32(addr >> 6),
        fold32(tag ^ set_idx),
        fold32(pc_hist),
        fold32((pc_hist << 3) ^ (addr >> 6)),
        fold32(((reuse_bucket & 0x7) << 5) ^ (pc >> 2) ^ set_idx),
    ]

def sat8(x):
    return max(W_MIN, min(W_MAX, x))

def to_signed(v, bits):
    return v - (1 << bits) if v >= (1 << (bits - 1)) else v

class Mirror:
    """Software model of the 7 weight banks + stage-2 math (gates = 1.0)."""
    def __init__(self):
        self.mem = [[0] * DEPTH for _ in range(N_PERSP)]

    def load(self, bank, addr, val):
        self.mem[bank][addr] = val

    def train(self, idxs, delta):
        for b, ix in enumerate(idxs):
            self.mem[b][ix] = sat8(self.mem[b][ix] + delta)

    def predict(self, idxs, theta):
        s = sum(self.mem[b][ix] for b, ix in enumerate(idxs))
        return (1 if s >= 0 else 0), s, (abs(s) < theta)

async def cycle(dut):
    await RisingEdge(dut.clk)
    await Timer(1, "ns")

def drive_req(dut, rec):
    dut.req_valid.value      = 1
    dut.pc_i.value           = rec["pc"] & 0xFFFFFFFF
    dut.addr_i.value         = rec["addr"] & ((1 << 48) - 1)
    dut.set_idx_i.value      = rec["set_idx"] & 0xFF
    dut.pc_hist_i.value      = rec["pc_hist"] & 0xFFFFFFFF
    dut.reuse_bucket_i.value = rec["reuse_bucket"] & 0x7

def clear_req(dut):
    dut.req_valid.value = 0

def sample_outputs(dut):
    return (int(dut.out_pred.value),
            to_signed(int(dut.out_sum.value), 12),
            bool(int(dut.out_low_conf.value)))

async def backdoor_fill(dut, fn):
    """Write fn(bank, addr) into every entry of every bank (256 cycles)."""
    for a in range(DEPTH):

        for b in range(N_PERSP):
            dut.dbg_we.value    = 1
            dut.dbg_mask.value  = 1 << b
            dut.dbg_addr.value  = a
            dut.dbg_wdata.value = fn(b, a) & 0xFF
            await cycle(dut)
    dut.dbg_we.value = 0
    dut.dbg_mask.value = 0
    await cycle(dut)

async def do_train(dut, idxs, delta, mirror):
    """Push one training event, then wait until the RMW drain completes."""
    packed = 0
    for b, ix in enumerate(idxs):
        packed |= (ix & 0xFF) << (8 * b)
    while int(dut.train_ready.value) == 0:
        await cycle(dut)
    dut.train_valid.value = 1
    dut.train_dir.value   = 1 if delta > 0 else 0
    dut.train_idx_i.value = packed
    await cycle(dut)
    dut.train_valid.value = 0
    while int(dut.upd_idle.value) == 0:
        await cycle(dut)
    mirror.train(idxs, delta)

async def one_predict(dut, rec, theta):
    """Single request with idle padding; returns sampled stage-2 outputs."""
    drive_req(dut, rec)
    await cycle(dut)
    clear_req(dut)
    assert int(dut.out_valid.value) == 1, "out_valid must rise 1 cycle after req"
    out = sample_outputs(dut)
    await cycle(dut)
    return out

@cocotb.test()
async def fastpath_all(dut):
    random.seed(7)
    with open(VECTORS) as f:
        recs = [json.loads(l) for l in f]
    assert len(recs) == 256

    try:
        cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    except AttributeError:
        cocotb.fork(Clock(dut.clk, 10, "ns").start())

    dut.rst_n.value = 0
    clear_req(dut)
    dut.train_valid.value = 0
    dut.train_dir.value = 0
    dut.train_idx_i.value = 0
    dut.dbg_we.value = 0
    dut.dbg_mask.value = 0
    dut.dbg_addr.value = 0
    dut.dbg_wdata.value = 0
    dut.gates_i.value = int.from_bytes(bytes([0x80] * N_PERSP), "little")
    dut.theta_i.value = 60
    for _ in range(4):
        await cycle(dut)
    dut.rst_n.value = 1
    await cycle(dut)

    mirror = Mirror()
    errors = 0

    dut._log.info("Phase 1a: zero-init + 256-vector golden replay")
    await backdoor_fill(dut, lambda b, a: 0)

    for k, rec in enumerate(recs):

        ov = int(dut.out_valid.value)
        exp = rec["expect"]
        if exp is None:
            if ov != 0:
                errors += 1
                dut._log.error(f"[1a c{k}] out_valid={ov}, expected 0")
        else:
            if ov != 1:
                errors += 1
                dut._log.error(f"[1a c{k}] out_valid={ov}, expected 1")
            else:
                pred, s, lc = sample_outputs(dut)
                epred = 1 if exp["pred"] == 1 else 0
                if (pred, s, lc) != (epred, exp["sum"], exp["low_conf"]):
                    errors += 1
                    dut._log.error(
                        f"[1a c{k}] got pred={pred} sum={s} lc={lc} "
                        f"exp pred={epred} sum={exp['sum']} lc={exp['low_conf']}")
        drive_req(dut, rec["in"])
        await cycle(dut)
    clear_req(dut)
    await cycle(dut)
    dut._log.info(f"Phase 1a done, errors so far: {errors}")

    dut._log.info("Phase 1b: random preload + mirror-model replay")
    rnd = lambda b, a: random.randint(-128, 127) & 0xFF
    vals = [[random.randint(-16, 16) for _ in range(DEPTH)] for _ in range(N_PERSP)]
    await backdoor_fill(dut, lambda b, a: vals[b][a] & 0xFF)
    for b in range(N_PERSP):
        for a in range(DEPTH):
            mirror.load(b, a, vals[b][a])

    prev = None
    for k, rec in enumerate(recs):
        if prev is not None:
            pred, s, lc = sample_outputs(dut)
            if (pred, s, lc) != prev:
                errors += 1
                dut._log.error(f"[1b c{k}] got ({pred},{s},{lc}) exp {prev}")
        r = rec["in"]
        idxs = hash_perspectives(r["pc"], r["addr"], r["set_idx"],
                                 r["pc_hist"], r["reuse_bucket"])
        prev = mirror.predict(idxs, 60)
        drive_req(dut, r)
        await cycle(dut)
    clear_req(dut)
    pred, s, lc = sample_outputs(dut)
    if (pred, s, lc) != prev:
        errors += 1
        dut._log.error(f"[1b last] got ({pred},{s},{lc}) exp {prev}")
    await cycle(dut)
    dut._log.info(f"Phase 1b done, errors so far: {errors}")

    dut._log.info("Phase 2: training path")
    await backdoor_fill(dut, lambda b, a: 0)
    mirror = Mirror()

    r0 = recs[10]["in"]
    idxs0 = hash_perspectives(r0["pc"], r0["addr"], r0["set_idx"],
                              r0["pc_hist"], r0["reuse_bucket"])

    async def check_point(tag, rec, theta=60):
        nonlocal errors
        dut.theta_i.value = theta
        await cycle(dut)
        got = await one_predict(dut, rec, theta)
        idxs = hash_perspectives(rec["pc"], rec["addr"], rec["set_idx"],
                                 rec["pc_hist"], rec["reuse_bucket"])
        exp = mirror.predict(idxs, theta)
        if got != exp:
            errors += 1
            dut._log.error(f"[2 {tag}] got {got} exp {exp}")
        dut.theta_i.value = 60

    for _ in range(3):
        await do_train(dut, idxs0, +1, mirror)
    await check_point("after +3", r0)

    for _ in range(5):
        await do_train(dut, idxs0, -1, mirror)
    await check_point("after -2", r0)

    for _ in range(140):
        await do_train(dut, idxs0, +1, mirror)
    await check_point("saturated", r0)

    r1 = recs[20]["in"]
    idxs1 = hash_perspectives(r1["pc"], r1["addr"], r1["set_idx"],
                              r1["pc_hist"], r1["reuse_bucket"])
    while int(dut.train_ready.value) == 0:
        await cycle(dut)
    packed = 0
    for b, ix in enumerate(idxs1):
        packed |= (ix & 0xFF) << (8 * b)
    dut.train_valid.value = 1
    dut.train_dir.value   = 1
    dut.train_idx_i.value = packed
    drive_req(dut, r1)
    await cycle(dut)
    dut.train_valid.value = 0
    for _ in range(6):
        drive_req(dut, r1)
        await cycle(dut)
    clear_req(dut)
    for _ in range(8):
        await cycle(dut)
    if int(dut.upd_idle.value) != 1:
        errors += 1
        dut._log.error("[2 stash] update queue failed to drain after traffic")
    mirror.train(idxs1, +1)
    await check_point("stash drained", r1)

    dut._log.info("Phase 3: theta boundaries")
    await check_point("theta=889 (|s|=889 not < 889)", r0, theta=889)
    await check_point("theta=890 (|s|=889 < 890)",     r0, theta=890)
    await check_point("theta=0 (never low-conf)",      r0, theta=0)

    assert errors == 0, f"TEST FAILED: {errors} mismatches"
    dut._log.info("ALL PHASES PASSED: 256-vector replay x2, training, "
                  "saturation, stash-under-traffic, theta boundaries")

@cocotb.test()
async def observation_ports(dut):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())

    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.train_valid.value = 0
    dut.dbg_we.value = 0
    dut.dbg_mask.value = 0
    dut.dbg_addr.value = 0
    dut.dbg_wdata.value = 0
    dut.pc_i.value = 0
    dut.addr_i.value = 0
    dut.set_idx_i.value = 0
    dut.pc_hist_i.value = 0
    dut.reuse_bucket_i.value = 0
    dut.train_dir.value = 0
    dut.train_idx_i.value = 0
    dut.gates_i.value = int("80" * N_PERSP, 16)
    dut.theta_i.value = 0
    for _ in range(4):
        await cycle(dut)
    dut.rst_n.value = 1
    await cycle(dut)

    mem = [[0] * DEPTH for _ in range(N_PERSP)]
    for a in range(DEPTH):
        for b in range(N_PERSP):
            mem[b][a] = (a * 7 + b * 13) & 0xFF

    for b in range(N_PERSP):
        dut.dbg_mask.value = 1 << b
        for a in range(DEPTH):
            dut.dbg_we.value = 1
            dut.dbg_addr.value = a
            dut.dbg_wdata.value = mem[b][a]
            await cycle(dut)
    dut.dbg_we.value = 0
    dut.dbg_mask.value = 0
    await cycle(dut)

    random.seed(0xC0FFEE)
    errors = 0
    checked = 0

    for _ in range(60):
        pc = random.getrandbits(32)
        addr = random.getrandbits(48)
        set_idx = random.getrandbits(8)
        pc_hist = random.getrandbits(32)
        rb = random.getrandbits(3)

        exp_idx = hash_perspectives(pc, addr, set_idx, pc_hist, rb)
        exp_w = [mem[b][exp_idx[b]] for b in range(N_PERSP)]

        dut.req_valid.value = 1
        dut.pc_i.value = pc
        dut.addr_i.value = addr
        dut.set_idx_i.value = set_idx
        dut.pc_hist_i.value = pc_hist
        dut.reuse_bucket_i.value = rb
        await cycle(dut)
        dut.req_valid.value = 0

        assert int(dut.out_valid.value) == 1, "out_valid must rise 1 cycle after req"

        got_idx_packed = int(dut.obs_idx.value)
        got_w_packed = int(dut.obs_weights.value)
        got_idx = [(got_idx_packed >> (k * 8)) & 0xFF for k in range(N_PERSP)]
        got_w = [(got_w_packed >> (k * 8)) & 0xFF for k in range(N_PERSP)]

        if got_idx != exp_idx:
            dut._log.error(f"obs_idx mismatch: got {got_idx} exp {exp_idx}")
            errors += 1
        if got_w != exp_w:
            dut._log.error(f"obs_weights mismatch: got {got_w} exp {exp_w}")
            errors += 1

        for k in range(N_PERSP):
            if got_w[k] != mem[k][got_idx[k]]:
                dut._log.error(
                    f"ALIGNMENT BUG bank {k}: obs_weights={got_w[k]} but "
                    f"mem[{k}][obs_idx={got_idx[k]}]={mem[k][got_idx[k]]}")
                errors += 1
        checked += 1
        await cycle(dut)

    assert errors == 0, f"{errors} observation-port errors over {checked} predictions"
    dut._log.info(
        f"obs_weights/obs_idx correct and cycle-aligned over {checked} predictions")

if __name__ == "__main__":
    import os
    import sys
    import inspect
    import subprocess
    from pathlib import Path

    proj_path = Path(__file__).resolve().parent
    sim = os.getenv("SIM", "icarus")

    get_runner = None
    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        try:
            from cocotb.runner import get_runner
        except ImportError:
            get_runner = None

    if get_runner is not None:
        runner = get_runner(sim)

        bkw = dict(hdl_toplevel="fastpath_top",
                   includes=[proj_path],

                   always=True)
        if "sources" in inspect.signature(runner.build).parameters:
            bkw["sources"] = [proj_path / "fastpath.sv"]
        else:
            bkw["verilog_sources"] = [proj_path / "fastpath.sv"]
        runner.build(**bkw)

        tkw = dict(hdl_toplevel="fastpath_top", test_module="testbench")
        if "test_dir" in inspect.signature(runner.test).parameters:
            tkw["test_dir"] = proj_path
        runner.test(**tkw)

    else:

        lib = subprocess.check_output(
            ["cocotb-config", "--lib-name-path", "vpi", "icarus"], text=True).strip()
        build = proj_path / "sim_build"
        build.mkdir(exist_ok=True)
        vvp_out = build / "sim.vvp"
        subprocess.check_call(
            ["iverilog", "-g2012", "-o", str(vvp_out), "-s", "fastpath_top",
             "-D", "COCOTB_SIM=1", "-I", str(proj_path), str(proj_path / "fastpath.sv")])
        env = dict(os.environ,
                   MODULE="testbench",
                   TOPLEVEL="fastpath_top",
                   TOPLEVEL_LANG="verilog",
                   PYTHONPATH=os.pathsep.join([str(proj_path)] + sys.path))
        sys.exit(subprocess.call(
            ["vvp", "-M", str(Path(lib).parent), "-m", Path(lib).stem, str(vvp_out)],
            env=env, cwd=str(proj_path)))
