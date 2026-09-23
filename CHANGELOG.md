# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-09-23

### Added

- A verification pass guards every purge that follows a harvest. The transfer is repeated as `rsync --dry-run --itemize-changes`; when it still reports an item, typically because a job on the node is writing, or when the pass itself fails, nothing is deleted and the target is reported as failed with the pending items named.
- Every push and pull appends the files it transfers to a per-target log, `local_destination_root/<name>.push.rsync.log` or `<name>.pull.rsync.log`, and the summary line reports the number of files and bytes transferred. The transfer runs with `--stats` instead of `-v`, so its standard output stays bounded whatever the size of the tree, and the log is the record of what was retrieved before a purge.

### Changed

- **Breaking:** `purge_scope` defaults to `"project"`. The tool deploys code that is not meant to stay on the nodes, so a purge now removes the whole `remote_dir` unless the configuration sets `purge_scope = "output"`. A configuration without the key, which purged only the output directory in 0.2.0, now purges the project. `--yes` and the path denylist apply as before.
- **Breaking:** `[push].local_source_dir` and `[pull].local_destination_root` are mandatory. They defaulted to the directory of the configuration file and to `data/harvested_results` below it, so a configuration that omitted them deployed the clone of this tool to every node and harvested into it. The default push excludes no longer list `data/output` and `harvested_results`, which existed only for that case.
- A pull whose requested purge was refused or failed is reported as a failed target (exit status 2) instead of a success with a remark, because the remote directory is still there.
- `scripts/run.jl`, `sandbox/run.jl`, and `test/runtests.jl` activate their environment through the `activate.jl` of that environment, so the test suite runs as `julia test/runtests.jl` without `--project`.
- The README opens with a short file tree, the environment setup, the entry points, and the component status; the full tree moved into a collapsed section.
- Dependabot runs weekly and also watches the formatting environment.
- The comments of `config.example.toml` state the units and the accepted form of every constrained key.

### Fixed

- `Pkg.test()` passes. The sandbox scenario that spawns `scripts/run.jl` inherited the load path that `Pkg.test` exports, which lacks the standard libraries, so the child could not load `Pkg` and the scenario failed; the spawned driver now starts without `JULIA_LOAD_PATH` and `JULIA_PROJECT`. Running the suite as a script was not affected.
- `julia format/format.jl --check` fails when a source file does not parse. JuliaFormatter skips such a file with a warning and still reports success, so a syntax error in a file that no test loads passed the formatting job; the script now lists the files that do not parse and exits 1 before formatting, in both modes.

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
- rsync deployment that honours the `.gitignore` of the source tree, resumable retrieval with `--partial`, and `resume`, `backup`, and `abort` strategies for existing local directories.
- Scoped remote purge (`purge_scope = "output" | "project"`) guarded by remote-path safety rules, a `--yes` confirmation flag, and automatic refusal after harvests narrowed by include patterns.
- Optional clean-git-tree requirement for deployments, evaluated in the configured source directory.
- Test suite with static analysis (Aqua, JET, ExplicitImports) and a stub-binary harness that exercises the process execution paths without network access; formatting enforced by a dedicated `format/` environment and CI job.

[Unreleased]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/PaulGoG/SshDataBridge.jl/releases/tag/v0.1.0
