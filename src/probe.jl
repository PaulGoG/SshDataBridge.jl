const REQUIRED_LOCAL_BINARIES = ("ssh", "sshpass", "rsync")

"""
    check_local_binaries()

Verify that `ssh`, `sshpass`, and `rsync` are available in `PATH`. Throws
[`MissingBinaryError`](@ref) naming the missing binaries otherwise.
"""
function check_local_binaries()
    missing_binaries = String[bin
                              for bin in REQUIRED_LOCAL_BINARIES
                              if Sys.which(bin) === nothing]
    isempty(missing_binaries) || throw(MissingBinaryError(missing_binaries))
    return nothing
end

"""
    resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String

Return the effective host key policy of `target`, honouring its override when present.
"""
function resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String
    return target.strict_host_key_checking !== nothing ? target.strict_host_key_checking :
           globals.strict_host_key_checking
end

"""
    build_ssh_command(target::BridgeTarget, globals::GlobalOptions,
                      remote_command::AbstractString)::Cmd

Construct the `sshpass -d 0 ssh -n ...` invocation that executes `remote_command` on
`target`. The password is not part of the command; [`run_authenticated`](@ref) supplies it
through standard input at execution time.
"""
function build_ssh_command(target::BridgeTarget, globals::GlobalOptions,
                           remote_command::AbstractString)::Cmd
    policy = resolve_target_policy(target, globals)
    return Cmd(String["sshpass", "-d", "0", "ssh", "-n", "-p", string(target.port),
                      "-o", "StrictHostKeyChecking=$(policy)",
                      "-o", "ConnectTimeout=$(globals.connect_timeout)",
                      "-o", "BatchMode=no",
                      "-o", "NumberOfPasswordPrompts=1",
                      "$(target.user)@$(target.host)",
                      String(remote_command)])
end

"""
    remote_output_directory(target::BridgeTarget)::String

Absolute path of the output directory of `target` on the remote host.
"""
function remote_output_directory(target::BridgeTarget)::String
    return normpath(joinpath(target.remote_dir, target.output_subdir))
end

"""
    build_probe_script(target::BridgeTarget)::String

Shell script executed on the remote host by [`probe_target`](@ref). It reports whether
`rsync` is installed and whether the base and output directories exist; every path is
POSIX-quoted.
"""
function build_probe_script(target::BridgeTarget)::String
    base_dir = Base.shell_escape_posixly(target.remote_dir)
    output_dir = Base.shell_escape_posixly(remote_output_directory(target))
    return join(["command -v rsync >/dev/null 2>&1 && echo RSYNC_OK || echo RSYNC_MISSING",
                 "test -d $(base_dir) && echo DIR_EXISTS || echo DIR_MISSING",
                 "test -d $(output_dir) && echo OUT_EXISTS || echo OUT_MISSING"], "; ")
end

"""
    probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult

Check SSH reachability of `target`, the presence of `rsync` on the remote host, and the
existence of the base and output directories. Connection and authentication failures are
reported through the result, never thrown.
"""
function probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult
    cmd = build_ssh_command(target, globals, build_probe_script(target))
    outcome = try
        run_authenticated(cmd, target.password)
    catch err
        err isa Base.IOError || rethrow()
        return ProbeResult(target, false, false, false, false, false,
                           "Spawn failure: $(sprint(showerror, err))")
    end

    ssh_ok = outcome.exitcode == 0
    rsync_ok = occursin("RSYNC_OK", outcome.stdout)
    remote_dir_exists = occursin("DIR_EXISTS", outcome.stdout)
    remote_output_dir_exists = occursin("OUT_EXISTS", outcome.stdout)

    messages = String[]
    if !ssh_ok
        push!(messages,
              "ssh exited with code $(outcome.exitcode): $(strip(outcome.stderr))")
    else
        rsync_ok || push!(messages, "rsync missing on remote")
        remote_dir_exists ||
            push!(messages, "remote base dir missing ('$(target.remote_dir)')")
        remote_output_dir_exists ||
            push!(messages,
                  "remote output dir missing ('$(remote_output_directory(target))')")
    end
    message = isempty(messages) ? "All remote diagnostics passed." : join(messages, "; ")
    return ProbeResult(target, ssh_ok && rsync_ok, ssh_ok, rsync_ok, remote_dir_exists,
                       remote_output_dir_exists, message)
end

"""
    probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}

Probe every configured target concurrently.
"""
function probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}
    check_local_binaries()
    tasks = map(config.targets) do target
        @async probe_target(target, config.globals)
    end
    return fetch.(tasks)
end

"""
    ensure_remote_directory(target::BridgeTarget, globals::GlobalOptions,
                            remote_path::AbstractString)

Create `remote_path` on `target` with `mkdir -p`. Returns `(; success, exitcode, stderr)`.
"""
function ensure_remote_directory(target::BridgeTarget, globals::GlobalOptions,
                                 remote_path::AbstractString)
    remote_command = "mkdir -p -- " * Base.shell_escape_posixly(remote_path)
    cmd = build_ssh_command(target, globals, remote_command)
    outcome = try
        run_authenticated(cmd, target.password)
    catch err
        err isa Base.IOError || rethrow()
        return (; success=false, exitcode=-1, stderr=sprint(showerror, err))
    end
    return (; success=outcome.exitcode == 0, exitcode=outcome.exitcode,
            stderr=outcome.stderr)
end

"""
    purge_path(target::BridgeTarget, scope::Symbol)::String

Remote directory removed by a purge of `target`: the output directory for
`scope == :output`, the whole project directory for `scope == :project`.
"""
function purge_path(target::BridgeTarget, scope::Symbol)::String
    if scope == :output
        return remote_output_directory(target)
    elseif scope == :project
        return target.remote_dir
    end
    return throw(ArgumentError("Purge scope must be one of $(VALID_PURGE_SCOPES) (received: :$(scope))."))
end

"""
    clean_remote_target(target::BridgeTarget, globals::GlobalOptions;
                        scope::Symbol=:output, dry_run::Bool=false)::TransferResult

Remove the directory selected by `scope` (see [`purge_path`](@ref)) on the remote host
with `rm -rf`. The path is checked with [`validate_remote_path_safety`](@ref) before any
command is issued; a refusal is reported as a failed result.
"""
function clean_remote_target(target::BridgeTarget, globals::GlobalOptions;
                             scope::Symbol=:output, dry_run::Bool=false)::TransferResult
    t_start = time()
    path = purge_path(target, scope)
    try
        validate_remote_path_safety(path, target.user)
    catch err
        err isa ArgumentError || rethrow()
        return TransferResult(target, :clean, false, -1, 0.0,
                              "Safety refusal: $(sprint(showerror, err))")
    end

    cmd = build_ssh_command(target, globals, "rm -rf -- " * Base.shell_escape_posixly(path))
    if dry_run
        return TransferResult(target, :clean, true, 0, 0.0,
                              "Dry run: $(command_string(cmd))")
    end

    outcome = try
        run_authenticated(cmd, target.password)
    catch err
        err isa Base.IOError || rethrow()
        return TransferResult(target, :clean, false, -1, time() - t_start,
                              "Spawn failure: $(sprint(showerror, err))")
    end
    duration = time() - t_start
    success = outcome.exitcode == 0
    message = success ?
              "Remote directory '$(path)' ($(scope) scope) purged in $(round(duration; digits=2)) s." :
              "rm exited with code $(outcome.exitcode): $(strip(outcome.stderr))"
    return TransferResult(target, :clean, success, outcome.exitcode, duration, message)
end

"""
    clean_all_remote_targets(config::BridgeConfig; dry_run::Bool=false)::Vector{TransferResult}

Purge the directory selected by `config.pull.purge_scope` on all configured targets
concurrently.
"""
function clean_all_remote_targets(config::BridgeConfig;
                                  dry_run::Bool=false)::Vector{TransferResult}
    dry_run || check_local_binaries()
    scope = config.pull.purge_scope
    @info "Dispatching parallel remote purge" total_targets = length(config.targets) scope = scope dry_run = dry_run
    tasks = map(config.targets) do target
        @async clean_remote_target(target, config.globals; scope=scope, dry_run=dry_run)
    end
    return fetch.(tasks)
end
