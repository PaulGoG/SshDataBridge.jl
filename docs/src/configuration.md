```@meta
CurrentModule = SshDataBridge
```

# Configuration

One TOML file describes a campaign. It may hold passwords in plain text, so [`load_config`](@ref) refuses a file that grants any permission to group or others. Create it from the template:

```bash
install -m 600 config.example.toml config.toml
```

Unknown keys and values of the wrong type are rejected before any node is contacted, and the message names the key. Relative local paths are resolved against the directory of the configuration file, and a leading `~` expands to the home directory. `[push].local_source_dir`, `[pull].local_destination_root`, and the target keys `name`, `host`, and `remote_dir` are mandatory, and `password` for a password target; every other key has a default. `port` and `user` may be left out, and ~/.ssh/config then decides; `host` may be one of its `Host` aliases.

`auth = "password"` (the default) feeds the target's `password` to `sshpass`. `auth = "key"` supplies no secret: ssh authenticates with the agent, an identity file, a certificate, or an open master connection, and never prompts (`BatchMode=yes`, and for jump hosts an askpass program of the package that ends the ssh asking). A key target may name `identity_file`, passed as `-i <path> -o IdentitiesOnly=yes`, and `proxy_jump`, passed as `ssh -J`; a password target accepts neither, except `proxy_jump = "none"` (any letter case), which connects any target directly (`-o ProxyCommand=none`). Key targets need OpenSSH 8.4 or newer on the workstation, and a `TMPDIR` from which the askpass program can be executed (not mounted `noexec`). Options given on the ssh command line apply to the target, not to its jump hosts: `strict_host_key_checking`, `connect_timeout`, and `identity_file` do not reach a jump host, whose key, authentication, and timeout follow its own entry in `~/.ssh/config`. A session through an existing master connection is kept alive by the master's own `ServerAliveInterval`, not by `server_alive_interval`.

`remote_dir` and `output_subdir` must not contain `..` segments or the characters `*`, `?`, `[`, `]`, which rsync would expand on the node. Two targets on the same host and port must not share a `remote_dir` or nest one inside the other, whatever the `purge_scope`: a project purge of one would remove the output of the other before it is harvested, and both would be deployed into one tree. [`BridgeConfig`](@ref) checks the configured hosts; the command-line driver checks again, a dry run included, on the host name and port that `ssh -G` evaluates for every configured target as a command session ([`check_endpoint_overlaps`](@ref)). Host names are compared without case, IP addresses by the value the C library reads, as ssh does. Nodes that mount one filesystem, such as a shared `/home` on a cluster, are caught by the ownership marker that a push writes into `remote_dir` ([`claim_script`](@ref)): a push into a directory claimed by another target, or nested in or containing one, is refused (of two nested claims made at the same moment, at least one), and so is a purge that would remove another target's tree ([`purge_script`](@ref)). A numeric `host` with a field in octal or hexadecimal notation (`192.0.2.012`, `0xc0.0.2.10`) is refused, and so is one that the C library does not read as an address (`192.168.1.256`, `2001:db8:10`).

## Template

`config.example.toml` from the repository root lists every key with its constraints:

```@eval
using Markdown
using SshDataBridge
fence = "`"^3
template = read(joinpath(pkgdir(SshDataBridge), "config.example.toml"), String)
Markdown.parse(fence * "toml\n" * template * "\n" * fence)
```
