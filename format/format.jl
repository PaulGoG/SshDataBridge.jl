#!/usr/bin/env julia
# Format the repository with JuliaFormatter, or verify it with `--check` (exit 1 on drift).
# A source file that does not parse is reported and fails the run in both modes, because
# JuliaFormatter skips such a file with a warning and still reports success.

include("activate.jl")

using JuliaFormatter

const REPOSITORY_ROOT = dirname(@__DIR__)

"""
    source_files(root::AbstractString)::Vector{String}

Every `.jl` file below `root`, hidden directories excluded, in sorted order.
"""
function source_files(root::AbstractString)::Vector{String}
    files = String[]
    for (directory, _, names) in walkdir(root)
        components = splitpath(relpath(directory, root))
        any(c -> c != "." && startswith(c, '.'), components) && continue
        for name in names
            endswith(name, ".jl") && push!(files, joinpath(directory, name))
        end
    end
    return sort!(files)
end

"""
    has_parse_error(expression)::Bool

Whether a parsed expression contains an `:error` or `:incomplete` node, which is how
`Meta.parseall` reports a syntax error inside the expression it returns.
"""
function has_parse_error(expression)::Bool
    expression isa Expr || return false
    expression.head in (:error, :incomplete) && return true
    return any(has_parse_error, expression.args)
end

"""
    unparsable_files(root::AbstractString)::Vector{String}

The source files below `root` that `Meta.parseall` cannot parse, whether it throws
`Meta.ParseError` or returns an expression with an error node.
"""
function unparsable_files(root::AbstractString)::Vector{String}
    return filter(source_files(root)) do file
        parsed = try
            Meta.parseall(read(file, String); filename=file)
        catch err
            err isa Meta.ParseError || rethrow()
            return true
        end
        return has_parse_error(parsed)
    end
end

function main(args::Vector{String}=ARGS)
    check_only = "--check" in args
    broken = unparsable_files(REPOSITORY_ROOT)
    if !isempty(broken)
        println(stderr, "Source files that do not parse; fix them before formatting:")
        for file in broken
            println(stderr, "  ", relpath(file, REPOSITORY_ROOT))
        end
        exit(1)
    end
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
