@testset "ParallelRunnerKit (path helpers)" begin
    include(joinpath(@__DIR__, "..", "src", "ParallelRunnerKit.jl"))
    using .ParallelRunnerKit

    mktempdir() do d
        @test project_package_name(d) === nothing
        write(joinpath(d, "Project.toml"), "name = \"FooBar\"\n")
        @test project_package_name(d) == "FooBar"
    end

    mktempdir() do root
        mkpath(joinpath(root, "kitstub"))
        write(joinpath(root, "Project.toml"), "name = \"App\"\n")
        write(joinpath(root, "kitstub", "Project.toml"), "name = \"ParallelRunnerKit\"\n")
        @test resolve_pkg_project_dir(joinpath(root, "kitstub")) == root
    end

    @test parallel_runner_kit_version() >= v"0.1.0"

    @test_throws ArgumentError ParallelRunnerKit.parse_runner_args(["--collect", "h"])
    @test_throws ArgumentError ParallelRunnerKit.parse_runner_args(["--collect-sync", "data/sweep", "host"])

    let r = ParallelRunnerKit.parse_runner_args(["--collect-missing", "data/sweep", "host-a", "host-b"])
        @test r.collect_root == abspath("data/sweep")
        @test r.collect_hosts == ["host-a", "host-b"]
        @test r.collect_overwrite == false
        @test r.script_path === nothing
    end

    let r = ParallelRunnerKit.parse_runner_args(["--collect-tree", "data/sweep", "host-a", "host-b"])
        @test r.collect_root == abspath("data/sweep")
        @test r.collect_hosts == ["host-a", "host-b"]
        @test r.collect_overwrite == false
    end

    let r = ParallelRunnerKit.parse_runner_args(["--collect-overwrite", "data/sweep", "host-a"])
        @test r.collect_root == abspath("data/sweep")
        @test r.collect_hosts == ["host-a"]
        @test r.collect_overwrite == true
    end

    let r = ParallelRunnerKit.parse_runner_args(["--collect-tree-sync", "data/sweep", "host-a"])
        @test r.collect_root == abspath("data/sweep")
        @test r.collect_hosts == ["host-a"]
        @test r.collect_overwrite == true
    end

    @test_throws ArgumentError ParallelRunnerKit.parse_runner_args(["--collect-missing", "data/sweep"])

    @test ParallelRunnerKit.local_dir_from_remote_mirror(
            "/Volumes/r/MyRepo/data/sweep/slug/20260101_120000",
            "/Volumes/r/MyRepo",
            "/Users/z/MyRepo",
        ) == joinpath("/Users/z/MyRepo", "data", "sweep", "slug", "20260101_120000") |> abspath

    @test ParallelRunnerKit.remote_path_for_ssh_collect(
            "/Users/z/MyRepo/data/out",
            "/Users/z/MyRepo",
        ) == "/Users/z/MyRepo/data/out"
    withenv("DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/Volumes/z/clone/MyRepo") do
        @test ParallelRunnerKit.remote_path_for_ssh_collect(
                "/Users/z/MyRepo/data/sweep/x/ts",
                "/Users/z/MyRepo",
            ) == joinpath("/Volumes/z/clone/MyRepo", "data", "sweep", "x", "ts") |> abspath
    end

    mktempdir() do d
        nested = joinpath(d, "a", "b.txt")
        mkpath(dirname(nested))
        write(nested, "")
        @test display_path(nested, d) == joinpath("a", "b.txt")
    end

    mktempdir() do repo
        sd = joinpath(repo, "scripts")
        mkpath(sd)
        out1 = joinpath(repo, "out1")
        out2 = joinpath(repo, "nested", "out2")
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "out1:$(out2)",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "ignored"),
        ) do
            roots = ParallelRunnerKit.distributed_collect_root_dirs(sd, repo)
            @test roots == String[abspath(joinpath(repo, "out1")), abspath(out2)]
        end
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "out1:out1",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "ignored"),
        ) do
            roots = ParallelRunnerKit.distributed_collect_root_dirs(sd, repo)
            @test roots == String[abspath(joinpath(repo, "out1"))]
        end
        withenv(
            "DISTRIBUTED_COLLECT_DIRS" => "",
            "DISTRIBUTED_OUTPUT_DIR" => joinpath(repo, "solo"),
        ) do
            @test ParallelRunnerKit.distributed_collect_root_dirs(sd, repo) ==
                String[abspath(joinpath(repo, "solo"))]
        end
    end
end

@testset "root Project.toml merges ParallelRunnerKit [deps]" begin
    using TOML
    repo_root = abspath(joinpath(@__DIR__, "..", ".."))
    root_deps = get(TOML.parsefile(joinpath(repo_root, "Project.toml")), "deps", Dict{String,String}())
    kit_deps =
        get(TOML.parsefile(joinpath(repo_root, "ParallelRunnerKit", "Project.toml")), "deps", Dict{String,String}())
    # `Distributed` is stdlib-only: listing it under [deps] in the app breaks `Pkg.resolve` on 1.12+ when
    # resolved as a Registry package (see julialang compat with stdlibs). The runner still loads it everywhere.
    skip_merge_check = ["Distributed"]
    for (name, uuid) in kit_deps
        n = String(name)
        n in skip_merge_check && continue
        @test haskey(root_deps, n)
        @test root_deps[n] == String(uuid)
    end
end
