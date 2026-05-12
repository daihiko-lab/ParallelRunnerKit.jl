# ParallelRunnerKit.jl

**Status:** Under active development in our lab. We are still **confirming behaviour through real simulation experiments**; treat interfaces, scripts, and operational notes as **subject to change** until a stable release line is declared.

Parallel execution of Julia **driver scripts** (for example `scripts/jobs.jl` with your own CLI) across local and remote worker processes using Distributed.jl (multi-process parallelism, not multi-threading).

日本語: [README.ja.md](README.ja.md)

**Note**: Uses multi-process parallelism, not multi-threading. For single-process thread parallelism, run your script directly with `julia -t N`.

**Platform (maintainers):** This kit is **developed and tested on macOS only**. Local workflows, examples, and several operational notes (rsync, power/sleep, Thunderbolt) assume macOS. **Linux and Windows are not in the supported matrix** here; remote workers are often Macs in our setups, but if you point the runner at other OSes you are on your own.

**Julia / GitHub:** This tree follows the usual small-package layout (`Project.toml` + `src/ParallelRunnerKit.jl`). A **`Manifest.toml`** is optional: generate it locally with **`Pkg.instantiate()`** under `julia --project=<kit_dir>` if you want pinned runner deps; this upstream repo **does not commit** that file (see **[`.gitignore`](.gitignore)** in this directory). The canonical standalone repo is **[daihiko-lab/ParallelRunnerKit.jl](https://github.com/daihiko-lab/ParallelRunnerKit.jl)** (`git clone https://github.com/daihiko-lab/ParallelRunnerKit.jl.git`). CLI scripts can stay at the repo root or move under `scripts/`.

## Upstream repository (clone / submodule)

```bash
git clone https://github.com/daihiko-lab/ParallelRunnerKit.jl.git
cd ParallelRunnerKit.jl
```

From another repository’s root (typical submodule path):

```bash
git submodule add https://github.com/daihiko-lab/ParallelRunnerKit.jl.git ParallelRunnerKit
```

## Standalone copy (optional `Manifest.toml`)

If you copy **`ParallelRunnerKit/`** alone and want a resolved environment for the runner stack (`ArgParse`, `JSON3`, stdlibs), run once:

```bash
julia --project=/path/to/ParallelRunnerKit -e 'using Pkg; Pkg.instantiate()'
```

That writes **`Manifest.toml`** next to **`Project.toml`** on disk. **`ParallelRunnerKit/.gitignore`** keeps it untracked so you are not forced to follow Julia-resolution churn in this upstream tree; downstream forks or private deployments can still **commit** their own manifest if they prefer strict pinning.

```bash
julia --project=/path/to/ParallelRunnerKit /path/to/ParallelRunnerKit/runner.jl --help
```

**Embedded in a full app:** Your simulation code still uses the **application root** environment (`julia --project=<repo_root>`) so workers load your main package. You can keep merging only **`[deps]`** from **`Project.toml`** into the host project, same as before.

**Integration:** Git **submodule**, **subtree**, **`Pkg.add` from a URL**, or a plain **directory copy** are all valid; choose what fits your release process. Submodule records a pinned kit commit in the parent repo, but **consumers of your app are not forced** to use submodules if they obtain the kit another way (e.g. vendored copy).

**SSH / multi-host distributed runs:** this directory is meant to be the **whole add-on** you need on top of a normal Julia project: `runner.jl`, `setup.jl`, `suggest_workers.jl`, **[`Project.toml`](Project.toml)** (runner deps; merge into the host project if needed), **`src/ParallelRunnerKit.jl`** (shared module loaded by those scripts), and **[`templates/script_template.jl`](templates/script_template.jl)** (minimal `init_output_dir!` / `main()` you can copy). Copy **`ParallelRunnerKit/` as-is** into another repo, keep the same layout, add the usual script hooks (**`init_output_dir!(args)`** and **`main()`** — see [DEVELOPMENT.md](docs/DEVELOPMENT.md#interface-contract-script-side)), and ensure the active environment declares the same small deps (**`ArgParse`**, **`JSON3`**, **`Dates`**, **`Distributed`**). The runner loads the module named in the root **`Project.toml`** by default, or **`--package NAME`** if the module name differs; it does **not** hard-code any particular application package.

**Simulation without this runner:** your model and batch code live in **your** application (`src/`, `scripts/`, etc.). If you do not need distributed runs, you can **omit or delete** this kit; the runner does not need to be present for single-process or ad hoc `julia -p N` / `julia -t N` workflows.

## Procedure

```
ParallelRunnerKit/runner.jl [--local N] [host1:W host2:W ...] script.jl [args...]
        │
        ▼
[1] add workers (local + remote)
        │
        ▼
[2] run script (e.g. `scripts/jobs.jl --config configs/cell.json`)
        │
        │    typical pattern: `Main.main()` partitions work, uses `pmap` (or similar)
        │    across workers, writes artifacts under a run-specific output directory
        │
        ▼
[3] collect result files from remotes
```

**Correspondence**:
- **Your driver** implements `init_output_dir!` / `main()` (see [DEVELOPMENT.md — Interface contract](docs/DEVELOPMENT.md#interface-contract-script-side)); `main()` usually schedules units of work and aggregates results.
- **Runner kit** (`ParallelRunnerKit/`): adds workers, runs the script on the master with `ARGS` forwarded, collects new result files from remotes (see `runner.jl` workflow).

**Reproducibility:** `runner.jl` logs **`parallel_runner_kit_version()`** (from `ParallelRunnerKit/Project.toml`) and a **short git hash** for the application project directory. Remote runs still enforce **full commit parity** across hosts unless **`--skip-hash-check`**. Stricter pinning (tags, `Manifest.toml`, worker self-report) is outlined in [DEVELOPMENT.md — Versioning and reproducibility](docs/DEVELOPMENT.md#versioning-and-reproducibility).

## Files

| File | Description |
|------|-------------|
| `runner.jl` | Add worker processes (local + remote), run script, collect results |
| `setup.jl` | Clone, check/sync git repo, install packages, cleanup on remote hosts |
| `suggest_workers.jl` | Load package on each host, measure RSS, suggest worker allocation |
| `src/ParallelRunnerKit.jl` | Module: paths, logging, SSH/git, runner CLI (`parse_runner_args`, `runner_help_text`), memory + git parity checks (from your own script: `include(...); using .ParallelRunnerKit`, or `using ParallelRunnerKit` if installed) |
| `test/runtests.jl` | Kit test entry: from app root `julia --project=. ParallelRunnerKit/test/runtests.jl`; from a standalone kit checkout `julia --project=. test/runtests.jl` |
| `test/test_parallel_runner_kit.jl` | Helper/path tests for `ParallelRunnerKit` (included by `test/runtests.jl`) |
| `Project.toml` | Declares runner-only deps for vendoring (not the env you use for `src/` sims) |
| `.gitignore` | Ignores locally generated `Manifest.toml` when this directory is used as its own `--project` |
| `templates/script_template.jl` | Runnable minimal driver (`init_output_dir!`, `main()`); try `ParallelRunnerKit/runner.jl --local 2 ParallelRunnerKit/templates/script_template.jl` |
| `docs/` | Developer notes: [DEVELOPMENT.md](docs/DEVELOPMENT.md), [DEVELOPMENT.ja.md](docs/DEVELOPMENT.ja.md); [index](docs/README.md) |
| `LICENSE` | MIT; this directory can be its own Git repository (submodule, fork, or standalone clone) |

## Prerequisites

- **macOS:** Local machine (and typical remotes) are expected to be **macOS**; this is the only platform we exercise in development.
- **SSH key authentication** to all remote hosts (password-less login)
- **GitHub SSH access** from all remote hosts (verify with `ssh -T git@github.com`)
- **Same project path** on every machine (e.g. `~/projects/MySimulation.jl`)
- **Julia installed** on remote hosts (auto-detected in common locations)

## Quick Start

```bash
# 1. Clone (first time only)
julia --project=. ParallelRunnerKit/setup.jl --clone HOST1 HOST2 ...

# 2. Install dependencies (first time only)
julia --project=. ParallelRunnerKit/setup.jl --instantiate HOST1 HOST2 ...

# 3. Check prerequisites
julia --project=. ParallelRunnerKit/setup.jl --check HOST1 HOST2 ...

# 4. Sync code (after local commits)
julia --project=. ParallelRunnerKit/setup.jl --sync HOST1 HOST2 ...

# 5. (Optional) Suggest worker allocation from benchmark
julia --project=. ParallelRunnerKit/suggest_workers.jl --local HOST1 HOST2 ...

# 6. Run script with local + remote workers
julia --project=. ParallelRunnerKit/runner.jl --local N HOST1:W HOST2:W ... path/to/script.jl [script_args...]
```

Replace `HOST1 HOST2 ...` with your hostnames, `N` / `W` with worker counts per host, and `path/to/script.jl` with your script and any arguments.

HTTPS origin URLs are automatically converted to SSH format.

## runner.jl

Add local and remote worker processes, then run a script with distributed `pmap` support.

**Workflow**: Verify git hashes → Clean up stale workers → Check memory → Add workers → Initialize (activate project, load package) → Run script → Collect results from remotes

### Usage

```bash
julia --project=. ParallelRunnerKit/runner.jl [options] [hosts...] script.jl [script_args...]

# Local + remote (example: driver with CLI)
julia --project=. ParallelRunnerKit/runner.jl --local 9 host1:10 host2:10 \
  scripts/jobs.jl --config configs/cell.json

# Remote only (master on local, workers on remotes)
julia --project=. ParallelRunnerKit/runner.jl host1:10 host2:10 \
  scripts/jobs.jl --config configs/cell.json

# Local only
julia --project=. ParallelRunnerKit/runner.jl --local 9 \
  scripts/jobs.jl --config configs/cell.json

# Files under data/sweep that exist on workers but not locally (recursive)
julia --project=. ParallelRunnerKit/runner.jl --collect-missing \
  data/sweep m4-mini-lan m4-mini2-tb

# Replace local tree from remote (same paths)
julia --project=. ParallelRunnerKit/runner.jl --collect-overwrite data/sweep m4-mini-lan m4-mini2-tb
```

### Options

| Option | Description |
|--------|-------------|
| `-l, --local N` | Number of local worker processes (default: 0) |
| `-w, --workers N` | Default worker count for remote hosts without explicit `:N` |
| `--julia PATH` | Julia executable path for remote hosts |
| `--skip-hash-check` | Skip git commit verification |
| `--no-log` | Do not write console output to a log file |
| `--log-dir PATH` | Log output directory (default: script's output dir, or `<script_dir>/results`) |
| `--collect-missing ROOT HOST...` | rsync: fetch files under `ROOT` missing locally (by relative path); then exit; no script |
| `--collect-overwrite ROOT HOST...` | rsync: merge whole tree under `ROOT` (updates same-named files) |
| `--collect-tree`, `--collect-tree-sync` | Aliases for `--collect-missing` / `--collect-overwrite` |
| `hostname:N` | Use N workers on this host (e.g., `host1:10`) |

| Variable | Description |
|----------|-------------|
| `DISTRIBUTED_OUTPUT_DIR` | Output dir during distributed runs (default runner log dir + fallback when collect dirs unset) |
| `DISTRIBUTED_COLLECT_DIRS` | Colon-separated local trees to rsync after the script (abs or repo-relative); overrides the single-tree default |
| `DISTRIBUTED_REMOTE_PROJECT_ROOT` | Absolute repo root **on SSH worker hosts** when it differs from this machine (collect / sentinel rsync use repo-relative suffix) |
| `DISTRIBUTED_SSH_OPTS` | Custom SSH options (space-separated) |
| `JULIA_DISTRIBUTED_EXE` | Default Julia path for remote hosts |
| `DISTRIBUTED_INIT_DELAY_SEC` | Connection-stabilisation wait after `addprocs` (sec, default: 5) |
| `DISTRIBUTED_PING_RETRIES` | Per-worker ping retries during init (default: 6) |

## setup.jl

Check, sync, and manage remote hosts before/after running distributed jobs.

```bash
julia --project=. ParallelRunnerKit/setup.jl --clone host1 host2       # Clone repository
julia --project=. ParallelRunnerKit/setup.jl --check host1 host2       # Check prerequisites
julia --project=. ParallelRunnerKit/setup.jl --sync host1 host2        # Push + pull
julia --project=. ParallelRunnerKit/setup.jl --pull host1 host2        # Pull latest code (localhost + remotes)
julia --project=. ParallelRunnerKit/setup.jl --instantiate host1 host2 # Pkg.instantiate
julia --project=. ParallelRunnerKit/setup.jl --cleanup host1 host2     # Kill stale workers
julia --project=. ParallelRunnerKit/setup.jl --delete host1 host2      # Delete remote repositories
```

## Notes

- **Clean Slate**: `--delete` → `--clone` → `--instantiate` to reset

## Manual result sync (rsync)

The runner collects result files from remote hosts when the job finishes. If the run was interrupted (e.g. disconnect or Ctrl+C) or you want to pull results manually, use `rsync` from your local machine. Use the same project path on remotes as locally.

```bash
# Single host — pull remote results into local (adjust PROJ and subpath)
rsync -avz HOST:PROJ/path/to/results/ ./path/to/results/

# Multiple hosts
for h in host1 host2 host3; do
  rsync -avz $h:PROJ/path/to/results/ ./path/to/results/
done
```

Replace `PROJ` with your project root on the remote (e.g. `~/projects/MySimulation.jl`) and `path/to/results/` with the output directory your script uses.

## Long-Running Jobs

- **tmux**: Run in `tmux new -s sweep` to survive disconnection (detach: `Ctrl+B, D`)
- **Logging**
  - **tee** (no tmux): Wrap your run so stdout/stderr are shown and saved:
    ```bash
    julia --project=. ParallelRunnerKit/runner.jl ... script.jl 2>&1 | tee run.log
    ```
  - **tmux pipe-pane** (built-in, while already inside tmux):
    1. Start your job in a tmux pane as usual.
    2. To **start** logging: press `Ctrl+B`, release, then type `:` (colon). At the prompt, type:
       ```text
       pipe-pane -o 'cat >> session.log'
       ```
       and press Enter. Everything in that pane is now appended to `session.log` (path is relative to the pane’s cwd).
    3. To **stop** logging: same as step 2 — press `Ctrl+B`, `:`, run the same `pipe-pane -o '...'` command again (it toggles).
  - **Key binding** (optional): In `~/.tmux.conf` add:
    ```text
    bind P pipe-pane -o 'cat >> $HOME/tmux-#{session_name}.log'
    ```
    Reload config (`tmux source-file ~/.tmux.conf` or restart tmux). Then `Ctrl+B` then `P` toggles logging to `~/tmux-SESSIONNAME.log`.
  - **Save after the run** (scrollback only): If you didn’t log during the run, you can still save what’s left in the pane’s scrollback. In the pane, press `Ctrl+B` then `:` and run:
    ```text
    capture-pane -S -3000 -p > session.log
    ```
    This writes the last 3000 lines of that pane to `session.log`. Change `-3000` to capture more or fewer lines (or use `-S -` to get the full history). The pane’s history limit (`history-limit` in tmux) caps how much is kept.
- **Prevent remote sleep** (macOS): `sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1`
- **Thunderbolt networking** (macOS): When connecting via Thunderbolt, TB subsystem power transitions can drop the link. On all remote hosts, run:
  ```bash
  sudo pmset -a powernap 0
  sudo pmset -a displaysleep 0   # 0 for headless; use 10 etc. if using a display
  ```
  Verify with `pmset -g`. To restore after the job: `sudo pmset -a powernap 1` and `sudo pmset -a displaysleep 10`
- **SSH KeepAlive**: Built-in (`ServerAliveInterval=60`, `ServerAliveCountMax=10` = ~10 min tolerance)

## suggest_workers.jl

Load the project package on a probe worker on each host, measure RSS, then suggest worker counts from RAM and CPU constraints. Works for any experiment — no simulation needed.

```bash
julia --project=. ParallelRunnerKit/suggest_workers.jl [options] [--local] [hosts...]

# Local + remote
julia --project=. ParallelRunnerKit/suggest_workers.jl --local host1 host2

# Remote only
julia --project=. ParallelRunnerKit/suggest_workers.jl host1 host2

# Skip measurement, assume 1.5 GB per worker
julia --project=. ParallelRunnerKit/suggest_workers.jl --gb-per-worker 1.5 --local host1 host2
```

| Option | Description |
|--------|-------------|
| `-l, --local` | Include localhost in suggestion |
| `--gb-per-worker N` | Skip measurement, assume N GB per worker |
| `--mem-headroom N` | Memory cap fraction (default: 0.75) |
| `--master-gb N` | Reserve for master process (default: 0.4) |

Output includes per-host RAM, cores, measured per-worker memory, and a `runner.jl` command template.

**Why package load only?** Verified: replication-scale simulation (1100 agents, 100 trials, 300k steps) adds only ~0.04 GB over package load. The 10% buffer and 0.5 GB floor already provide sufficient margin. Simulation-based measurement was removed as unnecessary.

## Memory Check

The runner checks memory capacity after cleaning up stale workers from previous runs:

1. **Stale worker cleanup** — kills leftover Julia worker processes on all hosts so that memory readings are accurate
2. **Per-worker estimate** — based on the master process's RSS (`Sys.maxrss()`) × 1.2, with a 0.5GB floor (fallback: 1.5GB if RSS is unavailable)
3. **Capacity check** — warns if `N workers × per-worker estimate` exceeds 70% of total RAM on any host
   - Local: total RAM from `Sys.total_memory()`
   - Remote: total RAM via SSH (`sysctl` on macOS, `/proc/meminfo` on Linux)

**Tips**:
- For 16GB RAM hosts, up to ~9 workers is typically safe
- Match worker count to available CPU cores **and** memory
- Monitor remote hosts with `htop` during execution

## For Developers

Notes on the design intent of `ParallelRunnerKit/` and a roadmap for eventually
extracting it as a reusable package (working name: `DistributedRunner.jl`)
are kept separately in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Git hash mismatch | Run `--sync` or `--pull` on remote hosts |
| Julia not found on remote | Set `--julia /path/to/julia` or `JULIA_DISTRIBUTED_EXE` |
| SSH timeout | Adjust `DISTRIBUTED_SSH_OPTS="-o ConnectTimeout=10"` |
| Worker dies during execution | Check package is precompiled on remote; run manually to see errors |
| Broken pipe error | Remote worker crashed; check memory, disk space, or run test job |
| Connection reset (long jobs) | Disable sleep on remotes, use tmux locally |
| TB link drop (Thunderbolt) | On remotes: `powernap 0` and `displaysleep 0` (see Long-Running Jobs) |
| Memory warning at startup | Reduce `--local N` or `host:N`; stale workers are cleaned up automatically |
| Stale workers after crash | Run `--cleanup host1 host2` or restart runner (auto-cleans) |
| `attempt to send to unknown socket` | Race right after `addprocs`. Increase wait via `DISTRIBUTED_INIT_DELAY_SEC=10` |

## License

MIT — see [`LICENSE`](LICENSE). This tree is a normal Git project: you can publish it as its own repository, tag releases, and add it to other apps as a submodule or subtree without Julia-specific licensing beyond this file.
