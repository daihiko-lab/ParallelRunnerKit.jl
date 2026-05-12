#!/usr/bin/env julia
# ParallelRunnerKit unit tests (not part of `Pkg.test("TCNashEvo")`).
# From repository root:
#   julia --project=. ParallelRunnerKit/test/runtests.jl

using Test
include(joinpath(@__DIR__, "test_parallel_runner_kit.jl"))
