#!/usr/bin/env julia

"""
Exercise every command-line action against stub `ssh`, `sshpass`, and `rsync`
executables and a throwaway configuration.

Nothing here touches the network, a real host, or a real credential, so the sandbox is a
safe way to confirm that the tool still behaves after a change. Run it directly:

```bash
julia sandbox/run.jl
```

The test suite includes this file and asserts the same expectations.
"""

const REPOSITORY_ROOT = dirname(@__DIR__)
const DRIVER = joinpath(REPOSITORY_ROOT, "scripts", "run.jl")

# Distinctive so that the sandbox can assert it never appears in any output.
const SANDBOX_PASSWORD = "sandbox-password-never-printed"

# Stub that impersonates ssh, sshpass, and rsync. It reports the remote directory probe as
# satisfied and exits successfully, unless STUB_EXIT_CODE says otherwise.
const STUB_EXECUTABLE = raw"""
#!/bin/sh
cat >/dev/null 2>&1 &
printf '%s\n' "RSYNC_OK"
printf '%s\n' "DIR_EXISTS"
printf '%s\n' "OUT_EXISTS"
exit "${STUB_EXIT_CODE:-0}"
"""

# Documentation addresses reserved by RFC 5737; they are never routable.
const SANDBOX_CONFIG = """
[globals]
connect_timeout = 5
strict_host_key_checking = "accept-new"
compress = true
bandwidth_limit = 0

[push]
local_source_dir = "."
excludes = [".git", "*.swp"]
use_gitignore = true
require_clean_git = false

[pull]
local_destination_root = "harvest"
output_subdir = "data"
includes = []
excludes = ["*.tmp"]
collision_strategy = "resume"
clean_remote_after_pull = false
purge_scope = "output"

[[targets]]
name = "sandbox-node-01"
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SANDBOX_PASSWORD)"
remote_dir = "/home/researcher/campaigns/sandbox"
output_subdir = "data"

[[targets]]
name = "sandbox-node-02"
host = "192.0.2.11"
port = 2222
user = "researcher"
password = "$(SANDBOX_PASSWORD)"
remote_dir = "/home/researcher/campaigns/sandbox"
"""

"""
    with_sandbox(f)

Call `f(config_path)` with stub `ssh`, `sshpass`, and `rsync` first on `PATH` and a
throwaway configuration file. Everything is removed afterwards.
"""
function with_sandbox(f)
    return mktempdir() do dir
        bin = joinpath(dir, "bin")
        mkpath(bin)
        for name in ("ssh", "sshpass", "rsync")
            path = joinpath(bin, name)
            write(path, STUB_EXECUTABLE)
            chmod(path, 0o700)
        end
        config_path = joinpath(dir, "config.toml")
        write(config_path, SANDBOX_CONFIG)
        return withenv("PATH" => bin * ":" * get(ENV, "PATH", ""),
                       "STUB_EXIT_CODE" => "0") do
            return cd(() -> f(config_path), dir)
        end
    end
end

"""
    invoke_driver(arguments, config_path)

Run the driver script with `arguments` against `config_path`, capturing both streams.
Returns `(; exitcode, output)`.
"""
function invoke_driver(arguments::Vector{String}, config_path::AbstractString)
    buffer = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no $(DRIVER) $(arguments) --config $(config_path)`
    process = run(pipeline(ignorestatus(command); stdout=buffer, stderr=buffer))
    return (; exitcode=process.exitcode, output=String(take!(buffer)))
end

"""
    SCENARIOS

Each entry is the action to run, the expected exit status, and what it demonstrates.
"""
const SCENARIOS = [(["probe"], 0, "probe reports both stub nodes healthy"),
                   (["push", "--dry-run"], 0, "push prints its rsync command"),
                   (["pull", "--dry-run"], 0, "pull prints its rsync command"),
                   (["clean", "--dry-run"], 0, "clean previews the removal"),
                   (["clean"], 1, "clean refuses to delete without --yes"),
                   (["clean", "--yes"], 0, "clean proceeds once confirmed"),
                   (["push"], 0, "push completes against the stubs"),
                   (["pull"], 0, "pull completes against the stubs"),
                   (["nonsense"], 1, "an unknown action is rejected")]

"""
    run_sandbox(; io = stdout, verbose = true)

Run every scenario and return a vector of `(; description, expected, exitcode, leaked)`.
`leaked` reports whether the sandbox password appeared in the output, which must never
happen.
"""
function run_sandbox(; io::IO=stdout, verbose::Bool=true)
    return with_sandbox() do config_path
        results = NamedTuple[]
        for (arguments, expected, description) in SCENARIOS
            outcome = invoke_driver(arguments, config_path)
            leaked = occursin(SANDBOX_PASSWORD, outcome.output)
            push!(results,
                  (; description, expected, exitcode=outcome.exitcode, leaked,
                   arguments=join(arguments, " ")))
            if verbose
                status = (outcome.exitcode == expected && !leaked) ? "ok" : "UNEXPECTED"
                println(io, rpad("[$(status)]", 14), rpad(join(arguments, " "), 20),
                        "exit ", outcome.exitcode, " (expected ", expected, ")   ",
                        description)
            end
        end
        return results
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Running the command-line sandbox: stub binaries, throwaway configuration, no network.\n")
    results = run_sandbox()
    failures = count(r -> r.exitcode != r.expected || r.leaked, results)
    println("\n", length(results) - failures, " of ", length(results),
            " scenarios behaved as expected.")
    any(r -> r.leaked, results) && println("A credential leaked into the output.")
    exit(failures == 0 ? 0 : 1)
end
