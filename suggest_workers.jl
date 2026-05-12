#!/usr/bin/env julia
"""
Worker Allocation Suggestion
=============================
Load the project package on each host and measure RSS as a per-worker
baseline, then suggest worker counts from RAM and CPU constraints.

Usage:
  julia --project=. ParallelRunnerKit/suggest_workers.jl [options] [--local] [hosts...]

Options:
  -l, --local         Include localhost in suggestion (omit for remote-only)
  --gb-per-worker N   Skip measurement, assume N GB per worker
  --mem-headroom N    Memory cap fraction (default: 0.75)
  --master-gb N       Reserve for master process (default: 0.4)
  -h, --help

Examples:
  julia --project=. ParallelRunnerKit/suggest_workers.jl --local host1 host2
  julia --project=. ParallelRunnerKit/suggest_workers.jl --gb-per-worker 1.5 host1
"""

const RUNNER_KIT_DIR = @__DIR__
const PROJECT_ROOT = get(ENV, "DISTRIBUTED_PROJECT_ROOT", dirname(RUNNER_KIT_DIR))

include(joinpath(RUNNER_KIT_DIR, "src", "ParallelRunnerKit.jl"))
using .ParallelRunnerKit

using Distributed

const _PATH_ANCHOR = abspath(expanduser(String(PROJECT_ROOT)))

function _project_root_disp()::String
    s = display_path(String(PROJECT_ROOT), _PATH_ANCHOR)
    return s == "." ? basename(abspath(String(PROJECT_ROOT))) : s
end

# ── Argument parsing ──────────────────────────────────────────────────────────

function parse_args(args::Vector{String})
    gb_per_worker = nothing
    mem_headroom  = 0.75
    master_gb     = 0.4
    include_local = false
    hosts         = String[]

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ["-h", "--help"]
            println(read(@__FILE__, String))
            exit(0)
        elseif arg in ["--local", "-l"]
            include_local = true
        elseif arg == "--gb-per-worker"
            i += 1; i > length(args) && error("--gb-per-worker requires a number")
            gb_per_worker = parse(Float64, args[i])
        elseif arg == "--mem-headroom"
            i += 1; i > length(args) && error("--mem-headroom requires a number")
            mem_headroom = parse(Float64, args[i])
        elseif arg == "--master-gb"
            i += 1; i > length(args) && error("--master-gb requires a number")
            master_gb = parse(Float64, args[i])
        elseif !startswith(arg, "-")
            push!(hosts, arg)
        else
            @warn "Unknown option: $arg (ignored)"
        end
        i += 1
    end

    return (gb_per_worker=gb_per_worker, mem_headroom=mem_headroom,
            master_gb=master_gb, include_local=include_local, hosts=hosts)
end

# ── RSS measurement via package load ─────────────────────────────────────────

"""
Add one probe worker per host, load the project package, measure RSS.
Returns Dict(hostname => GB).
"""
function measure_rss(hosts::Vector{String}; include_local::Bool=false)
    worker_to_host = Dict{Int,String}()

    if include_local
        try
            addprocs(1; exeflags=`--project=$PROJECT_ROOT`, topology=:master_worker)
            worker_to_host[workers()[1]] = "localhost"
        catch e
            @warn "Local worker failed: $e"
        end
    end

    if !isempty(hosts)
        sshflags_cmd = Cmd(collect(String, SSH_OPTS))
        for host in hosts
            julia_exe = something(detect_julia_path(host), "julia")
            try
                addprocs([(host, 1)];
                         exename=`$julia_exe`,
                         sshflags=sshflags_cmd,
                         dir=PROJECT_ROOT,
                         tunnel=true,
                         topology=:master_worker,
                         exeflags=`--project=$PROJECT_ROOT`)
                worker_to_host[workers()[end]] = host
            catch e
                @warn "Worker on $host failed: $e"
            end
        end
    end

    isempty(worker_to_host) && return Dict{String,Float64}()

    pkg_name = project_package_name(PROJECT_ROOT)

    # Load package on workers (mirrors runner.jl initialization)
    @eval @everywhere ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    @eval @everywhere using Pkg
    @eval @everywhere Pkg.activate($PROJECT_ROOT; io=devnull)

    if pkg_name !== nothing
        pkg_sym = Symbol(pkg_name)
        # Precompile once per host to avoid race conditions
        host_first = Dict{String,Int}()
        for (w, h) in worker_to_host
            haskey(host_first, h) || (host_first[h] = w)
        end
        for (_, w) in host_first
            try; remotecall_fetch(w) do; Pkg.precompile(; io=devnull); end; catch; end
        end
        try; @eval @everywhere using $pkg_sym; catch; end
    end

    # Measure RSS
    per_worker_gb = Dict{String,Float64}()
    for (wid, host) in worker_to_host
        try
            rss = remotecall_fetch(() -> Sys.maxrss(), wid)
            gb  = rss > 0 ? rss / 1024^3 * 1.1 : 1.0   # 10% buffer
            per_worker_gb[host] = round(max(gb, 0.5), digits=2)
        catch
            per_worker_gb[host] = 1.0
        end
    end

    rmprocs(workers(); waitfor=2.0)
    return per_worker_gb
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    opts      = parse_args(ARGS)
    hosts     = opts.hosts
    all_hosts = opts.include_local ? ["localhost"; hosts] : hosts

    isempty(all_hosts) && error("Give hosts and/or --local. Example: --local host1 host2")

    println("=" ^ 60)
    println("Worker Allocation Suggestion")
    println("=" ^ 60)
    println("Project: $(_project_root_disp())")
    println()

    # Per-worker memory: manual or measured
    per_worker_gb = Dict{String,Float64}()
    if opts.gb_per_worker !== nothing
        for h in all_hosts
            per_worker_gb[h] = opts.gb_per_worker
        end
        println("Per-worker: $(opts.gb_per_worker) GB (manual)")
    else
        println("Measuring per-worker memory (package load)...")
        println()
        measured = measure_rss(hosts; include_local=opts.include_local)
        if isempty(measured)
            println("Measurement failed. Use --gb-per-worker N.")
            exit(1)
        end
        failed = [h for h in all_hosts if !haskey(measured, h)]
        if !isempty(failed)
            printstyled("  Connection failed: $(join(failed, ", "))\n"; color=:yellow)
        end
        for h in all_hosts
            gb = get(measured, h, 1.0)
            per_worker_gb[h] = gb
            write(stdout, "  $h: ")
            if haskey(measured, h)
                printstyled("$gb GB\n"; color=:green)
            else
                printstyled("$gb GB (probe failed, using default)\n"; color=:yellow)
            end
        end
    end
    println()

    # Host resources (RAM + CPU)
    local_total, local_nproc = get_local_resources()
    host_resources = Dict{String,NamedTuple}(
        "localhost" => (total_gb=local_total, nproc=local_nproc)
    )
    for host in hosts
        host_resources[host] = (
            total_gb = something(get_remote_total_gb(host), 0.0),
            nproc    = something(get_remote_nproc(host), 1)
        )
    end

    # Suggest workers
    suggestions = Dict{String,Int}()
    println("Host           RAM      Cores   Per-worker  Suggested")
    println("-" ^ 54)
    for host in all_hosts
        res   = host_resources[host]
        pw    = per_worker_gb[host]
        avail = res.total_gb * opts.mem_headroom - (host == "localhost" ? opts.master_gb : 0.0)
        cpu_reserve = host == "localhost" ? 2 : 1   # master needs an extra core
        n     = min(max(0, floor(Int, avail / pw)), max(1, res.nproc - cpu_reserve))
        suggestions[host] = n
        println("  $(lpad(host, 12))  $(round(res.total_gb, digits=1)) GB   $(res.nproc)      $(pw) GB     $n")
    end
    println()

    total = sum(values(suggestions))
    println("Total: $total workers")
    println()

    # Command template
    local_n      = get(suggestions, "localhost", 0)
    remote_parts = ["$(h):$(suggestions[h])" for h in hosts if get(suggestions, h, 0) > 0]
    local_arg    = local_n > 0 ? "--local $local_n " : ""
    remote_arg   = isempty(remote_parts) ? "" : join(remote_parts, " ") * " "
    println("Command template:")
    worker_args = "$(local_arg)$(remote_arg)"
    if isempty(worker_args)
        println("  julia --project=. ParallelRunnerKit/runner.jl <script.jl> <args>")
    else
        println("  julia --project=. ParallelRunnerKit/runner.jl \\")
        println("    $(rstrip(worker_args)) \\")
        println("    <script.jl> <args>")
    end
    println("=" ^ 60)
end

main()
