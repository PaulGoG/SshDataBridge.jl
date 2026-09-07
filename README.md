# SshDataBridge.jl

[![CI](https://github.com/PaulGoG/SshDataBridge.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/PaulGoG/SshDataBridge.jl/actions/workflows/CI.yml)

Deployment of a simulation code base to several remote compute nodes and retrieval of their results over SSH and rsync, driven by one TOML file and executed for all nodes in parallel from a single command.

```
SshDataBridge/
├── .github/
│   ├── dependabot.yml       # Monthly updates of the GitHub Actions pins
│   └── workflows/
│       ├── CI.yml           # Test matrix: Julia LTS, latest stable, pre-release
│       └── TagBot.yml       # Release tagging once the package is registered
├── .gitignore               # Credentials, harvested data, manifests
├── .JuliaFormatter.toml     # YAS style, 92 columns
├── CHANGELOG.md             # Release history
├── LICENSE                  # MIT
├── Project.toml             # Package metadata; the TOML standard library is the only dependency
├── README.md
├── SECURITY.md              # Threat model and vulnerability reporting
├── activate.jl              # Activates and instantiates the root environment
├── config.example.toml      # Annotated configuration template
├── scripts/
│   └── run.jl               # Command-line driver: probe | push | pull | clean
├── src/
│   ├── SshDataBridge.jl     # Module and exports
│   ├── validation.jl        # Field grammars and remote-path safety rules
│   ├── types.jl             # Configuration, result, and exception types
│   ├── process.jl           # Credential delivery and process execution
│   ├── config.jl            # Typed TOML parser
│   ├── probe.jl             # ssh commands: probe, mkdir, purge
│   └── transfer.jl          # rsync commands: push, pull; clean-tree check
└── test/
    ├── Project.toml         # Test environment: Aqua, JET, ExplicitImports, JuliaFormatter
    ├── activate.jl          # Activates the test environment against the local source
    └── runtests.jl          # Static analysis, unit tests, stub-binary process tests
```

## Requirements

Linux with the OpenSSH client, `sshpass`, and `rsync` on the workstation; `rsync` on every remote node; Julia 1.10 or later.

```bash
sudo dnf install sshpass rsync openssh-clients          # Fedora, RHEL
sudo apt-get install sshpass rsync openssh-client       # Debian, Ubuntu
```

## Environment

The root environment depends only on the standard library. Instantiate it once:

```bash
julia activate.jl
```

The driver script activates the environment itself, so no `--project` flag is needed. The test environment lives in `test/` and develops the package from the local source:

```bash
julia test/activate.jl
```

## Entry points

```bash
cp config.example.toml config.toml                      # then edit hosts and credentials
julia scripts/run.jl probe                              # reachability, remote rsync, directories
julia scripts/run.jl push --dry-run                     # print the rsync commands
julia scripts/run.jl push                               # deploy to all targets
julia scripts/run.jl pull                               # harvest all targets
julia scripts/run.jl pull --clean-remote --yes          # harvest, then purge the remote output directory
julia scripts/run.jl clean --yes                        # purge without harvesting
julia scripts/run.jl clean --dry-run                    # show what a purge would remove
julia --project=test test/runtests.jl                   # test suite
julia --project=test -e 'using JuliaFormatter; format(".")'   # formatter
```

`--config <path>` selects another configuration file; the default is `config.toml` next to `Project.toml`. The exit status is 0 when every target succeeded, 2 when at least one failed, and 1 on a configuration or precondition error.

## Configuration

`config.toml` is ignored by git because it holds passwords. Unknown keys and values of the wrong type are rejected before anything runs; relative local paths are resolved against the directory of the configuration file and a leading `~` expands to the home directory.

```toml
[globals]
connect_timeout = 10                  # integer > 0; units: s
strict_host_key_checking = "accept-new"   # one of: "accept-new" | "yes" | "no"
compress = true                       # rsync -z
bandwidth_limit = 0                   # integer >= 0; units: KB/s; 0 = unlimited

[push]
local_source_dir = "."                # directory deployed to every target
excludes = [".git", ".github", "*.swp", "data/output"]   # rsync exclude patterns
use_gitignore = true                  # honour the .gitignore of the source tree
require_clean_git = false             # refuse to deploy from a dirty working tree

[pull]
local_destination_root = "data/harvested_results"   # one subdirectory per target name
output_subdir = "output"              # default remote output directory, relative to remote_dir
includes = []                         # rsync include patterns; empty = everything
excludes = ["*.tmp", "core.*", "*~"]  # rsync exclude patterns
collision_strategy = "resume"         # one of: "resume" | "backup" | "abort"
clean_remote_after_pull = false       # purge after a successful harvest (needs --yes)
purge_scope = "output"                # one of: "output" | "project"

[[targets]]
name = "Cluster-Node-01"              # letters, digits, '.', '_', '-'; names the local harvest directory
host = "192.168.1.100"                # hostname, IPv4, or IPv6 literal
port = 22                             # integer in [1, 65535]
user = "scientist"
password = "example_password_1"
remote_dir = "/home/scientist/campaigns/sim_batch_01"   # absolute
output_subdir = "output"              # optional; overrides [pull].output_subdir
strict_host_key_checking = "accept-new"   # optional override
```

## Actions

**probe** runs a short shell script on every target over ssh and reports whether the host answered, whether `rsync` is installed there, and whether the base and output directories exist. Nothing is modified.

**push** creates `remote_dir` if needed and runs `rsync -av --partial` from `local_source_dir` to it. With `use_gitignore` the `.gitignore` rules of the source tree are applied through a dir-merge filter, so data, plots, and build products of the deployed project stay local without duplicating the rules in `excludes`. Files removed locally are not removed remotely, because `--delete` is deliberately not used. With `require_clean_git` the source tree must be a git working tree without uncommitted changes; the check also applies to dry runs.

**pull** retrieves `remote_dir/output_subdir/` of every target into `local_destination_root/<name>/`. `--partial` resumes interrupted transfers. When the local directory already exists, `collision_strategy` decides: `resume` reuses it, `backup` renames it to `<name>#1`, `<name>#2`, ... before creating a fresh one, `abort` fails the target.

**clean** removes the directory selected by `purge_scope` with `rm -rf`: the output directory by default, the whole `remote_dir` with `"project"`. The same purge runs after a successful pull when `--clean-remote` is given or `clean_remote_after_pull` is set. Every purge outside a dry run requires `--yes` on the command line. The path is validated first: it must be absolute, at least two components deep, free of `..`, and neither `/`, `/root`, `/home`, the user's home directory, nor anything under `/usr`, `/etc`, `/var`, and the other system directories. A purge is never issued after a harvest narrowed by `includes`, because files the filter left behind would be lost.

All targets are processed concurrently; a failure on one target does not stop the others. Each action ends with a summary table giving the exit code, duration, and message per target.

## Security model

The password of each target is read from `config.toml` into memory. Every remote command runs as `sshpass -d 0 ...`, and the package writes the password to the standard input of `sshpass`, which forwards it to the ssh password prompt. The secret is therefore never part of a command line, never in the environment of any process, and never written to a file, so `ps`, `/proc/<pid>/cmdline`, and `/proc/<pid>/environ` show nothing. Dry-run output, log lines, and the printed form of every configuration and result object omit it as well.

What remains is inherent to password authentication on a shared account: any process running as the same user can read `config.toml` and could attach to `sshpass` while it runs. Keep the file at mode 0600 and prefer key-based authentication where the nodes allow it.

Host keys follow `strict_host_key_checking`: `accept-new` (default) records a host on first contact and refuses a changed key afterwards, `yes` refuses unknown hosts, `no` disables verification and is only acceptable for throwaway test clusters. Every ssh invocation is limited to one password prompt and uses `-n`, so a remote command can never read from the local terminal.

See `SECURITY.md` for the reporting procedure.

## Limitations

- Linux only; developed on Fedora, tested in CI on Ubuntu.
- Password authentication only; ssh keys and agents are not used.
- `push` never deletes remote files.
- Targets are processed by cooperative tasks on one thread, which is sufficient because the work is bound by the network and by rsync itself.
- No retry logic; rerun the action for the targets that failed.

## License

MIT, see `LICENSE`.
