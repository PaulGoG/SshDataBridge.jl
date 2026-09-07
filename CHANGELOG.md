# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-07

### Added

- TOML-driven configuration with typed parsing, rejection of unknown keys, and validation of every target field (host grammar, POSIX user names, absolute remote directories, relative output directories).
- `probe`, `push`, `pull`, and `clean` actions executed concurrently over all targets, each ending with a per-target summary of exit code, duration, and message.
- Password delivery to `sshpass` over standard input, so credentials never appear in command lines, process environments, files, log output, or dry-run output; printed configuration and result objects mask the password.
- rsync deployment that honours the `.gitignore` of the source tree, resumable retrieval with `--partial`, and `resume`, `backup`, and `abort` strategies for existing local directories.
- Scoped remote purge (`purge_scope = "output" | "project"`) guarded by remote-path safety rules, a `--yes` confirmation flag, and automatic refusal after harvests narrowed by include patterns.
- Optional clean-git-tree requirement for deployments, evaluated in the configured source directory.
- Test suite with static analysis (Aqua, JET, ExplicitImports), a formatting check, and a stub-binary harness that exercises the process execution paths without network access.

[Unreleased]: https://github.com/PaulGoG/SshDataBridge.jl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PaulGoG/SshDataBridge.jl/releases/tag/v0.1.0
