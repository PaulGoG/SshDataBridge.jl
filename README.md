# SshDataBridge.jl

Automated bidirectional SSH/rsync simulation campaign deployment and results harvesting orchestrator.

```
SshDataBridge/
├── .github/
│   └── workflows/
│       └── CI.yml           # Multi-version Julia continuous integration
├── .gitignore               # Credential, data, and cache exclusions
├── .JuliaFormatter.toml     # Formatting rules (YAS style)
├── LICENSE                  # MIT License
├── Project.toml             # Package definition and stdlib compat
├── activate.jl              # Pure-Julia root environment activation script
├── config.example.toml      # Reference TOML configuration template
├── README.md                # Package documentation and operational manual
├── src/
│   ├── SshDataBridge.jl     # Root module entry point and public exports
│   ├── types.jl             # Concrete immutable data structures
│   ├── validation.jl        # Strict parameter and schema validation logic
│   ├── config.jl            # TOML parser and path mapper
│   ├── probe.jl             # Pre-flight SSH & rsync diagnostic probes
│   └── transfer.jl          # Parallel rsync push/pull execution engine
├── scripts/
│   └── run.jl               # CLI driver script (probe | push | pull)
└── test/
    ├── Project.toml         # Test environment dependencies (Aqua, JET, etc.)
    ├── activate.jl          # Test environment activation script
    └── runtests.jl          # Static QA and unit test suite
```

---

## 1. System Requirements

- **Operating System:** Linux (Fedora, RHEL, Ubuntu, Debian)
- **Local Utilities:** OpenSSH client (`ssh`), `sshpass`, `rsync`
  ```bash
  # Fedora / RHEL:
  sudo dnf install -y sshpass rsync openssh-clients

  # Ubuntu / Debian:
  sudo apt-get update && sudo apt-get install -y sshpass rsync openssh-client
  ```
- **Remote Requirements:** `rsync` installed on remote computing nodes.
- **Julia Runtime:** Julia ≥ 1.10

---

## 2. Architectural Design & Security

### In-Memory Credential Injection
`SshDataBridge.jl` delivers authentication credentials exclusively through the process environment (`SSHPASS`) coupled with `sshpass -e`. Passwords never appear on disk, in volatile file buffers, or in process argument vectors (`/proc/*/cmdline`).

### Parallel Asynchronous Transfers
All node pushes and pulls execute concurrently using Julia tasks (`@async`). Transfer errors on any single target do not halt remaining jobs; a structured telemetry summary reports individual statuses, exit codes, and durations upon completion.

### Resumption & Bandwidth Efficiency
Results retrieval uses `rsync -avz --partial`, resuming interrupted large file downloads from the point of failure without re-transmitting completed data blocks.

---

## 3. Configuration Specification

Create `config.toml` (modeled after [`config.example.toml`](file:///path/to/workspace/SshDataBridge/config.example.toml)):

```toml
[globals]
connect_timeout = 10
strict_host_key_checking = "accept-new"
compress = true
bandwidth_limit = 0

[push]
local_source_dir = "."
excludes = [
    ".git",
    ".github",
    ".vscode",
    "*.swp",
    "data/output",
    "harvested_results",
]
require_clean_git = false

[pull]
local_destination_root = "data/harvested_results"
output_subdir = "output"
includes = []
excludes = ["*.tmp", "core.*", "*~"]
collision_strategy = "resume"
clean_remote_after_pull = false

[[targets]]
name = "Cluster-Node-01"
host = "192.168.1.100"
port = 22
user = "scientist"
password = "example_password_1"
remote_dir = "/home/scientist/campaigns/sim_batch_01"
output_subdir = "output"
```

---

## 4. Usage

### 1. Pre-Flight Diagnostic Probe
Verify network reachability, `rsync` binary presence, and remote paths across all targets:
```bash
julia --project=. scripts/run.jl probe
```

### 2. Deploy Project Code (`push`)
Deploy local project source tree to remote target base directories in parallel:
```bash
julia --project=. scripts/run.jl push
```

### 3. Harvest Simulation Results (`pull`)
Download remote output artifacts into target-specific local subdirectories in parallel:
```bash
julia --project=. scripts/run.jl pull

# Optional: Harvest and automatically purge remote project folder upon 100% success:
julia --project=. scripts/run.jl pull --clean-remote
```

### 4. Purge Remote Directories (`clean`)
Safely remove remote project directories on demand:
```bash
julia --project=. scripts/run.jl clean
```

### Dry-Run Inspection
Inspect constructed `rsync` and `ssh` commands and arguments without executing network transfers:
```bash
julia --project=. scripts/run.jl push --dry-run
julia --project=. scripts/run.jl pull --dry-run
julia --project=. scripts/run.jl clean --dry-run
```

---

## 5. Verification & Testing

Activate and run the test suite (comprising Aqua.jl static analysis, JET.jl type inference checks, ExplicitImports.jl linting, and full unit coverage):
```bash
julia test/activate.jl
julia --project=test test/runtests.jl
```

---

## 6. License

This project is licensed under the [MIT License](LICENSE).
