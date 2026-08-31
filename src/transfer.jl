"""
    build_ssh_rsh_string(target::BridgeTarget, globals::GlobalOptions)::String

Construct the `-e` argument for rsync defining the OpenSSH transport parameters.
"""
function build_ssh_rsh_string(target::BridgeTarget, globals::GlobalOptions)::String
    policy = resolve_target_policy(target, globals)
    return "ssh -p $(target.port) -o StrictHostKeyChecking=$(policy) -o ConnectTimeout=$(globals.connect_timeout)"
end

"""
    build_push_command(
        target::BridgeTarget,
        globals::GlobalOptions,
        push_opts::PushOptions,
    )::Cmd

Construct the `rsync` invocation command to deploy local code to a remote target.
"""
function build_push_command(target::BridgeTarget,
                            globals::GlobalOptions,
                            push_opts::PushOptions)::Cmd
    cmd_args = String["sshpass", "-e", "rsync", "-av", "--partial"]
    if globals.compress
        push!(cmd_args, "-z")
    end
    if globals.bandwidth_limit > 0
        push!(cmd_args, "--bwlimit=$(globals.bandwidth_limit)")
    end

    push!(cmd_args, "-e", build_ssh_rsh_string(target, globals))

    for exc in push_opts.excludes
        push!(cmd_args, "--exclude=$(exc)")
    end

    src = endswith(push_opts.local_source_dir, "/") ? push_opts.local_source_dir :
          "$(push_opts.local_source_dir)/"
    dst = "$(target.user)@$(target.host):$(target.remote_dir)/"
    push!(cmd_args, src, dst)

    base_cmd = Cmd(cmd_args)
    return setenv(base_cmd, merge(copy(ENV), Dict("SSHPASS" => target.password)))
end

"""
    build_pull_command(
        target::BridgeTarget,
        globals::GlobalOptions,
        pull_opts::PullOptions,
        local_target_dir::AbstractString,
    )::Cmd

Construct the `rsync` invocation command to retrieve remote simulation artifacts to the local workstation.
"""
function build_pull_command(target::BridgeTarget,
                            globals::GlobalOptions,
                            pull_opts::PullOptions,
                            local_target_dir::AbstractString)::Cmd
    cmd_args = String["sshpass", "-e", "rsync", "-av", "--partial"]
    if globals.compress
        push!(cmd_args, "-z")
    end
    if globals.bandwidth_limit > 0
        push!(cmd_args, "--bwlimit=$(globals.bandwidth_limit)")
    end

    push!(cmd_args, "-e", build_ssh_rsh_string(target, globals))

    for inc in pull_opts.includes
        push!(cmd_args, "--include=$(inc)")
    end
    for exc in pull_opts.excludes
        push!(cmd_args, "--exclude=$(exc)")
    end

    remote_src_dir = normpath(joinpath(target.remote_dir, target.output_subdir))
    src = "$(target.user)@$(target.host):$(remote_src_dir)/"
    dst = endswith(local_target_dir, "/") ? local_target_dir : "$(local_target_dir)/"
    push!(cmd_args, src, dst)

    base_cmd = Cmd(cmd_args)
    return setenv(base_cmd, merge(copy(ENV), Dict("SSHPASS" => target.password)))
end

"""
    prepare_local_pull_directory(
        target::BridgeTarget,
        pull_opts::PullOptions,
    )::String

Prepare and resolve the local destination directory for harvested results per collision policy.
"""
function prepare_local_pull_directory(target::BridgeTarget,
                                      pull_opts::PullOptions)::String
    dest_root = pull_opts.local_destination_root
    mkpath(dest_root)

    target_dir = joinpath(dest_root, target.name)

    if isdir(target_dir)
        if pull_opts.collision_strategy == :abort
            throw(ErrorException("Destination directory '$(target_dir)' already exists and collision_strategy is :abort."))
        elseif pull_opts.collision_strategy == :backup
            # Append backup suffix (#1, #2, ...)
            backup_idx = 1
            backup_dir = "$(target_dir)#$(backup_idx)"
            while isdir(backup_dir)
                backup_idx += 1
                backup_dir = "$(target_dir)#$(backup_idx)"
            end
            @info "Backing up existing destination directory" original=target_dir backup=backup_dir
            mv(target_dir, backup_dir)
            mkpath(target_dir)
        else
            # :resume - Keep existing directory for rsync partial resumption
        end
    else
        mkpath(target_dir)
    end

    return target_dir
end

"""
    push_target(
        target::BridgeTarget,
        config::BridgeConfig;
        dry_run::Bool = false,
    )::TransferResult

Deploy local source code to a single remote target node.
"""
function push_target(target::BridgeTarget,
                     config::BridgeConfig;
                     dry_run::Bool=false)::TransferResult
    t_start = time()
    if dry_run
        cmd = build_push_command(target, config.globals, config.push)
        return TransferResult(target, :push, true, 0, 0.0, "Dry run: `$(cmd)`")
    end

    # Ensure remote base directory exists
    ensure_remote_directory(target, config.globals, target.remote_dir)

    cmd = build_push_command(target, config.globals, config.push)
    out_buf = IOBuffer()
    err_buf = IOBuffer()

    try
        p = run(pipeline(cmd; stdout=out_buf, stderr=err_buf); wait=true)
        duration = time() - t_start
        success = (p.exitcode == 0)
        msg = success ? "Deployed successfully in $(round(duration; digits=2))s." :
              "rsync exited with code $(p.exitcode): $(String(take!(err_buf)))"
        return TransferResult(target, :push, success, p.exitcode, duration, msg)
    catch e
        duration = time() - t_start
        err_msg = String(take!(err_buf))
        detail = isempty(strip(err_msg)) ? sprint(showerror, e) : strip(err_msg)
        return TransferResult(target, :push, false, -1, duration,
                              "Transfer error: $(detail)")
    end
end

"""
    pull_target(
        target::BridgeTarget,
        config::BridgeConfig;
        dry_run::Bool = false,
        clean_remote::Union{Bool, Nothing} = nothing,
    )::TransferResult

Harvest simulation output artifacts from a single remote target node.
If `clean_remote` is true (or defaults to `config.pull.clean_remote_after_pull`), the remote project directory
is safely purged upon 100% successful harvest.
"""
function pull_target(target::BridgeTarget,
                     config::BridgeConfig;
                     dry_run::Bool=false,
                     clean_remote::Union{Bool, Nothing}=nothing)::TransferResult
    t_start = time()
    local_dir = joinpath(config.pull.local_destination_root, target.name)
    should_clean = clean_remote !== nothing ? clean_remote :
                   config.pull.clean_remote_after_pull

    if dry_run
        cmd = build_pull_command(target, config.globals, config.pull, local_dir)
        clean_note = should_clean ? " [Post-clean: rm -rf '$(target.remote_dir)']" : ""
        return TransferResult(target, :pull, true, 0, 0.0, "Dry run: `$(cmd)`$(clean_note)")
    end

    dest_dir = prepare_local_pull_directory(target, config.pull)
    cmd = build_pull_command(target, config.globals, config.pull, dest_dir)
    out_buf = IOBuffer()
    err_buf = IOBuffer()

    try
        p = run(pipeline(cmd; stdout=out_buf, stderr=err_buf); wait=true)
        duration = time() - t_start
        success = (p.exitcode == 0)

        if success
            base_msg = "Harvested successfully in $(round(duration; digits=2))s."
            if should_clean
                clean_res = clean_remote_target(target, config.globals; dry_run=false)
                if clean_res.success
                    msg = "$(base_msg) Remote project purged."
                else
                    msg = "$(base_msg) (Warning: remote cleanup failed: $(clean_res.message))"
                end
            else
                msg = base_msg
            end
            return TransferResult(target, :pull, true, p.exitcode, duration, msg)
        else
            err_msg = String(take!(err_buf))
            return TransferResult(target, :pull, false, p.exitcode, duration,
                                  "rsync exited with code $(p.exitcode): $(err_msg)")
        end
    catch e
        duration = time() - t_start
        err_msg = String(take!(err_buf))
        detail = isempty(strip(err_msg)) ? sprint(showerror, e) : strip(err_msg)
        return TransferResult(target, :pull, false, -1, duration,
                              "Harvest error: $(detail)")
    end
end

"""
    push_all_targets(
        config::BridgeConfig;
        dry_run::Bool = false,
    )::Vector{TransferResult}

Deploy local project tree to all configured remote targets in parallel.
"""
function push_all_targets(config::BridgeConfig;
                          dry_run::Bool=false)::Vector{TransferResult}
    if !dry_run
        check_local_binaries()
    end
    @info "Dispatching parallel push deployment" total_targets=length(config.targets) source=config.push.local_source_dir dry_run=dry_run
    tasks = map(config.targets) do target
        @async push_target(target, config; dry_run=dry_run)
    end
    return fetch.(tasks)
end

"""
    pull_all_targets(
        config::BridgeConfig;
        dry_run::Bool = false,
        clean_remote::Union{Bool, Nothing} = nothing,
    )::Vector{TransferResult}

Harvest simulation results from all configured remote targets in parallel.
"""
function pull_all_targets(config::BridgeConfig;
                          dry_run::Bool=false,
                          clean_remote::Union{Bool, Nothing}=nothing)::Vector{TransferResult}
    if !dry_run
        check_local_binaries()
    end
    should_clean = clean_remote !== nothing ? clean_remote :
                   config.pull.clean_remote_after_pull
    @info "Dispatching parallel results harvest" total_targets=length(config.targets) destination=config.pull.local_destination_root clean_remote=should_clean dry_run=dry_run
    tasks = map(config.targets) do target
        @async pull_target(target, config; dry_run=dry_run, clean_remote=should_clean)
    end
    return fetch.(tasks)
end
