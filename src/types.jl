const DEFAULT_PUSH_EXCLUDES = String[".git", ".github", ".vscode", "*.swp", "*~",
                                     "data/output", "harvested_results"]
const DEFAULT_PULL_EXCLUDES = String["*.tmp", "core.*", "*~"]

"""
    MissingBinaryError(binaries::Vector{String})

Raised when required system executables are not found in `PATH`.
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
    BridgeTarget

Immutable description of a remote computing node and its campaign directory layout.

# Fields
- `name::String`: Unique label; it also names the local harvest directory.
- `host::String`: DNS hostname, IPv4 address, or IPv6 literal.
- `port::Int`: SSH daemon port in `1:65535`.
- `user::String`: Remote user name.
- `password::String`: Remote password; never printed by `show`.
- `remote_dir::String`: Absolute base directory of the campaign on the remote host.
- `output_subdir::String`: Output directory relative to `remote_dir` (default `"output"`).
- `strict_host_key_checking::Union{String, Nothing}`: Optional host key policy override.

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
- `strict_host_key_checking::String`: Default host key policy (`"accept-new"`, `"yes"`, `"no"`).
- `compress::Bool`: Whether `rsync` compresses in flight (`-z`).
- `bandwidth_limit::Int`: Bandwidth cap in KB/s per transfer; `0` means unlimited.
"""
struct GlobalOptions
    connect_timeout::Int
    strict_host_key_checking::String
    compress::Bool
    bandwidth_limit::Int

    function GlobalOptions(connect_timeout::Integer=10,
                           strict_host_key_checking::AbstractString="accept-new",
                           compress::Bool=true,
                           bandwidth_limit::Integer=0)
        validate_global_options(connect_timeout, strict_host_key_checking, bandwidth_limit)
        return new(Int(connect_timeout), String(strict_host_key_checking), compress,
                   Int(bandwidth_limit))
    end
end

"""
    PushOptions

Parameters of the deployment of the local source tree to the remote targets.

# Fields
- `local_source_dir::String`: Local project directory to deploy.
- `excludes::Vector{String}`: `rsync` exclude patterns.
- `require_clean_git::Bool`: Abort when the local git working tree has uncommitted changes.
- `use_gitignore::Bool`: Honour the `.gitignore` rules of the source tree during deployment.
"""
struct PushOptions
    local_source_dir::String
    excludes::Vector{String}
    require_clean_git::Bool
    use_gitignore::Bool

    function PushOptions(local_source_dir::AbstractString,
                         excludes::AbstractVector=DEFAULT_PUSH_EXCLUDES,
                         require_clean_git::Bool=false,
                         use_gitignore::Bool=true)
        validate_push_options(local_source_dir)
        validate_patterns(excludes, "[push].excludes")
        return new(String(local_source_dir), String[String(e) for e in excludes],
                   require_clean_git, use_gitignore)
    end
end

"""
    PullOptions

Parameters of the retrieval of remote output directories to the local workstation.

# Fields
- `local_destination_root::String`: Local root under which one directory per target is created.
- `output_subdir::String`: Default output directory relative to each target's `remote_dir`.
- `includes::Vector{String}`: `rsync` include patterns; empty means everything.
- `excludes::Vector{String}`: `rsync` exclude patterns.
- `collision_strategy::Symbol`: `:resume`, `:backup`, or `:abort` when the local directory exists.
- `clean_remote_after_pull::Bool`: Purge the remote directory after a successful harvest.
"""
struct PullOptions
    local_destination_root::String
    output_subdir::String
    includes::Vector{String}
    excludes::Vector{String}
    collision_strategy::Symbol
    clean_remote_after_pull::Bool

    function PullOptions(local_destination_root::AbstractString,
                         output_subdir::AbstractString="output",
                         includes::AbstractVector=String[],
                         excludes::AbstractVector=DEFAULT_PULL_EXCLUDES,
                         collision_strategy::Symbol=:resume,
                         clean_remote_after_pull::Bool=false)
        validate_pull_options(local_destination_root, output_subdir, collision_strategy)
        validate_patterns(includes, "[pull].includes")
        validate_patterns(excludes, "[pull].excludes")
        return new(String(local_destination_root),
                   String(rstrip(output_subdir, '/')),
                   String[String(i) for i in includes],
                   String[String(e) for e in excludes],
                   collision_strategy,
                   clean_remote_after_pull)
    end
end

"""
    BridgeConfig

Complete configuration: global transport options, push and pull parameters, and the
non-empty list of targets.
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
        return new(globals, push, pull, Vector{BridgeTarget}(targets))
    end
end

"""
    ProbeResult

Outcome of a pre-flight probe of one target.

# Fields
- `target::BridgeTarget`: The probed target.
- `success::Bool`: SSH reachable and `rsync` present on the remote host.
- `ssh_ok::Bool`: The probe command exited with status zero.
- `rsync_ok::Bool`: `rsync` is installed on the remote host.
- `remote_dir_exists::Bool`: The base directory exists.
- `remote_output_dir_exists::Bool`: The output directory exists.
- `message::String`: Human-readable diagnostics.
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
- `target::BridgeTarget`: The affected target.
- `action::Symbol`: `:push`, `:pull`, or `:clean`.
- `success::Bool`: Whether the action completed with exit status zero.
- `exit_code::Int`: Exit status of the underlying process; `-1` when it could not be spawned.
- `duration_seconds::Float64`: Wall-clock duration.
- `message::String`: Human-readable outcome; never contains credentials.
"""
struct TransferResult
    target::BridgeTarget
    action::Symbol
    success::Bool
    exit_code::Int
    duration_seconds::Float64
    message::String
end
