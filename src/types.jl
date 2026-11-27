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

A remote compute node and the layout of its campaign directory.

# Fields
- `name::String`: unique label; it also names the local harvest directory.
- `host::String`: DNS hostname, ssh_config `Host` alias, IPv4 address, or IPv6 literal.
- `port::Union{Nothing, Int}`: SSH daemon port in `1:65535`; `nothing` leaves it to
  ~/.ssh/config.
- `user::Union{Nothing, String}`: remote user name; `nothing` leaves it to ~/.ssh/config
  or the local account name.
- `auth::Symbol`: `:password` (the password is fed to `sshpass`) or `:key` (no secret;
  ssh authenticates by agent, identity file, certificate, or an existing master
  connection, as ~/.ssh/config provides).
- `password::Union{Nothing, String}`: remote password of a password target, `nothing`
  for a key target; never printed by `show`.
- `identity_file::Union{Nothing, String}`: private key of a key target, or a public key
  selecting an agent key, stored with a leading `~/` expanded
  (`-i <path> -o IdentitiesOnly=yes`).
- `proxy_jump::Union{Nothing, String}`: jump-host specification of a key target (`-J`),
  or `"none"` (any target; accepted in any letter case and stored as `"none"`) to connect
  directly whatever ~/.ssh/config routes (`-o ProxyCommand=none`).
- `remote_dir::String`: absolute base directory of the campaign on the remote host.
- `output_subdir::String`: output directory relative to `remote_dir` (default `"output"`).
- `strict_host_key_checking::Union{String, Nothing}`: optional host key policy override.

`remote_dir` and `output_subdir` are stored normalized: `.` segments, repeated slashes,
and trailing slashes are removed on construction, so that every command names the
directory in one spelling. An `output_subdir` that is `.` itself stays `.`, the base
directory.

# Constructors
    BridgeTarget(name, host; remote_dir, port=nothing, user=nothing, auth=:password,
                 password=nothing, identity_file=nothing, proxy_jump=nothing,
                 output_subdir="output", strict_host_key_checking=nothing)
    BridgeTarget(name, host, port, user, password, remote_dir, output_subdir="output",
                 strict_host_key_checking=nothing)

The positional form builds a password target. Every field is checked by
[`validate_bridge_target_fields`](@ref).

# Examples
```julia
BridgeTarget("node01", "node01.cluster.example", 22, "researcher", "secret",
             "/home/researcher/campaign")
BridgeTarget("cluster", "hpc"; auth=:key, remote_dir="/scratch/researcher/campaign")
```
"""
struct BridgeTarget
    name::String
    host::String
    port::Union{Nothing, Int}
    user::Union{Nothing, String}
    auth::Symbol
    password::Union{Nothing, String}
    identity_file::Union{Nothing, String}
    proxy_jump::Union{Nothing, String}
    remote_dir::String
    output_subdir::String
    strict_host_key_checking::Union{String, Nothing}

    function BridgeTarget(name::AbstractString,
                          host::AbstractString;
                          remote_dir::AbstractString,
                          port::Union{Nothing, Integer}=nothing,
                          user::Union{Nothing, AbstractString}=nothing,
                          auth::Union{Symbol, AbstractString}=:password,
                          password::Union{Nothing, AbstractString}=nothing,
                          identity_file::Union{Nothing, AbstractString}=nothing,
                          proxy_jump::Union{Nothing, AbstractString}=nothing,
                          output_subdir::AbstractString="output",
                          strict_host_key_checking::Union{Nothing, AbstractString}=nothing)
        # A string is compared before Symbol(), which throws on a NUL byte without naming the key
        if auth isa AbstractString && !(auth in ("password", "key"))
            throw(ArgumentError("Target 'auth' must be \"password\" or \"key\" (received: $(repr(auth)); target '$(name)')."))
        end
        method = Symbol(auth)
        # A password target is refused for having identity_file at all, whatever its form
        key_path = identity_file === nothing || method != :key ? identity_file :
                   expand_identity_file(identity_file, "target '$(name)'")
        # ssh reads "none" in any letter case as the keyword; "NONE" would otherwise pass as
        # a hop and reach ssh as -J NONE, which leaves a ProxyCommand of ~/.ssh/config active
        jump = proxy_jump !== nothing && lowercase(proxy_jump) == "none" ? "none" :
               proxy_jump
        validate_bridge_target_fields(name, host, port, user, method, password, key_path,
                                      jump, remote_dir, output_subdir,
                                      strict_host_key_checking)
        return new(String(name),
                   String(host),
                   port === nothing ? nothing : Int(port),
                   user === nothing ? nothing : String(user),
                   method,
                   password === nothing ? nothing : String(password),
                   key_path === nothing ? nothing : String(key_path),
                   jump === nothing ? nothing : String(jump),
                   String(rstrip(normpath(remote_dir), '/')),
                   String(rstrip(normpath(output_subdir), '/')),
                   strict_host_key_checking === nothing ? nothing :
                   String(strict_host_key_checking))
    end
end

function BridgeTarget(name::AbstractString,
                      host::AbstractString,
                      port::Integer,
                      user::AbstractString,
                      password::AbstractString,
                      remote_dir::AbstractString,
                      output_subdir::AbstractString="output",
                      strict_host_key_checking::Union{AbstractString, Nothing}=nothing)
    return BridgeTarget(name, host; remote_dir=remote_dir, port=port, user=user,
                        auth=:password, password=password, output_subdir=output_subdir,
                        strict_host_key_checking=strict_host_key_checking)
end

"""
    target_address(host::AbstractString, port::Union{Nothing, Integer},
                   user::Union{Nothing, AbstractString})::String
    target_address(target::BridgeTarget)::String

Endpoint of a target as configured, for display: `[user@]host[:port]`, each optional part
omitted when ~/.ssh/config decides it.
"""
function target_address(host::AbstractString, port::Union{Nothing, Integer},
                        user::Union{Nothing, AbstractString})::String
    return (user === nothing ? "" : user * "@") * host *
           (port === nothing ? "" : ":$(port)")
end

target_address(target::BridgeTarget)::String = target_address(target.host, target.port,
                                                              target.user)

function Base.show(io::IO, target::BridgeTarget)
    print(io, "BridgeTarget(", repr(target.name), ", ", target_address(target), ", auth = ",
          target.auth, ", remote_dir = ", repr(target.remote_dir), ", output_subdir = ",
          repr(target.output_subdir))
    target.identity_file === nothing ||
        print(io, ", identity_file = ", repr(target.identity_file))
    target.proxy_jump === nothing || print(io, ", proxy_jump = ", repr(target.proxy_jump))
    target.auth == :password && print(io, ", password = <redacted>")
    print(io, ")")
    return nothing
end

"""
    GlobalOptions

Transport parameters shared by all targets.

# Fields
- `connect_timeout::Int`: SSH connection timeout in seconds.
- `strict_host_key_checking::String`: default host key policy (`"accept-new"`, `"yes"`, `"no"`).
- `compress::Bool`: whether `rsync` compresses in flight (`-z`).
- `bandwidth_limit::Int`: bandwidth cap in KiB/s per transfer (`rsync --bwlimit`); `0` means unlimited.
- `server_alive_interval::Int`: seconds of silence from the server after which ssh sends
  a keepalive request (`ServerAliveInterval`); `0` leaves keepalive to the ssh client
  configuration.
- `server_alive_count_max::Int`: unanswered keepalive requests after which ssh drops the
  connection (`ServerAliveCountMax`).

ssh abandons a connection after `server_alive_interval * (server_alive_count_max + 1)`
seconds without an answer from the server, 60 s with the defaults, so the transfer or
remote command fails instead of blocking. A session that runs through an existing master
connection (`ControlMaster`) is kept alive by the master, whose own options govern; these
two fields do not reach it.
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
- `includes::Vector{String}`: `rsync` include patterns applied before the `.gitignore` filter, re-admitting paths the deployed project ignores; `excludes` take precedence. Empty by default.
"""
struct PushOptions
    local_source_dir::String
    excludes::Vector{String}
    require_clean_git::Bool
    use_gitignore::Bool
    includes::Vector{String}

    function PushOptions(local_source_dir::AbstractString,
                         excludes::AbstractVector=DEFAULT_PUSH_EXCLUDES,
                         require_clean_git::Bool=DEFAULT_REQUIRE_CLEAN_GIT,
                         use_gitignore::Bool=DEFAULT_USE_GITIGNORE,
                         includes::AbstractVector=String[])
        validate_push_options(local_source_dir)
        validate_patterns(excludes, "[push].excludes")
        validate_patterns(includes, "[push].includes")
        return new(String(local_source_dir), String[String(e) for e in excludes],
                   require_clean_git, use_gitignore, String[String(i) for i in includes])
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
                   String(rstrip(normpath(output_subdir), '/')),
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
same directory would overwrite each other's results. Two targets on the same host and
port must not have overlapping remote directories, equal or one inside the other,
because a project purge of one would remove the output of the other before it is
harvested, and both would be deployed into one tree. The rule does not depend on
`purge_scope`. Hosts are compared as [`node_key`](@ref) describes, IP addresses by value,
with port 22 for a target whose port ~/.ssh/config decides. This is the lexical check on
the configured values; it concerns hosts, not storage, and does not recognize an
ssh_config alias and the name it stands for, two names or addresses of one machine,
nodes that mount one filesystem, or a symbolic link or bind mount on the node. The
command-line driver repeats it on the configuration that ssh evaluates for every target
(see [`check_endpoint_overlaps`](@ref)), and the ownership marker (see
[`claim_script`](@ref), [`purge_script`](@ref)) covers nodes that share storage. The
functions that take a single target act on the target they are given.
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
        for index in eachindex(targets), other_index in (index + 1):lastindex(targets)
            target = targets[index]
            other = targets[other_index]
            if node_key(target.host, something(target.port, DEFAULT_PORT)) ==
               node_key(other.host, something(other.port, DEFAULT_PORT)) &&
               paths_overlap(target.remote_dir, other.remote_dir)
                throw(ArgumentError("Targets '$(target.name)' and '$(other.name)' are on the same host and port and their remote directories overlap ('$(target.remote_dir)' and '$(other.remote_dir)'): the purge of one would remove the output of the other before it is harvested. Use one target per project directory."))
            end
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
- `message::String`: diagnostics, as printed in the summary.
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
- `exit_code::Int`: exit status of the underlying process, or `-1` when no process produced one: the command could not be started, or the step was refused locally (unsafe purge path, unusable local directory, incomplete harvest).
- `duration_seconds::Float64`: wall-clock duration.
- `message::String`: outcome, as printed in the summary; never contains credentials.
"""
struct TransferResult
    target::BridgeTarget
    action::Symbol
    success::Bool
    exit_code::Int
    duration_seconds::Float64
    message::String
end
