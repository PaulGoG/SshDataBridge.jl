module SshDataBridge

using Logging: ConsoleLogger, with_logger
using TOML: TOML

include("validation.jl")
include("types.jl")
include("process.jl")
include("config.jl")
include("probe.jl")
include("transfer.jl")
include("cli.jl")

export BridgeTarget,
       GlobalOptions,
       PushOptions,
       PullOptions,
       BridgeConfig,
       ProbeResult,
       TransferResult,
       MissingBinaryError,
       DirtyWorkingTreeError,
       load_config,
       parse_config,
       probe_target,
       probe_all_targets,
       push_target,
       push_all_targets,
       pull_target,
       pull_all_targets,
       clean_remote_target,
       clean_all_remote_targets

# `main` is the public command-line driver; it is not exported so that `using` never
# places a `main` in Main.
VERSION >= v"1.11" && eval(Expr(:public, :main))

end # module SshDataBridge
