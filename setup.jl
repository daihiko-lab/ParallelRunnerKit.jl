#!/usr/bin/env julia
"""
Clone, check prerequisites, and sync code to remote hosts for distributed execution.

Usage:
  julia --project=. ParallelRunnerKit/setup.jl                    # Show requirements
  julia --project=. ParallelRunnerKit/setup.jl --clone hosts...   # Clone repository
  julia --project=. ParallelRunnerKit/setup.jl --delete hosts...  # Delete remote repositories
  julia --project=. ParallelRunnerKit/setup.jl --check hosts...   # Check prerequisites
  julia --project=. ParallelRunnerKit/setup.jl --pull hosts...    # Pull on all hosts
  julia --project=. ParallelRunnerKit/setup.jl --sync hosts...    # Push + pull
"""

include(joinpath(@__DIR__, "src", "ParallelRunnerKit.jl"))
using .ParallelRunnerKit

const PROJECT_ROOT = get(ENV, "DISTRIBUTED_PROJECT_ROOT", dirname(@__DIR__))
# Relative path from home for remote hosts
const PROJECT_NAME = basename(PROJECT_ROOT)
const PROJECT_PARENT = basename(dirname(PROJECT_ROOT))  # e.g., "GitHub"
const REMOTE_HOME_PATH = joinpath("~", PROJECT_PARENT, PROJECT_NAME)

const _PATH_ANCHOR = abspath(expanduser(String(PROJECT_ROOT)))

"""Short label for the local project root in console output (same idea as `runner.jl`)."""
function _local_project_disp()::String
    s = display_path(String(PROJECT_ROOT), _PATH_ANCHOR)
    return s == "." ? basename(abspath(String(PROJECT_ROOT))) : s
end

function show_requirements()
    print_ok("Distributed Execution Setup")
    println()
    println()
    print_warn("Prerequisites")
    println()
    println("  1. SSH key auth to all remote hosts (ssh-copy-id user@host)")
    println("  2. GitHub SSH access from all remote hosts (ssh -T git@github.com)")
    println("  3. Julia installed on all hosts (auto-detected, or --julia PATH)")
    println()
    print_warn("Initial Setup (example with 3 hosts)")
    println()
    println("  julia --project=. ParallelRunnerKit/setup.jl \\")
    println("    --clone host1 host2 host3")
    println("  julia --project=. ParallelRunnerKit/setup.jl \\")
    println("    --instantiate host1 host2 host3")
    println("  julia --project=. ParallelRunnerKit/setup.jl \\")
    println("    --check host1 host2 host3")
    println()
    print_warn("Daily Use")
    println()
    println("  julia --project=. ParallelRunnerKit/setup.jl \\")
    println("    --sync host1 host2 host3")
    println("  julia --project=. ParallelRunnerKit/runner.jl \\")
    println("    --local 8 host1:8 host2:8 host3:8 script.jl")
end

function check_ssh(host::String)
    try
        result = read(Cmd(["ssh", SSH_OPTS..., host, "echo ok"]), String)
        return strip(result) == "ok"
    catch
        return false
    end
end

function check_julia(host::String, julia_path::String)
    try
        result = read(Cmd(["ssh", SSH_OPTS..., host, julia_path, "--version"]), String)
        return contains(result, "julia version")
    catch
        return false
    end
end

function check_project(host::String)
    try
        result = read(pipeline(Cmd(["ssh", SSH_OPTS..., host, "test -f $(REMOTE_HOME_PATH)/Project.toml && echo ok"]), stderr=devnull), String)
        return strip(result) == "ok"
    catch
        return false
    end
end

function check_git_clean()
    try
        result = read(`git -C $PROJECT_ROOT status --porcelain`, String)
        return isempty(strip(result))
    catch
        return false
    end
end

function git_push()
    try
        run(pipeline(`git -C $PROJECT_ROOT push`, stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function git_pull(host::String)
    # Run command directly via ssh (shell expands ~)
    cmd = "cd $(REMOTE_HOME_PATH) && git pull"
    try
        run(pipeline(Cmd(["ssh", SSH_OPTS..., host, cmd]), stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function get_git_remote_url()
    try
        return strip(read(`git -C $PROJECT_ROOT remote get-url origin`, String))
    catch
        return "<repo_url>"
    end
end

function check_prerequisites(hosts::Vector{String}, julia_path::String; require_clean_git::Bool=false, check_code_sync::Bool=true)
    println("Checking prerequisites...")
    println()
    
    all_ok = true
    needs_sync = false
    project_path = REMOTE_HOME_PATH
    
    # Local checks
    println("Local:")
    if check_git_clean()
        ok("Git working tree clean")
    else
        if require_clean_git
            fail("Git has uncommitted changes")
            println("    Fix: git add -A && git commit -m 'your message'")
            all_ok = false
        else
            warn("Git has uncommitted changes")
            println("    Fix: git add -A && git commit -m 'your message'")
        end
    end
    
    if isfile(joinpath(PROJECT_ROOT, "Project.toml"))
        ok("Project.toml at $(_local_project_disp())")
    else
        fail("Project.toml not found")
        all_ok = false
    end
    
    # Get local git commit hash
    local_hash = get_local_git_hash(String(PROJECT_ROOT); short=12)
    if local_hash === nothing
        fail("Could not get local git commit")
        all_ok = false
    else
        ok("Git commit: $local_hash")
    end
    println()
    
    # Remote checks
    for host in hosts
        println("$host:")
        
        if check_ssh(host)
            ok("SSH connection")
        else
            fail("SSH connection failed")
            println("    Fix: ssh-copy-id $host")
            all_ok = false
            println()
            continue
        end
        
        # Resolve Julia path per host
        host_julia = julia_path
        if host_julia == "auto"
            host_julia = detect_julia_path(host)
        end
        
        if host_julia !== nothing && check_julia(host, String(host_julia))
            ok("Julia found at $host_julia")
        else
            fail("Julia not found (checked: $(host_julia === nothing ? "auto-detect" : host_julia))")
            println("    Fix: Install Julia or use --julia PATH or set JULIA_DISTRIBUTED_EXE")
            all_ok = false
        end
        
        if check_project(host)
            ok("Project found at $project_path")
        else
            fail("Project not found at $project_path")
            println("    Fix: --clone $host")
            all_ok = false
            println()
            continue
        end
        
        # Check git commit matches
        remote_hash = get_remote_git_hash(host, REMOTE_HOME_PATH; short=12)
        if remote_hash === nothing
            warn("Could not get remote git commit")
            needs_sync = true
        elseif local_hash !== nothing && remote_hash == local_hash
            ok("Git commit matches ($remote_hash)")
        else
            needs_sync = true
            if check_code_sync
                fail("Git commit differs (local: $local_hash, remote: $remote_hash)")
                println("    Fix: --pull or --sync to update remote")
                all_ok = false
            else
                warn("Git commit differs (local: $local_hash, remote: $remote_hash)")
                println("    Will be synced by this operation")
            end
        end
        
        println()
    end
    
    return (ok=all_ok, needs_sync=needs_sync)
end

function git_pull_local()
    try
        run(pipeline(`git -C $PROJECT_ROOT pull`, stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function deploy(hosts::Vector{String}; do_push::Bool=true, do_pull::Bool=true, do_local_pull::Bool=false)
    if do_local_pull
        print("  localhost git pull: ")
        if git_pull_local()
            print_ok("✓")
            println()
        else
            print_err("✗")
            println()
            return false
        end
    end

    if do_push
        print("  git push: ")
        if git_push()
            print_ok("✓")
            println()
        else
            print_err("✗")
            println()
            println()
            repo_url = get_git_remote_url()
            print_warn("Push failed.")
            println()
            println()
            println("  Remote: $repo_url")
            println()
            println("  Not a team member?")
            println("    Use --pull instead (fork not needed for experiments)")
            println()
            println("  Team member?")
            println("    git pull --rebase && git push")
            return false
        end
    end
    
    if do_pull
        for host in hosts
            print("  $host git pull: ")
            if git_pull(host)
                print_ok("✓")
                println()
            else
                print_err("✗")
                println()
                return false
            end
        end
    end
    
    println()
    return true
end

function parse_args(args)
    mode = nothing
    do_push = true
    do_pull = true
    julia_path = get(ENV, "JULIA_DISTRIBUTED_EXE", "auto")  # default to env or auto-detect
    hosts = String[]
    show_help = false
    
    i = 1
    while i <= length(args)
        arg = args[i]
        
        if arg == "--check"
            mode = :check
            i += 1
        elseif arg == "--pull"
            mode = :pull
            i += 1
        elseif arg == "--sync"
            mode = :sync
            i += 1
        elseif arg == "--instantiate"
            mode = :instantiate
            i += 1
        elseif arg == "--cleanup"
            mode = :cleanup
            i += 1
        elseif arg == "--clone"
            mode = :clone
            i += 1
        elseif arg == "--delete"
            mode = :delete
            i += 1
        elseif arg == "--requirements"
            mode = :requirements
            i += 1
        elseif arg == "--julia" && i < length(args)
            julia_path = args[i+1]
            i += 2
        elseif arg in ["-h", "--help"]
            show_help = true
            i += 1
        else
            push!(hosts, arg)
            i += 1
        end
    end
    
    return (
        mode=mode,
        do_push=do_push,
        do_pull=do_pull,
        julia_path=julia_path,
        hosts=hosts,
        show_help=show_help
    )
end

function show_usage()
    println("""
Usage:
  julia --project=. ParallelRunnerKit/setup.jl
  julia --project=. ParallelRunnerKit/setup.jl --clone hosts...
  julia --project=. ParallelRunnerKit/setup.jl --check hosts...
  julia --project=. ParallelRunnerKit/setup.jl --pull hosts...
  julia --project=. ParallelRunnerKit/setup.jl --sync hosts...

Commands:
  (none)          Show requirements for distributed execution
  --clone         Clone repository on remote hosts
  --delete        Delete remote repositories
  --check         Check prerequisites on specified hosts
  --pull          Pull latest code on all hosts
  --sync          Push + pull (for development team)
  --instantiate   Run Pkg.instantiate on remote hosts
  --cleanup       Kill stale Julia worker processes on localhost + remote hosts

Options:
  --julia PATH    Julia path for remote hosts (default: \$JULIA_DISTRIBUTED_EXE or auto-detect)
  -h, --help      Show this help

Environment:
  JULIA_DISTRIBUTED_EXE    Default Julia path for remote hosts
  DISTRIBUTED_PROJECT_ROOT Local project root override (absolute path)
  DISTRIBUTED_SSH_OPTS     SSH options override (space-separated)

Arguments:
  hosts...        Remote hosts (user@host format)

Examples:
  julia --project=. ParallelRunnerKit/setup.jl
  julia --project=. ParallelRunnerKit/setup.jl --clone host1 host2
  julia --project=. ParallelRunnerKit/setup.jl --check host1 host2
  julia --project=. ParallelRunnerKit/setup.jl --pull host1 host2
  julia --project=. ParallelRunnerKit/setup.jl --instantiate host1 host2
  julia --project=. ParallelRunnerKit/setup.jl --cleanup host1 host2
""")
end

"""Get SSH-format clone URL from local git remote."""
function get_clone_url()
    origin_url = strip(read(`git -C $PROJECT_ROOT remote get-url origin`, String))
    # Convert HTTPS to SSH format if needed
    m = match(r"https://github\.com/(.+)", origin_url)
    if m !== nothing
        return "git@github.com:" * m.captures[1]
    end
    return origin_url
end

"""Delete remote repositories. Returns true if delete ran, false if cancelled."""
function delete_remotes(hosts::Vector{String})
    remote_path = REMOTE_HOME_PATH
    print("  ")
    print_err("This will DELETE repositories on all hosts.")
    println()
    println("  Remote path: $remote_path")
    println("  Hosts: $(join(hosts, ", "))")
    println()
    print("Type 'delete' to confirm: ")
    flush(stdout)
    answer = strip(readline())
    if answer != "delete"
        println("Cancelled.")
        return false
    end
    println()

    for host in hosts
        print("  $host: ")
        flush(stdout)
        try
            # Try rm -rf first; if path still exists (e.g. permission/lock), retry with chmod
            cmd = """
                rm -rf $remote_path 2>/dev/null
                if [ -e $remote_path ]; then
                  chmod -R u+rwX $remote_path 2>/dev/null
                  rm -rf $remote_path
                fi
            """
            read(Cmd(["ssh", SSH_OPTS..., host, cmd]), String)
            print_ok("✓")
            println()
        catch e
            print_err("✗")
            println()
            println("    $(sprint(showerror, e))")
        end
    end
    return true
end

"""Clone repository on remote hosts."""
function clone_to_remotes(hosts::Vector{String})
    clone_url = get_clone_url()
    remote_path = REMOTE_HOME_PATH
    println("  Repository: $clone_url")
    println("  Remote path: $remote_path")
    println("  Hosts: $(join(hosts, ", "))")
    println()
    print("Proceed? [y/N]: ")
    flush(stdout)
    answer = strip(readline())
    if lowercase(answer) != "y"
        println("Cancelled.")
        return
    end
    println()

    for host in hosts
        print("  $host: ")
        flush(stdout)
        try
            output = read(pipeline(Cmd(["ssh", SSH_OPTS..., host,
                "if [ -d $remote_path/.git ]; then echo EXISTS; else git clone $clone_url $remote_path 2>&1; fi"
            ]), stderr=devnull), String)
            if contains(output, "EXISTS")
                print_warn("already exists (skipped)")
                println()
            else
                print_ok("✓")
                println()
            end
        catch e
            print_err("✗")
            println()
            println("    $(sprint(showerror, e))")
        end
    end
end

"""Kill stale Julia worker processes on localhost and remote hosts."""
function cleanup_workers(hosts::Vector{String})
    # Local cleanup
    print("  localhost: ")
    try
        run(pipeline(Cmd(["pkill", "-9", "-f", "julia.*--worker"]), stdout=devnull, stderr=devnull))
    catch; end
    try
        run(pipeline(Cmd(["pkill", "-9", "-f", "julia.*--bind-to"]), stdout=devnull, stderr=devnull))
    catch; end
    print_ok("✓")
    println()

    # Remote cleanup (parallel)
    results = Dict{String,Bool}()
    @sync for host in hosts
        @async begin
            try
                cleanup_cmd = "pkill -9 -f 'julia.*worker' 2>/dev/null; pkill -9 -f 'julia.*--bind-to' 2>/dev/null; true"
                run(pipeline(Cmd(["ssh", SSH_OPTS..., host, cleanup_cmd]), stdout=devnull, stderr=devnull))
                results[host] = true
            catch
                results[host] = false
            end
        end
    end

    for host in hosts
        if get(results, host, false)
            ok("$host: done")
        else
            fail("$host: failed")
        end
    end
end

"""Run Pkg.instantiate on remote hosts (parallel)."""
function instantiate_remotes(hosts::Vector{String}, julia_path::String)
    project_path = REMOTE_HOME_PATH

    println("  Local project: $(_local_project_disp())")
    println("  Remote --project: $project_path")
    println()

    # Show all hosts as "instantiating..."
    for host in hosts
        println("  $host: instantiating...")
    end
    
    # Resolve Julia path per host and run in parallel
    results = Dict{String,Bool}()
    @sync for host in hosts
        @async begin
            host_julia = julia_path == "auto" ? detect_julia_path(host) : julia_path
            if host_julia === nothing
                results[host] = false
            else
                try
                    cmd = "$host_julia --project=$project_path -e 'using Pkg; Pkg.instantiate(io=devnull)'"
                    read(Cmd(["ssh", SSH_OPTS..., host, cmd]), String)
                    results[host] = true
                catch
                    results[host] = false
                end
            end
        end
    end
    
    # Show results
    for host in hosts
        if get(results, host, false)
            ok("$host: done")
        else
            fail("$host: failed")
        end
    end
end

function main()
    opts = parse_args(ARGS)
    
    if opts.show_help
        show_usage()
        return
    end
    
    if opts.mode === nothing || opts.mode == :requirements
        show_requirements()
        return
    end
    
    if isempty(opts.hosts)
        print_err("Error: ", bold=true)
        println("No hosts specified")
        println()
        show_usage()
        exit(1)
    end
    
    mode_name = Dict(:clone => "Clone", :delete => "Delete", :check => "Check Prerequisites", :pull => "Pull", :sync => "Sync", :instantiate => "Instantiate", :cleanup => "Cleanup Workers")[opts.mode]
    print_header(mode_name)
    println()
    
    # Handle delete mode
    if opts.mode == :delete
        if delete_remotes(opts.hosts)
            println()
            print_ok("Delete complete.")
            println()
        end
        return
    end

    # Handle clone mode
    if opts.mode == :clone
        clone_to_remotes(opts.hosts)
        println()
        print_ok("Clone complete.")
        println()
        return
    end

    # Handle instantiate mode separately
    if opts.mode == :instantiate
        instantiate_remotes(opts.hosts, opts.julia_path)
        println()
        print_ok("Instantiate complete.")
        println()
        return
    end
    
    # Handle cleanup mode separately
    if opts.mode == :cleanup
        cleanup_workers(opts.hosts)
        println()
        print_ok("Cleanup complete.")
        println()
        return
    end
    
    # Check prerequisites
    # For --pull and --sync: allow code mismatch (will be fixed by the operation)
    # For --check: require code sync
    require_clean = (opts.mode == :sync)
    check_code_sync = (opts.mode == :check)
    result = check_prerequisites(opts.hosts, opts.julia_path; require_clean_git=require_clean, check_code_sync=check_code_sync)
    
    if !result.ok
        print_err("Prerequisites not met. Fix issues above and retry.")
        println()
        exit(1)
    end
    
    if opts.mode == :check
        print_ok("All prerequisites met.")
        println()
        return
    end
    
    # Skip if already in sync
    if !result.needs_sync
        print_ok("Already up to date.")
        println()
        return
    end
    
    print_ok("Ready to proceed.")
    println()
    println()
    
    # Pull or Sync
    # --pull: pull on localhost first, then on remotes (so mini can self-update)
    # --sync: push from localhost, then pull on remotes (laptop-centric workflow)
    do_push       = (opts.mode == :sync)
    do_local_pull = (opts.mode == :pull)
    if !deploy(opts.hosts; do_push=do_push, do_pull=true, do_local_pull=do_local_pull)
        print_err("$mode_name failed.")
        println()
        exit(1)
    end
    
    print_ok("$mode_name complete.")
    println()
end

main()
