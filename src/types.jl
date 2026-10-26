"""
    MissingBinaryError(binaries::Vector{String})

Thrown when required system executables are not found in `PATH`.
"""
struct MissingBinaryError <: Exception
    binaries::Vector{String}
end

function Base.showerror(io::IO, err::MissingBinaryError)
    print(io, "Required system binaries not found in PATH: ", join(err.binaries, ", "),
          ". Install them (Fedora: 'sudo dnf install sshpass rsync openssh-clients git').")
    return nothing
end

"""
    DirtyWorkingTreeError(directory::String, entries::Vector{String})

Thrown when `require_clean_git` is enabled and the git working tree at `directory` has
uncommitted changes; `entries` holds the `git status --porcelain` lines.
"""
struct DirtyWorkingTreeError <: Exception
    directory::String
    entries::Vector{String}
end

function Base.showerror(io::IO, err::DirtyWorkingTreeError)
    print(io, "Git working tree at '", err.directory, "' has ", length(err.entries),
          " uncommitted change(s) and require_clean_git is enabled:")
    for entry in err.entries
        print(io, "\n  ", entry)
    end
    return nothing
end

"""
    BridgeTarget

Immutable description of a remote compute node and its campaign directory layout.

# Fields
- `name::String`: unique label; it also names the local harvest directory.
- `host::String`: DNS hostname, IPv4 address, or IPv6 literal.
- `port::Int`: SSH daemon port in `1:65535`.
- `user::String`: remote user name.
- `password::String`: remote password; never printed by `show`.
- `remote_dir::String`: absolute base directory of the campaign on the remote host.
- `output_subdir::String`: output directory relative to `remote_dir` (default `"output"`).
- `strict_host_key_checking::Union{String, Nothing}`: optional host key policy override.

Trailing slashes of `remote_dir` and `output_subdir` are removed on construction.
"""
struct BridgeTarget
    name::String
    host::String
    port::Int
    user::String
    password::String
    remote_dir::String
    output_subdir::String
    strict_host_key_checking::Union{String, Nothing}

    function BridgeTarget(name::AbstractString,
                          host::AbstractString,
                          port::Integer,
                          user::AbstractString,
                          password::AbstractString,
                          remote_dir::AbstractString,
                          output_subdir::AbstractString="output",
                          strict_host_key_checking::Union{AbstractString, Nothing}=nothing)
        validate_bridge_target_fields(name, host, port, user, password, remote_dir,
                                      output_subdir, strict_host_key_checking)
        return new(String(name),
                   String(host),
                   Int(port),
                   String(user),
                   String(password),
                   String(rstrip(remote_dir, '/')),
                   String(rstrip(output_subdir, '/')),
                   strict_host_key_checking === nothing ? nothing :
                   String(strict_host_key_checking))
    end
end

function Base.show(io::IO, target::BridgeTarget)
    print(io, "BridgeTarget(", repr(target.name), ", ", target.user, "@", target.host, ":",
          target.port, ", remote_dir = ", repr(target.remote_dir), ", output_subdir = ",
          repr(target.output_subdir), ", password = <redacted>)")
    return nothing
end

"""
    GlobalOptions

Transport parameters shared by all targets.

# Fields
- `connect_timeout::Int`: SSH connection timeout in seconds.
- `strict_host_key_checking::String`: default host key policy (`"accept-new"`, `"yes"`, `"no"`).
- `compress::Bool`: whether `rsync` compresses in flight (`-z`).
- `bandwidth_limit::Int`: bandwidth cap in KB/s per transfer; `0` means unlimited.
- `server_alive_interval::Int`: seconds of silence from the server after which ssh sends
  a keepalive request (`ServerAliveInterval`); `0` leaves keepalive to the ssh client
  configuration.
- `server_alive_count_max::Int`: unanswered keepalive requests after which ssh drops the
  connection (`ServerAliveCountMax`).

ssh abandons a connection after `server_alive_interval * (server_alive_count_max + 1)`
seconds without an answer from the server, 60 s with the defaults, so the transfer or
remote command fails instead of blocking.
"""
struct GlobalOptions
    connect_timeout::Int
    strict_host_key_checking::String
    compress::Bool
    bandwidth_limit::Int
    server_alive_interval::Int
    server_alive_count_max::Int

    function GlobalOptions(connect_timeout::Integer=DEFAULT_CONNECT_TIMEOUT,
                           strict_host_key_checking::AbstractString=DEFAULT_HOST_KEY_POLICY,
                           compress::Bool=DEFAULT_COMPRESS,
                           bandwidth_limit::Integer=DEFAULT_BANDWIDTH_LIMIT,
                           server_alive_interval::Integer=DEFAULT_SERVER_ALIVE_INTERVAL,
                           server_alive_count_max::Integer=DEFAULT_SERVER_ALIVE_COUNT_MAX)
        validate_global_options(connect_timeout, strict_host_key_checking, bandwidth_limit,
                                server_alive_interval, server_alive_count_max)
        return new(Int(connect_timeout), String(strict_host_key_checking), compress,
                   Int(bandwidth_limit), Int(server_alive_interval),
                   Int(server_alive_count_max))
    end
end

"""
    PushOptions

Parameters of the `push` action.

# Fields
- `local_source_dir::String`: local project directory to deploy; mandatory in the configuration.
- `excludes::Vector{String}`: `rsync` exclude patterns.
- `require_clean_git::Bool`: abort when the local git working tree has uncommitted changes.
- `use_gitignore::Bool`: honor the `.gitignore` rules of the source tree during deployment.
"""
struct PushOptions
    local_source_dir::String
    excludes::Vector{String}
    require_clean_git::Bool
    use_gitignore::Bool

    function PushOptions(local_source_dir::AbstractString,
                         excludes::AbstractVector=DEFAULT_PUSH_EXCLUDES,
                         require_clean_git::Bool=DEFAULT_REQUIRE_CLEAN_GIT,
                         use_gitignore::Bool=DEFAULT_USE_GITIGNORE)
        validate_push_options(local_source_dir)
        validate_patterns(excludes, "[push].excludes")
        return new(String(local_source_dir), String[String(e) for e in excludes],
                   require_clean_git, use_gitignore)
    end
end

"""
    PullOptions

Parameters of the `pull` action.

# Fields
- `local_destination_root::String`: local root under which one directory per target is created; mandatory in the configuration. It also holds the rsync logs of every target, see [`transfer_log_path`](@ref).
- `output_subdir::String`: default output directory relative to each target's `remote_dir`.
- `includes::Vector{String}`: `rsync` include patterns; empty means everything.
- `excludes::Vector{String}`: `rsync` exclude patterns.
- `collision_strategy::Symbol`: `:resume`, `:backup`, or `:abort` when the local directory exists.
- `clean_remote_after_pull::Bool`: purge the remote directory after a verified harvest.
- `purge_scope::Symbol`: directory removed by a purge: `:project` (the whole base directory, the default) or `:output` (the output directory only).

`clean_remote_after_pull` cannot be combined with `includes`: a purge after a harvest
narrowed by include patterns would destroy the files the filter left behind.
"""
struct PullOptions
    local_destination_root::String
    output_subdir::String
    includes::Vector{String}
    excludes::Vector{String}
    collision_strategy::Symbol
    clean_remote_after_pull::Bool
    purge_scope::Symbol

    function PullOptions(local_destination_root::AbstractString,
                         output_subdir::AbstractString=DEFAULT_OUTPUT_SUBDIR,
                         includes::AbstractVector=String[],
                         excludes::AbstractVector=DEFAULT_PULL_EXCLUDES,
                         collision_strategy::Symbol=DEFAULT_COLLISION_STRATEGY,
                         clean_remote_after_pull::Bool=DEFAULT_CLEAN_REMOTE_AFTER_PULL,
                         purge_scope::Symbol=DEFAULT_PURGE_SCOPE)
        validate_pull_options(local_destination_root, output_subdir, collision_strategy,
                              purge_scope)
        validate_patterns(includes, "[pull].includes")
        validate_patterns(excludes, "[pull].excludes")
        if clean_remote_after_pull && !isempty(includes)
            throw(ArgumentError("Pull parameter 'clean_remote_after_pull' cannot be combined with 'includes': a purge after a harvest narrowed by include patterns would destroy the files the filter left behind."))
        end
        return new(String(local_destination_root),
                   String(rstrip(output_subdir, '/')),
                   String[String(i) for i in includes],
                   String[String(e) for e in excludes],
                   collision_strategy,
                   clean_remote_after_pull,
                   purge_scope)
    end
end

"""
    BridgeConfig

Complete configuration: global transport options, push and pull parameters, and the
non-empty list of targets. Target names must be unique, because each one names the
local harvest directory of its target and two targets harvested concurrently into the
same directory would overwrite each other's results.
"""
struct BridgeConfig
    globals::GlobalOptions
    push::PushOptions
    pull::PullOptions
    targets::Vector{BridgeTarget}

    function BridgeConfig(globals::GlobalOptions,
                          push::PushOptions,
                          pull::PullOptions,
                          targets::AbstractVector{BridgeTarget})
        if isempty(targets)
            throw(ArgumentError("BridgeConfig must contain at least one configured BridgeTarget."))
        end
        names = String[t.name for t in targets]
        duplicated = unique!(String[n for n in names if count(==(n), names) > 1])
        if !isempty(duplicated)
            throw(ArgumentError("Target names must be unique because each names a local harvest directory; duplicated: $(join(duplicated, ", "))."))
        end
        return new(globals, push, pull, Vector{BridgeTarget}(targets))
    end
end

"""
    ProbeResult

Outcome of `probe` on one target.

# Fields
- `target::BridgeTarget`: the probed target.
- `success::Bool`: SSH reachable and `rsync` present on the remote host.
- `ssh_ok::Bool`: the probe command exited with status zero.
- `rsync_ok::Bool`: `rsync` is installed on the remote host.
- `remote_dir_exists::Bool`: the base directory exists.
- `remote_output_dir_exists::Bool`: the output directory exists.
- `message::String`: human-readable diagnostics.
"""
struct ProbeResult
    target::BridgeTarget
    success::Bool
    ssh_ok::Bool
    rsync_ok::Bool
    remote_dir_exists::Bool
    remote_output_dir_exists::Bool
    message::String
end

"""
    TransferResult

Outcome of a push, pull, or clean action on one target.

# Fields
- `target::BridgeTarget`: the affected target.
- `action::Symbol`: `:push`, `:pull`, or `:clean`.
- `success::Bool`: whether the action completed with exit status zero.
- `exit_code::Int`: exit status of the underlying process; `-1` when it could not be spawned.
- `duration_seconds::Float64`: wall-clock duration.
- `message::String`: human-readable outcome; never contains credentials.
"""
struct TransferResult
    target::BridgeTarget
    action::Symbol
    success::Bool
    exit_code::Int
    duration_seconds::Float64
    message::String
end
