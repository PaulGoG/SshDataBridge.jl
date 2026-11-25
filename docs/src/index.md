```@meta
CurrentModule = SshDataBridge
```

# SshDataBridge.jl

Deploys a simulation code base to several remote compute nodes with rsync over ssh and later harvests their results, on all nodes in parallel. One TOML file describes the nodes and the paths.

The [README](https://github.com/PaulGoG/SshDataBridge.jl#readme) covers the command line: the actions `probe`, `push`, `pull`, and `clean`, their options, the rules of a purge, and the security model. These pages hold the reference: the [configuration file](configuration.md) and the [library API](api.md).

## Requirements

Linux workstation with the OpenSSH client, `sshpass`, and `rsync`. Every remote node needs `rsync` as well, version 3.0 or newer on both sides. Julia 1.10 or later.

## Installation

The package is not registered. Add it by URL:

```julia
using Pkg
Pkg.add(url="https://github.com/PaulGoG/SshDataBridge.jl")
```

To use the command-line driver, clone the repository instead and run `julia scripts/run.jl`, as the README describes.

## Use from Julia

Each action of the command line is a function that takes the loaded configuration and returns one result per target:

```julia
using SshDataBridge

config = load_config("config.toml")

probe_all_targets(config)                         # Vector{ProbeResult}
push_all_targets(config; dry_run=true)            # Vector{TransferResult} holding the rsync commands
pull_all_targets(config)
clean_all_remote_targets(config; dry_run=true)
```

[`probe_target`](@ref), [`push_target`](@ref), [`pull_target`](@ref), and [`clean_remote_target`](@ref) act on a single target. [`SshDataBridge.main`](@ref) runs the command-line driver in process and returns its exit status:

```julia
SshDataBridge.main(["probe", "--config", "config.toml"])
```

The library functions do not ask for confirmation. [`clean_remote_target`](@ref) purges when called, and [`pull_target`](@ref) purges after a verified harvest when `clean_remote_after_pull` is set. The `--yes` gate belongs to the command line.
