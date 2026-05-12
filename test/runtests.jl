#!/usr/bin/env julia
# ParallelRunnerKit unit tests (optional; not required in every host application).
# From the application repo root (when this tree lives under `ParallelRunnerKit/`):
#   julia --project=. ParallelRunnerKit/test/runtests.jl
# From a standalone kit checkout (this directory as the active project):
#   julia --project=. test/runtests.jl

using Test
include(joinpath(@__DIR__, "test_parallel_runner_kit.jl"))
