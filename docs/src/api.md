```@meta
CurrentModule = SshDataBridge
```

# Library API

The exported names, and `SshDataBridge.main`, which is public but not exported.

## Configuration

```@docs
load_config
parse_config
BridgeConfig
GlobalOptions
PushOptions
PullOptions
BridgeTarget
```

## Actions

```@docs
probe_target
probe_all_targets
push_target
push_all_targets
pull_target
pull_all_targets
clean_remote_target
clean_all_remote_targets
```

## Results and errors

```@docs
ProbeResult
TransferResult
MissingBinaryError
DirtyWorkingTreeError
```

## Command-line driver

```@docs
SshDataBridge.main
```
