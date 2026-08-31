"""
    BridgeTarget

Immutable data structure defining a remote computing node and its simulation path mapping.

# Fields
- `name::String`: Unique human-readable label identifying the target node (e.g. "RTX-5070Ti").
- `host::String`: Remote IPv4/IPv6 address or domain name.
- `port::Int`: SSH daemon port number (1 to 65535).
- `user::String`: Remote authentication username.
- `password::String`: Remote authentication password.
- `remote_dir::String`: Base directory on the remote host for code deployment and campaign root.
- `output_subdir::String`: Relative subdirectory under `remote_dir` holding output artifacts (default: "output").
- `strict_host_key_checking::Union{String, Nothing}`: Optional target-specific override for host key policy.
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
        validate_bridge_target_fields(name,
                                      host,
                                      port,
                                      user,
                                      password,
                                      remote_dir,
                                      output_subdir,
                                      strict_host_key_checking)
        return new(String(strip(name)),
                   String(strip(host)),
                   Int(port),
                   String(strip(user)),
                   String(password),
                   String(strip(remote_dir)),
                   String(strip(output_subdir)),
                   strict_host_key_checking !== nothing ?
                   String(strip(strict_host_key_checking)) : nothing)
    end
end

"""
    GlobalOptions

Global transport and SSH network connection parameters.

# Fields
- `connect_timeout::Int`: SSH TCP connection timeout in seconds.
- `strict_host_key_checking::String`: Default host key policy ("accept-new", "yes", or "no").
- `compress::Bool`: Enables rsync in-flight compression (`-z`).
- `bandwidth_limit::Int`: Network bandwidth cap in KBytes/second (0 = unlimited).
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
        return new(Int(connect_timeout),
                   String(strip(strict_host_key_checking)),
                   compress,
                   Int(bandwidth_limit))
    end
end

"""
    PushOptions

Configuration parameters governing local project deployment to remote compute nodes.

# Fields
- `local_source_dir::String`: Path to the local project folder to deploy.
- `excludes::Vector{String}`: Array of glob patterns excluded from deployment.
- `require_clean_git::Bool`: If true, aborts deployment when local git working tree is dirty.
"""
struct PushOptions
    local_source_dir::String
    excludes::Vector{String}
    require_clean_git::Bool

    function PushOptions(local_source_dir::AbstractString,
                         excludes::AbstractVector=String[".git", ".github", ".vscode",
                                                         "*.swp", "*~", "data/output",
                                                         "harvested_results"],
                         require_clean_git::Bool=false)
        validate_push_options(local_source_dir)
        return new(String(strip(local_source_dir)),
                   String[String(strip(string(e))) for e in excludes],
                   require_clean_git)
    end
end

"""
    PullOptions

Configuration parameters governing remote simulation artifact retrieval to the local workstation.

# Fields
- `local_destination_root::String`: Local root directory where harvested results are stored.
- `output_subdir::String`: Default relative output folder on remote nodes (e.g. "output").
- `includes::Vector{String}`: Glob patterns to explicitly include during rsync retrieval.
- `excludes::Vector{String}`: Glob patterns to exclude during retrieval.
- `collision_strategy::Symbol`: Conflict handling strategy (`:resume`, `:backup`, `:abort`).
- `clean_remote_after_pull::Bool`: If true, purges the remote project directory upon 100% successful harvest.
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
                         excludes::AbstractVector=String["*.tmp", "core.*", "*~"],
                         collision_strategy::Symbol=:resume,
                         clean_remote_after_pull::Bool=false)
        validate_pull_options(local_destination_root, output_subdir, collision_strategy)
        return new(String(strip(local_destination_root)),
                   String(strip(output_subdir)),
                   String[String(strip(string(i))) for i in includes],
                   String[String(strip(string(e))) for e in excludes],
                   collision_strategy,
                   clean_remote_after_pull)
    end
end

"""
    BridgeConfig

Top-level immutable configuration for SshDataBridge.
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

Structured diagnostic telemetry returned by pre-flight node connectivity checks.
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

Structured outcome report returned after executing an asynchronous push or pull action.
"""
struct TransferResult
    target::BridgeTarget
    action::Symbol
    success::Bool
    exit_code::Int
    duration_seconds::Float64
    message::String
end
