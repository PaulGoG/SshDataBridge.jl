# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Key-based targets: `auth = "key"` lets `ssh` authenticate by itself (agent, identity file, certificate, master connection) and never prompts. Its commands run with `BatchMode=yes`, and with `SSH_ASKPASS_REQUIRE=force` and an `SSH_ASKPASS` program of the package, which reach the ssh of a jump host where `BatchMode` does not: the program reports the prompt and terminates the ssh that asked, so that no prompt reaches the terminal or a desktop dialog and no empty password reaches a jump host. Key targets require OpenSSH 8.4 or newer on the workstation. A host that asks for a second factor needs a master connection opened beforehand. When a probe of a key target fails on a refused prompt, `Permission denied`, or `Host key verification failed`, the message says what was refused and names the interactive `ssh` command, with the port, identity file, and jump hosts of the target, that resolves it. `auth = "password"` is the default and behaves as before. `sshpass` is required only with a password target.
- `host` may be a Host alias of `~/.ssh/config`; host names may contain `_`.
- `identity_file` and `proxy_jump` for key targets, passed as `-i <path> -o IdentitiesOnly=yes` and `-J`. The identity file must be an absolute path or start with `~/`, contain no `'`, `%`, or `$` (ssh expands the last two), and be a regular file without group or other permissions unless it is a public key (`.pub`) selecting an agent key. A jump specification is checked hop by hop; an IPv6 address in brackets is accepted in the last hop only, because ssh passes the earlier hops to the shell unquoted. `proxy_jump = "none"` connects directly (`-o ProxyCommand=none`, which overrides a `ProxyJump` or `ProxyCommand` of `~/.ssh/config`) and is the one value a password target accepts; any other jump is refused there, since `sshpass` would answer a jump host's password prompt with the target's password.
- Before any action the driver evaluates every target with `ssh -G` and repeats the overlap rule on the host name and port that ssh will use, before `--target` narrows the run: an alias and the name it stands for no longer pass as two nodes. A password target that `~/.ssh/config` routes through a jump host is warned about. The purge pre-check uses the evaluated user.
- Ownership marker: a push claims `remote_dir` by writing `.sshdatabridge-target` with the target name, atomically by a hard link, and is refused when the marker names another target, or when a marker of another target lies in an ancestor of the physical location of `remote_dir` or below it. A marker at the root of the source tree is never transferred. A purge is refused when the marker of another target lies at the purge path, in an ancestor of its physical location, or below it. Nodes that share storage, which the overlap rule cannot see, are caught that way. A purge that finds no marker of its target proceeds and says so. The marker is excluded from harvest and verification.

### Changed

- **Breaking:** `port` and `user` are optional, and an absent `port` is no longer passed as `-p 22`: `~/.ssh/config` decides, as for every key left out. A configuration without `port` whose host matches a `Host` block with a `Port` now connects to that port.
- **Breaking:** a push that finds `remote_dir` claimed by another target fails with exit status 97, and the step before the transfer is reported as `Remote directory claim failed` instead of `Remote directory creation failed`.
- **Breaking** for library use: `BridgeTarget` has the fields `auth`, `identity_file`, and `proxy_jump`, and `port`, `user`, and `password` may be `nothing`. The keyword constructor `BridgeTarget(name, host; remote_dir, ...)` takes every field; the positional constructor still builds a password target. The filter rules of a pull begin with `--exclude=/.sshdatabridge-target`.

## [0.6.0] - 2026-11-26

### Added

- A documentation site with the configuration reference and the library API, built with Documenter from `docs/` and deployed by CI.

### Fixed

- On Julia 1.10 the output of a child process could be read before it had been copied (about once in 30 000 runs on the development machine), so a verification pass with pending items could pass as complete and let a purge run. Both streams are now read to end-of-file on every Julia version.
- A TOML syntax error on a `password` line printed that line, password included, in the error message. A syntax error is now reported by its kind and line number, without the line.
- `remote_dir` and `output_subdir` may no longer contain `*`, `?`, `[`, or `]`. rsync expands them on the node, so a push or a pull could act on a sibling directory matching the pattern while the purge, which quotes the path, removed the literal one.
- rsync runs with `-s`, so the remote path no longer passes through the remote shell. With rsync older than 3.2.4 on the workstation, or with `RSYNC_OLD_ARGS` set, a path containing a space or a shell character was split or interpreted there.
- With `output_subdir = "."`, or one ending in `/.`, and `purge_scope = "output"`, the purge path kept a trailing slash, and the purge emptied the directory behind a symbolic link that it is meant to refuse. `remote_dir` and `output_subdir` are now stored normalized: `.` segments inside the path, repeated slashes, and a trailing slash are removed.
- `/.` and `/./` passed as `remote_dir` although they name the filesystem root.
- A purge refused because the path or the home directory could not be entered failed with exit status 98 and no reason; it now states the reason.
- An exclude or include entry that rsync reads as a rule of its own (`!`, or a leading `+ ` or `- `) is refused; `excludes = [".git", "!"]` used to deploy `.git`.
- A trailing newline passed the `name`, `host`, and `user` checks; the patterns are anchored at the end of the string.
- A second `--config` silently replaced the first; it is a usage error, as the README stated.
- A configuration file its owner cannot read, one in a directory that is not searchable, and a loop of symbolic links made the driver throw instead of exiting with status 1.
- Configuration and precondition errors were printed as `Error: ArgumentError: ...`; the exception type is gone, and an unreadable configuration file is reported by its reason (`Permission denied`) alone.
- The README listed only `name` among the mandatory target keys; `host`, `user`, `password`, and `remote_dir` are mandatory as well. `bandwidth_limit` is in KiB/s, the unit of rsync's `--bwlimit`, not KB/s.

### Changed

- **Breaking:** two targets on the same host and port whose remote directories overlap, equal or one inside the other, are refused when the configuration is loaded, whatever the purge scope. A project purge of one would have removed the output of the other before it was harvested. Host names are compared without case, IP addresses by the value the C library reads. Nodes that share a filesystem are not recognized; see the limitations in the README.
- **Breaking:** a numeric `host` with a field in octal or hexadecimal notation (`192.0.2.012`, `0xc0.0.2.10`) is refused, because the C library reads such a field by another value than it shows, and so is a numeric `host` that the C library does not read as an address (`192.168.1.256`, `2001:db8:10`), which could never connect.
- **Breaking:** the default `[pull].excludes` no longer contain `core.*`. The pattern also matched result files such as `core.h5`, which a harvest then skipped and a purge destroyed. A configuration that relied on the default to skip core dumps has to list the pattern itself. A configuration copied from the earlier template lists `core.*` in `[pull].excludes` explicitly; delete the entry there, or such files stay unharvested and a purge still destroys them.
- `sandbox/run.jl` is gone. Its command-line scenarios run in the test suite, on the stub binaries the other tests use.
- `format/format.jl` no longer parses every source file before formatting, and `format/activate.jl` no longer deletes a manifest resolved by another Julia version.
- The workflows pin their actions by commit. The test run on the stable release records coverage and uploads it to Codecov.
- A local directory that cannot be created is reported as `Could not create the log directory` or `Could not prepare the local destination`, no longer as a "refusal".
- The formatting check runs in its own workflow, `Format.yml`, and the test suite runs JET on the stable Julia release only.
- README and SECURITY.md revised; the badge row lists the checks that run and reads the Julia bound from `Project.toml`.

## [0.5.0] - 2026-10-26

### Added

- `--target <name>` restricts any action to the named targets and may be repeated; an unknown name is refused before anything runs, so a pull or a purge can be rerun for the targets that failed.
- `[push].includes`: rsync include patterns applied before the `.gitignore` filter, so that a path the deployed project ignores, `Manifest.toml` in particular, can be deployed on purpose; `excludes` take precedence.

### Fixed

- A child process killed by a signal was reported as exit status 0, so a killed `sshpass` passed as a successful transfer and a killed verification pass as a complete harvest, which would have let a purge run. A signal now reports `128 + signal`.
- A bracketed IPv6 literal passed validation but could never connect, because `ssh` does not strip the brackets; brackets are refused, and rsync endpoints are bracketed by the tool.
- rsync statistics are parsed whatever thousands separator the locale inserts; `1.234.567 bytes` used to drop the summary.
- A command that could not be started is reported as a failed target with exit status -1 instead of propagating an exception; one target's exception no longer interrupts the others, which now run to completion first.

### Changed

- **Breaking:** the exported names are the configuration and result types, the two errors, `load_config`, `parse_config`, and the per-target and all-targets action functions; validators, command builders, process runners, and the purge helpers are internal. `SshDataBridge.main` is public but not exported.
- **Breaking:** `name` is mandatory for every target. It names the harvest directory and the logs, and the former positional default moved a target's data when the list was reordered.
- **Breaking:** `load_config` refuses a configuration file readable by group or others, naming its mode; create the file with `install -m 600 config.example.toml config.toml`.
- **Breaking:** `clean_remote_after_pull` combined with `includes` is refused when the configuration is loaded, and `pull --clean-remote` with include patterns exits 1 before anything runs; the former "purge skipped" outcome is gone.
- **Breaking:** the command line matches actions exactly, accepts `--clean-remote` with `pull` only and `--yes` with `pull` and `clean` only, and refuses `--config` followed by an option. `pull_target` and `pull_all_targets` take `clean_remote::Bool`, which defaults to `clean_remote_after_pull`.
- The purge runs on the node as a POSIX script under `sh -c` that refuses a symbolic link and a directory containing the account's home directory with exit status 98; the probe script runs under `sh -c` as well, so a csh login shell no longer breaks it. When a purge is requested, the driver checks the lexical path rules of every target before any transfer.
- Every ssh invocation runs with `PubkeyAuthentication=no` and `PreferredAuthentications=keyboard-interactive,password`, so an agent holding many keys cannot exhaust the server's authentication attempts and an encrypted key cannot raise a passphrase prompt that `sshpass` does not answer; the option list is built in one place for the direct commands and the rsync transport.
- The summary tables are plain text, without box drawing or icons; probe fields that depend on a failed ssh command read `unknown`.
- The configuration readers are one generic family shared with the parser's defaults, which now live in one place; error messages read `Configuration key '<section>.<key>' must be of type <T>` and `Configuration table <section> is missing the mandatory key '<key>'`.
- `require_clean_git` examines only the tree below `local_source_dir`.
- `julia format/format.jl` refuses any argument other than `--check`; `.gitignore` ignores every `.toml` file except the tracked environment files and the template; the test environment carries `[compat]` bounds, Dependabot watches it, the formatter bound is `~2.14.0`, and CI also runs `Pkg.test()` on the stable Julia job.

## [0.4.0] - 2026-10-06

### Added

- ssh keepalive, set by the `[globals]` keys `server_alive_interval` (default 15 s) and `server_alive_count_max` (default 3) and passed as `ServerAliveInterval` and `ServerAliveCountMax` to every ssh connection, the rsync transport included. A dead connection now fails the target after about a minute instead of blocking for up to two hours (the Linux TCP keepalive defaults). `server_alive_interval = 0` leaves keepalive to the ssh client configuration.

## [0.3.0] - 2026-09-23

### Added

- A purge after a pull runs only when the transfer, repeated as `rsync --dry-run --itemize-changes`, reports nothing. Otherwise, or when that pass fails, nothing is deleted and the target fails with the pending items named.
- Every push and pull appends the files it transfers to a per-target log, `local_destination_root/<name>.push.rsync.log` or `<name>.pull.rsync.log`, and the summary line reports the number of files and bytes transferred. The transfer runs with `--stats` instead of `-v`, so its standard output stays bounded whatever the size of the tree, and the log is the record of what was retrieved before a purge.

### Changed

- **Breaking:** `purge_scope` defaults to `"project"`: a configuration without the key, which purged only the output directory in 0.2.0, now removes the whole `remote_dir`, since deployed code is not meant to stay on the nodes. `--yes` and the path denylist apply as before.
- **Breaking:** `[push].local_source_dir` and `[pull].local_destination_root` are mandatory. They defaulted to the directory of the configuration file and to `data/harvested_results` below it, so a configuration that omitted them deployed the clone of this tool to every node and harvested into it. The default push excludes no longer list `data/output` and `harvested_results`, which existed only for that case.
- A pull whose requested purge was refused or failed is reported as a failed target (exit status 2) instead of a success with a remark, because the remote directory is still there.
- `scripts/run.jl`, `sandbox/run.jl`, and `test/runtests.jl` activate their environment through the `activate.jl` of that environment, so the test suite runs as `julia test/runtests.jl` without `--project`.
- README reordered: short file tree first, full tree in a collapsed section.
- Dependabot runs weekly and also watches the formatting environment.
- The comments of `config.example.toml` state the units and the accepted form of every constrained key.

### Fixed

- `Pkg.test()` failed in the sandbox scenario that spawns `scripts/run.jl`: the child inherited the load path exported by `Pkg.test`, which lacks the standard libraries. The child now starts without `JULIA_LOAD_PATH` and `JULIA_PROJECT`.
- `format/format.jl` lists the files that do not parse and exits 1, in both modes. JuliaFormatter skips such files and reports success, so a syntax error in a file no test loads used to pass CI.

## [0.2.0] - 2026-09-10

### Fixed

- `[pull].includes` now narrows the harvest. The include patterns were passed to `rsync` without a closing exclude rule, so every file was still transferred; the filter now enters every directory, keeps the matching files, drops the rest, and prunes directories left empty. Exclude patterns take precedence.
- A `pull` whose local destination cannot be created (for example because a path component is a regular file) fails that target with a message instead of aborting the whole run with an uncaught exception.

### Changed

- Duplicated target names are rejected when the configuration is loaded, because two targets with the same name would harvest concurrently into the same local directory.
- `push` refuses to start, in dry runs as well, when `local_source_dir` does not exist, instead of reporting an `rsync` failure for every target.
- The sandbox asserts the content of the summary tables, covers unreachable nodes, drains the password deterministically, and reports the probe markers only when impersonating `ssh`.
- The command-line driver moved from `scripts/run.jl` into the package as `SshDataBridge.main(args; io, err)`, which returns the exit status instead of calling `exit` and takes its output streams as arguments; the script is a thin wrapper. The sandbox and the test suite call the driver in process, so the suite no longer spawns one Julia process per scenario.
- The test environment consumes the package through a relative `[sources]` entry, which Julia 1.11 and later read directly; `test/activate.jl` still develops the package on Julia 1.10.

## [0.1.0] - 2026-09-08

### Added

- TOML-driven configuration with typed parsing, rejection of unknown keys, and validation of every target field (host grammar, POSIX user names, absolute remote directories, relative output directories).
- `probe`, `push`, `pull`, and `clean` actions executed concurrently over all targets, each ending with a per-target summary of exit code, duration, and message.
- Password delivery to `sshpass` over standard input, so credentials never appear in command lines, process environments, files, log output, or dry-run output; printed configuration and result objects mask the password.
- rsync deployment that honors the `.gitignore` of the source tree, resumable retrieval with `--partial`, and `resume`, `backup`, and `abort` strategies for existing local directories.
- Scoped remote purge (`purge_scope = "output" | "project"`) guarded by remote-path safety rules, a `--yes` confirmation flag, and automatic refusal after harvests narrowed by include patterns.
- Optional clean-git-tree requirement for deployments, evaluated in the configured source directory.
- Test suite with static analysis (Aqua, JET, ExplicitImports) and a stub-binary harness that exercises the process execution paths without network access; formatting enforced by a dedicated `format/` environment and CI job.

[Unreleased]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/PaulGoG/SshDataBridge.jl/releases/tag/v0.1.0
