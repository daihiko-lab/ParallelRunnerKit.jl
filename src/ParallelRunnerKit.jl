"""
ParallelRunnerKit — shared utilities for `runner.jl`, `setup.jl`, and `suggest_workers.jl`
(paths, logging, SSH/git, remote resource probes, runner CLI parsing and help text,
worker memory checks, git parity across hosts).

Scripts load this module via a relative `include` and then `using .ParallelRunnerKit`.
When vendored as a registered package, replace with `using ParallelRunnerKit`.
"""
module ParallelRunnerKit

using Dates

export short_path, display_path, project_package_name, resolve_pkg_project_dir
export parallel_runner_kit_version, PARALLEL_RUNNER_KIT_VERSION
export OUTPUT_WIDTH, LOG_FILE_HANDLE
export write_both, writeln_both, init_log_file, close_log_file
export TeeIO
export print_separator, print_header
export use_colors
export print_ok, print_err, print_info, print_warn
export ok, fail, warn
export SSH_OPTS, build_ssh_opts, detect_julia_path
export get_local_git_hash, get_remote_git_hash
export get_remote_total_gb, get_remote_nproc, get_local_resources
export parse_runner_args, runner_help_text, check_memory_capacity, check_git_hashes
export remote_path_for_ssh_collect
export collect_tree_remote_files_ssh
export distributed_collect_root_dirs

# =============================================================================
# Path Helpers
# =============================================================================

"""Shorten absolute paths by replacing the home directory prefix with `~`."""
short_path(path::String) = let home = expanduser("~")
    startswith(path, home) ? "~" * path[length(home)+1:end] : path
end

"""
Paths under `anchor` → `relpath` from `anchor` (POSIX-style separators in the result).
Otherwise fall back to `short_path` (home as `~`).
"""
function display_path(path::AbstractString, anchor::AbstractString)::String
    ap = try
        abspath(expanduser(String(path)))
    catch
        return short_path(String(path))
    end
    an = try
        abspath(expanduser(String(anchor)))
    catch
        return short_path(String(path))
    end
    ap == an && return "."
    sep = Sys.iswindows() ? '\\' : '/'
    prefix = endswith(an, string(sep)) ? String(an) : an * sep
    if startswith(ap, prefix)
        return String(relpath(ap, an))
    end
    return short_path(String(path))
end

"""Read `name = "..."` from `proj_dir/Project.toml`; return `nothing` if missing or unreadable."""
function project_package_name(proj_dir::AbstractString)::Union{Nothing,String}
    path = joinpath(proj_dir, "Project.toml")
    isfile(path) || return nothing
    try
        m = match(r"name\s*=\s*\"([^\"]+)\"", read(path, String))
        return m === nothing ? nothing : String(m.captures[1])
    catch
        return nothing
    end
end

"""
Walk upward from `start_dir` to find the directory that should be passed to
`Pkg.activate` on workers.

If the first `Project.toml` found is the **vendored stub** (its `name` is
`ParallelRunnerKit`, matching this kit’s own `Project.toml`) and the parent
directory also has a `Project.toml`, skip it and keep walking so scripts
co-located with the kit inherit the application project root (regardless of
the kit folder’s basename).
"""
function resolve_pkg_project_dir(start_dir::AbstractString)::String
    test_dir = abspath(String(start_dir))
    fallback = dirname(test_dir)
    for _ in 1:24
        pt = joinpath(test_dir, "Project.toml")
        if isfile(pt)
            parent = dirname(test_dir)
            stub = project_package_name(test_dir)
            skip_stub = stub == "ParallelRunnerKit" && isfile(joinpath(parent, "Project.toml"))
            skip_stub || return test_dir
        end
        parent = dirname(test_dir)
        parent == test_dir && return fallback
        test_dir = parent
    end
    return fallback
end

"""Read `version = "x.y.z"` from `path` (`Project.toml`); return `nothing` if missing or invalid."""
function _project_toml_version(path::AbstractString)::Union{Nothing,VersionNumber}
    p = String(path)
    isfile(p) || return nothing
    try
        m = match(r"version\s*=\s*\"([^\"]+)\"", read(p, String))
        m === nothing && return nothing
        return VersionNumber(String(m.captures[1]))
    catch
        return nothing
    end
end

const _PARALLEL_RUNNER_KIT_PROJECT_TOML = joinpath(@__DIR__, "..", "Project.toml")

"""Semantic version of this vendored kit (from `ParallelRunnerKit/Project.toml`)."""
const PARALLEL_RUNNER_KIT_VERSION = something(
    _project_toml_version(_PARALLEL_RUNNER_KIT_PROJECT_TOML),
    v"0.0.0",
)

parallel_runner_kit_version()::VersionNumber = PARALLEL_RUNNER_KIT_VERSION

# =============================================================================
# Output Formatting
# =============================================================================

const OUTPUT_WIDTH = 60

# -----------------------------------------------------------------------------
# Log File
# -----------------------------------------------------------------------------

const LOG_FILE_HANDLE = Ref{Union{IO,Nothing}}(nothing)

function write_both(msg::String; color::Symbol=:normal, bold::Bool=false)
    if color == :normal && !bold
        print(msg)
    else
        printstyled(msg; color=color, bold=bold)
    end
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], msg)
        flush(LOG_FILE_HANDLE[])
    end
end

function writeln_both(msg::String=""; color::Symbol=:normal, bold::Bool=false)
    if color == :normal && !bold
        println(msg)
    else
        printstyled(msg * "\n"; color=color, bold=bold)
    end
    if LOG_FILE_HANDLE[] !== nothing
        println(LOG_FILE_HANDLE[], msg)
        flush(LOG_FILE_HANDLE[])
    end
end

function init_log_file(output_dir::String; prefix::String="runner", path_anchor::Union{Nothing,String}=nothing)
    isdir(output_dir) || mkpath(output_dir)
    timestamp = Dates.format(now(), dateformat"yyyy-mm-ddTHHMMSS")
    log_file = joinpath(output_dir, "$(prefix)_$(timestamp).log")
    LOG_FILE_HANDLE[] = open(log_file, "w")
    log_disp = path_anchor === nothing ? short_path(log_file) : display_path(log_file, path_anchor)
    writeln_both("Log file: $(log_disp)")
    return log_file
end

function close_log_file()
    if LOG_FILE_HANDLE[] !== nothing
        flush(LOG_FILE_HANDLE[])
        close(LOG_FILE_HANDLE[])
        LOG_FILE_HANDLE[] = nothing
    end
end

"""IO that writes to both primary (e.g. stdout) and secondary (e.g. log file).
For secondary: line-buffered — only complete lines are written. Progress bar
updates (\\r overwrites) are not written to log, avoiding bloat."""
mutable struct TeeIO <: IO
    primary::IO
    secondary::Union{IO,Nothing}
    linebuf::Vector{UInt8}
end

TeeIO(primary::IO, secondary::Union{IO,Nothing}) = TeeIO(primary, secondary, UInt8[])

function Base.write(io::TeeIO, b::UInt8)
    write(io.primary, b)
    if io.secondary !== nothing
        if b == 0x0d          # \r — discard (progress-bar overwrite)
            empty!(io.linebuf)
        elseif b == 0x0a      # \n — flush complete line to log
            write(io.secondary, io.linebuf)
            write(io.secondary, b)
            flush(io.secondary)
            empty!(io.linebuf)
        else
            push!(io.linebuf, b)
        end
    end
    return 1
end

function Base.write(io::TeeIO, b::AbstractVector{UInt8})
    write(io.primary, b)
    if io.secondary !== nothing
        for x in b
            if x == 0x0d
                empty!(io.linebuf)
            elseif x == 0x0a
                write(io.secondary, io.linebuf)
                write(io.secondary, x)
                flush(io.secondary)
                empty!(io.linebuf)
            else
                push!(io.linebuf, x)
            end
        end
    end
    return length(b)
end

function Base.flush(io::TeeIO)
    flush(io.primary)
    if io.secondary !== nothing && !isempty(io.linebuf)
        write(io.secondary, io.linebuf)
        flush(io.secondary)
    end
    nothing
end

print_separator(; width::Int=OUTPUT_WIDTH) = writeln_both("="^width)
print_header(title::String) = (print_separator(); writeln_both(title); print_separator())

# -----------------------------------------------------------------------------
# Colored Output (disabled when NO_COLOR is set or stdout is not a TTY)
# -----------------------------------------------------------------------------

"""Whether to use ANSI colors (false when NO_COLOR is set or output is piped)."""
use_colors() = !haskey(ENV, "NO_COLOR") && stdout isa Base.TTY

function _print_colored(io, msg, color, bold=false)
    use_colors() ? printstyled(io, msg; color=color, bold=bold) : print(io, msg)
end

function print_ok(msg; io=stdout, bold=false)
    _print_colored(io, msg, :green, bold)
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], msg); flush(LOG_FILE_HANDLE[])
    end
end

function print_err(msg; io=stdout, bold=false)
    _print_colored(io, msg, :red, bold)
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], msg); flush(LOG_FILE_HANDLE[])
    end
end

function print_info(msg; io=stdout, bold=false)
    _print_colored(io, msg, :cyan, bold)
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], msg); flush(LOG_FILE_HANDLE[])
    end
end

function print_warn(msg; io=stdout, bold=false)
    _print_colored(io, msg, :yellow, bold)
    if LOG_FILE_HANDLE[] !== nothing
        print(LOG_FILE_HANDLE[], msg); flush(LOG_FILE_HANDLE[])
    end
end

"""Setup-style: indent + symbol + message (used by setup.jl)."""
ok(msg)   = (write_both("  "); print_ok("✓ $msg");  writeln_both(""))
fail(msg) = (write_both("  "); print_err("✗ $msg"); writeln_both(""))
warn(msg) = (write_both("  "); print_warn("! $msg"); writeln_both(""))

# =============================================================================
# SSH Configuration
# =============================================================================

"""Build SSH options for non-interactive connections."""
function build_ssh_opts()
    custom = strip(get(ENV, "DISTRIBUTED_SSH_OPTS", ""))
    if isempty(custom)
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=60",
            "-o", "ServerAliveCountMax=10",
            "-o", "TCPKeepAlive=yes",
        ]
    end
    return split(custom)
end

const SSH_OPTS = build_ssh_opts()

"""Detect Julia path on remote host via SSH."""
function detect_julia_path(host::String)
    common_paths = [
        "/opt/homebrew/bin/julia",
        "/usr/local/bin/julia",
        raw"$HOME/.juliaup/bin/julia",
        "/usr/bin/julia",
    ]
    for path in common_paths
        try
            result = read(Cmd(["ssh", SSH_OPTS..., host, "test -x $path && echo $path"]), String)
            found = strip(result)
            isempty(found) || return String(found)
        catch
            continue
        end
    end
    try
        result = read(Cmd(["ssh", SSH_OPTS..., host, "which julia"]), String)
        p = strip(result)
        return isempty(p) ? nothing : String(p)
    catch
        return nothing
    end
end

# =============================================================================
# Git Utilities
# =============================================================================

"""Get local git commit hash (`short=nothing` → full hash, else `git rev-parse --short`)."""
function get_local_git_hash(proj_dir::AbstractString; short::Union{Nothing,Int}=nothing)::Union{Nothing,String}
    resolved = abspath(expanduser(String(proj_dir)))
    try
        cmd = if short === nothing
            Cmd(["git", "-C", resolved, "rev-parse", "HEAD"])
        else
            Cmd(["git", "-C", resolved, "rev-parse", "--short=$(short)", "HEAD"])
        end
        s = strip(read(pipeline(cmd; stderr=devnull), String))
        return isempty(s) ? nothing : s
    catch
        return nothing
    end
end

"""
Get remote git commit hash via SSH.

`remote_repo_dir` starting with `~` uses `cd DIR && git rev-parse …` (shell expands `~`);
otherwise uses `git -C DIR rev-parse …` (absolute path on the remote, same layout as local).
"""
function get_remote_git_hash(host::String, remote_repo_dir::AbstractString; short::Union{Nothing,Int}=nothing)::Union{Nothing,String}
    try
        dir = strip(String(remote_repo_dir))
        rev = short === nothing ? "HEAD" : "--short=$(short) HEAD"
        inner = if startswith(dir, "~")
            "cd $(dir) && git rev-parse $(rev)"
        else
            "git -C $(dir) rev-parse $(rev)"
        end
        s = strip(read(pipeline(Cmd(["ssh", SSH_OPTS..., host, inner]); stderr=devnull), String))
        return isempty(s) ? nothing : s
    catch
        return nothing
    end
end

# =============================================================================
# Remote Resource Detection
# =============================================================================

"""Get total memory (GB) for a remote host via SSH."""
function get_remote_total_gb(host::String)
    try
        s = strip(read(pipeline(Cmd(["ssh", SSH_OPTS..., host,
            "sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/{print \$2*1024}' /proc/meminfo 2>/dev/null"]),
            stderr=devnull), String))
        isempty(s) && return nothing
        return parse(Float64, s) / 1024^3
    catch end
    return nothing
end

"""Get CPU core count for a remote host via SSH."""
function get_remote_nproc(host::String)
    try
        s = strip(read(pipeline(Cmd(["ssh", SSH_OPTS..., host,
            "sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null"]), stderr=devnull), String))
        isempty(s) && return nothing
        return parse(Int, s)
    catch end
    return nothing
end

"""Get total memory (GB) and CPU cores for localhost."""
function get_local_resources()
    total_gb = Sys.total_memory() / 1024^3
    nproc = try
        s = strip(read(pipeline(`sysctl -n hw.ncpu`, stderr=devnull), String))
        isempty(s) ? Sys.CPU_THREADS : parse(Int, s)
    catch
        Sys.CPU_THREADS
    end
    return (total_gb=total_gb, nproc=nproc)
end

# =============================================================================
# Runner: worker memory checks, git parity, CLI (runner.jl)
# =============================================================================

const WORKER_MEMORY_GB_FALLBACK = 1.5

function estimate_worker_memory_gb()
    try
        rss_bytes = Sys.maxrss()
        if rss_bytes > 0
            return max(rss_bytes / 1024^3 * 1.2, 0.5)
        end
    catch
    end
    return WORKER_MEMORY_GB_FALLBACK
end

function estimate_available_gb()
    total = Sys.total_memory() / 1024^3
    free = Sys.free_memory() / 1024^3
    return (total, max(free, total * 0.5))
end

function check_memory_capacity(local_workers::Int, hosts::Vector{Tuple{String,Union{Int,Nothing}}}, default_workers::Union{Int,Nothing})
    per_worker = estimate_worker_memory_gb()
    r(x) = round(x, digits=1)
    writeln_both("Checking memory capacity...")
    writeln_both("  Per-worker estimate: $(round(per_worker, digits=2))GB")
    warnings = String[]

    function check_host(label::String, n_workers::Int, total_gb)
        if total_gb === nothing
            writeln_both("  $label: (memory check failed)")
            return
        end
        avail = total_gb * 0.7
        estimated = n_workers * per_worker
        max_w = max(1, floor(Int, avail / per_worker))
        if estimated > avail
            push!(warnings, "  $label: $(n_workers) × $(r(per_worker))GB = $(r(estimated))GB > $(r(avail))GB (70% of $(r(total_gb))GB)")
            write_both("  $label: $(r(total_gb))GB, $(n_workers) workers → ")
            print_warn("⚠ (max ~$(max_w))")
            writeln_both("")
        else
            write_both("  $label: $(r(total_gb))GB, $(n_workers) workers → ")
            print_ok("✓")
            writeln_both("")
        end
    end

    if local_workers > 0
        total, _ = estimate_available_gb()
        check_host("localhost", local_workers + 1, total)
    end

    host_totals = Dict{String,Int}()
    for (host_name, host_workers_spec) in hosts
        n = something(host_workers_spec, default_workers, 1)
        host_totals[host_name] = get(host_totals, host_name, 0) + n
    end

    for (host_name, host_workers) in host_totals
        check_host(host_name, host_workers, get_remote_total_gb(host_name))
    end
    writeln_both("")

    if !isempty(warnings)
        print_warn("WARNING: ", bold=true)
        writeln_both("Memory pressure detected!")
        writeln_both("")
        for w in warnings
            print_warn(w * "\n")
        end
        writeln_both("")
        writeln_both("Consider reducing worker count.")
        writeln_both("")
        write_both("Continue anyway? [y/N]: ")
        response = readline()
        if lowercase(strip(response)) != "y"
            writeln_both("Aborted.")
            exit(0)
        end
        writeln_both("")
    end
end

function check_git_hashes(hosts::Vector{String}, proj_dir::String)
    local_hash = get_local_git_hash(proj_dir)
    if local_hash === nothing
        write_both("  ")
        print_warn("⚠ Could not get local git hash (not a git repo?)")
        writeln_both("")
        return true, String[]
    end

    writeln_both("  Local: $(local_hash[1:8])...")

    mismatches = String[]
    for host in hosts
        remote_hash = get_remote_git_hash(host, proj_dir)
        if remote_hash === nothing
            write_both("  $host: ")
            print_warn("⚠ Could not get git hash")
            writeln_both("")
        elseif remote_hash != local_hash
            write_both("  $host: ")
            print_err("✗ $(remote_hash[1:8])... (MISMATCH)")
            writeln_both("")
            push!(mismatches, host)
        else
            write_both("  $host: ")
            print_ok("✓ $(remote_hash[1:8])...")
            writeln_both("")
        end
    end

    return isempty(mismatches), mismatches
end

function _parse_host_workers_spec(spec::String)
    if contains(spec, ':')
        parts = split(spec, ':', limit=2)
        host = String(parts[1])
        workers = parse(Int, parts[2])
        return (host, workers)
    else
        return (spec, nothing)
    end
end

"""
List all files under `remote_root` on `host` recursively via SSH `find`, returning
`(remote_abs_path, relative_path)` pairs (relative to `remote_root`).
"""
function collect_tree_remote_files_ssh(host::AbstractString, remote_root::AbstractString)::Vector{Tuple{String,String}}
    hp  = String(host)
    rr  = String(remote_root)
    out = try
        read(
            pipeline(
                Cmd(["ssh", SSH_OPTS..., hp, "find", rr, "-type", "f", "-print"]);
                stderr=devnull,
            ),
            String,
        )
    catch
        return Tuple{String,String}[]
    end
    sep = endswith(rr, '/') ? rr : rr * '/'
    pairs = Tuple{String,String}[]
    for line in split(out, '\n')
        p = String(strip(line))
        isempty(p) && continue
        rel = startswith(p, sep) ? p[length(sep)+1:end] : String(relpath(p, rr))
        isempty(rel) && continue
        push!(pairs, (p, rel))
    end
    return pairs
end

"""Map remote absolute path under `remote_repo` to the same repo-relative path under `local_repo`."""
function local_dir_from_remote_mirror(
    remote_abs::AbstractString,
    remote_repo::AbstractString,
    local_repo::AbstractString,
)::String
    ra = String(abspath(remote_abs))
    rr = String(abspath(remote_repo))
    lr = String(abspath(local_repo))
    rel = String(relpath(ra, rr))
    startswith(rel, "..") &&
        throw(ArgumentError("remote path $(repr(ra)) is not under remote repo $(repr(rr))"))
    return String(abspath(joinpath(lr, rel)))
end

"""
Absolute path to use on SSH worker hosts for `find` / rsync source / sentinel.

When `DISTRIBUTED_REMOTE_PROJECT_ROOT` is unset, returns `local_abs_dir` (legacy: identical paths everywhere).

When set, `local_application_repo_root` must prefix `local_abs_dir`; the suffix is appended under the remote root.
Paths must lie under the application repo root on this machine (otherwise falls back to `local_abs_dir`).
"""
function remote_path_for_ssh_collect(
    local_abs_dir::AbstractString,
    local_application_repo_root::AbstractString,
)::String
    ld = String(abspath(expanduser(String(local_abs_dir))))
    root = String(abspath(expanduser(String(local_application_repo_root))))
    alt = strip(get(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT", ""))
    if isempty(alt)
        return ld
    end
    rroot = String(abspath(expanduser(alt)))
    if ld == root
        return rroot
    end
    rootpfx = endswith(root, '/') ? root : root * '/'
    if startswith(ld, rootpfx)
        rel = String(relpath(ld, root))
        isempty(rel) && return rroot
        rel == "." && return rroot
        return String(abspath(joinpath(rroot, rel)))
    end
    return ld
end

"""
Local absolute directories used for per-run sentinel placement and post-run rsync from SSH workers.

If `ENV["DISTRIBUTED_COLLECT_DIRS"]` is non-empty: colon-separated list (same convention as POSIX `PATH`).
Each token is `abspath(expanduser(token))` when absolute, otherwise `abspath(joinpath(project_root, token))`.
Empty tokens are skipped; duplicates removed (first occurrence order preserved).

If unset or blank after trimming: a single root from `DISTRIBUTED_OUTPUT_DIR`, or `joinpath(script_dir, "..", "results")` when that env is unset.

Scripts should set `DISTRIBUTED_COLLECT_DIRS` to every tree that may receive new files on workers during the run
(e.g. sweep output plus figures). Logs may stay under `DISTRIBUTED_OUTPUT_DIR` only; omit that path here if logs
should not be rsync'd.
"""
function distributed_collect_root_dirs(
    script_dir::AbstractString,
    project_root::AbstractString,
)::Vector{String}
    spec = String(strip(get(ENV, "DISTRIBUTED_COLLECT_DIRS", "")))
    repo = String(abspath(expanduser(String(project_root))))
    if !isempty(spec)
        out = String[]
        for chunk in split(spec, ':')
            p = String(strip(String(chunk)))
            isempty(p) && continue
            pe = String(expanduser(p))
            ap = String(abspath(isabspath(pe) ? pe : joinpath(repo, pe)))
            push!(out, ap)
        end
        seen = Set{String}()
        uniq = String[]
        for p in out
            p in seen && continue
            push!(seen, p)
            push!(uniq, p)
        end
        if !isempty(uniq)
            return uniq
        end
    end
    rd = get(ENV, "DISTRIBUTED_OUTPUT_DIR", nothing)
    rd = rd === nothing ? normpath(joinpath(String(script_dir), "..", "results")) : String(rd)
    return String[String(abspath(expanduser(rd)))]
end

function parse_runner_args(args::Vector{String})
    local_workers = 0
    default_workers = nothing
    julia_exe = nothing
    skip_hash_check = false
    enable_log = true
    log_dir = nothing
    explicit_package = nothing
    hosts = Tuple{String,Union{Int,Nothing}}[]
    script_path = nothing
    script_args = String[]

    i = 1
    while i <= length(args)
        arg = args[i]

        if (arg == "--local" || arg == "-l") && i < length(args)
            local_workers = parse(Int, args[i+1])
            i += 2
        elseif (arg == "--workers" || arg == "-w") && i < length(args)
            default_workers = parse(Int, args[i+1])
            i += 2
        elseif arg == "--julia" && i < length(args)
            julia_exe = args[i+1]
            i += 2
        elseif arg == "--skip-hash-check" || arg == "--no-hash-check"
            skip_hash_check = true
            i += 1
        elseif arg == "--no-log"
            enable_log = false
            i += 1
        elseif arg == "--log-dir" && i < length(args)
            log_dir = args[i+1]
            i += 2
        elseif arg == "--package" && i < length(args)
            p = String(strip(args[i+1]))
            explicit_package = isempty(p) ? nothing : p
            i += 2
        elseif arg == "--collect" || arg == "--collect-sync"
            throw(ArgumentError(
                "$(arg) was removed; use --collect-missing ROOT HOST... or --collect-overwrite ROOT HOST...",
            ))
        elseif arg == "--collect-missing" ||
                arg == "--collect-overwrite" ||
                arg == "--collect-tree" ||
                arg == "--collect-tree-sync"
            flag = arg
            merge = flag == "--collect-overwrite" || flag == "--collect-tree-sync"
            !isempty(hosts) &&
                throw(ArgumentError(
                    "host specs before $(flag) are not supported; use $(flag) ROOT HOST..."))
            tail = args[i+1:end]
            isempty(tail) && throw(ArgumentError("`$(flag)` requires ROOT HOST [HOST...]"))
            for a in tail
                if startswith(a, '-') && length(a) > 1
                    throw(ArgumentError(
                        "`$(flag)` arguments cannot include options like $(repr(a)); put flags before $(flag)"))
                end
            end
            tree_root = String(abspath(expanduser(String(tail[1]))))
            tree_hosts = String[_parse_host_workers_spec(String(x))[1] for x in tail[2:end]]
            isempty(tree_hosts) && throw(ArgumentError("`$(flag)` requires at least one HOST after ROOT"))
            if julia_exe === nothing
                env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
                julia_exe = env_val == "auto" ? nothing : env_val
            elseif julia_exe == "auto"
                julia_exe = nothing
            end
            return (
                local_workers=local_workers,
                default_workers=default_workers,
                julia=julia_exe,
                skip_hash_check=skip_hash_check,
                enable_log=enable_log,
                log_dir=log_dir,
                explicit_package=explicit_package,
                hosts=Tuple{String,Union{Int,Nothing}}[],
                script_path=nothing,
                script_args=String[],
                collect_root=tree_root,
                collect_hosts=tree_hosts,
                collect_overwrite=merge,
                help=false,
            )
        elseif arg == "--help" || arg == "-h"
            return (
                local_workers=0,
                default_workers=nothing,
                julia=nothing,
                skip_hash_check=false,
                enable_log=true,
                log_dir=nothing,
                explicit_package=nothing,
                hosts=Tuple{String,Union{Int,Nothing}}[],
                script_path=nothing,
                script_args=String[],
                collect_root=nothing,
                collect_hosts=nothing,
                collect_overwrite=nothing,
                help=true,
            )
        elseif endswith(arg, ".jl")
            script_path = arg
            script_args = args[i+1:end]
            break
        else
            push!(hosts, _parse_host_workers_spec(arg))
            i += 1
        end
    end

    if julia_exe === nothing
        env_val = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")
        julia_exe = env_val == "auto" ? nothing : env_val
    elseif julia_exe == "auto"
        julia_exe = nothing
    end

    return (
        local_workers=local_workers,
        default_workers=default_workers,
        julia=julia_exe,
        skip_hash_check=skip_hash_check,
        enable_log=enable_log,
        log_dir=log_dir,
        explicit_package=explicit_package,
        hosts=hosts,
        script_path=script_path,
        script_args=script_args,
        collect_root=nothing,
        collect_hosts=nothing,
        collect_overwrite=nothing,
        help=false,
    )
end

function runner_help_text()::String
    """
Usage:
  julia --project=. ParallelRunnerKit/runner.jl [options] [hosts...] script.jl [script_args...]

Collect-only (no script):
  julia --project=. ParallelRunnerKit/runner.jl --collect-missing ROOT HOST [HOST...]
  julia --project=. ParallelRunnerKit/runner.jl --collect-overwrite ROOT HOST [HOST...]
  (aliases: --collect-tree == --collect-missing; --collect-tree-sync == --collect-overwrite)

Options:
  -l, --local N       Number of local worker processes (default: 0)
  -w, --workers N     Default workers for remote hosts without explicit count
  --julia PATH        Julia path for remote hosts (default: auto = detect common paths)
  --skip-hash-check   Skip git hash verification between local and remote hosts
  --no-log            Do not write console output to a log file
  --log-dir PATH      Log output directory (default: script's output dir, or <script_dir>/results)
  --package NAME      `using NAME` on workers (overrides package name from Project.toml)
  --collect-missing ROOT HOST...
                      files under ROOT missing locally only (by relative path)
  --collect-overwrite ROOT HOST...
                      rsync-merge entire tree under ROOT (same-named local files replaced from remote)
  --collect-tree / --collect-tree-sync  aliases for the two flags above (older names)
  -h, --help          Show this help

Arguments:
  hosts...        Remote hosts: "host" or "host:workers" (e.g., host1:10)
  script.jl       Julia script to run (required)
  script_args...  Arguments passed to the script

Worker counts:
  - Local: --local N (default: 0, master only)
  - Remote: host:N if specified, else --workers value, else 1

Examples:
  # Local + remote (9 local + 10 + 8 remote = 27 worker processes)
  julia --project=. ParallelRunnerKit/runner.jl --local 9 host1:10 host2:8 myscript.jl

  # Default workers for all remote hosts
  julia --project=. ParallelRunnerKit/runner.jl --local 9 --workers 10 host1 host2 myscript.jl

  # Local only (9 worker processes)
  julia --project=. ParallelRunnerKit/runner.jl --local 9 myscript.jl

  # Remote only (master on local, workers on remotes)
  julia --project=. ParallelRunnerKit/runner.jl host1:10 myscript.jl

  # Pull any file under data/sweep that exists on hosts but not locally (recursive; sweep scripts write here):
  julia --project=. ParallelRunnerKit/runner.jl --collect-missing data/sweep host1 host2

Note:
  This uses Distributed.jl (multi-process parallelism).
  Each worker is a separate Julia process with its own memory.
  For multi-threading within a single process, run your script directly with -t N.

Environment:
  JULIA_DISTRIBUTED_EXE           Default Julia path for remote hosts
  DISTRIBUTED_OUTPUT_DIR          Output dir set by distributed scripts (runner log default + legacy single-tree rsync)
  DISTRIBUTED_COLLECT_DIRS        Colon-separated local abs or repo-relative dirs to rsync after runs (overrides single-tree default)
  DISTRIBUTED_REMOTE_PROJECT_ROOT If workers clone the repo elsewhere: absolute path to repo root **on SSH hosts**

Prerequisites:
  - SSH key authentication to remote hosts
  - Same project layout relative to repo root on workers (or set DISTRIBUTED_REMOTE_PROJECT_ROOT)
  - Same git commit on all machines (checked automatically, use --skip-hash-check to override)
"""
end

end # module ParallelRunnerKit
