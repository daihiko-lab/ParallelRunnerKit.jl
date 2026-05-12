# Developer Notes for `ParallelRunnerKit/`

This document records the intent and design constraints for eventually
extracting `ParallelRunnerKit/` into a reusable package (working name:
`DistributedRunner.jl`). It is written for developers who want to understand
what is generic vs. project-specific, and what needs to change before
separation is practical.

日本語: [DEVELOPMENT.ja.md](DEVELOPMENT.ja.md)

User-facing usage docs live in [README.md](../README.md). This file is for
internal / future-developer reference only.

**Platform:** Maintainers develop and test on **macOS only**. Some implementation details (e.g. rsync flags, remote RAM probes) mention Linux paths for completeness, but **non-macOS behaviour is not validated** in this tree.

**Distribution split:**
- **Add distributed runs only:** copy **`ParallelRunnerKit/` wholesale** (now includes `src/ParallelRunnerKit.jl`), satisfy the script contract (`init_output_dir!`, `main()`), and merge **`ParallelRunnerKit/Project.toml`** `[deps]` into the active environment. Your simulation code can live elsewhere; the runner does not import any host package by name. Use **`--package NAME`** when the module to load on workers is not the root `Project.toml` `name`.
- **Simulation only:** **delete the entire `ParallelRunnerKit/` directory** if unused; the host application’s `Project.toml` does not need to list this kit (drop README links in forks if you like).

**Folder name:** Matches the Julia module and stub `Project.toml` `name` (`ParallelRunnerKit`), which is the layout you want before splitting this tree into its own GitHub repo. The published upstream is **[daihiko-lab/ParallelRunnerKit.jl](https://github.com/daihiko-lab/ParallelRunnerKit.jl)**. `resolve_pkg_project_dir` keys off **`name == ParallelRunnerKit`**, not the directory basename, so co-located scripts still resolve the application `Project.toml` correctly.

## Coupling to the host application

`ParallelRunnerKit/` is already almost free of project-specific code. The only
coupling is:

| Location | What it assumes |
|----------|-----------------|
| `runner.jl` | Loads the project's main package on workers via `Project.toml` name detection, or `--package`; orchestrates workers and `Main.main()` |
| `runner.jl` | Calls `init_output_dir!(ARGS)` and `main()` on the included script |
| `src/ParallelRunnerKit.jl` | Shared helpers (paths, logging, SSH/git, runner CLI `parse_runner_args` / `runner_help_text`, memory + git parity checks); no host package imports |
| `setup.jl`  | Project root is a Julia project with a `Project.toml` |

None of the files import the host application by name. The runner discovers the
package name by reading `Project.toml`, so it works for any Julia project
without modification.

## Interface contract (script side)

For a script to work with `runner.jl`, it must expose exactly two functions
in `Main` after being `include`d:

```julia
# Called BEFORE workers are added.
# Must set ENV["DISTRIBUTED_OUTPUT_DIR"] to the desired output path.
# Optionally set ENV["DISTRIBUTED_SKIP_COLLECT"] = "1" if the script
# saves results only on the master (e.g. pmap-based runs that merge on master).
function init_output_dir!(args::Vector{String})::String
    ...
end

# Called AFTER workers are ready.
# Must use nworkers() / workers() to distribute work.
# All parallelism strategy (pmap, remotecall, @distributed) is decided here.
function main()
    ...
end
```

This two-function interface is the only coupling between `runner.jl` and
the experiment scripts. It must be kept stable if `ParallelRunnerKit/` is extracted.

## What makes extraction hard right now

1. **Single-repo assumption**: `setup.jl` assumes the project root is a git
   repo cloned from a known remote. The remote URL is read from
   `git remote get-url origin` on the master and replicated to workers. A
   standalone package would need a more general way to specify the project
   to deploy.

2. **`Project.toml`-based package loading**: `runner.jl` loads the project's
   main package by default from the root `name` field, with **`--package NAME`**
   as an override. A future extracted package could treat that flag as the primary API.

3. **Versioning**: `ParallelRunnerKit/Project.toml` lists runner-only deps for vendoring;
   it is **not** the environment used for normal `julia --project=.` simulations
   (the repo root project remains canonical). The stub package name is not registered.

4. **Module boundary**: shared code lives in **`src/ParallelRunnerKit.jl`** (`ParallelRunnerKit`). Entry scripts `include` it and `using .ParallelRunnerKit`; if the package is installed in the active environment, scripts can use plain `using ParallelRunnerKit`.

## Proposed extraction steps (when the time comes)

1. ~~**Consolidate shared code in a module**~~ — done (`src/ParallelRunnerKit.jl`).
2. **Generalise `setup.jl`** so it accepts an arbitrary remote URL instead
   of reading from the local git config.
3. **Stabilise the `init_output_dir!` / `main()` interface** as a documented
   public API (consider a lightweight abstract interface, or just
   documentation).
4. **Register as `DistributedRunner.jl`** (or keep unregistered for
   lab-internal use).

Already in-tree: **`src/ParallelRunnerKit.jl`** (proper module), **`Project.toml`** (dep manifest for merging), **`templates/script_template.jl`** (minimal driver), **`runner.jl --package NAME`** (worker module override).

## Versioning and reproducibility

**Today (vendored tree):**

- **`ParallelRunnerKit/Project.toml` `version`** is the kit’s semantic version. It is exposed as **`parallel_runner_kit_version()`** / **`PARALLEL_RUNNER_KIT_VERSION`** and printed at **`runner.jl`** startup next to the resolved application **`Project.toml`** path.
- **`runner.jl`** logs a **short git hash** for the **application** project directory (the env workers activate), so logs tie a run to a code revision even before remotes are involved.
- **Remote hosts:** existing **`check_git_hashes`** still enforces **full commit equality** against **`DISTRIBUTED_PROJECT_ROOT`** (default: repo root) when any SSH workers are used (unless **`--skip-hash-check`**).

**Stricter controls to consider later:**

- **Local checks (no CI in-repo):** from the repo root, `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test(; coverage=false)'` and `julia --project=. ParallelRunnerKit/test/runtests.jl`. The kit test verifies (**almost**) every **`[deps]`** entry in **`ParallelRunnerKit/Project.toml`** appears with the **same UUID** in the **application root** `Project.toml`. **`Distributed`** is excluded: it ships with Julia and cannot be mirrored as an ordinary **`[deps]`** line during **`Pkg.resolve`** on current Julia; the runner relies on **`using Distributed`** from the bundled stdlib.
- **Release discipline:** git tags matching `Project.toml` version, **`CHANGELOG.md`**, and CI that fails if tag and `version` disagree.
- **Environment pinning:** ship or require a **`Manifest.toml`** (or `Pkg.resolve` in `setup.jl`) so every host resolves the same dependency graph, not only the same application commit.
- **Worker self-report:** optional RPC so each worker prints **`VERSION`**, project path, and **`parallel_runner_kit_version()`** once after `using`, to catch mixed checkouts or stale depot caches.
- **Policy:** treat **`--skip-hash-check`** as audit-only; forbid in production configs.

## What NOT to do

- Do not add simulation-specific logic (`SimulationConfig`, result formats,
  etc.) into `ParallelRunnerKit/`. The runner must stay simulation-agnostic.
- Do not try to support non-Julia workers or non-SSH transports — that scope
  creep would make the package much harder to maintain.
- Do not add auto-retry or fault-tolerance beyond the current heartbeat +
  connection stability wait. True fault-tolerance (re-queuing failed tasks)
  is a different problem that `pmap`'s error handling already covers at the
  script level.

## Stability note on Julia 1.12

Julia 1.12 with `tunnel=true` and many SSH workers can trigger a race where
`addprocs` returns before all TCP connections are fully registered.
`runner.jl` works around this with `DISTRIBUTED_INIT_DELAY_SEC` (default:
5s) and per-worker ping retries (default: 6).

If this package is extracted, this workaround should be documented
prominently and possibly made configurable at the API level.
