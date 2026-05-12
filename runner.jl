#!/usr/bin/env julia
"""
Distributed Runner
==================
Add local and/or remote SSH worker processes, then run a Julia script with distributed pmap support.

NOTE: This uses Distributed.jl (multi-process), not multi-threading.
      - pmap/remotecall work across separate Julia processes
      - Each worker is an independent process with its own memory
      - For multi-threading within a single process, use Julia's -t option directly

Workflow:
  1. Verify git hash matches across all hosts (skip with --skip-hash-check)
  2. Clean up stale worker processes (local + remote)
  3. Check memory capacity (after cleanup for accurate readings)
  4. Add local/remote worker processes
  5. Initialize workers: activate project, load package
  6. Run the target script
  7. Collect new result files from remote hosts back to local

Usage:
  # Remote hosts only (master process on local, workers on remotes)
  julia --project=. ParallelRunnerKit/runner.jl host1:10 host2:10 script.jl --args

  # Local + remote (9 local workers + 20 remote = 29 total worker processes)
  julia --project=. ParallelRunnerKit/runner.jl --local 9 host1:10 host2:10 script.jl --args

  # Local only (9 worker processes)
  julia --project=. ParallelRunnerKit/runner.jl --local 9 script.jl --args

Host specification:
  hostname        Use default worker count (1 or --workers N)
  hostname:N      Use N workers on this host

Options:
  -l, --local N         Number of local worker processes to add (default: 0)
  -w, --workers N       Default worker count for hosts without explicit :N
  --julia PATH          Julia executable path for remote hosts (default: auto-detect)
  --skip-hash-check     Skip git commit verification (not recommended)
  --no-log              Do not write console output to a log file
  --log-dir PATH        Log output directory (default: script's output dir, or <script_dir>/results)
  --package NAME        Load this module on workers instead of `name` from Project.toml
  --collect-missing ROOT HOST...   files under ROOT missing locally only (by relative path)
  --collect-overwrite ROOT HOST... rsync-merge whole tree under ROOT (overwrite same-named files)
  --collect-tree / --collect-tree-sync  aliases (--collect-missing / --collect-overwrite)
  -h, --help            Show help

Output:
  Console output is written to <log_dir>/runner_<timestamp>.log.
  Default log dir is determined by the script (via ENV["DISTRIBUTED_OUTPUT_DIR"] set by init_output_dir!),
  then --output-dir from script_args, then <script_dir>/results as last fallback.
  Use --log-dir to override. Use --no-log to disable.

Environment variables:
  DISTRIBUTED_SSH_OPTS       Custom SSH options (space-separated)
  DISTRIBUTED_COLLECT_DIRS   Colon-separated dirs to rsync after run (repo-relative or abs); see ParallelRunnerKit.distributed_collect_root_dirs
  JULIA_DISTRIBUTED_EXE      Default Julia path for remote hosts

Prerequisites:
  - SSH key authentication to all remote hosts
  - Same project path on all machines (e.g., ~/projects/MyModel.jl)
  - Same git commit (checked automatically)
  - Julia installed on remote hosts (auto-detected in common locations)

Example (full workflow):
  # 1. Sync code to remotes
  julia --project=. ParallelRunnerKit/setup.jl --sync host1 host2

  # 2. Run parameter sweep with 29 distributed worker processes (9 local + 10 + 10 remote)
  julia --project=. ParallelRunnerKit/runner.jl --local 9 host1:10 host2:10 \\
      experiments/sweep_run.jl --config experiments/configs/main.json

See also: ParallelRunnerKit/setup.jl, ParallelRunnerKit/README.md
"""

using Distributed
using Dates

include(joinpath(@__DIR__, "src", "ParallelRunnerKit.jl"))
using .ParallelRunnerKit

# Project root for git checks (same as setup.jl; script-path-derived proj_dir used for execution)
const PROJECT_ROOT = get(ENV, "DISTRIBUTED_PROJECT_ROOT", dirname(@__DIR__))

show_help() = println(runner_help_text())

"""
Recursively pull files under `local_root` from each host.

- `merge=false`: skip relative paths that already exist locally.
- `merge=true`:  rsync the whole tree (overwrites same-named files).

Uses `DISTRIBUTED_REMOTE_PROJECT_ROOT` (via `remote_path_for_ssh_collect`) to map the local root to the correct path on each host.
"""
function runner_collect_tree(local_root::AbstractString, host_names::Vector{String}; merge::Bool=false)
    root_disp    = abspath(expanduser(String(PROJECT_ROOT)))
    repo_root    = abspath(expanduser(String(PROJECT_ROOT)))
    local_root   = String(abspath(expanduser(String(local_root))))
    ssh_cmd_str  = "ssh " * join(SSH_OPTS, " ")

    println("============================================================")
    println(merge ? "ParallelRunnerKit collect-overwrite" : "ParallelRunnerKit collect-missing")
    println("============================================================")
    println("local root : ", display_path(local_root, root_disp))
    println("mode       : ", merge ? "full sync (same-named files updated when remote differs)" :
                                     "missing paths only (existing local files left unchanged)")
    println("hosts      : ", join(host_names, ", "))
    println("")

    remote_root = remote_path_for_ssh_collect(local_root, repo_root)
    if remote_root != local_root
        println("remote root: ", remote_root)
        println("")
    end

    ok = true
    for host in host_names
        print("  ", host, ": ")
        flush(stdout)
        try
            if !success(pipeline(
                    Cmd(["ssh", SSH_OPTS..., host, "test", "-d", remote_root]);
                    stderr=devnull, stdout=devnull,
                ))
                println("(skip: no directory on host at ", remote_root, ")")
                println("      hint: export DISTRIBUTED_REMOTE_PROJECT_ROOT=<repo root on SSH host>")
                continue
            end

            remote_files = collect_tree_remote_files_ssh(host, remote_root)
            if isempty(remote_files)
                println("(remote root empty or no files found)")
                continue
            end

            if merge
                # No `--mkpath`: macOS ships BSD rsync without that flag (GNU rsync 3.2.3+).
                rsync_cmd = Cmd(String[
                    "rsync", "-az",
                    "-e", ssh_cmd_str,
                    string(host, ":", remote_root, "/"),
                    local_root * "/",
                ])
                run(pipeline(rsync_cmd; stderr=stderr))
                println("✓ (synced ", length(remote_files), " remote file",
                        length(remote_files) == 1 ? "" : "s", ")")
            else
                need = String[rel for (_, rel) in remote_files
                              if !isfile(joinpath(local_root, rel))]
                if isempty(need)
                    println("(nothing new — all remote files exist locally; use --collect-overwrite to replace)")
                    continue
                end
                sort!(need)
                # `--files-from` does not create parents on BSD rsync; pre-create (GNU rsync `--mkpath` unavailable).
                for rel in need
                    d = dirname(joinpath(local_root, rel))
                    !isempty(d) && mkpath(d)
                end
                rsync_cmd = Cmd(String[
                    "rsync", "-az",
                    "-e", ssh_cmd_str,
                    "--files-from=-",
                    string(host, ":", remote_root, "/"),
                    local_root * "/",
                ])
                buf = IOBuffer()
                foreach(p -> println(buf, p), need)
                seekstart(buf)
                run(pipeline(rsync_cmd; stdin=buf, stderr=stderr))
                n = length(need)
                println("✓ ($n file", n == 1 ? "" : "s", ")")
            end
        catch e
            ok = false
            println("✗ ", sprint(showerror, e))
        end
    end
    println("")
    ok || println("(some hosts failed; exit 1)")
    return ok
end

function runner_main()
    parsed = parse_runner_args(ARGS)

    if parsed.help
        show_help()
        exit(0)
    end

    if parsed.collect_root !== nothing
        ok = runner_collect_tree(
            parsed.collect_root,
            parsed.collect_hosts;
            merge=something(parsed.collect_overwrite, false),
        )
        exit(ok ? 0 : 1)
    end

    if parsed.script_path === nothing
        show_help()
        exit(1)
    end

    hosts = parsed.hosts  # Vector of (host, workers) tuples
    root_disp = abspath(expanduser(String(PROJECT_ROOT)))  # anchor for human-readable paths in logs
    script_path = parsed.script_path
    script_args = parsed.script_args
    local_workers = parsed.local_workers
    default_workers = parsed.default_workers
    julia_exe = parsed.julia
    skip_hash_check = parsed.skip_hash_check
    enable_log = parsed.enable_log
    log_dir = parsed.log_dir
    explicit_package = parsed.explicit_package
    
    # Extract host names for checks
    host_names = [h[1] for h in hosts]
    
    # Make script path absolute
    if !isabspath(script_path)
        script_path = abspath(script_path)
    end
    
    if !isfile(script_path)
        error("Script not found: $script_path")
    end
    
    script_dir = dirname(script_path)
    proj_dir = resolve_pkg_project_dir(script_dir)

    # Include script early (defines functions only; no @everywhere — workers not yet added).
    # If the script defines init_output_dir!(args), call it to set ENV["DISTRIBUTED_OUTPUT_DIR"]
    # so the log file lands in the same directory as the data output by default.
    include(script_path)
    if isdefined(Main, :init_output_dir!)
        @invokelatest Main.init_output_dir!(script_args)
    end
    
    # Start console log file
    if enable_log
        resolved_log_dir = log_dir
        if resolved_log_dir === nothing
            # Use ENV set by init_output_dir! above (single source of truth with the script)
            resolved_log_dir = get(ENV, "DISTRIBUTED_OUTPUT_DIR", nothing)
        end
        if resolved_log_dir === nothing
            # Fallback: try --output-dir from script args
            for j in 1:length(script_args)-1
                if script_args[j] == "--output-dir"
                    resolved_log_dir = script_args[j+1]
                    break
                end
            end
        end
        if resolved_log_dir === nothing
            resolved_log_dir = joinpath(script_dir, "results")
        end
        init_log_file(String(resolved_log_dir); prefix="runner", path_anchor=root_disp)
        atexit(close_log_file)
    end
    
    print_header("Distributed Runner")
    writeln_both("")
    writeln_both("Script: $(display_path(script_path, root_disp))")
    writeln_both("Args: $(join(script_args, " "))")
    proj_disp = let s = display_path(proj_dir, root_disp)
        s == "." ? basename(abspath(String(proj_dir))) : s
    end
    writeln_both("Project: $(proj_disp)")
    writeln_both("ParallelRunnerKit: $(parallel_runner_kit_version())")
    app_git = get_local_git_hash(proj_dir; short=8)
    writeln_both("Application git (project dir): $(app_git === nothing ? "unavailable" : app_git)")
    writeln_both("")
    
    # Check git hashes before adding workers
    if !isempty(host_names)
        if skip_hash_check
            writeln_both("Git hash check: skipped (--skip-hash-check)")
            writeln_both("")
        else
            writeln_both("Checking git hashes...")
            ok, mismatches = check_git_hashes(host_names, PROJECT_ROOT)
            writeln_both("")
            if !ok
                print_err("ERROR: ", bold=true)
                writeln_both("Git hash mismatch on $(join(mismatches, ", "))")
                writeln_both("")
                writeln_both("To sync, run:")
                print_info("  julia --project=. ParallelRunnerKit/setup.jl --sync $(join(mismatches, " "))\n")
                writeln_both("")
                writeln_both("Or skip check (not recommended):")
                print_warn("  --skip-hash-check\n")
                writeln_both("")
                exit(1)
            end
        end
    end
    
    # Clean up stale worker processes first (frees memory for accurate check)
    writeln_both("Cleaning up stale workers...")
    
    try
        run(pipeline(Cmd(["pkill", "-9", "-f", "julia.*--worker"]), stdout=devnull, stderr=devnull))
    catch
    end
    try
        run(pipeline(Cmd(["pkill", "-9", "-f", "julia.*--bind-to"]), stdout=devnull, stderr=devnull))
    catch
    end
    write_both("  localhost: ")
    print_ok("✓")
    writeln_both("")
    
    for (host_name, _) in hosts
        try
            cleanup_cmd = """
                pkill -9 -f 'julia.*worker' 2>/dev/null
                pkill -9 -f 'julia.*--bind-to' 2>/dev/null
                true
            """
            cmd = Cmd(["ssh", SSH_OPTS..., host_name, cleanup_cmd])
            run(pipeline(cmd, stdout=devnull, stderr=devnull))
            write_both("  $host_name: ")
            print_ok("✓")
            writeln_both("")
        catch e
            writeln_both("  $host_name: (skipped - $e)")
        end
    end
    writeln_both("")
    
    # Check memory capacity (after cleanup so readings are accurate)
    if local_workers > 0 || !isempty(hosts)
        check_memory_capacity(local_workers, hosts, default_workers)
    end
    
    # Add worker processes
    writeln_both("Adding workers...")
    
    # Track successfully added remote hosts for result collection
    successful_hosts = String[]
    
    # Local worker processes (separate Julia processes on localhost)
    if local_workers > 0
        write_both("  localhost ($local_workers workers): ")
        try
            addprocs(local_workers; exeflags=`--project=$proj_dir`, topology=:master_worker)
            print_ok("✓")
            writeln_both("")
        catch e
            print_err("✗ ($e)")
            writeln_both("")
        end
    else
        writeln_both("  localhost: master only (use --local N for local workers)")
    end
    
    # Build SSH flags as a Cmd object (each element becomes a separate argument)
    sshflags_cmd = Cmd(collect(String, SSH_OPTS))
    
    for (host_name, host_workers_spec) in hosts
        # Auto-detect Julia path if not specified
        host_julia = julia_exe
        if host_julia === nothing
            write_both("  $host_name: detecting Julia... ")
            host_julia = detect_julia_path(host_name)
            if host_julia === nothing
                print_err("✗ (Julia not found)")
                writeln_both("")
                continue
            end
            print_info("found at $host_julia")
            writeln_both("")
            write_both("  ")
        end
        
        # Use: explicit host:N > --workers N > default 1
        host_workers = something(host_workers_spec, default_workers, 1)
        
        write_both("$host_name ($host_workers workers): ")
        try
            addprocs([(host_name, host_workers)];
                     exename=`$host_julia`,
                     sshflags=sshflags_cmd,
                     dir=script_dir,
                     tunnel=true,
                     topology=:master_worker,
                     exeflags=`--project=$proj_dir`)
            print_ok("✓")
            writeln_both("")
            push!(successful_hosts, host_name)
        catch e
            print_err("✗")
            writeln_both("")
            if e isa CompositeException
                for (i, ex) in enumerate(e.exceptions)
                    actual_ex = ex isa TaskFailedException ? ex.task.result : ex
                    writeln_both("    Error $i: $(typeof(actual_ex))")
                    # Show first line of error message
                    msg = sprint(showerror, actual_ex)
                    first_line = first(split(msg, '\n'))
                    writeln_both("    $first_line")
                end
            else
                writeln_both("    $(sprint(showerror, e))")
            end
        end
    end
    
    writeln_both("")
    writeln_both("Workers: $(nworkers())")
    writeln_both("")
    
    if nworkers() == 0
        error("No workers available. Check SSH connectivity.")
    end

    # Let SSH tunnels and worker↔master TCP registration settle before the first
    # `remotecall_fetch`. Hitting workers immediately after `addprocs` can trigger
    # Distributed.jl "attempt to send to unknown socket" cascades (observed with
    # Julia 1.12 + tunnel=true + many hosts). Override with ENV:
    #   DISTRIBUTED_INIT_DELAY_SEC=0   — skip wait
    #   DISTRIBUTED_INIT_DELAY_SEC=8   — longer pause on flaky networks
    _init_delay = tryparse(Float64, get(ENV, "DISTRIBUTED_INIT_DELAY_SEC", "5"))
    if _init_delay !== nothing && _init_delay > 0
        write_both("Waiting for worker connections ($(round(_init_delay, digits=1))s)... ")
        flush(stdout)
        sleep(_init_delay)
        print_ok("✓")
        writeln_both("")
    end
    
    # Register cleanup handler to terminate workers on exit
    # Note: atexit handlers may not run on forceful termination (multiple Ctrl+C)
    # The startup cleanup handles leftover workers from previous runs
    cleanup_registered = Ref(false)
    function cleanup_workers()
        cleanup_registered[] && return  # Avoid double cleanup
        cleanup_registered[] = true
        
        # Stop heartbeat monitors first to prevent "unknown socket" errors
        if nworkers() > 0
            try
                @everywhere stop_heartbeat_monitor()
                sleep(0.5)  # Give heartbeats time to stop
            catch
            end
        end
        
        # Then try graceful shutdown
        if nworkers() > 0
            try
                rmprocs(workers(); waitfor=5.0)
            catch
            end
        end
        
        # Force kill any remaining Julia worker processes on remote hosts
        for host in successful_hosts
            try
                cleanup_cmd = "pkill -9 -f 'julia.*worker' 2>/dev/null; pkill -9 -f 'julia.*--bind-to' 2>/dev/null; true"
                cmd = Cmd(["ssh", SSH_OPTS..., host, cleanup_cmd])
                run(pipeline(cmd, stdout=devnull, stderr=devnull); wait=true)
            catch
                # Ignore errors - host might be unreachable
            end
        end
    end
    atexit(cleanup_workers)
    
    # Verify all workers are responsive and load project package
    write_both("Initializing workers... ")
    flush(stdout)
    try
        # First, verify basic connectivity with timeout
        worker_ids = workers()
        responses = Int[]
        failed_workers = Int[]
        
        _ping_retries = something(tryparse(Int, get(ENV, "DISTRIBUTED_PING_RETRIES", "6")), 6)
        for w in worker_ids
            local r_ok
            r_ok = nothing
            local last_ex
            last_ex = nothing
            for attempt in 1:max(1, _ping_retries)
                try
                    r_ok = remotecall_fetch(() -> myid(), w)
                    break
                catch e
                    last_ex = e
                    attempt < max(1, _ping_retries) && sleep(0.4 * attempt)
                end
            end
            if r_ok !== nothing
                push!(responses, r_ok)
            else
                push!(failed_workers, w)
                @warn "Worker $w not responding" exception=something(last_ex, ErrorException("unknown"))
            end
        end
        
        if !isempty(failed_workers)
            writeln_both("($(length(failed_workers)) workers failed to respond)")
            # Remove failed workers
            for w in failed_workers
                try
                    rmprocs(w)
                catch
                end
            end
        end
        
        if isempty(responses)
            error("No workers responding")
        end
        
        # Load the project package on all workers (if it exists)
        # This ensures dependencies are available before running the script
        print_ok("✓ ($(length(responses)) workers)")
        writeln_both("")
        write_both("  Loading packages on workers... ")
        flush(stdout)
        
        # Disable automatic precompilation on workers to avoid noisy interleaved output
        @eval @everywhere ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
        
        # Use eval to run @everywhere at runtime (required inside a function)
        @eval @everywhere using Pkg
        @eval @everywhere Pkg.activate($proj_dir; io=devnull)
        
        # Load the main package on workers: --package wins, else Project.toml `name`
        pkg_name = explicit_package !== nothing ? explicit_package : project_package_name(proj_dir)
        if pkg_name !== nothing
            pkg_sym = Symbol(pkg_name)
            try
                # Precompile on one worker per host to avoid race conditions and noisy output
                host_workers = Dict{String, Int}()
                for w in workers()
                    host = remotecall_fetch(() -> gethostname(), w)
                    if !haskey(host_workers, host)
                        host_workers[host] = w
                    end
                end

                precompile_futures = [remotecall(w) do
                    Pkg.precompile(; io=devnull)
                end for (_, w) in host_workers]
                for f in precompile_futures
                    fetch(f)
                end

                @eval @everywhere using $pkg_sym

                for w in workers()
                    remotecall_fetch(() -> true, w)
                end

                print_ok("✓ ($pkg_name loaded)")
                writeln_both("")
            catch e
                writeln_both("(package load skipped: $(sprint(showerror, e)))")
            end
        elseif !isfile(joinpath(proj_dir, "Project.toml"))
            writeln_both("(no Project.toml in $(display_path(proj_dir, root_disp)))")
        else
            writeln_both("(no package name in Project.toml; use --package NAME)")
        end
        
        # Final verification: test that all workers can run a simple computation
        write_both("  Verifying workers... ")
        flush(stdout)
        test_results = pmap(w -> (myid(), 1 + 1), workers())
        working_count = count(r -> r[2] == 2, test_results)
        print_ok("✓ ($working_count workers verified)")
        writeln_both("")
        
        # Start heartbeat monitors on remote workers
        # Workers will exit if they can't reach master for 60 seconds
        write_both("  Starting heartbeat monitors... ")
        flush(stdout)
        @eval @everywhere begin
            # Global flag to stop heartbeat monitor gracefully
            const HEARTBEAT_STOP = Ref(false)
            
            function stop_heartbeat_monitor()
                HEARTBEAT_STOP[] = true
            end
            
            function start_heartbeat_monitor()
                myid() == 1 && return  # Master doesn't need this
                @async begin
                    consecutive_failures = 0
                    max_failures = 6  # 6 × 10s = 60s timeout
                    while !HEARTBEAT_STOP[]
                        sleep(10)
                        HEARTBEAT_STOP[] && break
                        try
                            # Try to ping master
                            remotecall_fetch(() -> true, 1)
                            consecutive_failures = 0
                        catch
                            consecutive_failures += 1
                            if consecutive_failures >= max_failures
                                # Master unreachable, exit
                                exit(0)
                            end
                        end
                    end
                end
            end
        end
        @everywhere start_heartbeat_monitor()
        
        # Synchronization barrier: ensure all output from workers has flushed
        for w in workers()
            remotecall_fetch(() -> (flush(stdout); flush(stderr); true), w)
        end
        print_ok("✓")
        writeln_both("")
    catch e
        print_err("✗")
        writeln_both("")
        @warn "Worker initialization failed" exception=e
        writeln_both("Continuing anyway...")
    end
    writeln_both("")
    
    # Set ARGS for the script
    empty!(ARGS)
    append!(ARGS, script_args)
    
    # Set a flag so scripts know they're running via runner
    ENV["DISTRIBUTED_RUNNER"] = "1"

    # When `DISTRIBUTED_SKIP_COLLECT=1` (e.g. demo.jl: results only on master), do not
    # touch the remote results directory — otherwise `.runner_sentinel_*` and empty
    # dirs are left on workers because the collection step never runs `rm`.
    skip_collect = get(ENV, "DISTRIBUTED_SKIP_COLLECT", "") == "1"
    sentinel_name = ""

    # Place a sentinel file on each remote host just before the script runs.
    # After the script, only files newer than the sentinel are rsync'd, so
    # pre-existing results from earlier runs are never copied to the master.
    if !skip_collect && !isempty(successful_hosts)
        sentinel_name = ".runner_sentinel_$(getpid())_$(Dates.format(now(), "yyyymmddTHHMMSS"))"
        repo_ra = abspath(String(PROJECT_ROOT))
        collect_roots_sentinel = distributed_collect_root_dirs(script_dir, repo_ra)
        for local_rd in collect_roots_sentinel
            _early_local = abspath(String(local_rd))
            for host in unique(successful_hosts)
                try
                    remote_early = remote_path_for_ssh_collect(_early_local, repo_ra)
                    run(pipeline(Cmd(["ssh", SSH_OPTS..., host, "mkdir", "-p", remote_early]),
                        stdout=devnull, stderr=devnull))
                    run(pipeline(Cmd(["ssh", SSH_OPTS..., host, "touch", joinpath(remote_early, sentinel_name)]),
                        stdout=devnull, stderr=devnull))
                catch; end
            end
        end
    end

    # Run script (catch Ctrl+C to ensure worker cleanup)
    writeln_both("Running script...")
    writeln_both("")
    run_script = () -> begin
        Base.invokelatest() do
            if isdefined(Main, :main)
                Main.main()
            end
        end
    end
    try
        if enable_log && LOG_FILE_HANDLE[] !== nothing
            orig_stdout = stdout
            log_io = LOG_FILE_HANDLE[]
            linebuf = UInt8[]
            rd, wr = redirect_stdout()
            reader = @async begin
                try
                    while true
                        data = readavailable(rd)
                        if !isempty(data)
                            write(orig_stdout, data)
                            for b in data
                                if b == 0x0d
                                    empty!(linebuf)
                                elseif b == 0x0a
                                    write(log_io, linebuf)
                                    write(log_io, b)
                                    flush(log_io)
                                    empty!(linebuf)
                                else
                                    push!(linebuf, b)
                                end
                            end
                        end
                        (isempty(data) && (eof(rd) || !isopen(wr))) && break
                        isempty(data) && yield()
                    end
                    if !isempty(linebuf)
                        write(log_io, linebuf)
                        flush(log_io)
                    end
                catch e
                    isa(e, Base.IOError) || rethrow()
                end
            end
            try
                run_script()
            finally
                flush(stdout)
                close(wr)
                # Timeout to avoid indefinite hang if reader blocks
                wait_ok = @async wait(reader)
                for _ in 1:300  # 30s timeout
                    istaskdone(wait_ok) && break
                    sleep(0.1)
                end
                if !istaskdone(wait_ok)
                    close(rd)  # Unblock reader so it can exit
                    wait(reader)
                end
                redirect_stdout(orig_stdout)
            end
        else
            run_script()
        end
    catch e
        if e isa InterruptException
            writeln_both("\nInterrupted. Cleaning up workers...")
            cleanup_workers()
            exit(130)
        end
        rethrow()
    end
    
    # Collect results from remote hosts (rsync for bulk transfer, much faster than scp-per-file)
    results_dir = get(ENV, "DISTRIBUTED_OUTPUT_DIR", nothing)
    if results_dir === nothing
        results_dir = normpath(joinpath(script_dir, "..", "results"))
    end
    results_dir = abspath(results_dir)

    if !isempty(successful_hosts)
        writeln_both("")
        if skip_collect
            # Script saves all results on master (e.g. pmap-based demo.jl) — nothing to fetch.
            writeln_both("Results saved locally (no remote collection needed).")
            writeln_both("Results: $(display_path(results_dir, root_disp))")
        else
            collect_roots = distributed_collect_root_dirs(script_dir, abspath(String(PROJECT_ROOT)))
            for local_rd in collect_roots
                mkpath(local_rd)
            end
            writeln_both("Collecting results from remote hosts...")
            repo_ra = abspath(String(PROJECT_ROOT))
            for host in unique(successful_hosts)
                write_both("  $host: ")
                total_for_host = 0
                host_err = nothing
                try
                    ssh_cmd = "ssh " * join(SSH_OPTS, " ")
                    for local_rd in collect_roots
                        local_abs = abspath(String(local_rd))
                        remote_rd_collect = remote_path_for_ssh_collect(local_abs, repo_ra)
                        remote_sentinel = joinpath(remote_rd_collect, sentinel_name)
                        try
                            remote_find_raw = try
                                strip(
                                    read(
                                        pipeline(
                                            Cmd([
                                                "ssh",
                                                SSH_OPTS...,
                                                host,
                                                "find",
                                                remote_rd_collect,
                                                "-type",
                                                "f",
                                                "-newer",
                                                remote_sentinel,
                                                "!",
                                                "-name",
                                                sentinel_name,
                                                "-print",
                                            ]);
                                            stderr=devnull,
                                        ),
                                        String,
                                    ),
                                )
                            catch
                                ""
                            end
                            rroot = String(rstrip(String(remote_rd_collect), '/'))
                            rel_lines = String[]
                            for line in split(remote_find_raw, '\n')
                                lp = strip(String(line))
                                isempty(lp) && continue
                                rel = if startswith(lp, rroot * "/")
                                    lp[(length(rroot) + 2):end]
                                else
                                    continue
                                end
                                isempty(rel) && continue
                                push!(rel_lines, rel)
                            end
                            file_list = join(unique(rel_lines), '\n')

                            if !isempty(file_list)
                                remote_uri = string(host, ":", remote_rd_collect, "/")
                                rsync_part = Cmd(String[
                                    "rsync",
                                    "-az",
                                    "-e",
                                    ssh_cmd,
                                    "--files-from=-",
                                    remote_uri,
                                    local_abs * "/",
                                ])
                                buf = IOBuffer()
                                print(buf, strip(file_list))
                                write(buf, '\n')
                                seekstart(buf)
                                run(pipeline(rsync_part; stdin=buf, stderr=stderr))
                                total_for_host +=
                                    count(!isempty(strip(l)) for l in split(file_list, '\n'))
                            end
                        catch e
                            host_err === nothing && (host_err = e)
                        finally
                            try
                                run(pipeline(Cmd(["ssh", SSH_OPTS..., host, "rm", "-f", remote_sentinel]),
                                             stdout=devnull, stderr=devnull))
                            catch; end
                        end
                    end
                    if host_err !== nothing
                        print_err("✗ ($host_err)")
                    elseif total_for_host == 0
                        print_warn("(nothing to collect)")
                    else
                        print_ok("✓ ($total_for_host file$(total_for_host == 1 ? "" : "s"))")
                    end
                    writeln_both("")
                catch e
                    print_err("✗ ($e)")
                    writeln_both("")
                end
            end
            coll_disp = join(
                (display_path(String(p), root_disp) for p in collect_roots),
                ", ",
            )
            writeln_both("Results collected to: $coll_disp")
        end
    end
end

runner_main()
