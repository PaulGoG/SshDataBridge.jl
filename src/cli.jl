const ACTIONS = ("probe", "push", "pull", "clean")

"""
    CliOptions

Parsed command line of the driver.

# Fields
- `action::Symbol`: `:help`, `:probe`, `:push`, `:pull`, or `:clean`.
- `config_path::String`: configuration file to load.
- `dry_run::Bool`: print the commands without executing them.
- `clean_remote::Bool`: purge the remote directory after a successful pull.
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
           SshDataBridge — simulation campaign deployment and results harvesting over SSH/rsync

           Usage:
             julia scripts/run.jl <action> [options]

           Actions:
             probe         Check connectivity, remote rsync, and remote directories
             push          Deploy the local source tree to all targets in parallel
             pull          Harvest the remote output directories in parallel
             clean         Purge the remote directory selected by purge_scope on all targets

           Options:
             --config, -c <path>   Configuration TOML (default: config.toml next to the project)
             --clean-remote        On pull: purge the remote directory after a successful harvest
             --yes                 Confirm remote deletion (required for clean and any purge)
             --dry-run             Print the commands that would run without executing them
             --help, -h            Show this reference
           """
end

"""
    parse_arguments(args; default_config=default_config_path())::CliOptions

Parse the command line of the driver. `--help` or `-h` anywhere, or an empty command
line, selects the `:help` action. Throws `ArgumentError` for an unknown action, an
unrecognized option, or `--config` without a path.
"""
function parse_arguments(args::AbstractVector{<:AbstractString};
                         default_config::AbstractString=default_config_path())::CliOptions
    if isempty(args) || "--help" in args || "-h" in args
        return CliOptions(:help, String(default_config), false, false, false)
    end

    action = lowercase(args[1])
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
            if idx + 1 > length(args)
                throw(ArgumentError("$(arg) requires a file path argument."))
            end
            config_path = String(args[idx + 1])
            idx += 2
        elseif arg == "--dry-run"
            dry_run = true
            idx += 1
        elseif arg == "--clean-remote"
            clean_remote = true
            idx += 1
        elseif arg == "--yes"
            confirmed = true
            idx += 1
        else
            throw(ArgumentError("unrecognized option '$(arg)'."))
        end
    end
    return CliOptions(Symbol(action), config_path, dry_run, clean_remote, confirmed)
end

"""
    format_probe_table(io::IO, results::Vector{ProbeResult})

Print the pre-flight probe summary to `io`.
"""
function format_probe_table(io::IO, results::Vector{ProbeResult})
    println(io, "\n" * "═"^80)
    println(io, "  PRE-FLIGHT DIAGNOSTIC PROBE SUMMARY")
    println(io, "═"^80)
    for r in results
        status_icon = r.success ? "✓" : "✗"
        println(io,
                "$(status_icon) Target: $(r.target.name) ($(r.target.user)@$(r.target.host):$(r.target.port))")
        println(io, "  ├─ SSH reachable:        $(r.ssh_ok ? "YES" : "NO")")
        println(io, "  ├─ Remote rsync:         $(r.rsync_ok ? "YES" : "NO")")
        println(io,
                "  ├─ Remote base dir:      $(r.remote_dir_exists ? "EXISTS" : "MISSING") ('$(r.target.remote_dir)')")
        println(io,
                "  ├─ Remote output dir:    $(r.remote_output_dir_exists ? "EXISTS" : "MISSING") ('$(purge_path(r.target, :output))')")
        println(io, "  └─ Diagnostics:          $(r.message)")
        println(io, "─"^80)
    end
    return nothing
end

"""
    format_transfer_table(io::IO, results::Vector{TransferResult}, action::Symbol)

Print the outcome summary of a push, pull, or clean action to `io`.
"""
function format_transfer_table(io::IO, results::Vector{TransferResult}, action::Symbol)
    action_str = if action == :push
        "DEPLOYMENT (PUSH)"
    elseif action == :pull
        "HARVESTING (PULL)"
    else
        "PURGE (CLEAN)"
    end
    println(io, "\n" * "═"^80)
    println(io, "  PARALLEL $(action_str) SUMMARY")
    println(io, "═"^80)
    success_count = count(r -> r.success, results)
    for r in results
        status_icon = r.success ? "✓ PASS" : "✗ FAIL"
        dur_str = "$(round(r.duration_seconds; digits=2)) s"
        println(io,
                "[$(status_icon)] Target: $(r.target.name) (exit code: $(r.exit_code), duration: $(dur_str))")
        println(io, "       └─ $(r.message)")
    end
    println(io, "═"^80)
    println(io,
            "Total: $(length(results)) | Succeeded: $(success_count) | Failed: $(length(results) - success_count)")
    println(io, "═"^80 * "\n")
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
        results = pull_all_targets(config; dry_run=dry_run,
                                   clean_remote=clean_remote ? true : nothing)
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
        println(err, "Create one from 'config.example.toml'.")
        return 1
    end

    @info "Loading SshDataBridge configuration" path = options.config_path action = options.action dry_run = options.dry_run
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
    if purge_requested && !options.dry_run && !options.confirmed
        println(err,
                "Error: this invocation deletes remote directories (purge_scope = $(config.pull.purge_scope)); re-run with --yes to confirm, or use --dry-run to preview.")
        return 1
    end

    all_passed = try
        execute(io, options.action, config, options.dry_run, options.clean_remote)
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
tables and the usage text go to `io`; error messages and log records go to `err`.
`scripts/run.jl` is a thin wrapper around this function.

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
