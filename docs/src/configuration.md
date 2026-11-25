```@meta
CurrentModule = SshDataBridge
```

# Configuration

One TOML file describes a campaign. It holds passwords in plain text, so [`load_config`](@ref) refuses a file that grants any permission to group or others. Create it from the template:

```bash
install -m 600 config.example.toml config.toml
```

Unknown keys and values of the wrong type are rejected before any node is contacted, and the message names the key. Relative local paths are resolved against the directory of the configuration file, and a leading `~` expands to the home directory. `[push].local_source_dir`, `[pull].local_destination_root`, and the target keys `name`, `host`, `user`, `password`, and `remote_dir` are mandatory; every other key has a default.

`remote_dir` and `output_subdir` must not contain `..` segments or the characters `*`, `?`, `[`, `]`, which rsync would expand on the node. Two targets on the same host and port must not share a `remote_dir` or nest one inside the other, whatever the `purge_scope`: a project purge of one would remove the output of the other before it is harvested, and both would be deployed into one tree. Host names are compared without case and IP addresses by value. A `host` with an address field in octal or hexadecimal notation (`192.0.2.012`, `0xc0.0.2.10`) is refused.

## Template

`config.example.toml` from the repository root lists every key with its constraints:

```@eval
using Markdown
using SshDataBridge
fence = "`"^3
template = read(joinpath(pkgdir(SshDataBridge), "config.example.toml"), String)
Markdown.parse(fence * "toml\n" * template * "\n" * fence)
```
