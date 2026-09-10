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

# Stub that impersonates sshpass and, through it, ssh and rsync: every invocation is
# `sshpass -d 0 <binary> ...`, so the third argument names the impersonated binary. The
# password line that `run_authenticated` writes to standard input is consumed first, so
# the write never races the exit. Only ssh reports the remote probe markers, since only
# the probe script reads them; STUB_EXIT_CODE makes every binary fail.
const STUB_EXECUTABLE = raw"""
#!/bin/sh
IFS= read -r _ || :
code="${STUB_EXIT_CODE:-0}"
if [ "$code" -ne 0 ]; then
    printf '%s\n' "stub: connection refused" >&2
    exit "$code"
fi
if [ "$3" = "ssh" ]; then
    printf '%s\n' "RSYNC_OK" "DIR_EXISTS" "OUT_EXISTS"
fi
exit 0
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
        return withenv("PATH" => bin * ":" * get(ENV, "PATH", "")) do
            return f(config_path)
        end
    end
end

"""
    invoke_driver(arguments, config_path; exit_code = 0)

Run the driver script with `arguments` against `config_path`, capturing both streams,
with the stub binaries exiting with `exit_code`. Returns `(; exitcode, output)`.
"""
function invoke_driver(arguments::Vector{String}, config_path::AbstractString;
                       exit_code::Integer=0)
    buffer = IOBuffer()
    command = `$(Base.julia_cmd()) --startup-file=no $(DRIVER) $(arguments) --config $(config_path)`
    process = withenv("STUB_EXIT_CODE" => string(exit_code)) do
        return run(pipeline(ignorestatus(command); stdout=buffer, stderr=buffer))
    end
    return (; exitcode=process.exitcode, output=String(take!(buffer)))
end

"""
    SCENARIOS

Each entry gives the arguments, the exit status of the stub binaries, the expected exit
status of the driver, fragments (strings or regular expressions) that the output must
contain, and what the scenario demonstrates.
"""
const SCENARIOS = [(; arguments=["probe"], stub_exit=0, expected=0,
                    fragments=[r"SSH reachable:\s+YES", r"Remote rsync:\s+YES",
                               "All remote diagnostics passed."],
                    description="probe reports both stub nodes healthy"),
                   (; arguments=["push", "--dry-run"], stub_exit=0, expected=0,
                    fragments=["Dry run: sshpass -d 0 rsync", "Succeeded: 2 | Failed: 0"],
                    description="push prints its rsync command"),
                   (; arguments=["pull", "--dry-run"], stub_exit=0, expected=0,
                    fragments=["Dry run: sshpass -d 0 rsync", "Succeeded: 2 | Failed: 0"],
                    description="pull prints its rsync command"),
                   (; arguments=["clean", "--dry-run"], stub_exit=0, expected=0,
                    fragments=["Dry run: sshpass -d 0 ssh -n",
                               "rm -rf -- /home/researcher/campaigns/sandbox/data"],
                    description="clean previews the removal"),
                   (; arguments=["clean"], stub_exit=0, expected=1,
                    fragments=["re-run with --yes"],
                    description="clean refuses to delete without --yes"),
                   (; arguments=["clean", "--yes"], stub_exit=0, expected=0,
                    fragments=["purged in", "Succeeded: 2 | Failed: 0"],
                    description="clean proceeds once confirmed"),
                   (; arguments=["push"], stub_exit=0, expected=0,
                    fragments=["Deployed successfully", "Succeeded: 2 | Failed: 0"],
                    description="push completes against the stubs"),
                   (; arguments=["pull"], stub_exit=0, expected=0,
                    fragments=["Harvested successfully", "Succeeded: 2 | Failed: 0"],
                    description="pull completes against the stubs"),
                   (; arguments=["probe"], stub_exit=255, expected=2,
                    fragments=[r"SSH reachable:\s+NO", "ssh exited with code 255",
                               "connection refused"],
                    description="probe reports unreachable nodes and exits 2"),
                   (; arguments=["push"], stub_exit=255, expected=2,
                    fragments=["Remote directory creation failed",
                               "Succeeded: 0 | Failed: 2"],
                    description="push reports every failed node and exits 2"),
                   (; arguments=["nonsense"], stub_exit=0, expected=1,
                    fragments=["unknown action"],
                    description="an unknown action is rejected")]

"""
    run_sandbox(; io = stdout, verbose = true)

Run every scenario and return a vector of
`(; description, arguments, expected, exitcode, leaked, missing_fragments)`. `leaked`
reports whether the sandbox password appeared in the output, which must never happen;
`missing_fragments` lists the expected output fragments that did not appear.
"""
function run_sandbox(; io::IO=stdout, verbose::Bool=true)
    return with_sandbox() do config_path
        results = NamedTuple[]
        for scenario in SCENARIOS
            outcome = invoke_driver(scenario.arguments, config_path;
                                    exit_code=scenario.stub_exit)
            leaked = occursin(SANDBOX_PASSWORD, outcome.output)
            missing_fragments = [string(fragment)
                                 for fragment in scenario.fragments
                                 if !occursin(fragment, outcome.output)]
            push!(results,
                  (; scenario.description, arguments=join(scenario.arguments, " "),
                   scenario.expected, exitcode=outcome.exitcode, leaked,
                   missing_fragments))
            if verbose
                ok = outcome.exitcode == scenario.expected && !leaked &&
                     isempty(missing_fragments)
                println(io, rpad(ok ? "[ok]" : "[UNEXPECTED]", 14),
                        rpad(join(scenario.arguments, " "), 20), "exit ", outcome.exitcode,
                        " (expected ", scenario.expected, ")   ", scenario.description)
                for fragment in missing_fragments
                    println(io, " "^14, "missing from the output: ", fragment)
                end
            end
        end
        return results
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Running the command-line sandbox: stub binaries, throwaway configuration, no network.\n")
    results = run_sandbox()
    failures = count(r -> r.exitcode != r.expected || r.leaked ||
                          !isempty(r.missing_fragments), results)
    println("\n", length(results) - failures, " of ", length(results),
            " scenarios behaved as expected.")
    any(r -> r.leaked, results) && println("A credential leaked into the output.")
    exit(failures == 0 ? 0 : 1)
end
