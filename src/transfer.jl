"""
    build_ssh_rsh_string(target::BridgeTarget, globals::GlobalOptions)::String

Construct the remote-shell string passed to `rsync -e`.
"""
function build_ssh_rsh_string(target::BridgeTarget, globals::GlobalOptions)::String
    policy = resolve_target_policy(target, globals)
    return "ssh -p $(target.port) -o StrictHostKeyChecking=$(policy) " *
           "-o ConnectTimeout=$(globals.connect_timeout) -o NumberOfPasswordPrompts=1"
end

"""
    rsync_host(host::AbstractString)::String

Return `host` in the form accepted by `rsync` endpoints: IPv6 literals are wrapped in
square brackets, everything else is returned unchanged.
"""
function rsync_host(host::AbstractString)::String
    return occursin(':', host) && !startswith(host, '[') ? "[" * host * "]" : String(host)
end

"""
    rsync_base_arguments(globals::GlobalOptions)::Vector{String}

Leading arguments shared by push and pull invocations: the `sshpass` prefix, the archive
and resumption flags, and the optional compression and bandwidth settings.
"""
function rsync_base_arguments(globals::GlobalOptions)::Vector{String}
    args = String["sshpass", "-d", "0", "rsync", "-av", "--partial"]
    globals.compress && push!(args, "-z")
    globals.bandwidth_limit > 0 && push!(args, "--bwlimit=$(globals.bandwidth_limit)")
    return args
end

"""
    build_push_command(target::BridgeTarget, globals::GlobalOptions,
                       push_opts::PushOptions)::Cmd

Construct the `rsync` invocation that deploys the local source tree to `target`. The
password is not part of the command; [`run_authenticated`](@ref) supplies it.
"""
function build_push_command(target::BridgeTarget, globals::GlobalOptions,
                            push_opts::PushOptions)::Cmd
    args = rsync_base_arguments(globals)
    push!(args, "-e", build_ssh_rsh_string(target, globals))
    push_opts.use_gitignore && push!(args, "--filter=:- .gitignore")
    for pattern in push_opts.excludes
        push!(args, "--exclude=$(pattern)")
    end
    source = endswith(push_opts.local_source_dir, '/') ? push_opts.local_source_dir :
             push_opts.local_source_dir * "/"
    destination = "$(target.user)@$(rsync_host(target.host)):$(target.remote_dir)/"
    push!(args, source, destination)
    return Cmd(args)
end

"""
    build_pull_command(target::BridgeTarget, globals::GlobalOptions,
                       pull_opts::PullOptions, local_target_dir::AbstractString)::Cmd

Construct the `rsync` invocation that retrieves the remote output directory of `target`
into `local_target_dir`. The password is not part of the command;
[`run_authenticated`](@ref) supplies it.
"""
function build_pull_command(target::BridgeTarget, globals::GlobalOptions,
                            pull_opts::PullOptions, local_target_dir::AbstractString)::Cmd
    args = rsync_base_arguments(globals)
    push!(args, "-e", build_ssh_rsh_string(target, globals))
    for pattern in pull_opts.includes
        push!(args, "--include=$(pattern)")
    end
    for pattern in pull_opts.excludes
        push!(args, "--exclude=$(pattern)")
    end
    source = "$(target.user)@$(rsync_host(target.host)):$(remote_output_directory(target))/"
    destination = endswith(local_target_dir, '/') ? String(local_target_dir) :
                  local_target_dir * "/"
    push!(args, source, destination)
    return Cmd(args)
end

"""
    prepare_local_pull_directory(target::BridgeTarget, pull_opts::PullOptions)::String

Resolve and create the local destination directory of `target` according to the collision
strategy: `:resume` keeps an existing directory, `:backup` renames it with a `#n` suffix
before creating a fresh one, and `:abort` throws an `ErrorException`.
"""
function prepare_local_pull_directory(target::BridgeTarget, pull_opts::PullOptions)::String
    dest_root = pull_opts.local_destination_root
    mkpath(dest_root)
    target_dir = joinpath(dest_root, target.name)

    if isdir(target_dir)
        if pull_opts.collision_strategy == :abort
            throw(ErrorException("Destination directory '$(target_dir)' already exists and collision_strategy is :abort."))
        elseif pull_opts.collision_strategy == :backup
            backup_idx = 1
            backup_dir = "$(target_dir)#$(backup_idx)"
            while isdir(backup_dir)
                backup_idx += 1
                backup_dir = "$(target_dir)#$(backup_idx)"
            end
            @info "Backing up existing destination directory" original = target_dir backup = backup_dir
            mv(target_dir, backup_dir)
            mkpath(target_dir)
        end
    else
        mkpath(target_dir)
    end
    return target_dir
end

"""
    push_target(target::BridgeTarget, config::BridgeConfig; dry_run::Bool=false)::TransferResult

Deploy the local source tree to a single target. The remote base directory is created
first; a failure there is reported before `rsync` is attempted.
"""
function push_target(target::BridgeTarget, config::BridgeConfig;
                     dry_run::Bool=false)::TransferResult
    t_start = time()
    cmd = build_push_command(target, config.globals, config.push)
    if dry_run
        return TransferResult(target, :push, true, 0, 0.0,
                              "Dry run: $(command_string(cmd))")
    end

    directory = ensure_remote_directory(target, config.globals, target.remote_dir)
    if !directory.success
        return TransferResult(target, :push, false, directory.exitcode, time() - t_start,
                              "Remote directory creation failed (exit code $(directory.exitcode)): $(strip(directory.stderr))")
    end

    outcome = try
        run_authenticated(cmd, target.password)
    catch err
        err isa Base.IOError || rethrow()
        return TransferResult(target, :push, false, -1, time() - t_start,
                              "Spawn failure: $(sprint(showerror, err))")
    end
    duration = time() - t_start
    success = outcome.exitcode == 0
    message = success ? "Deployed successfully in $(round(duration; digits=2)) s." :
              "rsync exited with code $(outcome.exitcode): $(strip(outcome.stderr))"
    return TransferResult(target, :push, success, outcome.exitcode, duration, message)
end

"""
    pull_target(target::BridgeTarget, config::BridgeConfig; dry_run::Bool=false,
                clean_remote::Union{Bool, Nothing}=nothing)::TransferResult

Harvest the remote output directory of a single target. When `clean_remote` is `true`, or
`nothing` and `config.pull.clean_remote_after_pull` is set, the directory selected by
`config.pull.purge_scope` is purged after a successful transfer. The purge is skipped, and
the reason reported, when `config.pull.includes` narrows the harvest, because files left
unharvested by the filter would otherwise be destroyed.
"""
function pull_target(target::BridgeTarget, config::BridgeConfig; dry_run::Bool=false,
                     clean_remote::Union{Bool, Nothing}=nothing)::TransferResult
    t_start = time()
    should_clean = clean_remote !== nothing ? clean_remote :
                   config.pull.clean_remote_after_pull
    scope = config.pull.purge_scope
    filtered = !isempty(config.pull.includes)
    local_dir = joinpath(config.pull.local_destination_root, target.name)

    if dry_run
        cmd = build_pull_command(target, config.globals, config.pull, local_dir)
        clean_note = if !should_clean
            ""
        elseif filtered
            " [post-pull purge skipped: 'includes' filter active]"
        else
            " [post-pull purge of '$(purge_path(target, scope))']"
        end
        return TransferResult(target, :pull, true, 0, 0.0,
                              "Dry run: $(command_string(cmd))$(clean_note)")
    end

    dest_dir = try
        prepare_local_pull_directory(target, config.pull)
    catch err
        err isa ErrorException || rethrow()
        return TransferResult(target, :pull, false, -1, time() - t_start,
                              "Destination refusal: $(sprint(showerror, err))")
    end
    cmd = build_pull_command(target, config.globals, config.pull, dest_dir)
    outcome = try
        run_authenticated(cmd, target.password)
    catch err
        err isa Base.IOError || rethrow()
        return TransferResult(target, :pull, false, -1, time() - t_start,
                              "Spawn failure: $(sprint(showerror, err))")
    end
    duration = time() - t_start
    if outcome.exitcode != 0
        return TransferResult(target, :pull, false, outcome.exitcode, duration,
                              "rsync exited with code $(outcome.exitcode): $(strip(outcome.stderr))")
    end

    message = "Harvested successfully in $(round(duration; digits=2)) s."
    if should_clean
        if filtered
            message *= " Remote purge skipped: an 'includes' filter is active, so unharvested files may remain."
        else
            clean_result = clean_remote_target(target, config.globals; scope=scope)
            message *= clean_result.success ? " " * clean_result.message :
                       " Remote purge failed: " * clean_result.message
        end
    end
    return TransferResult(target, :pull, true, outcome.exitcode, duration, message)
end

"""
    push_all_targets(config::BridgeConfig; dry_run::Bool=false)::Vector{TransferResult}

Deploy the local source tree to all configured targets concurrently.
"""
function push_all_targets(config::BridgeConfig;
                          dry_run::Bool=false)::Vector{TransferResult}
    dry_run || check_local_binaries()
    @info "Dispatching parallel push deployment" total_targets = length(config.targets) source = config.push.local_source_dir dry_run = dry_run
    tasks = map(config.targets) do target
        @async push_target(target, config; dry_run=dry_run)
    end
    return fetch.(tasks)
end

"""
    pull_all_targets(config::BridgeConfig; dry_run::Bool=false,
                     clean_remote::Union{Bool, Nothing}=nothing)::Vector{TransferResult}

Harvest the remote output directories of all configured targets concurrently.
"""
function pull_all_targets(config::BridgeConfig; dry_run::Bool=false,
                          clean_remote::Union{Bool, Nothing}=nothing)::Vector{TransferResult}
    dry_run || check_local_binaries()
    should_clean = clean_remote !== nothing ? clean_remote :
                   config.pull.clean_remote_after_pull
    @info "Dispatching parallel results harvest" total_targets = length(config.targets) destination = config.pull.local_destination_root clean_remote = should_clean dry_run = dry_run
    tasks = map(config.targets) do target
        @async pull_target(target, config; dry_run=dry_run, clean_remote=should_clean)
    end
    return fetch.(tasks)
end
