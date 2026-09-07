#!/usr/bin/env julia

using Pkg
const PROJECT_ROOT = dirname(@__DIR__)
Pkg.activate(PROJECT_ROOT; io=devnull)
Pkg.instantiate(; io=devnull)

using SshDataBridge

"""
    print_usage()

Print CLI usage instructions.
"""
function print_usage()
    return println("""
           SshDataBridge CLI — Simulation Campaign Deployment & Results Harvester

           Usage:
             julia --project=. scripts/run.jl <action> [options]

           Actions:
             probe         Execute pre-flight connectivity, rsync, and path diagnostics
             push          Deploy local project tree to remote targets in parallel
             pull          Harvest simulation output artifacts from remote targets in parallel
             clean         Purge the remote directory selected by purge_scope on all targets

           Options:
             --config, -c <path>   Path to configuration TOML (default: config.toml)
             --clean-remote        On pull: purge the remote directory after a successful harvest
             --yes                 Confirm remote deletion (required for clean and any purge)
             --dry-run             Print constructed commands without executing transfers
             --help, -h            Show this help manual
           """)
end

"""
    format_probe_table(results::Vector{ProbeResult})

Print formatted diagnostic summary for pre-flight probes.
"""
function format_probe_table(results::Vector{ProbeResult})
    println("\n" * "═"^80)
    println("  PRE-FLIGHT DIAGNOSTIC PROBE SUMMARY")
    println("═"^80)
    for r in results
        status_icon = r.success ? "✓" : "✗"
        println("$(status_icon) Target: $(r.target.name) ($(r.target.user)@$(r.target.host):$(r.target.port))")
        println("  ├─ SSH Reachable:        $(r.ssh_ok ? "YES" : "NO")")
        println("  ├─ Remote rsync:         $(r.rsync_ok ? "YES" : "NO")")
        println("  ├─ Remote Base Dir:      $(r.remote_dir_exists ? "EXISTS" : "MISSING") ('$(r.target.remote_dir)')")
        out_path = normpath(joinpath(r.target.remote_dir, r.target.output_subdir))
        println("  ├─ Remote Output Dir:    $(r.remote_output_dir_exists ? "EXISTS" : "MISSING") ('$(out_path)')")
        println("  └─ Diagnostics:          $(r.message)")
        println("─"^80)
    end
end

"""
    format_transfer_table(results::Vector{TransferResult}, action::Symbol)

Print formatted transfer outcome summary table.
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
        dur_str = "$(round(r.duration_seconds; digits=2))s"
        println("[$(status_icon)] Target: $(r.target.name) (exit code: $(r.exit_code), duration: $(dur_str))")
        println("       └─ $(r.message)")
    end
    println("═"^80)
    println("Total: $(length(results)) | Succeeded: $(success_count) | Failed: $(length(results) - success_count)")
    return println("═"^80 * "\n")
end

function main(args::Vector{String}=ARGS)
    if isempty(args) || "--help" in args || "-h" in args
        print_usage()
        exit(0)
    end

    action_str = lowercase(args[1])
    if !(action_str in ("probe", "push", "pull", "clean"))
        println(stderr,
                "Error: Unknown action '$(action_str)'. Must be 'probe', 'push', 'pull', or 'clean'.\n")
        print_usage()
        exit(1)
    end
    action = Symbol(action_str)

    config_path = joinpath(dirname(@__DIR__), "config.toml")
    dry_run = false
    clean_remote_flag = nothing
    confirmed = false

    idx = 2
    while idx <= length(args)
        arg = args[idx]
        if arg in ("--config", "-c")
            if idx + 1 <= length(args)
                config_path = args[idx + 1]
                idx += 2
                continue
            else
                println(stderr, "Error: --config requires a file path argument.")
                exit(1)
            end
        elseif arg == "--dry-run"
            dry_run = true
            idx += 1
        elseif arg == "--clean-remote"
            clean_remote_flag = true
            idx += 1
        elseif arg == "--yes"
            confirmed = true
            idx += 1
        else
            println(stderr, "Error: Unrecognized option '$(arg)'.")
            print_usage()
            exit(1)
        end
    end

    if !isfile(config_path)
        println(stderr, "Error: Configuration file not found at '$(config_path)'.")
        println(stderr, "Please create one based on 'config.example.toml'.")
        exit(1)
    end

    @info "Loading SshDataBridge configuration" path=config_path action=action dry_run=dry_run
    config = load_config(config_path)

    purge_requested = action == :clean ||
                      (action == :pull &&
                       (clean_remote_flag === true || config.pull.clean_remote_after_pull))
    if purge_requested && !dry_run && !confirmed
        println(stderr,
                "Error: this invocation deletes remote directories (purge_scope = $(config.pull.purge_scope)); re-run with --yes to confirm, or use --dry-run to preview.")
        exit(1)
    end

    if action == :probe
        results = probe_all_targets(config)
        format_probe_table(results)
        all_passed = all(r -> r.success, results)
        exit(all_passed ? 0 : 2)
    elseif action == :push
        if config.push.require_clean_git
            git_check = try
                read(`git status --porcelain`, String)
            catch
                ""
            end
            if !isempty(strip(git_check))
                println(stderr,
                        "Error: Local git repository has uncommitted modifications and require_clean_git=true.")
                exit(1)
            end
        end
        results = push_all_targets(config; dry_run=dry_run)
        format_transfer_table(results, :push)
        all_passed = all(r -> r.success, results)
        exit(all_passed ? 0 : 2)
    elseif action == :pull
        results = pull_all_targets(config; dry_run=dry_run, clean_remote=clean_remote_flag)
        format_transfer_table(results, :pull)
        all_passed = all(r -> r.success, results)
        exit(all_passed ? 0 : 2)
    elseif action == :clean
        results = clean_all_remote_targets(config; dry_run=dry_run)
        format_transfer_table(results, :clean)
        all_passed = all(r -> r.success, results)
        exit(all_passed ? 0 : 2)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
