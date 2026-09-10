# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `[pull].includes` now narrows the harvest. The include patterns were passed to `rsync` without a closing exclude rule, so every file was still transferred; the filter now enters every directory, keeps the matching files, drops the rest, and prunes directories left empty. Exclude patterns take precedence.
- A `pull` whose local destination cannot be created (for example because a path component is a regular file) fails that target with a message instead of aborting the whole run with an uncaught exception.

### Changed

- Duplicated target names are rejected when the configuration is loaded, because two targets with the same name would harvest concurrently into the same local directory.
- `push` refuses to start, in dry runs as well, when `local_source_dir` does not exist, instead of reporting an `rsync` failure for every target.
- The sandbox asserts the content of the summary tables, covers unreachable nodes, drains the password deterministically, and reports the probe markers only when impersonating `ssh`.

## [0.1.0] - 2026-09-08

### Added

- TOML-driven configuration with typed parsing, rejection of unknown keys, and validation of every target field (host grammar, POSIX user names, absolute remote directories, relative output directories).
- `probe`, `push`, `pull`, and `clean` actions executed concurrently over all targets, each ending with a per-target summary of exit code, duration, and message.
- Password delivery to `sshpass` over standard input, so credentials never appear in command lines, process environments, files, log output, or dry-run output; printed configuration and result objects mask the password.
- rsync deployment that honours the `.gitignore` of the source tree, resumable retrieval with `--partial`, and `resume`, `backup`, and `abort` strategies for existing local directories.
- Scoped remote purge (`purge_scope = "output" | "project"`) guarded by remote-path safety rules, a `--yes` confirmation flag, and automatic refusal after harvests narrowed by include patterns.
- Optional clean-git-tree requirement for deployments, evaluated in the configured source directory.
- Test suite with static analysis (Aqua, JET, ExplicitImports) and a stub-binary harness that exercises the process execution paths without network access; formatting enforced by a dedicated `format/` environment and CI job.

[Unreleased]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PaulGoG/SshDataBridge.jl/releases/tag/v0.1.0
