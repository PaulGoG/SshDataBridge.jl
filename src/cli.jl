const ACTIONS = ("probe", "push", "pull", "clean")

"""
    CliOptions

Parsed command line of the driver.

# Fields
- `action::Symbol`: `:help`, `:probe`, `:push`, `:pull`, or `:clean`.
- `config_path::String`: configuration file to load.
- `dry_run::Bool`: print the commands without executing them.
- `clean_remote::Bool`: purge the remote directory after a verified harvest.
- `confirmed::Bool`: `--yes` was given, confirming remote deletion.
"""
struct CliOptions
    action::Symbol
    config_path::String
    dry_run::Bool
    clean_remote::Bool
    confirmed::Bool
end

"""
    default_config_path()::String

`config.toml` next to `Project.toml` of the package.
"""
default_config_path()::String = joinpath(something(pkgdir(@__MODULE__), pwd()),
                                         "config.toml")

"""
    usage()::String

The command-line reference printed by `--help` and after a usage error.
"""
function usage()::String
    return """
           Usage: julia scripts/run.jl <action> [options]

           Deploy a source tree to the configured nodes and harvest their results over ssh and
           rsync. Every action runs on all targets concurrently.

           Actions:
             probe   Check ssh access, remote rsync, and the remote directories
             push    Deploy the local source tree to every target
             pull    Harvest the remote output directory of every target
             clean   Purge the directory selected by purge_scope on every target

           Options:
             -c, --config PATH   Configuration file (default: config.toml next to the project)
             --clean-remote      With pull: purge after a verified harvest
             --yes               Confirm a purge (clean, or pull with a purge requested)
             --dry-run           Print the commands without running them
             -h, --help          Show this message and exit
           """
end

"""
    parse_arguments(args; default_config=default_config_path())::CliOptions

Parse the command line of the driver. `--help` or `-h` anywhere, or an empty command
line, selects the `:help` action. Actions and options match exactly. Throws
`ArgumentError` for an unknown action, an unrecognized option, `--config` without a path,
`--clean-remote` with an action other than `pull`, or `--yes` with an action other than
`pull` or `clean`.
"""
function parse_arguments(args::AbstractVector{<:AbstractString};
                         default_config::AbstractString=default_config_path())::CliOptions
    if isempty(args) || "--help" in args || "-h" in args
        return CliOptions(:help, String(default_config), false, false, false)
    end

    action = String(args[1])
    if !(action in ACTIONS)
        throw(ArgumentError("unknown action '$(action)'; expected one of $(join(ACTIONS, ", "))."))
    end

    config_path = String(default_config)
    dry_run = false
    clean_remote = false
    confirmed = false
    idx = 2
    while idx <= length(args)
        arg = args[idx]
        if arg in ("--config", "-c")
            if idx + 1 > length(args) || startswith(args[idx + 1], "-")
                throw(ArgumentError("$(arg) requires a file path argument."))
            end
            config_path = String(args[idx + 1])
            idx += 2
        elseif arg == "--dry-run"
            dry_run = true
            idx += 1
        elseif arg == "--clean-remote"
            action == "pull" || throw(ArgumentError("--clean-remote applies to pull only."))
            clean_remote = true
            idx += 1
        elseif arg == "--yes"
            action in ("pull", "clean") ||
                throw(ArgumentError("--yes applies to pull and clean only."))
            confirmed = true
            idx += 1
        else
            throw(ArgumentError("unrecognized option '$(arg)'."))
        end
    end
    return CliOptions(Symbol(action), config_path, dry_run, clean_remote, confirmed)
end

count_targets(n::Integer)::String = string(n, n == 1 ? " target" : " targets")

presence(known::Bool, exists::Bool)::String = known ? (exists ? "present" : "missing") :
                                              "unknown"

"""
    format_probe_table(io::IO, results::Vector{ProbeResult})

Print the probe results to `io`: one block per target, then a tally of the targets that
are ready (reachable, with `rsync` installed). Fields that depend on a successful ssh
command read `unknown` when it failed.
"""
function format_probe_table(io::IO, results::Vector{ProbeResult})
    println(io, "\nprobe: ", count_targets(length(results)), "\n")
    for r in results
        println(io, r.target.name, "  ", r.target.user, "@", r.target.host, ":",
                r.target.port)
        println(io, "  SSH reachable:     ", r.ssh_ok ? "yes" : "no")
        println(io, "  Remote rsync:      ",
                r.ssh_ok ? (r.rsync_ok ? "yes" : "no") : "unknown")
        println(io, "  Base directory:    ", presence(r.ssh_ok, r.remote_dir_exists), "  ",
                r.target.remote_dir)
        println(io, "  Output directory:  ",
                presence(r.ssh_ok, r.remote_output_dir_exists), "  ",
                remote_output_directory(r.target))
        println(io, "  Diagnostics:       ", r.message)
        println(io)
    end
    ready = count(r -> r.success, results)
    println(io, count_targets(length(results)), ": ", ready, " ready, ",
            length(results) - ready, " not ready")
    return nothing
end

"""
    format_transfer_table(io::IO, results::Vector{TransferResult}, action::Symbol)

Print the outcome of a push, pull, or clean action to `io`: one line per target with
its status, exit code, and duration, the message beneath it, then a tally.
"""
function format_transfer_table(io::IO, results::Vector{TransferResult}, action::Symbol)
    println(io, "\n", action, ": ", count_targets(length(results)), "\n")
    width = maximum(r -> length(r.target.name), results; init=0)
    for r in results
        println(io, rpad(r.target.name, width), "  ", rpad(r.success ? "ok" : "failed", 6),
                "  ", rpad("exit $(r.exit_code)", 9), "  ",
                round(r.duration_seconds; digits=2), " s")
        println(io, "  ", r.message)
    end
    succeeded = count(r -> r.success, results)
    println(io, "\n", count_targets(length(results)), ": ", succeeded, " succeeded, ",
            length(results) - succeeded, " failed")
    return nothing
end

"""
    execute(io::IO, action::Symbol, config::BridgeConfig, dry_run::Bool,
            clean_remote::Bool)::Bool

Run `action` and print its summary table to `io`; returns whether every target
succeeded.
"""
function execute(io::IO, action::Symbol, config::BridgeConfig, dry_run::Bool,
                 clean_remote::Bool)::Bool
    if action == :probe
        results = probe_all_targets(config)
        format_probe_table(io, results)
        return all(r -> r.success, results)
    elseif action == :push
        results = push_all_targets(config; dry_run=dry_run)
    elseif action == :pull
        results = pull_all_targets(config; dry_run=dry_run, clean_remote=clean_remote)
    else
        results = clean_all_remote_targets(config; dry_run=dry_run)
    end
    format_transfer_table(io, results, action)
    return all(r -> r.success, results)
end

"""
    run_driver(args, io::IO, err::IO)::Int

Body of [`main`](@ref) without the logger setup.
"""
function run_driver(args::AbstractVector{<:AbstractString}, io::IO, err::IO)::Int
    options = try
        parse_arguments(args)
    catch e
        e isa ArgumentError || rethrow()
        println(err, "Error: ", e.msg, "\n")
        print(err, usage())
        return 1
    end
    if options.action == :help
        print(io, usage())
        return 0
    end

    if !isfile(options.config_path)
        println(err, "Error: configuration file not found at '$(options.config_path)'.")
        if options.config_path == default_config_path()
            println(err,
                    "Create one from the template: install -m 600 config.example.toml config.toml")
        end
        return 1
    end

    @info "Loading configuration" path=options.config_path action=options.action dry_run=options.dry_run
    config = try
        load_config(options.config_path)
    catch e
        e isa ArgumentError || rethrow()
        println(err, "Error: ", sprint(showerror, e))
        return 1
    end

    purge_requested = options.action == :clean ||
                      (options.action == :pull &&
                       (options.clean_remote || config.pull.clean_remote_after_pull))
    if purge_requested && options.action == :pull && !isempty(config.pull.includes)
        println(err,
                "Error: a purge cannot follow a harvest narrowed by [pull].includes; drop --clean-remote or the include patterns.")
        return 1
    end
    if purge_requested && !options.dry_run && !options.confirmed
        println(err,
                "Error: this invocation deletes remote directories (purge_scope = $(config.pull.purge_scope)); rerun with --yes to confirm, or use --dry-run to preview.")
        return 1
    end
    if purge_requested
        for target in config.targets
            try
                validate_remote_path_safety(purge_path(target, config.pull.purge_scope),
                                            target.user)
            catch e
                e isa ArgumentError || rethrow()
                println(err, "Error: target '$(target.name)': ", e.msg)
                return 1
            end
        end
    end

    all_passed = try
        execute(io, options.action, config, options.dry_run, purge_requested)
    catch e
        e isa Union{ArgumentError, MissingBinaryError, DirtyWorkingTreeError} || rethrow()
        println(err, "Error: ", sprint(showerror, e))
        return 1
    end
    return all_passed ? 0 : 2
end

"""
    main(args::AbstractVector{<:AbstractString}=ARGS; io::IO=stdout, err::IO=stderr)::Int

Run the command-line driver (`probe`, `push`, `pull`, `clean`; see [`usage`](@ref)) and
return the exit status instead of calling `exit`: 0 when every target succeeded, 1 on a
usage, configuration, or precondition error, 2 when at least one target failed. Summary
tables, and the usage text when `--help` is given, go to `io`; error messages, the usage
text after a usage error, and log records go to `err`. `scripts/run.jl` is a thin
wrapper around this function.

# Example
```julia
exit(main(["probe", "--config", "config.toml"]))
```
"""
function main(args::AbstractVector{<:AbstractString}=ARGS; io::IO=stdout,
              err::IO=stderr)::Int
    return with_logger(ConsoleLogger(err)) do
        return run_driver(args, io, err)
    end
end
