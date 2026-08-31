"""
    check_local_binaries()

Verify that required system utilities (`ssh`, `sshpass`, `rsync`) exist on the local system.
"""
function check_local_binaries()
    required = ["ssh", "sshpass", "rsync"]
    missing = filter(bin -> Sys.which(bin) === nothing, required)
    if !isempty(missing)
        throw(ErrorException("Missing required local binaries in PATH: $(join(missing, ", ")). " *
                             "Please ensure they are installed (e.g. 'sudo dnf install sshpass rsync')."))
    end
    return nothing
end

"""
    resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String

Resolve effective host key policy for a target.
"""
function resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String
    return target.strict_host_key_checking !== nothing ? target.strict_host_key_checking :
           globals.strict_host_key_checking
end

"""
    build_ssh_base_command(target::BridgeTarget, globals::GlobalOptions)::Vector{String}

Build base command argument list for OpenSSH invocations.
"""
function build_ssh_base_command(target::BridgeTarget,
                                globals::GlobalOptions)::Vector{String}
    policy = resolve_target_policy(target, globals)
    return String["ssh",
                  "-p", string(target.port),
                  "-o", "StrictHostKeyChecking=$(policy)",
                  "-o", "ConnectTimeout=$(globals.connect_timeout)",
                  "-o", "BatchMode=no",
                  "$(target.user)@$(target.host)"]
end

"""
    probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult

Perform an automated remote diagnostic check over SSH.
Probes SSH connectivity, verifies remote `rsync` presence, and checks directory existence.
"""
function probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult
    remote_out = normpath(joinpath(target.remote_dir, target.output_subdir))
    probe_script = """
    if which rsync >/dev/null 2>&1; then echo "RSYNC_OK"; else echo "RSYNC_MISSING"; fi
    if [ -d "$(target.remote_dir)" ]; then echo "DIR_EXISTS"; else echo "DIR_MISSING"; fi
    if [ -d "$(remote_out)" ]; then echo "OUT_EXISTS"; else echo "OUT_MISSING"; fi
    """

    ssh_args = build_ssh_base_command(target, globals)
    cmd_args = String["sshpass", "-e"]
    append!(cmd_args, ssh_args)
    push!(cmd_args, probe_script)

    cmd = setenv(Cmd(cmd_args), merge(copy(ENV), Dict("SSHPASS" => target.password)))
    out_buf = IOBuffer()
    err_buf = IOBuffer()

    try
        p = run(pipeline(cmd; stdout=out_buf, stderr=err_buf); wait=true)
        output = String(take!(out_buf))
        ssh_ok = (p.exitcode == 0)
        rsync_ok = occursin("RSYNC_OK", output)
        remote_dir_exists = occursin("DIR_EXISTS", output)
        remote_output_dir_exists = occursin("OUT_EXISTS", output)

        messages = String[]
        if !rsync_ok
            push!(messages, "rsync missing on remote")
        end
        if !remote_dir_exists
            push!(messages, "remote base dir missing ('$(target.remote_dir)')")
        end
        if !remote_output_dir_exists
            push!(messages, "remote output dir missing ('$(remote_out)')")
        end

        msg = isempty(messages) ? "All remote diagnostics passed." : join(messages, "; ")
        return ProbeResult(target, ssh_ok && rsync_ok, ssh_ok, rsync_ok, remote_dir_exists,
                           remote_output_dir_exists, msg)
    catch e
        err_msg = String(take!(err_buf))
        detail = isempty(strip(err_msg)) ? sprint(showerror, e) : strip(err_msg)
        return ProbeResult(target, false, false, false, false, false,
                           "Connection failure: $(detail)")
    end
end

"""
    probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}

Probe all configured remote targets concurrently using Julia tasks.
"""
function probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}
    check_local_binaries()
    tasks = map(config.targets) do target
        @async probe_target(target, config.globals)
    end
    return fetch.(tasks)
end

"""
    ensure_remote_directory(target::BridgeTarget, globals::GlobalOptions, remote_path::AbstractString)::Bool

Ensure a remote directory exists via `mkdir -p`.
"""
function ensure_remote_directory(target::BridgeTarget, globals::GlobalOptions,
                                 remote_path::AbstractString)::Bool
    ssh_args = build_ssh_base_command(target, globals)
    cmd_args = String["sshpass", "-e"]
    append!(cmd_args, ssh_args)
    push!(cmd_args, "mkdir -p '$(remote_path)'")

    cmd = setenv(Cmd(cmd_args), merge(copy(ENV), Dict("SSHPASS" => target.password)))
    try
        p = run(cmd; wait=true)
        return p.exitcode == 0
    catch
        return false
    end
end

"""
    clean_remote_target(
        target::BridgeTarget,
        globals::GlobalOptions;
        dry_run::Bool = false,
    )::TransferResult

Safely remove the remote project directory (`target.remote_dir`) on a target machine over SSH.
Validates that the path is not a critical system/user root before execution.
"""
function clean_remote_target(target::BridgeTarget,
                             globals::GlobalOptions;
                             dry_run::Bool=false)::TransferResult
    t_start = time()
    try
        validate_remote_path_safety(target.remote_dir, target.user)
    catch e
        duration = time() - t_start
        return TransferResult(target, :clean, false, -1, duration,
                              "Safety refusal: $(sprint(showerror, e))")
    end

    ssh_args = build_ssh_base_command(target, globals)
    cmd_args = String["sshpass", "-e"]
    append!(cmd_args, ssh_args)
    push!(cmd_args, "rm -rf -- '$(target.remote_dir)'")

    cmd = setenv(Cmd(cmd_args), merge(copy(ENV), Dict("SSHPASS" => target.password)))

    if dry_run
        return TransferResult(target, :clean, true, 0, 0.0, "Dry run: `$(cmd)`")
    end

    out_buf = IOBuffer()
    err_buf = IOBuffer()
    try
        p = run(pipeline(cmd; stdout=out_buf, stderr=err_buf); wait=true)
        duration = time() - t_start
        success = (p.exitcode == 0)
        msg = success ?
              "Remote directory '$(target.remote_dir)' purged successfully in $(round(duration; digits=2))s." :
              "rm exited with code $(p.exitcode): $(String(take!(err_buf)))"
        return TransferResult(target, :clean, success, p.exitcode, duration, msg)
    catch e
        duration = time() - t_start
        err_msg = String(take!(err_buf))
        detail = isempty(strip(err_msg)) ? sprint(showerror, e) : strip(err_msg)
        return TransferResult(target, :clean, false, -1, duration,
                              "Cleanup error: $(detail)")
    end
end

"""
    clean_all_remote_targets(
        config::BridgeConfig;
        dry_run::Bool = false,
    )::Vector{TransferResult}

Purge remote project directories across all configured targets in parallel.
"""
function clean_all_remote_targets(config::BridgeConfig;
                                  dry_run::Bool=false)::Vector{TransferResult}
    if !dry_run
        check_local_binaries()
    end
    @info "Dispatching parallel remote project purge" total_targets=length(config.targets) dry_run=dry_run
    tasks = map(config.targets) do target
        @async clean_remote_target(target, config.globals; dry_run=dry_run)
    end
    return fetch.(tasks)
end
