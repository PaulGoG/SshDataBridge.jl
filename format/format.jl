#!/usr/bin/env julia
# Format the repository with JuliaFormatter, or verify it with `--check` (exit 1 on drift);
# any other argument is refused with exit 2.

include("activate.jl")

using JuliaFormatter

const REPOSITORY_ROOT = dirname(@__DIR__)

function main(args::Vector{String}=ARGS)
    if !issubset(args, ("--check",))
        println(stderr, "Usage: julia format/format.jl [--check]")
        exit(2)
    end
    check_only = "--check" in args
    formatted = format(REPOSITORY_ROOT; overwrite=(!check_only))
    if check_only && !formatted
        println(stderr,
                "Formatting check failed; run 'julia format/format.jl' to reformat the sources.")
        exit(1)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
