# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/PaulGoG/SshDataBridge.jl/releases/tag/v0.1.0
