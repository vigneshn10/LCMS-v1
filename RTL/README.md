# RTL

Three directories, each independently simulatable with cocotb + Icarus Verilog.

| directory | top module | testbench |
|---|---|---|
| `Fastpath/` | `fastpath_top` | 256-vector golden replay + observation ports |
| `Slowpath/` | `slowpath_top` | golden vector replay |
| `Cache/` | `orchestrator_top` | 9 suites, integrated |

Each contains its own copy of `fakeram7_256x8.v` (the SRAM behavioural model),
its golden vectors as `.jsonl`, and a portable `run.sh`. A run writes cocotb
JUnit output to `results.xml`; generated results and Python bytecode are ignored
rather than committed.

`Fastpath/golden/` is a standalone EDA Playground bundle containing the
reference model (`design.sv`) that the RTL is checked against; see the
`README.txt` inside it for pane-by-pane setup.

`Cache/` carries its own copies of `fastpath.sv` and `slowpath.sv` so the
integrated testbench runs without reaching outside its directory. They are
identical to the per-path copies.

## Running

From the repository root, install the pinned Python dependency and run all three
suites:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements.txt
./RTL/run_all.sh
```

Run one suite with `./RTL/Fastpath/run.sh`, `./RTL/Slowpath/run.sh`, or
`./RTL/Cache/run.sh`. The scripts resolve their own location, preserve the
calling environment, default `SIM` to `icarus`, and return the simulator's real
exit status. Set `PYTHON` or `SIM` to override those defaults.

Python 3.9–3.13 is supported by the pinned cocotb 2.0.1 release. Icarus Verilog
12 or newer is recommended; the oss-cad-suite build is stricter
about the SRAM model's port declarations and is the one used during development.
GitHub Actions installs Icarus and `requirements.txt`, then invokes the same
`./RTL/run_all.sh` entry point used locally.

## What the suites establish

- `Fastpath` checks 256 golden predictions and the cycle alignment of the
  observation evidence.
- `Slowpath` replays 256 observations against its fixed-point Python model and
  checks counters and the quiescent-only parameter backdoor.
- `Cache` exercises the integrated timing, sampler, drop, collision, starvation,
  tuning, and statistics paths.

The integrated learning test establishes that tuning bundles are produced and
applied. It does not by itself establish workload-level convergence or a cache
performance improvement; that requires trace-driven evaluation in addition to
the RTL regression.

## Research and AI-assisted verification references

The RTL’s direct architectural lineage is [Multiperspective Reuse
Prediction](https://doi.org/10.1145/3123939.3123942), [Perceptron Learning for
Reuse Prediction](https://doi.org/10.1109/MICRO.2016.7783705), and [Sampling
Dead Block Prediction](https://doi.org/10.1109/MICRO.2010.24). The recurrent and
teacher-label mechanisms draw on the [original GRU
paper](https://arxiv.org/abs/1406.1078) and
[DAgger](https://proceedings.mlr.press/v15/ross11a.html). The complete research
bibliography and the distinction between direct lineage and neighboring work
are at the end of the [main README](../README.md#research-lineage-and-verification-disclosure).

OpenAI Codex and Anthropic Claude were used for AI-assisted review, with every
accepted claim checked against source, simulation, or generated reports rather
than accepted on model authority. See the official [OpenAI Codex
documentation](https://developers.openai.com/) and [Anthropic Claude Code
documentation](https://code.claude.com/docs/en/overview).
