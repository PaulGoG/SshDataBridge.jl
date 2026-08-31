module SshDataBridge

using TOML: TOML

include("validation.jl")
include("types.jl")
include("config.jl")
include("probe.jl")
include("transfer.jl")

export BridgeTarget,
       GlobalOptions,
       PushOptions,
       PullOptions,
       BridgeConfig,
       ProbeResult,
       TransferResult,
       load_config,
       parse_config,
       validate_bridge_target_fields,
       validate_global_options,
       validate_push_options,
       validate_pull_options,
       check_local_binaries,
       probe_target,
       probe_all_targets,
       ensure_remote_directory,
       build_push_command,
       build_pull_command,
       prepare_local_pull_directory,
       push_target,
       pull_target,
       push_all_targets,
       pull_all_targets

end # module SshDataBridge
