#!/usr/bin/env julia

using Pkg
const PROJECT_ROOT = dirname(@__DIR__)
Pkg.activate(PROJECT_ROOT; io=devnull)
Pkg.instantiate(; io=devnull)

using SshDataBridge

const ACTIONS = ("probe", "push", "pull", "clean")

"""
    print_usage()

Print the command-line reference.
"""
function print_usage()
    return println("""
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
           """)
end

"""
    format_probe_table(results::Vector{ProbeResult})

Print the pre-flight probe summary.
"""
function format_probe_table(results::Vector{ProbeResult})
    println("\n" * "═"^80)
    println("  PRE-FLIGHT DIAGNOSTIC PROBE SUMMARY")
    println("═"^80)
    for r in results
        status_icon = r.success ? "✓" : "✗"
        println("$(status_icon) Target: $(r.target.name) ($(r.target.user)@$(r.target.host):$(r.target.port))")
        println("  ├─ SSH reachable:        $(r.ssh_ok ? "YES" : "NO")")
        println("  ├─ Remote rsync:         $(r.rsync_ok ? "YES" : "NO")")
        println("  ├─ Remote base dir:      $(r.remote_dir_exists ? "EXISTS" : "MISSING") ('$(r.target.remote_dir)')")
        println("  ├─ Remote output dir:    $(r.remote_output_dir_exists ? "EXISTS" : "MISSING") ('$(purge_path(r.target, :output))')")
        println("  └─ Diagnostics:          $(r.message)")
        println("─"^80)
    end
    return nothing
end

"""
    format_transfer_table(results::Vector{TransferResult}, action::Symbol)

Print the outcome summary of a push, pull, or clean action.
"""
function format_transfer_table(results::Vector{TransferResult}, action::Symbol)
    action_str = if action == :push
        "DEPLOYMENT (PUSH)"
    elseif action == :pull
        "HARVESTING (PULL)"
    else
        "PURGE (CLEAN)"
    end
    println("\n" * "═"^80)
    println("  PARALLEL $(action_str) SUMMARY")
    println("═"^80)
    success_count = count(r -> r.success, results)
    for r in results
        status_icon = r.success ? "✓ PASS" : "✗ FAIL"
        dur_str = "$(round(r.duration_seconds; digits=2)) s"
        println("[$(status_icon)] Target: $(r.target.name) (exit code: $(r.exit_code), duration: $(dur_str))")
        println("       └─ $(r.message)")
    end
    println("═"^80)
    println("Total: $(length(results)) | Succeeded: $(success_count) | Failed: $(length(results) - success_count)")
    println("═"^80 * "\n")
    return nothing
end

"""
    parse_arguments(args::Vector{String})

Parse the command line into `(; action, config_path, dry_run, clean_remote, confirmed)`.
Prints the usage reference and exits on `--help` or on an invalid invocation.
"""
function parse_arguments(args::Vector{String})
    if isempty(args) || "--help" in args || "-h" in args
        print_usage()
        exit(0)
    end

    action_str = lowercase(args[1])
    if !(action_str in ACTIONS)
        println(stderr,
                "Error: unknown action '$(action_str)'; expected one of $(join(ACTIONS, ", ")).\n")
        print_usage()
        exit(1)
    end

    config_path = joinpath(dirname(@__DIR__), "config.toml")
    dry_run = false
    clean_remote = false
    confirmed = false
    idx = 2
    while idx <= length(args)
        arg = args[idx]
        if arg in ("--config", "-c")
            if idx + 1 > length(args)
                println(stderr, "Error: --config requires a file path argument.")
                exit(1)
            end
            config_path = args[idx + 1]
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
            println(stderr, "Error: unrecognized option '$(arg)'.\n")
            print_usage()
            exit(1)
        end
    end
    return (; action=Symbol(action_str), config_path, dry_run, clean_remote, confirmed)
end

"""
    execute(action::Symbol, config::BridgeConfig, dry_run::Bool, clean_remote::Bool)::Bool

Run `action` and print its summary table; returns whether every target succeeded.
"""
function execute(action::Symbol, config::BridgeConfig, dry_run::Bool,
                 clean_remote::Bool)::Bool
    if action == :probe
        results = probe_all_targets(config)
        format_probe_table(results)
        return all(r -> r.success, results)
    elseif action == :push
        results = push_all_targets(config; dry_run=dry_run)
    elseif action == :pull
        results = pull_all_targets(config; dry_run=dry_run,
                                   clean_remote=clean_remote ? true : nothing)
    else
        results = clean_all_remote_targets(config; dry_run=dry_run)
    end
    format_transfer_table(results, action)
    return all(r -> r.success, results)
end

function main(args::Vector{String}=ARGS)
    options = parse_arguments(args)

    if !isfile(options.config_path)
        println(stderr, "Error: configuration file not found at '$(options.config_path)'.")
        println(stderr, "Create one from 'config.example.toml'.")
        exit(1)
    end

    @info "Loading SshDataBridge configuration" path = options.config_path action = options.action dry_run = options.dry_run
    config = try
        load_config(options.config_path)
    catch err
        err isa ArgumentError || rethrow()
        println(stderr, "Error: ", sprint(showerror, err))
        exit(1)
    end

    purge_requested = options.action == :clean ||
                      (options.action == :pull &&
                       (options.clean_remote || config.pull.clean_remote_after_pull))
    if purge_requested && !options.dry_run && !options.confirmed
        println(stderr,
                "Error: this invocation deletes remote directories (purge_scope = $(config.pull.purge_scope)); re-run with --yes to confirm, or use --dry-run to preview.")
        exit(1)
    end

    all_passed = try
        execute(options.action, config, options.dry_run, options.clean_remote)
    catch err
        err isa Union{ArgumentError, MissingBinaryError, DirtyWorkingTreeError} || rethrow()
        println(stderr, "Error: ", sprint(showerror, err))
        exit(1)
    end
    return exit(all_passed ? 0 : 2)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
