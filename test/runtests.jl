# Run as a script, the suite activates the test environment itself. Under Pkg.test the
# sandboxed environment is already active and PROGRAM_FILE is empty, so nothing happens.
if abspath(PROGRAM_FILE) == @__FILE__
    include(joinpath(@__DIR__, "activate.jl"))
end

using Test
using SshDataBridge
using SshDataBridge: validate_remote_path_safety, run_authenticated, command_string,
                     check_local_binaries, claim_remote_directory, purge_path,
                     build_push_command, build_pull_command, prepare_local_pull_directory,
                     assert_clean_git_tree
using Aqua
using ExplicitImports

# JET follows the compiler, and each of its release series supports only a few Julia
# minors. It runs on the stable release alone: the LTS resolves an old series, and a
# pre-release may be ahead of JET.
const RUN_JET = VERSION >= v"1.12" && isempty(VERSION.prerelease)
if RUN_JET
    using JET
end

const STUB_SCRIPT = raw"""
#!/bin/sh
case " $* " in
    " -V ")
        printf '%s\n' "${STUB_SSH_VERSION:-OpenSSH_10.2p1, stub}" >&2
        exit 0
        ;;
    *" -G "*)
        if [ -n "${STUB_ARGS_FILE:-}" ]; then
            printf '%s\n' "$*" >> "$STUB_ARGS_FILE"
        fi
        if [ -n "${STUB_G_EXIT_CODE:-}" ]; then
            printf '%s\n' "${STUB_STDERR:-stub stderr}" >&2
            exit "$STUB_G_EXIT_CODE"
        fi
        port=22
        previous=""
        for argument in "$@"; do
            if [ "$previous" = "-p" ]; then port="$argument"; fi
            previous="$argument"
        done
        destination="$previous"
        host="${destination#*@}"
        case "$destination" in
            *@*) user="${destination%%@*}" ;;
            *) user=stubuser ;;
        esac
        mapped="$host"
        oldifs="$IFS"
        IFS=','
        for pair in ${STUB_G_HOSTNAMES:-}; do
            if [ "${pair%%=*}" = "$host" ]; then mapped="${pair#*=}"; fi
        done
        IFS="$oldifs"
        printf 'hostname %s\nport %s\nuser %s\n' "$mapped" "$port" "$user"
        if [ -n "${STUB_G_PROXYJUMP:-}" ]; then
            printf 'proxyjump %s\n' "$STUB_G_PROXYJUMP"
        fi
        exit 0
        ;;
esac
if [ "$3" = "rsync" ] || [ "${0##*/}" = "rsync" ]; then
    code="${STUB_RSYNC_EXIT_CODE:-${STUB_EXIT_CODE:-0}}"
else
    code="${STUB_EXIT_CODE:-0}"
fi
out="${STUB_STDOUT:-}"
case "$*" in
    *--itemize-changes*)
        code="${STUB_VERIFY_EXIT_CODE:-$code}"
        out="${STUB_VERIFY_STDOUT:-}"
        if [ -n "${STUB_VERIFY_KILL:-}" ]; then kill -9 $$; fi
        ;;
esac
if [ -n "${STUB_ARGS_FILE:-}" ]; then
    printf '%s\n' "$*" >> "$STUB_ARGS_FILE"
fi
printf '%s\n' "$out"
printf '%s\n' "${STUB_STDERR:-stub stderr}" >&2
exit "$code"
"""

"""
    with_stub_binaries(f; exit_code, rsync_exit_code, verify_exit_code, stdout_text,
                       verify_stdout_text, stderr_text, verify_kill, g_exit_code,
                       g_hostnames, g_proxyjump, ssh_version)

Run `f(args_file)` with stub `sshpass`, `ssh`, and `rsync` executables placed first on
`PATH`. The stubs print `stdout_text` and `stderr_text`, append their argument vector to
`args_file`, and exit with `exit_code` (or `rsync_exit_code` when the third argument is
`rsync` or the stub runs as `rsync` itself, i.e. for transfer commands). The verification pass of a harvest, recognized by
`--itemize-changes`, prints `verify_stdout_text` instead and exits with
`verify_exit_code` when that is given; with `verify_kill` the verification pass kills
itself with SIGKILL. `ssh -V` prints `ssh_version` (default an OpenSSH 10.2 banner).

An invocation carrying `-G` (the evaluation of the ssh configuration) prints `hostname`,
`port`, and `user` lines and exits with 0, or with `g_exit_code` when that is given. The
hostname is the destination host mapped through `g_hostnames` (`"alias=hostname,..."`),
the port is the value after `-p` or 22, the user is that of the destination or
`stubuser`; `g_proxyjump` adds a `proxyjump` line.
"""
function with_stub_binaries(f; exit_code::Integer=0,
                            rsync_exit_code::Union{Nothing, Integer}=nothing,
                            verify_exit_code::Union{Nothing, Integer}=nothing,
                            stdout_text::AbstractString="",
                            verify_stdout_text::AbstractString="",
                            stderr_text::AbstractString="stub stderr",
                            verify_kill::Bool=false,
                            g_exit_code::Union{Nothing, Integer}=nothing,
                            g_hostnames::AbstractString="",
                            g_proxyjump::Union{Nothing, AbstractString}=nothing,
                            ssh_version::Union{Nothing, AbstractString}=nothing)
    return mktempdir() do stubdir
        for name in ("sshpass", "ssh", "rsync")
            path = joinpath(stubdir, name)
            write(path, STUB_SCRIPT)
            chmod(path, 0o700)
        end
        args_file = joinpath(stubdir, "invocations.log")
        rsync_code = rsync_exit_code === nothing ? exit_code : rsync_exit_code
        withenv("PATH" => stubdir * ":" * get(ENV, "PATH", ""),
                "STUB_EXIT_CODE" => string(exit_code),
                "STUB_RSYNC_EXIT_CODE" => string(rsync_code),
                "STUB_VERIFY_EXIT_CODE" =>
                    verify_exit_code === nothing ? nothing :
                    string(verify_exit_code),
                "STUB_STDOUT" => stdout_text,
                "STUB_VERIFY_STDOUT" => verify_stdout_text,
                "STUB_STDERR" => stderr_text,
                "STUB_VERIFY_KILL" => (verify_kill ? "1" : nothing),
                "STUB_G_EXIT_CODE" =>
                    g_exit_code === nothing ? nothing : string(g_exit_code),
                "STUB_G_HOSTNAMES" => isempty(g_hostnames) ? nothing : string(g_hostnames),
                "STUB_G_PROXYJUMP" =>
                    g_proxyjump === nothing ? nothing :
                    string(g_proxyjump),
                "STUB_SSH_VERSION" => ssh_version,
                "STUB_ARGS_FILE" => args_file) do
            return f(args_file)
        end
    end
end

# The stubs record `$*`, so a line carries no program name. The evaluations of the ssh
# configuration (`-G`) are listed apart from the remaining invocations.
is_config_query(line::AbstractString)::Bool = occursin(" -G ", " " * line)

function recorded_lines(args_file)
    return isfile(args_file) ? readlines(args_file) : String[]
end
recorded_invocations(args_file) = filter(!is_config_query, recorded_lines(args_file))
recorded_config_queries(args_file) = filter(is_config_query, recorded_lines(args_file))

function refusal_message(f)
    err = try
        f()
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    return err isa ArgumentError ? err.msg : ""
end

function contains_run(haystack::AbstractVector, needle::AbstractVector)::Bool
    n = length(needle)
    return any(i -> haystack[i:(i + n - 1)] == needle, 1:(length(haystack) - n + 1))
end

"""
    with_identity_file(f; subdirectory = "", mode = 0o600)

Run `f(path)` with `path` the absolute path of a stub key file `id_test` of the given
`mode`, placed in `subdirectory` of a temporary directory.
"""
function with_identity_file(f; subdirectory::AbstractString="", mode::Integer=0o600)
    return mktempdir() do dir
        directory = joinpath(dir, subdirectory)
        mkpath(directory)
        path = joinpath(directory, "id_test")
        write(path, "stub key\n")
        chmod(path, mode)
        return f(path)
    end
end

function key_target(identity_file; name="K1", host="hpc", remote_dir="/data/k1",
                    kwargs...)
    return BridgeTarget(name, host; remote_dir=remote_dir, auth=:key,
                        identity_file=identity_file, kwargs...)
end

function password_target(; name="P1", host="hpc", remote_dir="/data/p1", password="pw",
                         kwargs...)
    return BridgeTarget(name, host; remote_dir=remote_dir, password=password, kwargs...)
end

function pair_config(targets...)
    return BridgeConfig(GlobalOptions(), PushOptions("/x"), PullOptions("/y"),
                        collect(targets))
end

# Environment entries of a command; a command without environment has none.
cmd_environment(cmd::Cmd) = cmd.env === nothing ? String[] : String.(cmd.env)
function sets_askpass(cmd::Cmd)::Bool
    environment = cmd_environment(cmd)
    return "SSH_ASKPASS_REQUIRE=force" in environment &&
           any(startswith("SSH_ASKPASS="), environment)
end

# The purge runs as `sh -c '<script>'`, so a recorded invocation carries the quoted path
# of the script in its escaped form; the path is matched followed by its closing quote.
function purges(line::AbstractString, path::AbstractString)::Bool
    return occursin("sh -c 'p=", line) && occursin(path * "'", line) &&
           occursin("rm -rf -- \"\$p\"", line)
end

const DRIVER = joinpath(dirname(@__DIR__), "scripts", "run.jl")

# Distinctive, so that the scenarios can assert it never appears in any output.
const SCENARIO_PASSWORD = "scenario-password-never-printed"

# Documentation addresses reserved by RFC 5737; they are never routable.
const SCENARIO_CONFIG = """
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
purge_scope = "project"

[[targets]]
name = "Node-01"
host = "192.0.2.10"
port = 22
user = "researcher"
password = "$(SCENARIO_PASSWORD)"
remote_dir = "/home/researcher/campaigns/batch"
output_subdir = "data"

[[targets]]
name = "Node-02"
host = "192.0.2.11"
port = 2222
user = "researcher"
password = "$(SCENARIO_PASSWORD)"
remote_dir = "/home/researcher/campaigns/batch"
"""

"""
    invoke_driver(arguments, config_path; spawn = false)

Run the driver with `arguments` against `config_path`, capturing both streams in one
buffer. The call is made in process through `SshDataBridge.main`; with `spawn = true` a
separate Julia process runs `scripts/run.jl` instead, which covers the script wrapper
itself. The stub binaries take their exit status from the environment, which the caller
sets. Returns `(; exitcode, output)`.
"""
function invoke_driver(arguments::Vector{String}, config_path::AbstractString;
                       spawn::Bool=false)
    buffer = IOBuffer()
    full_arguments = vcat(arguments, ["--config", String(config_path)])
    if spawn
        # Pkg.test exports a load path without the standard libraries; the driver
        # activates its own environment and must not inherit it.
        command = addenv(`$(Base.julia_cmd()) --startup-file=no $(DRIVER) $(full_arguments)`,
                         "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
        # Both streams go to one pipe, read to end-of-file: on Julia 1.10 a buffer
        # handed to pipeline may still be filling when run returns.
        pipe = Pipe()
        process = run(pipeline(ignorestatus(command); stdout=pipe, stderr=pipe);
                      wait=false)
        close(pipe.in)
        write(buffer, read(pipe))
        wait(process)
        exitcode = process.exitcode
    else
        exitcode = SshDataBridge.main(full_arguments; io=buffer, err=buffer)
    end
    return (; exitcode, output=String(take!(buffer)))
end

# Each entry gives the arguments, the exit status of the stub binaries, the expected exit
# status of the driver, fragments (strings or regular expressions) that the output must
# contain, whether to spawn `scripts/run.jl` instead of calling `main` in process, and
# what the scenario demonstrates.
const DRIVER_SCENARIOS = [(; arguments=["probe"], stub_exit=0, expected=0,
                           fragments=[r"SSH reachable:\s+yes", r"Remote rsync:\s+yes",
                                      "All remote diagnostics passed."], spawn=false,
                           description="probe reports both stub nodes healthy"),
                          (; arguments=["probe", "--target", "Node-02"], stub_exit=0,
                           expected=0,
                           fragments=["probe: 1 target", "Node-02",
                                      "1 target: 1 ready, 0 not ready"], spawn=false,
                           description="--target restricts the action to one node"),
                          (; arguments=["probe", "--target", "nowhere"], stub_exit=0,
                           expected=1, fragments=["unknown target(s): nowhere"],
                           spawn=false, description="an unknown target is refused"),
                          (; arguments=["push", "--dry-run"], stub_exit=0, expected=0,
                           fragments=["Dry run: sshpass -d 0 rsync", "--stats --log-file=",
                                      "2 succeeded, 0 failed"],
                           spawn=false, description="push prints its rsync command"),
                          (; arguments=["pull", "--dry-run"], stub_exit=0, expected=0,
                           fragments=["Dry run: sshpass -d 0 rsync", "--stats --log-file=",
                                      "2 succeeded, 0 failed"],
                           spawn=false, description="pull prints its rsync command"),
                          (; arguments=["clean", "--dry-run"], stub_exit=0, expected=0,
                           fragments=["Dry run: sshpass -d 0 ssh -n",
                                      "p=/home/researcher/campaigns/batch;",
                                      "rm -rf -- \"\$p\""],
                           spawn=false, description="clean previews the removal"),
                          (; arguments=["clean"], stub_exit=0, expected=1,
                           fragments=["rerun with --yes"], spawn=false,
                           description="clean refuses to delete without --yes"),
                          (; arguments=["pull", "--clean-remote"], stub_exit=0, expected=1,
                           fragments=["rerun with --yes"], spawn=false,
                           description="a purge after a pull needs --yes"),
                          (; arguments=["clean", "--yes"], stub_exit=0, expected=0,
                           fragments=["purged in", "2 succeeded, 0 failed"], spawn=false,
                           description="clean proceeds once confirmed"),
                          (; arguments=["push"], stub_exit=0, expected=0,
                           fragments=["Deployed successfully", "Node-01.push.rsync.log",
                                      "2 succeeded, 0 failed"],
                           spawn=false, description="push completes against the stubs"),
                          (; arguments=["pull"], stub_exit=0, expected=0,
                           fragments=["Harvested successfully", "Node-01.pull.rsync.log",
                                      "2 succeeded, 0 failed"],
                           spawn=false, description="pull completes against the stubs"),
                          (; arguments=["pull", "--clean-remote", "--yes"], stub_exit=0,
                           expected=0,
                           fragments=["Harvested successfully", "(project scope) purged in",
                                      "2 succeeded, 0 failed"], spawn=false,
                           description="a verified harvest is followed by the project purge"),
                          (; arguments=["push"], stub_exit=255, expected=2,
                           fragments=["Remote directory claim failed",
                                      "0 succeeded, 2 failed"], spawn=false,
                           description="push reports every failed node and exits 2"),
                          (; arguments=["nonsense"], stub_exit=0, expected=1,
                           fragments=["unknown action"], spawn=false,
                           description="an unknown action is rejected"),
                          (; arguments=["probe"], stub_exit=255, expected=2,
                           fragments=[r"SSH reachable:\s+no", "ssh exited with code 255",
                                      "connection refused"], spawn=true,
                           description="scripts/run.jl forwards the arguments and the exit status")]

@testset "SshDataBridge.jl" begin
    @testset "Static analysis" begin
        @testset "Aqua" begin
            Aqua.test_all(SshDataBridge)
        end

        if RUN_JET
            @testset "JET" begin
                JET.test_package(SshDataBridge; target_modules=[SshDataBridge])
            end
        end

        @testset "ExplicitImports" begin
            @test ExplicitImports.check_no_implicit_imports(SshDataBridge) === nothing
            @test ExplicitImports.check_no_stale_explicit_imports(SshDataBridge) === nothing
        end
    end

    @testset "Field validation" begin
        t = BridgeTarget("Node-01", "192.168.1.50", 22, "admin", "secret", "/opt/sims/",
                         "results/", "accept-new")
        @test t.name == "Node-01"
        @test t.host == "192.168.1.50"
        @test t.port == 22
        @test t.user == "admin"
        @test t.password == "secret"
        @test t.remote_dir == "/opt/sims"
        @test t.output_subdir == "results"
        @test t.strict_host_key_checking == "accept-new"

        t_default = BridgeTarget("Node-02", "10.0.0.1", 2222, "root", "toor", "/tmp/sim")
        @test t_default.output_subdir == "output"
        @test t_default.strict_host_key_checking === nothing

        # Paths are stored in one spelling, without "." segments or doubled slashes
        respelled = BridgeTarget("Node-03", "10.0.0.1", 22, "root", "toor", "/srv//p/.",
                                 "out/./x/")
        @test respelled.remote_dir == "/srv/p"
        @test respelled.output_subdir == "out/x"

        for host in ("localhost", "node01.cluster.local", "10.0.0.1", "::1",
                     "2001:db8::10", "a-b.example.org.")
            @test BridgeTarget("N", host, 22, "u", "p", "/d/e").host == host
        end

        # An address field in octal or hexadecimal notation has another value than it
        # shows: the C library reads 192.0.2.012 and 0xc0.0.2.10 as 192.0.2.10.
        for host in ("192.0.2.012", "0xc0.0.2.10", "0300.0.2.10", "010")
            @test_throws ArgumentError BridgeTarget("N", host, 22, "u", "p", "/d/e")
        end
        # A numeric host that the C library does not read as an address can never connect
        for host in ("192.168.1.256", "1.2.3.4.5", "99999999999999999999999",
                     "2001:db8:10", "2001::db8::10", ":::")
            @test_throws ArgumentError BridgeTarget("N", host, 22, "u", "p", "/d/e")
        end
        for host in ("0xcafe.example.org", "007.example.org", "192.0.2.10", "10")
            @test BridgeTarget("N", host, 22, "u", "p", "/d/e").host == host
        end
        # A trailing dot does not turn a numeric host into a name; the C library reads no
        # address from any of these.
        for (host, reason) in (("192.0.2.012.", "octal or hexadecimal"),
                               ("0xc0.0.2.10.", "octal or hexadecimal"),
                               ("192.168.1.256.", "not an IP address"),
                               ("192.0.2.10.", "not an IP address"))
            refusal = try
                BridgeTarget("N", host, 22, "u", "p", "/d/e")
                nothing
            catch error
                error
            end
            @test refusal isa ArgumentError
            @test occursin(reason, sprint(showerror, refusal))
        end

        function valid_target(; name="N1", host="192.168.1.50", port=22, user="admin",
                              password="pass", remote_dir="/dir/sub", output_subdir="out",
                              policy=nothing)
            return BridgeTarget(name, host, port, user, password, remote_dir,
                                output_subdir, policy)
        end
        @test valid_target() isa BridgeTarget
        for name in ("", "-lead", "bad/name", "..", "a b", "x"^65, "node\n")
            @test_throws ArgumentError valid_target(; name=name)
        end
        @test valid_target(; host="my_cluster").host == "my_cluster"
        for host in ("", "192.168.1.1 0", "-bad.example", "a..b", "-my_cluster", "x"^254,
                     "bad;rm -rf /", "\$(id)", "[2001:db8::10]", "[::1", "::1]",
                     "node01\n", "::1\n")
            @test_throws ArgumentError valid_target(; host=host)
        end
        @test_throws ArgumentError valid_target(; port=0)
        @test_throws ArgumentError valid_target(; port=70000)
        for user in ("", "admin user", "-x", "a@b", "x"^33, "u;id", "admin\n")
            @test_throws ArgumentError valid_target(; user=user)
        end
        @test_throws ArgumentError valid_target(; password="")
        @test_throws ArgumentError valid_target(; password="pa\nss")
        password_error = try
            valid_target(; password="top\tsecret")
            nothing
        catch err
            err
        end
        @test password_error isa ArgumentError
        @test !occursin("secret", sprint(showerror, password_error))
        # The root in any spelling, and the characters rsync would expand on the node
        for dir in ("", "rel/dir", "/", "//", "/.", "/./", "/a/../b", "/a\nb",
                    "/data/sim_[1]", "/data/run*", "/data/run?")
            @test_throws ArgumentError valid_target(; remote_dir=dir)
        end
        for sub in ("", "/abs", "../up", "a/../b", "a\tb", "out*", "run[1]", "run?")
            @test_throws ArgumentError valid_target(; output_subdir=sub)
        end
        @test_throws ArgumentError valid_target(; policy="invalid_policy")

        g_valid = GlobalOptions(15, "yes", true, 5000)
        @test g_valid.connect_timeout == 15
        @test g_valid.strict_host_key_checking == "yes"
        @test g_valid.compress == true
        @test g_valid.bandwidth_limit == 5000
        @test g_valid.server_alive_interval == 15
        @test g_valid.server_alive_count_max == 3
        @test GlobalOptions(10, "yes", true, 0, 0, 1).server_alive_interval == 0
        @test_throws ArgumentError GlobalOptions(0, "accept-new", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "invalid_policy", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "accept-new", true, -10)
        @test_throws ArgumentError GlobalOptions(10, "accept-new", true, 0, -1, 3)
        @test_throws ArgumentError GlobalOptions(10, "accept-new", true, 0, 15, 0)

        p_valid = PushOptions("/local/src", ["*.tmp"], true, true)
        @test p_valid.local_source_dir == "/local/src"
        @test p_valid.excludes == ["*.tmp"]
        @test p_valid.require_clean_git == true
        @test p_valid.use_gitignore == true
        @test ".git" in PushOptions("/x").excludes
        @test_throws ArgumentError PushOptions("")
        @test_throws ArgumentError PushOptions("/x", [""])
        @test_throws ArgumentError PushOptions("/x", ["a\nb"])
        @test_throws ArgumentError PushOptions("/x", Any[1])
        # Entries that rsync would read as rules of their own, not as patterns
        @test_throws ArgumentError PushOptions("/x", [".git", "!"])
        @test_throws ArgumentError PushOptions("/x", ["+ x.tmp"])
        @test_throws ArgumentError PullOptions("/x", "output", ["- keep.txt"])
        @test isempty(PushOptions("/x").includes)
        @test PushOptions("/x", String[], false, true, ["/Manifest.toml"]).includes ==
              ["/Manifest.toml"]
        @test_throws ArgumentError PushOptions("/x", String[], false, true, [""])

        pull_valid = PullOptions("/local/dest", "output_dir", ["*.csv"], ["*.tmp"],
                                 :backup, false)
        @test pull_valid.local_destination_root == "/local/dest"
        @test pull_valid.output_subdir == "output_dir"
        @test pull_valid.includes == ["*.csv"]
        @test pull_valid.excludes == ["*.tmp"]
        @test pull_valid.collision_strategy == :backup
        @test pull_valid.clean_remote_after_pull == false
        @test PullOptions("/x").excludes == SshDataBridge.DEFAULT_PULL_EXCLUDES
        @test PullOptions("/x").purge_scope == :project
        @test PullOptions("/x", "output", String[], String[], :resume, false,
                          :output).purge_scope == :output
        @test_throws ArgumentError PullOptions("/x", "output", String[], String[], :resume,
                                               false, :everything)
        @test PullOptions("/x", "out/").output_subdir == "out"
        @test_throws ArgumentError PullOptions("")
        @test_throws ArgumentError PullOptions("/local/dest", "")
        @test_throws ArgumentError PullOptions("/local/dest", "/abs")
        @test_throws ArgumentError PullOptions("/local/dest", "../up")
        @test_throws ArgumentError PullOptions("/local/dest", "output", String[],
                                               String[], :invalid_strategy)
        @test_throws ArgumentError PullOptions("/local/dest", "output", [""])
        @test_throws ArgumentError PullOptions("/x", "output", ["*.csv"], String[],
                                               :resume, true)

        for path in ("/home/user/campaigns/sim01", "/scratch/worker/batch1",
                     "/data/sims/run1", "/tmp/campaign", "/mnt/data/x", "/home/user/x")
            @test validate_remote_path_safety(path, "user") === nothing
        end
        for path in ("", "/", "//", "/root", "/home", "/home/user", "/home/user/", "~",
                     "relative/path", "/single", "/usr/lib", "/etc/ssh", "/var/lib/x",
                     "/opt/x", "/home/user/../other/y", "/a/b\n")
            @test_throws ArgumentError validate_remote_path_safety(path, "user")
        end

        @test occursin("git", sprint(showerror, MissingBinaryError(["git"])))
    end

    @testset "Configuration parsing" begin
        toml_content = """
        [globals]
        connect_timeout = 20
        strict_host_key_checking = "yes"
        compress = false
        bandwidth_limit = 1024
        server_alive_interval = 30
        server_alive_count_max = 4

        [push]
        local_source_dir = "./src_payload"
        excludes = [".git", "data/output"]
        includes = ["/Manifest.toml"]
        require_clean_git = true

        [pull]
        local_destination_root = "./harvested_data"
        output_subdir = "results"
        includes = ["*.jld2", "*.csv"]
        excludes = ["*.tmp"]
        collision_strategy = "backup"
        clean_remote_after_pull = false
        purge_scope = "project"

        [[targets]]
        name = "GPU-Worker-1"
        host = "worker01.cluster.local"
        port = 2201
        user = "researcher"
        password = "secret_pass_1"
        remote_dir = "/scratch/simulations/batch_01"
        output_subdir = "out_custom"

        [[targets]]
        name = "GPU-Worker-2"
        host = "worker02.cluster.local"
        port = 2202
        user = "researcher"
        password = "secret_pass_2"
        remote_dir = "/scratch/simulations/batch_01"
        strict_host_key_checking = "accept-new"
        """

        mktemp() do path, io
            write(io, toml_content)
            close(io)

            config = load_config(path)
            @test config.globals.connect_timeout == 20
            @test config.globals.strict_host_key_checking == "yes"
            @test config.globals.compress == false
            @test config.globals.bandwidth_limit == 1024
            @test config.globals.server_alive_interval == 30
            @test config.globals.server_alive_count_max == 4

            @test occursin("src_payload", config.push.local_source_dir)
            @test config.push.excludes == [".git", "data/output"]
            @test config.push.includes == ["/Manifest.toml"]
            @test config.push.require_clean_git == true

            @test occursin("harvested_data", config.pull.local_destination_root)
            @test config.pull.output_subdir == "results"
            @test config.pull.includes == ["*.jld2", "*.csv"]
            @test config.pull.excludes == ["*.tmp"]
            @test config.pull.collision_strategy == :backup
            @test config.pull.clean_remote_after_pull == false
            @test config.pull.purge_scope == :project

            @test length(config.targets) == 2
            t1 = config.targets[1]
            @test t1.name == "GPU-Worker-1"
            @test t1.host == "worker01.cluster.local"
            @test t1.port == 2201
            @test t1.user == "researcher"
            @test t1.password == "secret_pass_1"
            @test t1.remote_dir == "/scratch/simulations/batch_01"
            @test t1.output_subdir == "out_custom"
            @test t1.strict_host_key_checking === nothing

            t2 = config.targets[2]
            @test t2.name == "GPU-Worker-2"
            @test t2.host == "worker02.cluster.local"
            @test t2.port == 2202
            @test t2.output_subdir == "results"
            @test t2.strict_host_key_checking == "accept-new"

            # Credentials never appear in the printed representation of the configuration
            @test !occursin("secret_pass", repr(config))
            @test !occursin("secret_pass", sprint(show, MIME("text/plain"), config))
        end

        @test_throws ArgumentError parse_config(Dict{String, Any}("globals" => Dict()))
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" => Any[]))

        # Malformed TOML, unknown keys, wrong types, and missing mandatory keys fail fast
        mktemp() do path, io
            write(io, "[globals]\nconnect_timeout = [1,\n")
            close(io)
            @test_throws ArgumentError load_config(path)
        end

        # A syntax error is reported by kind and line number. The line itself is never
        # echoed: it may be the password line, or a password pasted without its key. No
        # parser error stays on the exception stack as a cause either, because the
        # display of an uncaught error prints causes, and that of a parser error prints
        # the line.
        head = "[[targets]]\nname = \"N1\"\n"
        for (text, line) in
            ((head * "host = \"10.0.0.1\"\nuser = \"u\"\npassword = \"never-echoed\" x\n",
              5),
             (head * "password = \"never-echoed\n", 3),
             (head * "never-echoed\nhost = \"10.0.0.1\"\n", 3),
             (head * "= 1\n", 3),
             ("[globals\n", 1))
            mktemp() do path, io
                write(io, text)
                close(io)
                syntax_error = try
                    load_config(path)
                    nothing
                catch err
                    err
                end
                @test syntax_error isa ArgumentError
                @test occursin("near line $(line).", sprint(showerror, syntax_error))
                @test !occursin("never-echoed", sprint(showerror, syntax_error))
                causes = try
                    load_config(path)
                    0
                catch
                    length(current_exceptions())
                end
                @test causes == 1
            end
        end

        # A file its owner cannot read is a configuration error, not a crash. Root reads
        # any file, so the case is skipped there.
        mktemp() do path, io
            close(io)
            chmod(path, 0o000)
            denied = try
                open(close, path)
                nothing
            catch err
                err isa SystemError || rethrow()
                err
            end
            if denied === nothing
                @test_skip "unreadable configuration file"
            else
                @test_throws ArgumentError load_config(path)
                err = IOBuffer()
                @test SshDataBridge.main(["probe", "--config", path]; io=IOBuffer(),
                                         err=err) == 1
                message = String(take!(err))
                # The reason is the C library's text, in the locale of the process
                @test occursin("cannot be read: $(Libc.strerror(denied.errnum)).", message)
                @test !occursin("SystemError", message)
            end
        end
        # A path that cannot be inspected is a configuration error as well: a loop of
        # symbolic links, and a file in a directory that is not searchable (skipped for
        # root, which searches any directory).
        mktempdir() do dir
            loop = joinpath(dir, "loop.toml")
            symlink(loop, loop)
            locked = joinpath(dir, "locked")
            mkdir(locked)
            inside = joinpath(locked, "config.toml")
            write(inside, "")
            chmod(inside, 0o600)
            chmod(locked, 0o000)
            searchable = try
                isfile(joinpath(locked, "absent"))
                true
            catch err
                err isa Base.IOError || rethrow()
                false
            end
            searchable && @test_skip "configuration file in an unsearchable directory"
            cases = searchable ? [(loop, Libc.ELOOP)] :
                    [(loop, Libc.ELOOP), (inside, Libc.EACCES)]
            for (path, errno) in cases
                causes = try
                    load_config(path)
                    0
                catch err
                    @test err isa ArgumentError
                    length(current_exceptions())
                end
                @test causes == 1
                err = IOBuffer()
                @test SshDataBridge.main(["probe", "--config", path]; io=IOBuffer(),
                                         err=err) == 1
                message = String(take!(err))
                @test occursin("cannot be read: $(Libc.strerror(errno)).", message)
                @test !occursin("IOError", message)
            end
            chmod(locked, 0o700)
        end
        @test_throws ArgumentError load_config(joinpath(@__DIR__, "does-not-exist.toml"))

        minimal_target() = Dict{String, Any}("name" => "N1", "host" => "10.0.0.1",
                                             "user" => "u", "password" => "p",
                                             "remote_dir" => "/a/b")
        function minimal_config(; push=Dict{String, Any}(), pull=Dict{String, Any}(),
                                targets=Any[minimal_target()],
                                extra=Dict{String, Any}())
            sections = Dict{String, Any}("push" =>
                                             merge(Dict{String, Any}("local_source_dir" => "src"),
                                                   push),
                                         "pull" =>
                                             merge(Dict{String, Any}("local_destination_root" => "harvest"),
                                                   pull),
                                         "targets" => targets)
            return merge(sections, extra)
        end

        # Target names must be unique because they name the local harvest directories
        twin(name) = Dict{String, Any}("name" => name, "host" => "10.0.0.1", "user" => "u",
                                       "password" => "p", "remote_dir" => "/a/" * name)
        duplicate_error = try
            parse_config(minimal_config(;
                                        targets=Any[twin("Node"), twin("Other"),
                                                    twin("Node")]))
            nothing
        catch err
            err
        end
        @test duplicate_error isa ArgumentError
        @test occursin("duplicated: Node.", sprint(showerror, duplicate_error))
        @test parse_config(minimal_config(; targets=Any[twin("Node"), twin("Other")])) isa
              BridgeConfig
        same = BridgeTarget("Node", "10.0.0.1", 22, "u", "p", "/a/b")
        @test_throws ArgumentError BridgeConfig(GlobalOptions(), PushOptions("/x"),
                                                PullOptions("/y"), [same, same])
        @test_throws ArgumentError parse_config(minimal_config(;
                                                               pull=Dict{String, Any}("purge_scope" => "everything")))

        function config_error(dict)
            return try
                parse_config(dict)
                nothing
            catch err
                err
            end
        end
        function config_error_message(dict)
            err = config_error(dict)
            @test err isa ArgumentError
            return err isa ArgumentError ? err.msg : ""
        end
        function config_error_message_of(f)
            err = try
                f()
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            return err isa ArgumentError ? err.msg : ""
        end

        # Two targets on one host and port must not have overlapping remote directories
        node(name, host, port, dir) = BridgeTarget(name, host, port, "u", "p", dir)
        function paired(first_target, second_target)
            return BridgeConfig(GlobalOptions(), PushOptions("/x"), PullOptions("/y"),
                                [first_target, second_target])
        end
        overlap_message = config_error_message_of() do
            return paired(node("A", "10.0.0.1", 22, "/a/b"),
                          node("B", "10.0.0.1", 22, "/a/b"))
        end
        @test occursin("'A'", overlap_message)
        @test occursin("'B'", overlap_message)
        @test occursin("overlap", overlap_message)
        # One inside the other
        @test_throws ArgumentError paired(node("A", "10.0.0.1", 22, "/a/b"),
                                          node("B", "10.0.0.1", 22, "/a/b/c"))
        # In either order
        @test_throws ArgumentError paired(node("A", "10.0.0.1", 22, "/a/b/c"),
                                          node("B", "10.0.0.1", 22, "/a/b"))
        # One directory in two spellings
        @test_throws ArgumentError paired(node("A", "10.0.0.1", 22, "/a/b/"),
                                          node("B", "10.0.0.1", 22, "/a//b/."))
        # Host case and trailing dot
        @test_throws ArgumentError paired(node("A", "Node01.Example.org", 22, "/a/b"),
                                          node("B", "node01.example.org.", 22, "/a/b"))
        # Sibling with a common name prefix
        @test paired(node("A", "10.0.0.1", 22, "/a/b"),
                     node("B", "10.0.0.1", 22, "/a/bc")) isa BridgeConfig
        # Disjoint directories
        @test paired(node("A", "10.0.0.1", 22, "/a/b"),
                     node("B", "10.0.0.1", 22, "/a/c")) isa BridgeConfig
        # Another port is another node
        @test paired(node("A", "10.0.0.1", 22, "/a/b"),
                     node("B", "10.0.0.1", 2222, "/a/b")) isa BridgeConfig
        # Another host
        @test paired(node("A", "10.0.0.1", 22, "/a/b"),
                     node("B", "10.0.0.2", 22, "/a/b")) isa BridgeConfig
        # One address in two spellings is one node. The IPv6 pairs are equal by RFC 5952;
        # the C library reads the mapped and the shortened IPv4 forms as 192.0.2.10
        # (`getent ahosts`).
        for (first_host, second_host) in (("2001:db8::10", "2001:db8:0:0:0:0:0:10"),
                                          ("2001:DB8::10", "2001:0db8::0010"),
                                          ("::ffff:192.0.2.10", "192.0.2.10"),
                                          ("::ffff:c000:20a", "192.0.2.10"),
                                          ("64:ff9b::192.0.2.10", "64:ff9b::c000:20a"),
                                          ("192.0.522", "192.0.2.10"),
                                          ("3221225994", "192.0.2.10"))
            @test_throws ArgumentError paired(node("A", first_host, 22, "/a/b"),
                                              node("B", second_host, 22, "/a/b"))
        end
        # Different addresses and different names stay different nodes
        for (first_host, second_host) in (("2001:db8::10", "2001:db8::11"),
                                          ("192.0.2.10", "192.0.2.11"),
                                          ("::ffff:192.0.2.10", "192.0.2.11"),
                                          ("node10", "node11"))
            @test paired(node("A", first_host, 22, "/a/b"),
                         node("B", second_host, 22, "/a/b")) isa BridgeConfig
        end
        # The rule holds for either purge scope
        scoped = PullOptions("/y", "output", String[], String[], :resume, false, :output)
        @test_throws ArgumentError BridgeConfig(GlobalOptions(), PushOptions("/x"), scoped,
                                                [BridgeTarget("A", "10.0.0.1", 22, "u", "p",
                                                              "/a/b", "first"),
                                                 BridgeTarget("B", "10.0.0.1", 22, "u", "p",
                                                              "/a/b", "second")])
        # The parser refuses the same overlap
        overlapping = Any[merge(minimal_target(), Dict("name" => "One")),
                          merge(minimal_target(), Dict("name" => "Two"))]
        @test_throws ArgumentError parse_config(minimal_config(; targets=overlapping))

        @test parse_config(minimal_config()) isa BridgeConfig
        # A purge removes the whole project unless the configuration narrows it
        @test parse_config(minimal_config()).pull.purge_scope == :project
        # No default exclude may match a result file: a purge destroys what the excludes
        # leave
        @test parse_config(minimal_config()).pull.excludes == ["*.tmp", "*~"]
        @test PullOptions("/y").excludes == ["*.tmp", "*~"]
        # The default output directory is stored in the spelling the targets use
        @test PullOptions("/y", "out/.").output_subdir == "out"
        @test PullOptions("/y", "./").output_subdir == "."
        # The tracked template agrees with the default excludes
        parsed = SshDataBridge.TOML.parsefile(joinpath(dirname(@__DIR__),
                                                       "config.example.toml"))
        @test parsed["pull"]["excludes"] == ["*.tmp", "*~"]
        # ssh keepalive is on unless the configuration disables it
        @test parse_config(minimal_config()).globals.server_alive_interval == 15
        @test parse_config(minimal_config()).globals.server_alive_count_max == 3
        @test occursin("server_alive_interval",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("globals" =>
                                                                                       Dict{String,
                                                                                            Any}("server_alive_interval" =>
                                                                                                     true)))))
        @test occursin("server_alive_count_max",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("globals" =>
                                                                                       Dict{String,
                                                                                            Any}("server_alive_count_max" =>
                                                                                                     0)))))
        @test occursin("'typo'",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("typo" =>
                                                                                       1))))
        @test occursin("[pull]",
                       config_error_message(minimal_config(;
                                                           pull=Dict{String, Any}("purge_scopes" => "output"))))
        @test occursin("[[targets]] entry #1",
                       config_error_message(minimal_config(;
                                                           targets=Any[merge(minimal_target(),
                                                                             Dict("hostname" => "x"))])))
        @test occursin("must be of type Integer",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("globals" =>
                                                                                       Dict{String,
                                                                                            Any}("connect_timeout" => "10")))))
        @test occursin("must be of type Integer",
                       config_error_message(minimal_config(;
                                                           targets=Any[merge(minimal_target(),
                                                                             Dict("port" =>
                                                                                      true))])))
        @test occursin("must be of type Bool",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("globals" =>
                                                                                       Dict{String,
                                                                                            Any}("compress" =>
                                                                                                     1)))))
        @test occursin("must be of type AbstractString",
                       config_error_message(minimal_config(;
                                                           pull=Dict{String, Any}("purge_scope" =>
                                                                                      3))))
        @test occursin("must be of type AbstractVector",
                       config_error_message(minimal_config(;
                                                           push=Dict{String, Any}("excludes" => "x"))))
        @test occursin("entry #2 must be a string",
                       config_error_message(minimal_config(;
                                                           push=Dict{String, Any}("excludes" =>
                                                                                      Any["a",
                                                                                          2]))))
        @test occursin("'globals' must be of type AbstractDict",
                       config_error_message(minimal_config(;
                                                           extra=Dict{String, Any}("globals" =>
                                                                                       5))))
        @test occursin("array of [[targets]] tables",
                       config_error_message(minimal_config(; targets="x")))
        @test occursin("entry #1 is not a table",
                       config_error_message(minimal_config(; targets=Any[1])))
        for mandatory in ("name", "host", "remote_dir")
            incomplete = minimal_target()
            delete!(incomplete, mandatory)
            message = config_error_message(minimal_config(; targets=Any[incomplete]))
            @test occursin("[[targets]] entry #1 is missing the mandatory key '$(mandatory)'",
                           message)
        end
        # The password is mandatory with auth = "password" only
        without_password = minimal_target()
        delete!(without_password, "password")
        @test occursin("mandatory with auth = \"password\"",
                       config_error_message(minimal_config(;
                                                           targets=Any[without_password])))
        # The user is optional: ssh resolves it from its configuration
        without_user = minimal_target()
        delete!(without_user, "user")
        user_less = parse_config(minimal_config(; targets=Any[without_user])).targets[1]
        @test user_less.user === nothing
        @test user_less.port === nothing

        # Relative local paths resolve against the configuration directory; ~ expands
        resolved = parse_config(minimal_config(;
                                               push=Dict{String, Any}("local_source_dir" => "src"),
                                               pull=Dict{String, Any}("local_destination_root" => "~/harvest"));
                                config_dir="/cfg/dir")
        @test resolved.push.local_source_dir == "/cfg/dir/src"
        @test resolved.pull.local_destination_root == joinpath(homedir(), "harvest")
        @test resolved.targets[1].name == "N1"
        # An absent port or user is left to the ssh configuration
        @test resolved.targets[1].port === nothing
        @test resolved.targets[1].user == "u"

        # The local paths are mandatory: nothing deploys or harvests into the directory
        # of the tool by omission
        for (section, key) in (("push", "local_source_dir"),
                               ("pull", "local_destination_root"))
            without = minimal_config()
            delete!(without[section], key)
            @test occursin("[$(section)] is missing the mandatory key '$(key)'",
                           config_error_message(without))
        end
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" =>
                                                                      Any[minimal_target()]))

        # The template must satisfy the schema it documents
        mktemp() do path, io
            write(io, read(joinpath(pkgdir(SshDataBridge), "config.example.toml"), String))
            close(io)
            @test load_config(path) isa BridgeConfig
        end

        # A configuration readable by others is refused before it is parsed
        mktemp() do path, io
            write(io, toml_content)
            close(io)
            chmod(path, 0o644)
            @test occursin("mode 644", config_error_message_of(() -> load_config(path)))
        end
    end

    @testset "Git working-tree requirement" begin
        mktempdir() do no_git
            withenv("PATH" => no_git) do
                @test_throws MissingBinaryError assert_clean_git_tree(no_git)
            end
        end

        if Sys.which("git") === nothing
            @warn "git is not available; skipping working-tree checks"
        else
            mktempdir() do plain
                @test_throws ArgumentError assert_clean_git_tree(plain)
                @test_throws ArgumentError assert_clean_git_tree(joinpath(plain, "missing"))
            end

            mktempdir() do repo
                run(pipeline(`git -C $repo init -q`; stdout=devnull, stderr=devnull))
                @test assert_clean_git_tree(repo) === nothing

                write(joinpath(repo, "untracked.txt"), "x")
                dirty_error = try
                    assert_clean_git_tree(repo)
                    nothing
                catch err
                    err
                end
                @test dirty_error isa DirtyWorkingTreeError
                @test any(occursin("untracked.txt", e) for e in dirty_error.entries)
                @test occursin("untracked.txt", sprint(showerror, dirty_error))

                globals = GlobalOptions()
                target = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "pw", "/rem/sim")
                pull_opts = PullOptions("/local/dst")
                dirty_config = BridgeConfig(globals, PushOptions(repo, String[], true),
                                            pull_opts, [target])
                @test_throws DirtyWorkingTreeError push_all_targets(dirty_config;
                                                                    dry_run=true)

                rm(joinpath(repo, "untracked.txt"))
                clean_results = push_all_targets(dirty_config; dry_run=true)
                @test only(clean_results).success

                relaxed_config = BridgeConfig(globals, PushOptions(repo, String[], false),
                                              pull_opts, [target])
                write(joinpath(repo, "untracked.txt"), "x")
                @test only(push_all_targets(relaxed_config; dry_run=true)).success
            end
        end
    end

    @testset "Command construction and collision strategies" begin
        globals = GlobalOptions(12, "accept-new", true, 2048)
        push_opts = PushOptions("/local/workspace", [".git", "*.tmp"], false)
        pull_opts_resume = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"],
                                       :resume, false)
        target = BridgeTarget("RTX-Node", "10.0.0.5", 2222, "worker", "p@ssword#1",
                              "/srv/sim_01", "results")

        push_cmd = build_push_command(target, globals, push_opts)
        @test push_cmd.exec[1:4] == ["sshpass", "-d", "0", "rsync"]
        @test "SSH_ASKPASS_REQUIRE=never" in cmd_environment(push_cmd)
        @test "-a" in push_cmd.exec
        @test !("-av" in push_cmd.exec) && !("-v" in push_cmd.exec)
        @test "--stats" in push_cmd.exec
        @test !any(startswith("--log-file="), push_cmd.exec)
        @test "--partial" in push_cmd.exec
        @test "-s" in push_cmd.exec
        @test "-z" in push_cmd.exec
        @test "--bwlimit=2048" in push_cmd.exec
        @test "--filter=:- .gitignore" in push_cmd.exec
        @test "--exclude=.git" in push_cmd.exec
        @test "--exclude=*.tmp" in push_cmd.exec
        @test "-e" in push_cmd.exec
        @test any(occursin("ssh -p 2222", arg) for arg in push_cmd.exec)
        @test any(occursin("StrictHostKeyChecking=accept-new", arg)
                  for arg in push_cmd.exec)
        @test any(occursin("NumberOfPasswordPrompts=1", arg) for arg in push_cmd.exec)
        rsh = push_cmd.exec[findfirst(==("-e"), push_cmd.exec) + 1]
        @test occursin("-o ServerAliveInterval=15 -o ServerAliveCountMax=3", rsh)
        @test occursin("-o PubkeyAuthentication=no -o PreferredAuthentications=keyboard-interactive,password -o NumberOfPasswordPrompts=1",
                       rsh)
        @test push_cmd.exec[end - 1] == "/local/workspace/"
        @test push_cmd.exec[end] == "worker@10.0.0.5:/srv/sim_01/"
        logged_push = build_push_command(target, globals, push_opts;
                                         log_file="/local/harvest/RTX-Node.push.rsync.log")
        @test "--log-file=/local/harvest/RTX-Node.push.rsync.log" in logged_push.exec
        @test logged_push.exec[(end - 1):end] == push_cmd.exec[(end - 1):end]

        pull_cmd = build_pull_command(target, globals, pull_opts_resume,
                                      "/local/harvest/RTX-Node")
        @test pull_cmd.exec[1:4] == ["sshpass", "-d", "0", "rsync"]
        @test "SSH_ASKPASS_REQUIRE=never" in cmd_environment(pull_cmd)
        @test pull_cmd.exec[end - 1] == "worker@10.0.0.5:/srv/sim_01/results/"
        @test pull_cmd.exec[end] == "/local/harvest/RTX-Node/"
        @test "--stats" in pull_cmd.exec
        @test !any(startswith("--log-file="), pull_cmd.exec)
        logged_pull = build_pull_command(target, globals, pull_opts_resume,
                                         "/local/harvest/RTX-Node";
                                         log_file="/local/harvest/RTX-Node.pull.rsync.log")
        @test "--log-file=/local/harvest/RTX-Node.pull.rsync.log" in logged_pull.exec

        # The verification pass prints nothing but pending items: no statistics, no log
        verification = SshDataBridge.build_verification_command(target, globals,
                                                                pull_opts_resume,
                                                                "/local/harvest/RTX-Node")
        @test "--dry-run" in verification.exec && "--itemize-changes" in verification.exec
        @test "-s" in verification.exec
        @test !("--stats" in verification.exec) && !("-v" in verification.exec)
        @test !any(startswith("--log-file="), verification.exec)

        # The ownership marker never travels back: it is the first filter argument, ahead
        # of the configured excludes
        for exec in (pull_cmd.exec, verification.exec)
            marker_index = findfirst(==("--exclude=/.sshdatabridge-target"), exec)
            @test marker_index !== nothing
            @test marker_index == findfirst(startswith("--exclude="), exec)
            @test exec[marker_index + 1] == "--exclude=*.tmp"
        end

        log_config = BridgeConfig(globals, push_opts, pull_opts_resume, [target])
        @test SshDataBridge.transfer_log_path(log_config, target, :pull) ==
              "/local/harvest/RTX-Node.pull.rsync.log"
        @test SshDataBridge.transfer_log_path(log_config, target, :push) ==
              "/local/harvest/RTX-Node.push.rsync.log"
        @test_throws ArgumentError SshDataBridge.transfer_log_path(log_config, target,
                                                                   :clean)

        # Statistics parsing and the summary line
        @test SshDataBridge.transfer_statistics("Number of regular files transferred: 1,234\nTotal transferred file size: 5,368,709 bytes\n") ==
              (files=1234, bytes=5368709)
        @test SshDataBridge.transfer_statistics("Number of regular files transferred: 0\nTotal transferred file size: 0 bytes") ==
              (files=0, bytes=0)
        @test SshDataBridge.transfer_statistics("") === nothing
        @test SshDataBridge.transfer_statistics("Number of regular files transferred: 3\n") ===
              nothing
        @test SshDataBridge.transfer_statistics("Number of regular files transferred: 1.234\nTotal transferred file size: 5.368.709 bytes\n") ==
              (files=1234, bytes=5368709)
        @test SshDataBridge.format_bytes(0) == "0 B"
        @test SshDataBridge.format_bytes(1023) == "1023 B"
        @test SshDataBridge.format_bytes(1536) == "1.5 KiB"
        @test SshDataBridge.format_bytes(5368709) == "5.1 MiB"
        @test SshDataBridge.format_bytes(2^40) == "1.0 TiB"
        @test SshDataBridge.transfer_summary("Harvested", 12.3456,
                                             "Number of regular files transferred: 1\nTotal transferred file size: 512 bytes",
                                             "/l/x.pull.rsync.log") ==
              "Harvested successfully in 12.35 s: 1 file, 512 B transferred; log: /l/x.pull.rsync.log."
        @test SshDataBridge.transfer_summary("Deployed", 0.5, "", "/l/x.push.rsync.log") ==
              "Deployed successfully in 0.5 s; log: /l/x.push.rsync.log."

        # Include patterns narrow the harvest: the ownership marker and the excludes
        # first, then the directory rule, the includes, and a final catch-all exclude;
        # empty directories are pruned.
        @test SshDataBridge.pull_filter_arguments(pull_opts_resume) ==
              ["--exclude=/.sshdatabridge-target", "--exclude=*.tmp", "--include=*/",
               "--include=*.csv", "--exclude=*", "--prune-empty-dirs"]
        unfiltered = PullOptions("/local/harvest", "output", String[], ["*.tmp", "core.*"])
        @test SshDataBridge.pull_filter_arguments(unfiltered) ==
              ["--exclude=/.sshdatabridge-target", "--exclude=*.tmp", "--exclude=core.*"]
        @test SshDataBridge.pull_filter_arguments(PullOptions("/local/harvest", "output",
                                                              String[], String[])) ==
              ["--exclude=/.sshdatabridge-target"]

        # Push filter rules: the marker at the source root first, so that a copied marker
        # never replaces the claim, then excludes, includes, the .gitignore dir-merge
        @test SshDataBridge.push_filter_arguments(PushOptions("/x", [".git"], false, true,
                                                              ["/Manifest.toml"])) ==
              ["--exclude=/.sshdatabridge-target", "--exclude=.git",
               "--include=/Manifest.toml", "--filter=:- .gitignore"]
        @test SshDataBridge.push_filter_arguments(PushOptions("/x", [".git"], false, false)) ==
              ["--exclude=/.sshdatabridge-target", "--exclude=.git"]

        if Sys.which("rsync") === nothing
            @warn "rsync is not available; skipping the harvest narrowing check"
        else
            mktempdir() do dir
                source = joinpath(dir, "source")
                mkpath(joinpath(source, "nested"))
                mkpath(joinpath(source, "empty"))
                source_names = ("a.csv", "b.txt", "c.tmp", joinpath("nested", "d.csv"),
                                joinpath("nested", "e.txt"))
                for name in source_names
                    write(joinpath(source, name), name)
                end
                harvested = String[]
                for (opts, expected) in ((pull_opts_resume, ["a.csv", "nested/d.csv"]),
                                         (unfiltered,
                                          ["a.csv", "b.txt", "nested/d.csv",
                                           "nested/e.txt"]))
                    destination = mktempdir(dir)
                    filters = SshDataBridge.pull_filter_arguments(opts)
                    run(pipeline(`rsync -a $(filters) $(source)/ $(destination)/`;
                                 stdout=devnull))
                    empty!(harvested)
                    for (root, _, files) in walkdir(destination), file in files
                        push!(harvested, relpath(joinpath(root, file), destination))
                    end
                    @test sort(harvested) == expected
                end

                # The transfer flags make rsync list every file in the log and print the
                # statistics block that the package parses; a repeated run appends
                destination = mktempdir(dir)
                log_file = joinpath(dir, "logs", "node.pull.rsync.log")
                mkpath(dirname(log_file))
                flags = vcat(["-a", "--partial"],
                             SshDataBridge.transfer_arguments(log_file))
                outcome = SshDataBridge.run_captured(`rsync $(flags) $(source)/ $(destination)/`)
                @test outcome.exitcode == 0
                expected_bytes = sum(filesize(joinpath(source, name))
                                     for name in source_names)
                @test SshDataBridge.transfer_statistics(outcome.stdout) ==
                      (files=length(source_names), bytes=expected_bytes)
                logged = read(log_file, String)
                @test occursin(">f+++++++++ a.csv", logged)
                @test occursin("nested/d.csv", logged)
                outcome = SshDataBridge.run_captured(`rsync $(flags) $(source)/ $(destination)/`)
                @test SshDataBridge.transfer_statistics(outcome.stdout) ==
                      (files=0, bytes=0)
                @test count("building file list", read(log_file, String)) == 2

                # An include re-admits what .gitignore drops; an exclude still wins
                project = joinpath(dir, "project")
                mkpath(joinpath(project, "src"))
                mkpath(joinpath(project, "data"))
                write(joinpath(project, ".gitignore"), "Manifest.toml\ndata/\n")
                write(joinpath(project, "Manifest.toml"), "manifest")
                write(joinpath(project, "data", "big.bin"), "data")
                write(joinpath(project, "src", "a.jl"), "code")
                for (opts, expected) in ((PushOptions(project, String[], false, true),
                                          [".gitignore", "src/a.jl"]),
                                         (PushOptions(project, String[], false, true,
                                                      ["/Manifest.toml"]),
                                          [".gitignore", "Manifest.toml", "src/a.jl"]),
                                         (PushOptions(project, ["/Manifest.toml"], false,
                                                      true, ["/Manifest.toml"]),
                                          [".gitignore", "src/a.jl"]))
                    deployed = mktempdir(dir)
                    filters = SshDataBridge.push_filter_arguments(opts)
                    run(pipeline(`rsync -a $(filters) $(project)/ $(deployed)/`;
                                 stdout=devnull))
                    empty!(harvested)
                    for (root, _, files) in walkdir(deployed), file in files
                        push!(harvested, relpath(joinpath(root, file), deployed))
                    end
                    @test sort(harvested) == expected
                end
            end
        end

        # IPv6 literals are bracketed for rsync endpoints only
        ipv6_target = BridgeTarget("V6", "2001:db8::10", 22, "worker", "pw", "/srv/sim")
        ipv6_push = build_push_command(ipv6_target, globals, push_opts)
        @test ipv6_push.exec[end] == "worker@[2001:db8::10]:/srv/sim/"
        @test SshDataBridge.build_ssh_command(ipv6_target, globals, "true").exec[end - 1] ==
              "worker@2001:db8::10"

        @test purge_path(target, :output) == "/srv/sim_01/results"
        @test purge_path(target, :project) == "/srv/sim_01"
        @test_throws ArgumentError purge_path(target, :bogus)

        # No trailing slash, whatever the spelling of the output directory: the purge
        # script must see a symbolic link, not the directory behind it
        dotted = BridgeTarget("Dotted", "10.0.0.9", 22, "worker", "pw", "/srv/p", ".")
        @test purge_path(dotted, :output) == "/srv/p"
        nested = BridgeTarget("Nested", "10.0.0.9", 22, "worker", "pw", "/srv/p", "out/.")
        @test purge_path(nested, :output) == "/srv/p/out"

        # Remote commands are POSIX-quoted and use ssh -n with a single password prompt
        spaced = BridgeTarget("Spaced", "10.0.0.9", 22, "worker", "pw", "/srv/sim a",
                              "out b")
        probe_cmd = SshDataBridge.build_ssh_command(spaced, globals,
                                                    SshDataBridge.remote_shell(SshDataBridge.build_probe_script(spaced)))
        @test probe_cmd.exec[1:5] == ["sshpass", "-d", "0", "ssh", "-n"]
        @test "NumberOfPasswordPrompts=1" in probe_cmd.exec
        @test "PubkeyAuthentication=no" in probe_cmd.exec
        @test !("BatchMode=no" in probe_cmd.exec)
        @test "ServerAliveInterval=15" in probe_cmd.exec
        @test "ServerAliveCountMax=3" in probe_cmd.exec

        # server_alive_interval = 0 leaves keepalive to the ssh client configuration
        no_keepalive = GlobalOptions(12, "accept-new", true, 2048, 0, 3)
        @test isempty(SshDataBridge.keepalive_options(no_keepalive))
        @test !any(occursin("ServerAlive", arg)
                   for arg in build_push_command(target, no_keepalive, push_opts).exec)
        @test !any(occursin("ServerAlive", arg)
                   for arg in SshDataBridge.build_ssh_command(target, no_keepalive,
                                                   "true").exec)
        @test startswith(probe_cmd.exec[end], "sh -c ")
        @test occursin("/srv/sim a", probe_cmd.exec[end])
        @test occursin("/srv/sim a/out b", probe_cmd.exec[end])

        mktempdir() do tmpdir
            pull_test_opts = PullOptions(tmpdir, "output", String[], String[], :resume,
                                         false)
            dest_dir = prepare_local_pull_directory(target, pull_test_opts)
            @test isdir(dest_dir)
            @test dest_dir == joinpath(tmpdir, "RTX-Node")

            marker = joinpath(dest_dir, "test.txt")
            write(marker, "data")
            prepare_local_pull_directory(target, pull_test_opts)
            @test isfile(marker)

            pull_backup_opts = PullOptions(tmpdir, "output", String[], String[], :backup,
                                           false)
            dest_dir3 = prepare_local_pull_directory(target, pull_backup_opts)
            @test isdir(dest_dir3)
            @test isdir("$(dest_dir3)#1")
            @test isfile(joinpath("$(dest_dir3)#1", "test.txt"))

            pull_abort_opts = PullOptions(tmpdir, "output", String[], String[], :abort,
                                          false)
            @test_throws ErrorException prepare_local_pull_directory(target,
                                                                     pull_abort_opts)
        end

        # The purge script refuses a symbolic link and a directory containing the home
        # directory, treats an absent path as done, and removes an ordinary directory
        mktempdir() do dir
            victim = mkpath(joinpath(dir, "victim"))
            write(joinpath(victim, "f"), "x")
            link = joinpath(dir, "link")
            symlink(victim, link)
            run_purge(path) = SshDataBridge.run_captured(`sh -c $(SshDataBridge.purge_script(path, "Node-A"))`)
            refused = run_purge(link)
            @test refused.exitcode == 98
            @test occursin("symbolic link", refused.stderr)
            @test isdir(victim) && islink(link)
            slashed = run_purge(link * "/")
            @test slashed.exitcode == 98
            @test isfile(joinpath(victim, "f"))
            home_refused = withenv("HOME" => victim) do
                return run_purge(dir)
            end
            @test home_refused.exitcode == 98
            @test occursin("home directory", home_refused.stderr)
            @test isdir(victim)
            @test run_purge(joinpath(dir, "absent")).exitcode == 0
            @test run_purge(victim).exitcode == 0
            @test !isdir(victim)
            # A path it cannot enter is refused with its reason: a file, and a directory
            # without search permission (skipped for root, which enters any directory)
            plain = joinpath(dir, "plain")
            write(plain, "x")
            not_entered = run_purge(plain)
            @test not_entered.exitcode == 98
            @test occursin("cannot be entered", not_entered.stderr)
            @test isfile(plain)
            closed = mkpath(joinpath(dir, "closed"))
            write(joinpath(closed, "f"), "x")
            chmod(closed, 0o000)
            enterable = success(`sh -c "cd -- $(closed)"`)
            if enterable
                @test_skip "purge of a directory without search permission"
            else
                not_entered = run_purge(closed)
                @test not_entered.exitcode == 98
                @test occursin("cannot be entered", not_entered.stderr)
            end
            chmod(closed, 0o700)
            @test isfile(joinpath(closed, "f"))
        end
    end

    @testset "Key-based targets" begin
        with_identity_file() do identity
            target = key_target(identity)
            @test target.auth === :key
            @test target.port === nothing
            @test target.user === nothing
            @test target.password === nothing
            @test target.identity_file == identity
            @test target.proxy_jump === nothing
            @test target.output_subdir == "output"
            @test target.strict_host_key_checking === nothing
            full = key_target(identity; port=2222, user="researcher",
                              proxy_jump="admin@gw.example.org", output_subdir="results",
                              strict_host_key_checking="yes")
            @test full.port == 2222
            @test full.user == "researcher"
            @test full.proxy_jump == "admin@gw.example.org"
            @test full.output_subdir == "results"
            @test full.strict_host_key_checking == "yes"
            @test key_target(nothing).identity_file === nothing
            @test key_target(identity; host="my_cluster").host == "my_cluster"
            @test password_target(; host="my_cluster").host == "my_cluster"
            @test_throws ArgumentError key_target(identity; host="-hpc")
            @test_throws ArgumentError key_target(identity; port=0)
            @test_throws ArgumentError key_target(identity; user="a b")

            # The positional constructor keeps building password targets
            legacy = BridgeTarget("N", "hpc", 22, "researcher", "pw", "/d/e")
            @test legacy.auth === :password
            @test legacy.identity_file === nothing
            @test legacy.proxy_jump === nothing

            # A leading tilde is expanded
            mktempdir() do home
                mkpath(joinpath(home, ".ssh"))
                tilde = joinpath(home, ".ssh", "id_tilde")
                write(tilde, "stub key\n")
                chmod(tilde, 0o600)
                expanded = withenv("HOME" => home) do
                    return key_target("~/.ssh/id_tilde").identity_file
                end
                @test expanded == tilde
            end

            # Authentication method and its dependent fields
            message = refusal_message() do
                return BridgeTarget("N", "hpc"; remote_dir="/d/e", auth=:agent,
                                    password="pw-never-printed")
            end
            @test occursin("'auth'", message)
            @test !occursin("pw-never-printed", message)
            @test occursin("mandatory with auth = \"password\"",
                           refusal_message(() -> BridgeTarget("N", "hpc";
                                                              remote_dir="/d/e")))
            @test occursin("applies to auth = \"key\" only",
                           refusal_message(() -> password_target(;
                                                                 identity_file=identity)))
            @test occursin("sshpass",
                           refusal_message(() -> password_target(;
                                                                 proxy_jump="gw.example.org")))
            message = refusal_message() do
                return BridgeTarget("N", "hpc"; remote_dir="/d/e", auth=:key,
                                    identity_file=identity, password="pw-never-printed")
            end
            @test occursin("must not be set with auth = \"key\"", message)
            @test !occursin("pw-never-printed", message)

            # Jump hosts are validated like the argument of ssh -J
            for spec in ("none", "gw.example.org", "admin@gw.example.org",
                         "gw.example.org:2200", "admin@gw.example.org:2200,gw2.example.org",
                         "[2001:db8::1]", "admin@[2001:db8::1]:2200")
                @test key_target(identity; proxy_jump=spec).proxy_jump == spec
            end
            for spec in
                ("", "gw1,,gw2", "-oProxyCommand=x", "gw:0", "ssh://gw.example.org",
                 "2001:db8::1")
                @test_throws ArgumentError key_target(identity; proxy_jump=spec)
            end

            # Addresses and printed representations
            @test SshDataBridge.target_address(target) == "hpc"
            @test SshDataBridge.target_address(key_target(identity; user="researcher")) ==
                  "researcher@hpc"
            @test SshDataBridge.target_address(key_target(identity; port=2222)) ==
                  "hpc:2222"
            @test SshDataBridge.target_address(full) == "researcher@hpc:2222"
            for shown in (sprint(show, full), sprint(show, MIME("text/plain"), full))
                @test occursin("auth = key", shown)
                @test occursin("researcher@hpc:2222", shown)
                @test !occursin("<redacted>", shown)
            end
            with_password = password_target(; user="researcher",
                                            password="pw-never-printed")
            for shown in (sprint(show, with_password),
                          sprint(show, MIME("text/plain"), with_password))
                @test occursin("auth = password", shown)
                @test occursin("researcher@hpc", shown)
                @test occursin("<redacted>", shown)
                @test !occursin("pw-never-printed", shown)
            end
        end

        # The identity file is checked on disk
        with_identity_file(; subdirectory="it's keys") do quoted
            @test occursin("single quote", refusal_message(() -> key_target(quoted)))
        end
        with_identity_file(; subdirectory="tab\tdir") do control
            @test_throws ArgumentError key_target(control)
        end
        with_identity_file() do identity
            @test occursin("absolute path or start with '~'",
                           refusal_message(() -> key_target("keys/id_test")))
            @test_throws ArgumentError key_target(joinpath(dirname(identity), "absent"))
            @test occursin("not a regular file",
                           refusal_message(() -> key_target(dirname(identity))))
        end
        for mode in (0o644, 0o640, 0o604)
            with_identity_file(; mode=mode) do loose
                @test occursin("chmod 600", refusal_message(() -> key_target(loose)))
            end
        end
        for mode in (0o600, 0o400, 0o700)
            with_identity_file(; mode=mode) do strict
                @test key_target(strict) isa BridgeTarget
            end
        end

        # A public key selecting an agent key may be readable by others, as ssh allows;
        # ssh expands '%' tokens and ${VAR} in an identity path after the check here
        mktempdir() do dir
            public_key = joinpath(dir, "id_agent.pub")
            write(public_key, "stub public key\n")
            chmod(public_key, 0o644)
            @test key_target(public_key).identity_file == public_key
            for name in ("id%d", "id%%x", "id\${HOME}", "id\$x")
                expanded = joinpath(dir, name)
                write(expanded, "stub key\n")
                chmod(expanded, 0o600)
                @test occursin("'%' or '\$'", refusal_message(() -> key_target(expanded)))
            end

            # A path that cannot be inspected is reported by its reason
            loop = joinpath(dir, "loop")
            symlink(loop * "2", loop)
            symlink(loop, loop * "2")
            @test occursin("cannot be inspected", refusal_message(() -> key_target(loop)))
        end

        # '~user' is not expanded; the message names the key and the target
        message = refusal_message(() -> key_target("~root/id"))
        @test occursin("'identity_file'", message) && occursin("~user", message)
        @test occursin("target 'K1'", message)
        @test occursin("applies to auth = \"key\" only",
                       refusal_message(() -> password_target(; identity_file="~root/id")))

        # An auth string is compared before it becomes a Symbol
        @test occursin("'auth'",
                       refusal_message(() -> BridgeTarget("N", "hpc"; remote_dir="/d/e",
                                                          auth="key\0")))

        # Brackets before the last hop reach /bin/sh unquoted, where they are a glob
        @test key_target(nothing; proxy_jump="gw.example.org,[2001:db8::1]").proxy_jump ==
              "gw.example.org,[2001:db8::1]"
        for spec in ("[2001:db8::1],gw", "admin@[2001:db8::1]:22,gw1,gw2")
            @test occursin("only in the last hop",
                           refusal_message(() -> key_target(nothing; proxy_jump=spec)))
        end

        # "none" is the one jump specification a password target accepts
        @test password_target(; proxy_jump="none").proxy_jump == "none"
    end

    @testset "Configuration of key-based targets" begin
        function config_dict(targets)
            return Dict{String, Any}("push" =>
                                         Dict{String, Any}("local_source_dir" => "src"),
                                     "pull" =>
                                         Dict{String, Any}("local_destination_root" => "harvest"),
                                     "targets" => targets)
        end
        with_identity_file() do identity
            key_entry = Dict{String, Any}("name" => "K1", "host" => "hpc", "auth" => "key",
                                          "identity_file" => identity,
                                          "proxy_jump" => "admin@gw.example.org",
                                          "remote_dir" => "/data/k1")
            parsed = parse_config(config_dict(Any[key_entry])).targets[1]
            @test parsed.auth === :key
            @test parsed.identity_file == identity
            @test parsed.proxy_jump == "admin@gw.example.org"
            @test parsed.port === nothing
            @test parsed.user === nothing
            @test parsed.password === nothing

            password_entry = Dict{String, Any}("name" => "P1", "host" => "hpc",
                                               "password" => "pw",
                                               "remote_dir" => "/data/p1")
            parsed = parse_config(config_dict(Any[password_entry])).targets[1]
            @test parsed.auth === :password
            @test parsed.port === nothing
            @test parsed.user === nothing

            message = refusal_message() do
                return parse_config(config_dict(Any[merge(key_entry, Dict("auth" => 1))]))
            end
            @test occursin("must be of type AbstractString", message)
        end

        # With no port given, the lexical check reads the ssh default, 22
        shared = "/data/shared"
        @test_throws ArgumentError pair_config(password_target(; name="A",
                                                               remote_dir=shared),
                                               password_target(; name="B", port=22,
                                                               remote_dir=shared))
        @test pair_config(password_target(; name="A", remote_dir=shared),
                          password_target(; name="B", port=2222, remote_dir=shared)) isa
              BridgeConfig
    end

    @testset "Key-target commands" begin
        globals = GlobalOptions(12, "accept-new", true, 2048)
        push_opts = PushOptions("/local/workspace", [".git", "*.tmp"], false)
        pull_opts = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"], :resume,
                                false)
        keepalive = SshDataBridge.keepalive_options(globals)
        common = vcat(["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=12"],
                      keepalive, ["-o", "BatchMode=yes"])

        with_identity_file(; subdirectory="my keys") do identity
            full = key_target(identity; port=2222, user="researcher",
                              proxy_jump="admin@gw.example.org")
            bare = key_target(identity; name="K2", host="hpc-login", remote_dir="/data/k2")
            unkeyed = key_target(nothing; name="K3", host="hpc-agent",
                                 remote_dir="/data/k3")
            full_options = vcat(["-p", "2222"], common,
                                ["-i", identity, "-o", "IdentitiesOnly=yes", "-J",
                                 "admin@gw.example.org"])
            @test SshDataBridge.ssh_options(full, globals) == full_options
            @test SshDataBridge.ssh_options(bare, globals) ==
                  vcat(common, ["-i", identity, "-o", "IdentitiesOnly=yes"])
            @test SshDataBridge.ssh_options(unkeyed, globals) == common

            ssh_full = SshDataBridge.build_ssh_command(full, globals, "true")
            @test ssh_full.exec[1:2] == ["ssh", "-n"]
            @test contains_run(ssh_full.exec, full_options)
            @test ssh_full.exec[end - 1] == "researcher@hpc"
            @test ssh_full.exec[end] == "true"
            ssh_bare = SshDataBridge.build_ssh_command(bare, globals, "true")
            @test ssh_bare.exec[end - 1] == "hpc-login"
            @test ssh_bare.exec[end] == "true"

            push_cmd = build_push_command(full, globals, push_opts)
            pull_cmd = build_pull_command(full, globals, pull_opts, "/local/harvest/K1")
            verification = SshDataBridge.build_verification_command(full, globals,
                                                                    pull_opts,
                                                                    "/local/harvest/K1")
            for cmd in (ssh_full, ssh_bare, push_cmd, pull_cmd, verification)
                @test !("sshpass" in cmd.exec)
                @test sets_askpass(cmd)
            end
            for cmd in (push_cmd, pull_cmd, verification)
                @test cmd.exec[1:4] == ["rsync", "-a", "--partial", "-s"]
                rsh = cmd.exec[findfirst(==("-e"), cmd.exec) + 1]
                @test occursin("BatchMode=yes", rsh)
                @test occursin("IdentitiesOnly=yes", rsh)
                @test occursin("-J ", rsh)
                @test occursin("admin@gw.example.org", rsh)
            end
            @test push_cmd.exec[end] == "researcher@hpc:/data/k1/"
            @test pull_cmd.exec[end - 1] == "researcher@hpc:/data/k1/output/"
            @test pull_cmd.exec[end] == "/local/harvest/K1/"
            @test build_push_command(bare, globals, push_opts).exec[end] ==
                  "hpc-login:/data/k2/"
            for cmd in (pull_cmd, verification)
                marker_index = findfirst(==("--exclude=/.sshdatabridge-target"), cmd.exec)
                @test marker_index !== nothing
                @test marker_index == findfirst(startswith("--exclude="), cmd.exec)
                @test cmd.exec[marker_index + 1] == "--exclude=*.tmp"
            end
            @test "--dry-run" in verification.exec
            @test "--itemize-changes" in verification.exec

            ipv6 = key_target(identity; name="K6", host="2001:db8::10",
                              user="researcher", remote_dir="/data/k6")
            @test build_push_command(ipv6, globals, push_opts).exec[end] ==
                  "researcher@[2001:db8::10]:/data/k6/"
            @test build_push_command(key_target(identity; name="K7", host="2001:db8::10",
                                                remote_dir="/data/k7"), globals,
                                     push_opts).exec[end] == "[2001:db8::10]:/data/k7/"

            # Password targets keep sshpass and turn off an askpass preference of the
            # caller, which would take the prompt away from sshpass
            pw = password_target(; user="researcher", port=2222)
            commands = withenv("SSH_ASKPASS_REQUIRE" => "prefer",
                               "SSH_ASKPASS" => "/usr/bin/ksshaskpass") do
                return (SshDataBridge.build_ssh_command(pw, globals, "true"),
                        build_push_command(pw, globals, push_opts),
                        build_pull_command(pw, globals, pull_opts, "/local/harvest/P"))
            end
            for cmd in commands
                @test cmd.exec[1] == "sshpass"
                askpass_entries = filter(startswith("SSH_ASKPASS_REQUIRE="),
                                         cmd_environment(cmd))
                @test askpass_entries == ["SSH_ASKPASS_REQUIRE=never"]
                @test !sets_askpass(cmd)
            end
        end

        # A path with a space is single-quoted in the remote shell string of rsync
        with_identity_file(; subdirectory="my keys") do identity
            target = key_target(identity; user="researcher")
            rsh = SshDataBridge.build_ssh_rsh_string(target, globals)
            @test occursin("-i '$(identity)'", rsh)
            @test !occursin("'-i'", rsh)
        end

        # rsync itself splits the remote shell string: a key path with a space and a
        # double quote reaches ssh as one argument
        if Sys.which("rsync") !== nothing
            with_identity_file(; subdirectory="my \"keys\"") do identity
                target = key_target(identity; user="researcher",
                                    proxy_jump="admin@gw.example.org")
                rsh = SshDataBridge.build_ssh_rsh_string(target, globals)
                mktempdir() do dir
                    argv_file = joinpath(dir, "argv")
                    write(joinpath(dir, "ssh"),
                          "#!/bin/sh\nprintf '%s\\n' \"\$@\" > " *
                          Base.shell_escape_posixly(argv_file) * "\nexit 1\n")
                    chmod(joinpath(dir, "ssh"), 0o700)
                    withenv("PATH" => dir * ":" * ENV["PATH"]) do
                        return run(pipeline(ignorestatus(`rsync -e $(rsh) researcher@hpc:/x/ $(joinpath(dir, "dest"))/`);
                                            stdin=devnull, stdout=devnull, stderr=devnull))
                    end
                    received = readlines(argv_file)
                    @test received[findfirst(==("-i"), received) + 1] == identity
                    @test received[findfirst(==("-J"), received) + 1] ==
                          "admin@gw.example.org"
                    @test "BatchMode=yes" in received
                end
            end
        end

        # "none" connects directly: -o ProxyCommand=none, for either authentication
        direct = key_target(nothing; proxy_jump="none")
        @test SshDataBridge.ssh_options(direct, globals)[(end - 1):end] ==
              ["-o", "ProxyCommand=none"]
        @test !("-J" in SshDataBridge.ssh_options(direct, globals))
        direct_password = password_target(; proxy_jump="none")
        @test SshDataBridge.ssh_options(direct_password, globals)[(end - 7):end] ==
              ["-o", "PubkeyAuthentication=no",
               "-o", "PreferredAuthentications=keyboard-interactive,password",
               "-o", "NumberOfPasswordPrompts=1", "-o", "ProxyCommand=none"]

        # The interactive command of a hint follows the route of the target
        with_identity_file(; subdirectory="my keys") do identity
            routed = key_target(identity; port=2222, user="researcher",
                                proxy_jump="admin@gw.example.org")
            @test SshDataBridge.interactive_ssh_command(routed) ==
                  "ssh -p 2222 -i '$(identity)' -o IdentitiesOnly=yes " *
                  "-J 'admin@gw.example.org' 'researcher@hpc'"
            @test SshDataBridge.interactive_ssh_command(routed; master=true) ==
                  "ssh -fN -p 2222 -i '$(identity)' -o IdentitiesOnly=yes " *
                  "-J 'admin@gw.example.org' 'researcher@hpc'"
            @test SshDataBridge.interactive_ssh_command(key_target(nothing;
                                                                   proxy_jump="none")) ==
                  "ssh -o ProxyCommand=none hpc"
            @test SshDataBridge.interactive_ssh_command(key_target(nothing)) == "ssh hpc"
        end
    end

    @testset "Prompt refusal" begin
        program = SshDataBridge.prompt_refusal_program()
        @test isfile(program)
        @test filemode(program) & 0o777 == 0o700
        @test filemode(dirname(program)) & 0o077 == 0
        @test SshDataBridge.prompt_refusal_program() == program
        @test SshDataBridge.prompt_refusal_environment() ==
              ["SSH_ASKPASS" => program, "SSH_ASKPASS_REQUIRE" => "force"]
        with_identity_file() do identity
            cmd = SshDataBridge.build_ssh_command(key_target(identity), GlobalOptions(),
                                                  "true")
            @test "SSH_ASKPASS=$(program)" in cmd_environment(cmd)
        end

        # The program reports the first line of the prompt and terminates the process
        # that ran it, here a shell standing in for the ssh of a jump host
        out = IOBuffer()
        err = IOBuffer()
        script = "\"\$1\" \"\$2\"; echo survived"
        prompt = "Enter passphrase for key '/k/id':\nsecond line"
        parent = run(pipeline(ignorestatus(`sh -c $(script) sh $(program) $(prompt)`);
                              stdin=devnull, stdout=out, stderr=err))
        @test parent.termsignal == 15
        @test !occursin("survived", String(take!(out)))
        reported = String(take!(err))
        @test occursin(SshDataBridge.PROMPT_REFUSAL_REPORT *
                       ": Enter passphrase for key '/k/id':", reported)
        @test !occursin("second line", reported)

        # A copy that has gone is written again
        rm(program)
        rewritten = SshDataBridge.prompt_refusal_program()
        @test isfile(rewritten)
        @test rewritten != program
    end

    @testset "SSH endpoint resolution" begin
        parse_ssh_config = SshDataBridge.parse_ssh_config
        SshEndpoint = SshDataBridge.SshEndpoint
        text = "user researcher\nhostname login.example.org\nport 2222\nproxyjump admin@gw.example.org\nidentityfile ~/.ssh/a\nidentityfile ~/.ssh/b\n"
        endpoint = parse_ssh_config(text)
        @test endpoint.hostname == "login.example.org"
        @test endpoint.port == 2222
        @test endpoint.user == "researcher"
        @test endpoint.proxy_jump == "admin@gw.example.org"
        @test endpoint.proxy_command === nothing
        @test parse_ssh_config(replace(text,
                                       "proxyjump admin@gw.example.org" => "proxyjump none")).proxy_jump ===
              nothing
        upper = parse_ssh_config("HostName login.example.org\nPort 2222\nUser researcher\n")
        @test upper.hostname == "login.example.org"
        @test upper.port == 2222
        @test upper.user == "researcher"
        for key in ("hostname", "port", "user")
            without = join(filter(line -> !startswith(line, key * " "), split(text, '\n')),
                           "\n")
            @test_throws ArgumentError parse_ssh_config(without)
        end
        for port in ("0", "x")
            @test_throws ArgumentError parse_ssh_config(replace(text,
                                                                "port 2222" =>
                                                                    "port " * port))
        end

        globals = GlobalOptions(12, "accept-new", true, 0)
        alias = password_target(; name="A", host="hpc")
        explicit = password_target(; name="K", host="hpc", port=2222, user="researcher")
        query = SshDataBridge.ssh_config_command(explicit, globals)
        @test query.exec[1:2] == ["ssh", "-G"]
        @test query.exec[end] == "researcher@hpc"
        @test !("sshpass" in query.exec)
        @test SshDataBridge.ssh_config_command(alias, globals).exec[end] == "hpc"

        with_stub_binaries(; g_hostnames="hpc=login.example.org") do args_file
            resolved = SshDataBridge.resolve_endpoint(alias, globals)
            @test resolved.hostname == "login.example.org"
            @test resolved.port == 22
            @test resolved.user == "stubuser"
            @test resolved.proxy_jump === nothing
            resolved = SshDataBridge.resolve_endpoint(explicit, globals)
            @test resolved.hostname == "login.example.org"
            @test resolved.port == 2222
            @test resolved.user == "researcher"
            queries = recorded_config_queries(args_file)
            @test length(queries) == 2
            @test all(startswith("-G "), queries)
            @test isempty(recorded_invocations(args_file))
        end
        with_stub_binaries(; g_proxyjump="admin@gw.example.org") do _
            @test SshDataBridge.resolve_endpoint(alias, globals).proxy_jump ==
                  "admin@gw.example.org"
        end

        # Two aliases of one host and port must not share remote directories
        check = SshDataBridge.check_endpoint_overlaps
        first_target = password_target(; name="Alpha", host="hpc",
                                       remote_dir="/data/shared")
        second_target(dir; name="Beta") = password_target(; name=name, host="hpc-login",
                                                          remote_dir=dir)
        login = SshEndpoint("login.example.org", 22, "researcher", nothing, nothing)
        message = refusal_message() do
            return check([first_target, second_target("/data/shared")], [login, login])
        end
        @test occursin("Alpha", message)
        @test occursin("Beta", message)
        @test occursin("same host and port", message)
        @test_throws ArgumentError check([first_target, second_target("/data/shared/sub")],
                                         [login, login])
        @test_throws ArgumentError check([first_target, second_target("/data")],
                                         [login, login])
        upper_login = SshEndpoint("Login.Example.org", 22, "researcher", nothing, nothing)
        @test_throws ArgumentError check([first_target, second_target("/data/shared")],
                                         [login, upper_login])
        routed = SshEndpoint("login.example.org", 22, "researcher", "admin@gw.example.org",
                             nothing)
        @test_throws ArgumentError check([first_target, second_target("/data/shared")],
                                         [login, routed])
        other_port = SshEndpoint("login.example.org", 2222, "researcher", nothing, nothing)
        @test (check([first_target, second_target("/data/shared")], [login, other_port]);
               true)
        @test (check([first_target, second_target("/data/other")], [login, login]); true)
    end

    @testset "Ownership marker" begin
        marker = ".sshdatabridge-target"
        run_claim(dir, name) = SshDataBridge.run_captured(`sh -c $(SshDataBridge.claim_script(dir, name))`)
        run_purge(path, name) = SshDataBridge.run_captured(`sh -c $(SshDataBridge.purge_script(path, name))`)

        mktempdir() do root
            # A claim creates the directory and writes the name
            project = joinpath(root, "project")
            claimed = run_claim(project, "alpha")
            @test claimed.exitcode == 0
            @test isdir(project)
            @test read(joinpath(project, marker), String) == "alpha\n"
            @test run_claim(project, "alpha").exitcode == 0
            @test read(joinpath(project, marker), String) == "alpha\n"
            refused = run_claim(project, "beta")
            @test refused.exitcode == 97
            @test occursin("push refused", refused.stderr)
            @test occursin("alpha", refused.stderr)
            @test read(joinpath(project, marker), String) == "alpha\n"

            # Concurrent claims on a fresh directory have one winner
            for round in 1:20
                dir = joinpath(root, "race$(round)")
                names = ("alpha", "beta")
                processes = [run(pipeline(ignorestatus(`sh -c $(SshDataBridge.claim_script(dir, name))`);
                                          stdout=devnull, stderr=devnull); wait=false)
                             for name in names]
                foreach(wait, processes)
                @test sort([process.exitcode for process in processes]) == [0, 97]
                winner = names[findfirst(process -> process.exitcode == 0, processes)]
                @test read(joinpath(dir, marker), String) == winner * "\n"
                @test !any(startswith(".sshdatabridge-target."), readdir(dir))
            end

            # A directory nested in the tree of another target is refused, in either
            # order of the two claims
            outer = joinpath(root, "outer")
            @test run_claim(outer, "alpha").exitcode == 0
            inner = run_claim(joinpath(outer, "inner"), "beta")
            @test inner.exitcode == 97
            @test occursin("lies inside", inner.stderr) && occursin("alpha", inner.stderr)
            @test !isfile(joinpath(outer, "inner", marker))
            later = joinpath(root, "later")
            @test run_claim(joinpath(later, "inner"), "beta").exitcode == 0
            enclosing = run_claim(later, "alpha")
            @test enclosing.exitcode == 97
            @test occursin("contains", enclosing.stderr)
            @test !isfile(joinpath(later, marker))
            # Through a symbolic link, the physical location counts
            symlink(outer, joinpath(root, "alias"))
            @test run_claim(joinpath(root, "alias", "deeper"), "beta").exitcode == 97
            # Markers of the same target above or below do not refuse it
            @test run_claim(joinpath(outer, "own"), "alpha").exitcode == 0

            # A push never carries a marker from the source tree into the claimed directory
            if Sys.which("rsync") !== nothing
                source = mkpath(joinpath(root, "source"))
                write(joinpath(source, marker), "beta\n")
                write(joinpath(source, "run.jl"), "x")
                claimed = joinpath(root, "claimed")
                @test run_claim(claimed, "alpha").exitcode == 0
                filters = SshDataBridge.push_filter_arguments(PushOptions(source))
                run(pipeline(`rsync -a $(filters) $(source)/ $(claimed)/`; stdout=devnull))
                @test read(joinpath(claimed, marker), String) == "alpha\n"
                @test isfile(joinpath(claimed, "run.jl"))
            end

            # A purge honours the marker of the directory
            own = mkpath(joinpath(root, "own"))
            write(joinpath(own, marker), "alpha\n")
            write(joinpath(own, "f"), "x")
            foreign = mkpath(joinpath(root, "foreign"))
            write(joinpath(foreign, marker), "beta\n")
            write(joinpath(foreign, "f"), "x")
            refused = run_purge(foreign, "alpha")
            @test refused.exitcode == 98
            @test occursin("purge refused", refused.stderr)
            @test occursin("in use by target", refused.stderr)
            @test isfile(joinpath(foreign, "f"))
            @test run_purge(own, "alpha").exitcode == 0
            @test !isdir(own)

            # The marker of an ancestor decides for a purge of the output directory
            ancestor = mkpath(joinpath(root, "ancestor"))
            write(joinpath(ancestor, marker), "alpha\n")
            mkpath(joinpath(ancestor, "output"))
            write(joinpath(ancestor, "output", "f"), "x")
            @test run_purge(joinpath(ancestor, "output"), "alpha").exitcode == 0
            @test !isdir(joinpath(ancestor, "output"))
            @test isdir(ancestor)
            @test isfile(joinpath(ancestor, marker))
            mkpath(joinpath(ancestor, "output"))
            write(joinpath(ancestor, "output", "f"), "x")
            refused = run_purge(joinpath(ancestor, "output"), "beta")
            @test refused.exitcode == 98
            @test isfile(joinpath(ancestor, "output", "f"))

            # A marker below the purged directory counts as well
            nested = mkpath(joinpath(root, "nested", "sub"))
            write(joinpath(nested, marker), "beta\n")
            write(joinpath(nested, "f"), "x")
            refused = run_purge(joinpath(root, "nested"), "alpha")
            @test refused.exitcode == 98
            @test occursin("belongs to another target", refused.stderr)
            @test isfile(joinpath(nested, "f"))
            @test run_purge(joinpath(root, "nested"), "beta").exitcode == 0
            @test !isdir(joinpath(root, "nested"))

            # Without any marker the purge proceeds and says so
            legacy = mkpath(joinpath(root, "legacy"))
            write(joinpath(legacy, "f"), "x")
            unmarked = run_purge(legacy, "alpha")
            @test unmarked.exitcode == 0
            @test occursin("purge note:", unmarked.stderr)
            @test !isdir(legacy)

            # Names and paths with a space and a single quote survive the quoting
            awkward = joinpath(root, "it's dir")
            @test run_claim(awkward, "node one").exitcode == 0
            @test read(joinpath(awkward, marker), String) == "node one\n"
            @test run_claim(awkward, "node two").exitcode == 97
            @test run_purge(awkward, "node two").exitcode == 98
            @test isdir(awkward)
            @test run_purge(awkward, "node one").exitcode == 0
            @test !isdir(awkward)
        end
    end

    @testset "Prerequisites and safety refusal" begin
        with_identity_file() do identity
            key = key_target(identity)
            password = password_target()
            mktempdir() do bin
                for name in ("ssh", "rsync")
                    path = joinpath(bin, name)
                    write(path, "#!/bin/sh\necho \"\$STUB_BANNER\" >&2\nexit 0\n")
                    chmod(path, 0o700)
                end
                withenv("PATH" => bin, "STUB_BANNER" => "OpenSSH_8.4p1, stub") do
                    @test (check_local_binaries([key]); true)
                    missing_error = try
                        check_local_binaries([key, password])
                        nothing
                    catch err
                        err
                    end
                    @test missing_error isa MissingBinaryError
                    @test missing_error.binaries == ["sshpass"]
                end
                # Key targets need SSH_ASKPASS_REQUIRE, which OpenSSH 8.4 introduced;
                # a configuration of password targets does not depend on it
                for (banner, accepted) in (("OpenSSH_8.3p1, stub", false),
                                           ("OpenSSH_7.4p1, stub", false),
                                           ("Dropbear 2022.83", false), ("", false),
                                           ("OpenSSH_9.9p2 Debian, stub", true),
                                           ("OpenSSH_10.0p2, stub", true))
                    withenv("PATH" => bin, "STUB_BANNER" => banner) do
                        reported = match(r"^OpenSSH_(\d+\.\d+)", banner)
                        expected = reported === nothing ? nothing :
                                   VersionNumber(reported[1])
                        @test isequal(SshDataBridge.openssh_version(), expected)
                        if accepted
                            @test (check_local_binaries([key]); true)
                        else
                            @test occursin("OpenSSH 8.4 or newer",
                                           refusal_message(() -> check_local_binaries([key])))
                        end
                    end
                end
                write(joinpath(bin, "sshpass"), "#!/bin/sh\nexit 0\n")
                chmod(joinpath(bin, "sshpass"), 0o700)
                withenv("PATH" => bin, "STUB_BANNER" => "OpenSSH_7.4p1, stub") do
                    @test (check_local_binaries([password]); true)
                end
            end

            # The user of a key target comes from ssh -G; /home/stubuser is its home
            globals = GlobalOptions(10, "accept-new", false, 0)
            homeless = key_target(identity; remote_dir="/home/stubuser")
            with_stub_binaries() do args_file
                result = clean_remote_target(homeless, globals)
                @test !result.success
                @test startswith(result.message, "Safety refusal")
                @test !any(occursin("rm -rf", line)
                           for line in recorded_invocations(args_file))
            end
        end
    end

    @testset "Credential handling and redaction" begin
        password = "s3cret-p@ss'word"
        target = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", password, "/rem/sim_a")

        # The password travels through standard input and is read by the child
        echo = run_authenticated(`sh -c 'read -r x; printf "got:%s\n" "$x"'`, password)
        @test echo.exitcode == 0
        @test echo.stdout == "got:$(password)\n"

        # A child exiting before reading the password is reported, not thrown
        fast = run_authenticated(`sh -c 'echo err >&2; exit 3'`, password)
        @test fast.exitcode == 3
        @test fast.stderr == "err\n"

        # A missing executable is reported, not thrown
        missing = run_authenticated(`definitely-missing-binary-xyz`, password)
        @test missing.exitcode == -1
        @test occursin("definitely-missing-binary-xyz", missing.stderr)

        # A child killed by a signal reports 128 + signal, not 0
        @test run_authenticated(`sh -c 'kill -9 $$'`, password).exitcode == 137

        # Both streams are read to end-of-file, here beyond the capacity of a pipe
        flood = run_authenticated(`sh -c 'read -r x; i=0; while [ $i -lt 20000 ]; do echo out-line; echo err-line >&2; i=$((i+1)); done'`,
                                  password)
        @test flood.exitcode == 0
        @test count(==('\n'), flood.stdout) == 20000
        @test count(==('\n'), flood.stderr) == 20000
        captured = SshDataBridge.run_captured(`sh -c 'i=0; while [ $i -lt 20000 ]; do echo out-line; i=$((i+1)); done; exit 4'`)
        @test captured.exitcode == 4
        @test count(==('\n'), captured.stdout) == 20000

        # Output that a descendant writes after the child has exited is still read. On
        # Julia 1.10, wait alone returned before it arrived.
        late = run_authenticated(`sh -c 'read -r x; (sleep 0.5; printf late) & exit 0'`,
                                 password)
        @test late.stdout == "late"
        @test SshDataBridge.run_captured(`sh -c '(sleep 0.5; printf late) & exit 0'`).stdout ==
              "late"

        # command_string never renders the environment
        secret_cmd = setenv(`echo hello`, "SSHPASS" => password)
        @test command_string(secret_cmd) == "echo hello"
        @test !occursin(password, command_string(secret_cmd))
        @test command_string(`rm -rf -- "/a b"`) == "rm -rf -- '/a b'"

        # Printed representations of targets and results are redacted
        shown = sprint(show, target)
        @test occursin("Node-A", shown)
        @test occursin("auth = password", shown)
        @test occursin("admin@10.0.0.1:22", shown)
        @test occursin("<redacted>", shown)
        @test !occursin(password, repr(target))
        @test !occursin(password, sprint(show, MIME("text/plain"), target))
        probe = ProbeResult(target, true, true, true, true, true, "ok")
        @test !occursin(password, sprint(show, probe))
        transfer = TransferResult(target, :push, true, 0, 1.0, "ok")
        @test !occursin(password, sprint(show, transfer))
        @test !occursin(password, repr([transfer]))
    end

    @testset "Process execution (stub binaries)" begin
        globals = GlobalOptions(10, "accept-new", false, 0)
        push_opts = PushOptions(mktempdir(), String[".git"], false)
        target = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "pw-A", "/rem/sim a")

        with_stub_binaries(; stdout_text="RSYNC_OK\nDIR_EXISTS\nOUT_MISSING") do args_file
            result = probe_target(target, globals)
            @test result.ssh_ok
            @test result.rsync_ok
            @test result.remote_dir_exists
            @test !result.remote_output_dir_exists
            @test result.success
            @test occursin("output directory missing", result.message)
            invocation = only(recorded_invocations(args_file))
            @test occursin("/rem/sim a", invocation)
            @test occursin("sh -c", invocation)
            @test occursin("-n -p 22", invocation)
        end

        with_stub_binaries(; exit_code=255, stderr_text="Connection refused") do _
            result = probe_target(target, globals)
            @test !result.ssh_ok
            @test !result.success
            @test occursin("255", result.message)
            @test occursin("Connection refused", result.message)
        end

        # The claim creates remote_dir and writes or checks the ownership marker
        with_stub_binaries() do args_file
            directory = claim_remote_directory(target, globals)
            @test directory.success
            @test directory.exitcode == 0
            invocation = only(recorded_invocations(args_file))
            @test occursin("mkdir -p -- \"\$d\"", invocation)
            @test occursin("/rem/sim a", invocation)
            @test occursin(".sshdatabridge-target", invocation)
        end

        with_stub_binaries(; exit_code=1, stderr_text="mkdir: permission denied") do _
            directory = claim_remote_directory(target, globals)
            @test !directory.success
            @test directory.exitcode == 1
            @test occursin("permission denied", directory.stderr)
        end

        mktempdir() do harvest_root
            pull_opts = PullOptions(harvest_root, "output", String[], String[], :resume,
                                    false)
            config = BridgeConfig(globals, push_opts, pull_opts, [target])

            # rsync exit code propagates while the preceding mkdir succeeds
            with_stub_binaries(; rsync_exit_code=23, stderr_text="partial transfer") do _
                result = push_target(target, config)
                @test !result.success
                @test result.exit_code == 23
                @test occursin("rsync exited with code 23", result.message)
                @test occursin("partial transfer", result.message)
            end

            # A failing claim stops the push before rsync runs
            with_stub_binaries(; exit_code=1, rsync_exit_code=0,
                               stderr_text="mkdir failed") do args_file
                result = push_target(target, config)
                @test !result.success
                @test result.exit_code == 1
                @test occursin("Remote directory claim failed", result.message)
                @test length(recorded_invocations(args_file)) == 1
            end

            # A directory claimed by another target refuses the push before rsync runs
            with_stub_binaries(; exit_code=97, rsync_exit_code=0,
                               stderr_text="push refused: /rem/sim a is in use by target 'Node-B'",
                               ) do args_file
                result = push_target(target, config)
                @test !result.success
                @test result.exit_code == 97
                @test startswith(result.message, "Push refused: ")
                @test occursin("Node-B", result.message)
                @test length(recorded_invocations(args_file)) == 1
            end

            with_stub_binaries() do _
                results = push_all_targets(config)
                @test length(results) == 1
                @test results[1].success
                @test results[1].exit_code == 0
            end

            # The statistics block of rsync becomes the summary line; the log path is named
            statistics = "Number of regular files transferred: 12\nTotal transferred file size: 3,145,728 bytes\n"
            push_log = joinpath(harvest_root, "Node-A.push.rsync.log")
            with_stub_binaries(; stdout_text=statistics) do args_file
                result = push_target(target, config)
                @test result.success
                @test result.message ==
                      "Deployed successfully in $(round(result.duration_seconds; digits=2)) s: 12 files, 3.0 MiB transferred; log: $(push_log)."
                invocations = recorded_invocations(args_file)
                @test length(invocations) == 2
                @test occursin("rsync -a --partial -s --stats --log-file=$(push_log) -e ",
                               invocations[2])
                @test !occursin("-av", invocations[2])
            end

            # The log directory is created before the remote is contacted
            fresh_root = joinpath(harvest_root, "fresh")
            fresh_config = BridgeConfig(globals, push_opts, PullOptions(fresh_root),
                                        [target])
            with_stub_binaries() do _
                @test push_target(target, fresh_config).success
                @test isdir(fresh_root)
            end

            # A source tree that does not exist is refused before any target is contacted
            absent_config = BridgeConfig(globals,
                                         PushOptions(joinpath(harvest_root, "absent")),
                                         pull_opts, [target])
            with_stub_binaries() do args_file
                @test_throws ArgumentError push_all_targets(absent_config)
                @test_throws ArgumentError push_all_targets(absent_config; dry_run=true)
                @test isempty(recorded_invocations(args_file))
            end

            with_stub_binaries(; exit_code=255, stderr_text="timed out") do _
                result = pull_target(target, config)
                @test !result.success
                @test result.exit_code == 255
                @test occursin("timed out", result.message)
                @test isdir(joinpath(harvest_root, "Node-A"))
            end

            # A local destination that cannot be created fails the target, not the run
            blocker = joinpath(harvest_root, "blocker")
            write(blocker, "not a directory")
            blocked_config = BridgeConfig(globals, push_opts,
                                          PullOptions(joinpath(blocker, "root")), [target])
            with_stub_binaries() do args_file
                result = pull_target(target, blocked_config)
                @test !result.success
                @test result.exit_code == -1
                @test occursin("Could not prepare the local destination", result.message)
                @test isempty(recorded_invocations(args_file))
                @test only(pull_all_targets(blocked_config)).success == false
            end

            # A log directory that cannot be created fails the push before any contact
            with_stub_binaries() do args_file
                result = push_target(target, blocked_config)
                @test !result.success
                @test result.exit_code == -1
                @test occursin("Could not create the log directory", result.message)
                @test isempty(recorded_invocations(args_file))
            end

            # A purge follows a verified harvest: transfer, verification pass, removal of
            # the whole project directory
            with_stub_binaries() do args_file
                result = pull_target(target, config; clean_remote=true)
                @test result.success
                @test occursin("Harvested successfully", result.message)
                @test occursin("purged", result.message)
                invocations = recorded_invocations(args_file)
                @test length(invocations) == 3
                pull_log = joinpath(harvest_root, "Node-A.pull.rsync.log")
                @test occursin("rsync -a --partial -s --stats --log-file=$(pull_log) -e ",
                               invocations[1])
                @test occursin("; log: $(pull_log).", result.message)
                @test occursin("rsync -a --partial", invocations[2])
                @test occursin("--dry-run --itemize-changes", invocations[2])
                @test !occursin("--stats", invocations[2])
                @test !occursin("--log-file", invocations[2])
                @test purges(invocations[3], "/rem/sim a")
                @test !occursin("/output", invocations[3])
            end

            # The output scope narrows the purge to the output directory
            output_opts = PullOptions(harvest_root, "output", String[], String[], :resume,
                                      false, :output)
            output_config = BridgeConfig(globals, push_opts, output_opts, [target])
            with_stub_binaries() do args_file
                result = pull_target(target, output_config; clean_remote=true)
                @test result.success
                @test purges(recorded_invocations(args_file)[3], "/rem/sim a/output")
            end

            # Items that changed on the remote since the transfer block the purge: nothing
            # is deleted and the target fails although the data were retrieved
            pending = ">f+++++++++ late_a.csv\n>f.st...... run.log\n.d..t...... ./\n>f+++++++++ late_b.csv"
            with_stub_binaries(; verify_stdout_text=pending) do args_file
                result = pull_target(target, config; clean_remote=true)
                @test !result.success
                @test result.exit_code == -1
                @test occursin("Harvested successfully", result.message)
                @test occursin("Remote purge refused, nothing was deleted", result.message)
                @test occursin("4 item(s) on the node differ", result.message)
                @test occursin("late_a.csv", result.message)
                @test occursin("; ...", result.message)
                @test !occursin("late_b.csv", result.message)
                invocations = recorded_invocations(args_file)
                @test length(invocations) == 2
                @test !any(occursin("rm -rf", line) for line in invocations)
            end

            # A failed verification pass blocks the purge
            with_stub_binaries(; verify_exit_code=12, stderr_text="connection reset",
                               ) do args_file
                result = pull_target(target, config; clean_remote=true)
                @test !result.success
                @test occursin("verification pass exited with code 12", result.message)
                @test occursin("connection reset", result.message)
                @test !any(occursin("rm -rf", line)
                           for line in recorded_invocations(args_file))
            end

            # So does one killed by a signal
            with_stub_binaries(; verify_kill=true) do args_file
                result = pull_target(target, config; clean_remote=true)
                @test !result.success
                @test occursin("verification pass exited with code 137", result.message)
                @test !any(occursin("rm -rf", line)
                           for line in recorded_invocations(args_file))
            end

            # The same gate for a key target, whose rsync runs without sshpass
            keyed = key_target(nothing; name="Node-K", remote_dir="/rem/keyed a")
            keyed_config = BridgeConfig(globals, push_opts, pull_opts, [keyed])
            with_stub_binaries() do args_file
                result = pull_target(keyed, keyed_config; clean_remote=true)
                @test result.success
                invocations = recorded_invocations(args_file)
                @test length(invocations) == 3
                @test !any(startswith("-d 0"), invocations)
                @test purges(invocations[3], "/rem/keyed a")
            end
            with_stub_binaries(; verify_stdout_text=pending) do args_file
                result = pull_target(keyed, keyed_config; clean_remote=true)
                @test !result.success
                @test occursin("Remote purge refused, nothing was deleted", result.message)
                @test !any(occursin("rm -rf", line)
                           for line in recorded_invocations(args_file))
            end
            with_stub_binaries(; rsync_exit_code=23, stderr_text="partial transfer",
                               ) do args_file
                result = pull_target(keyed, keyed_config; clean_remote=true)
                @test !result.success
                @test result.exit_code == 23
                @test length(recorded_invocations(args_file)) == 1
            end

            # Probe hints of a key target name the prompt and the route
            routed = key_target(nothing; name="Node-R", port=2222, user="researcher",
                                proxy_jump="admin@gw.example.org", remote_dir="/rem/r")
            report = SshDataBridge.PROMPT_REFUSAL_REPORT
            for (stderr_text, fragment, command) in
                (("researcher@hpc: Permission denied (publickey).", "allows no prompt",
                  "ssh -fN -p 2222 -J 'admin@gw.example.org' 'researcher@hpc'"),
                 ("$(report): Enter passphrase for key '/k/id':", "allows no prompt",
                  "ssh -fN -p 2222 -J 'admin@gw.example.org' 'researcher@hpc'"),
                 ("$(report): admin@gw.example.org's password:", "allows no prompt",
                  "ssh -fN -p 2222 -J 'admin@gw.example.org' 'researcher@hpc'"),
                 ("Host key verification failed.", "cannot confirm a host key",
                  "ssh -p 2222 -J 'admin@gw.example.org' 'researcher@hpc'"),
                 ("$(report): The authenticity of host 'gw.example.org' can't be established.",
                  "cannot confirm a host key",
                  "ssh -p 2222 -J 'admin@gw.example.org' 'researcher@hpc'"))
                with_stub_binaries(; exit_code=255, stderr_text=stderr_text) do _
                    result = probe_target(routed, globals)
                    @test !result.ssh_ok
                    @test occursin(fragment, result.message)
                    @test occursin("($(command))", result.message)
                end
            end
            with_stub_binaries(; exit_code=255,
                               stderr_text="researcher@hpc: Permission denied (password).",
                               ) do _
                message = probe_target(target, globals).message
                @test !occursin("allows no prompt", message)
                @test !occursin("cannot confirm", message)
            end

            # Without a requested purge no verification pass runs
            with_stub_binaries() do args_file
                result = pull_target(target, config)
                @test result.success
                @test occursin("; log: $(joinpath(harvest_root, "Node-A.pull.rsync.log")).",
                               result.message)
                @test length(recorded_invocations(args_file)) == 1
            end

            # A purge can never follow a filtered harvest: refused before any transfer
            filtered_opts = PullOptions(harvest_root, "output", ["*.csv"], String[],
                                        :resume, false)
            filtered_config = BridgeConfig(globals, push_opts, filtered_opts, [target])
            with_stub_binaries() do args_file
                @test_throws ArgumentError pull_target(target, filtered_config;
                                                       clean_remote=true)
                @test isempty(recorded_invocations(args_file))
                @test pull_target(target, filtered_config).success
                @test length(recorded_invocations(args_file)) == 1
            end

            # Project scope removes the base directory
            with_stub_binaries() do args_file
                result = clean_remote_target(target, globals; scope=:project)
                @test result.success
                @test occursin("project scope", result.message)
                invocation = only(recorded_invocations(args_file))
                @test purges(invocation, "/rem/sim a")
            end
            project_opts = PullOptions(harvest_root, "output", String[], String[], :resume,
                                       false, :project)
            project_config = BridgeConfig(globals, push_opts, project_opts, [target])
            with_stub_binaries() do args_file
                results = clean_all_remote_targets(project_config)
                @test only(results).success
                invocation = only(recorded_invocations(args_file))
                @test purges(invocation, "/rem/sim a")
            end

            with_stub_binaries(; exit_code=1, stderr_text="rm: cannot remove") do _
                result = clean_remote_target(target, globals)
                @test !result.success
                @test result.exit_code == 1
                @test occursin("rm: cannot remove", result.message)
            end

            with_stub_binaries() do args_file
                @test clean_remote_target(target, globals).success
                invocation = only(recorded_invocations(args_file))
                @test purges(invocation, "/rem/sim a")
                @test clean_remote_target(target, globals; scope=:output).success
                @test purges(last(recorded_invocations(args_file)), "/rem/sim a/output")
            end

            with_stub_binaries() do _
                results = pull_all_targets(config)
                @test length(results) == 1
                @test results[1].success
            end
        end

        # Targets run concurrently and keep their place in the result; every task runs to
        # completion before the exception of another one propagates.
        slow = BridgeTarget("Slow", "10.0.0.2", 22, "admin", "pw", "/rem/slow")
        fast = BridgeTarget("Fast", "10.0.0.3", 22, "admin", "pw", "/rem/fast/x")
        finished = String[]
        lengths = SshDataBridge.map_targets([slow, fast], Int) do t
            t === slow && sleep(0.2)
            push!(finished, t.name)
            return length(t.remote_dir)
        end
        @test lengths == [9, 11]
        @test finished == ["Fast", "Slow"]
        empty!(finished)
        @test_throws CompositeException SshDataBridge.map_targets([slow, fast],
                                                                  Nothing) do t
            t === slow && error("failure on one target")
            sleep(0.05)
            push!(finished, t.name)
            return nothing
        end
        @test finished == ["Fast"]

        # No password may reach any stub through the environment or the arguments
        with_stub_binaries() do args_file
            probe_target(target, globals)
            @test !occursin("pw-A", read(args_file, String))
        end

        mktempdir() do empty_dir
            withenv("PATH" => empty_dir) do
                @test_throws MissingBinaryError check_local_binaries([target])
                missing_error = try
                    check_local_binaries([target])
                    nothing
                catch err
                    err
                end
                @test occursin("ssh, sshpass, rsync", sprint(showerror, missing_error))
            end
        end
    end

    @testset "Dry-run mode" begin
        globals = GlobalOptions(10, "accept-new", true, 0)
        push_opts = PushOptions(mktempdir(), String[".git"], false)
        pull_opts = PullOptions("/local/dst", "output", String[], String[], :resume, true)
        target1 = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "p1-secret", "/rem/sim_a")
        target2 = BridgeTarget("Node-B", "10.0.0.2", 22, "admin", "p2-secret", "/rem/sim_b")
        config = BridgeConfig(globals, push_opts, pull_opts, [target1, target2])

        push_results = push_all_targets(config; dry_run=true)
        @test length(push_results) == 2
        @test all(r -> r.success, push_results)
        @test all(r -> r.action == :push, push_results)
        @test all(r -> occursin("Dry run: sshpass -d 0 rsync", r.message), push_results)
        @test occursin("--stats --log-file=/local/dst/Node-A.push.rsync.log",
                       push_results[1].message)
        @test occursin("--log-file=/local/dst/Node-B.push.rsync.log",
                       push_results[2].message)

        pull_results = pull_all_targets(config; dry_run=true, clean_remote=true)
        @test length(pull_results) == 2
        @test all(r -> r.success, pull_results)
        @test all(r -> r.action == :pull, pull_results)
        @test all(r -> occursin("Dry run: sshpass -d 0 rsync", r.message), pull_results)
        @test occursin("--stats --log-file=/local/dst/Node-A.pull.rsync.log",
                       pull_results[1].message)
        @test all(r -> occursin("post-pull purge of '/rem/sim_", r.message), pull_results)
        @test occursin("post-pull purge of '/rem/sim_a' after a verification pass",
                       pull_results[1].message)

        filtered_config = BridgeConfig(globals, push_opts,
                                       PullOptions("/local/dst", "output", ["*.csv"],
                                                   String[], :resume, false),
                                       [target1, target2])
        @test_throws ArgumentError pull_all_targets(filtered_config; dry_run=true,
                                                    clean_remote=true)
        @test all(r -> !occursin("purge", r.message),
                  pull_all_targets(filtered_config; dry_run=true))

        output_config = BridgeConfig(globals, push_opts,
                                     PullOptions("/local/dst", "output", String[],
                                                 String[], :resume, true, :output),
                                     [target1, target2])
        output_clean = clean_all_remote_targets(output_config; dry_run=true)
        @test occursin("p=/rem/sim_a/output;", output_clean[1].message)

        clean_results = clean_all_remote_targets(config; dry_run=true)
        @test length(clean_results) == 2
        @test all(r -> r.success, clean_results)
        @test all(r -> r.action == :clean, clean_results)
        @test occursin("p=/rem/sim_a;", clean_results[1].message)
        @test occursin("rm -rf -- \"\$p\"", clean_results[1].message)
        @test occursin("ssh -n -p 22", clean_results[1].message)

        for result in vcat(push_results, pull_results, clean_results)
            @test !occursin("secret", result.message)
            @test !occursin("secret", sprint(show, result))
        end
    end

    @testset "Command-line driver" begin
        parse = SshDataBridge.parse_arguments
        @test parse(String[]).action == :help
        @test parse(["push", "--help"]).action == :help
        @test parse(["-h"]).action == :help
        options = parse(["pull", "--config", "/cfg/x.toml", "--dry-run", "--clean-remote",
                         "--yes"])
        @test options.action == :pull
        @test options.config_path == "/cfg/x.toml"
        @test options.dry_run && options.clean_remote && options.confirmed
        defaults = parse(["probe"]; default_config="/cfg/default.toml")
        @test defaults.config_path == "/cfg/default.toml"
        @test !(defaults.dry_run || defaults.clean_remote || defaults.confirmed)
        @test_throws ArgumentError parse(["nonsense"])
        @test_throws ArgumentError parse(["probe", "--bogus"])
        @test_throws ArgumentError parse(["probe", "--config"])
        @test_throws ArgumentError parse(["PULL"])
        @test_throws ArgumentError parse(["push", "--clean-remote"])
        @test_throws ArgumentError parse(["probe", "--yes"])
        @test_throws ArgumentError parse(["probe", "--config", "--dry-run"])
        @test_throws ArgumentError parse(["probe", "--config", "a.toml", "--config",
                                          "b.toml"])
        selected = parse(["pull", "--target", "a", "--target", "b"])
        @test selected.targets == ["a", "b"]
        @test isempty(parse(["probe"]).targets)
        @test_throws ArgumentError parse(["probe", "--target"])
        @test_throws ArgumentError parse(["probe", "--target", "--yes"])
        @test endswith(SshDataBridge.default_config_path(), "config.toml")

        # main returns the status instead of exiting and writes to the given streams
        io = IOBuffer()
        err = IOBuffer()
        @test SshDataBridge.main(String[]; io=io, err=err) == 0
        @test occursin("Usage:", String(take!(io)))
        @test isempty(take!(err))
        @test SshDataBridge.main(["clean", "--config", "/nonexistent/config.toml"]; io=io,
                                 err=err) == 1
        @test isempty(take!(io))
        @test occursin("configuration file not found", String(take!(err)))
        @test SshDataBridge.main(["probe", "--bogus"]; io=io, err=err) == 1
        @test occursin("unrecognized option '--bogus'", String(take!(err)))

        # A configuration error is printed without the exception type
        mktemp() do path, cfg
            write(cfg, "[push]\n")
            close(cfg)
            chmod(path, 0o644)
            @test SshDataBridge.main(["probe", "--config", path]; io=io, err=err) == 1
            @test occursin("\nError: Configuration file", String(take!(err)))
        end

        # An unsafe purge path is refused before any node is contacted
        mktemp() do path, cfg
            write(cfg, """
            [push]
            local_source_dir = "."
            [pull]
            local_destination_root = "harvest"
            [[targets]]
            name = "home"
            host = "192.0.2.10"
            user = "researcher"
            password = "pw"
            remote_dir = "/home/researcher"
            """)
            close(cfg)
            # The driver evaluates the ssh configuration of every target first; the
            # stubs answer that query
            with_stub_binaries() do _
                @test SshDataBridge.main(["clean", "--yes", "--config", path]; io=io,
                                         err=err) == 1
                @test occursin("protected path", String(take!(err)))
                @test isempty(take!(io))
                # An unknown --target is refused before anything runs
                @test SshDataBridge.main(["probe", "--target", "nowhere", "--config",
                                          path]; io=io, err=err) == 1
                @test occursin("unknown target(s): nowhere", String(take!(err)))
                @test isempty(take!(io))
            end
        end

        # Overlapping targets are refused when the configuration is loaded, whatever the
        # action or the selection
        mktemp() do path, cfg
            write(cfg, """
            [push]
            local_source_dir = "."
            [pull]
            local_destination_root = "harvest"
            [[targets]]
            name = "One"
            host = "192.0.2.10"
            user = "researcher"
            password = "pw"
            remote_dir = "/home/researcher/campaigns/batch"
            [[targets]]
            name = "Two"
            host = "192.0.2.10"
            user = "researcher"
            password = "pw"
            remote_dir = "/home/researcher/campaigns/batch/sub"
            """)
            close(cfg)
            with_stub_binaries() do _
                @test SshDataBridge.main(["probe", "--config", path]; io=io, err=err) == 1
                @test occursin("overlap", String(take!(err)))
                @test isempty(take!(io))
                @test SshDataBridge.main(["clean", "--yes", "--target", "One", "--config",
                                          path]; io=io, err=err) == 1
                @test occursin("overlap", String(take!(err)))
                @test isempty(take!(io))
            end
        end
    end

    @testset "Command-line scenarios" begin
        mktempdir() do dir
            config_path = joinpath(dir, "config.toml")
            write(config_path, SCENARIO_CONFIG)
            chmod(config_path, 0o600)
            # What a healthy node answers to the probe script, and what ssh prints when
            # the connection fails.
            markers = "RSYNC_OK\nDIR_EXISTS\nOUT_EXISTS"
            refusal = "stub: connection refused"
            for scenario in DRIVER_SCENARIOS
                @testset "$(scenario.description)" begin
                    outcome = with_stub_binaries(; exit_code=scenario.stub_exit,
                                                 stdout_text=markers,
                                                 stderr_text=refusal) do _
                        return invoke_driver(scenario.arguments, config_path;
                                             spawn=scenario.spawn)
                    end
                    @test outcome.exitcode == scenario.expected
                    @test !occursin(SCENARIO_PASSWORD, outcome.output)
                    for fragment in scenario.fragments
                        @test occursin(fragment, outcome.output)
                    end
                end
            end
        end
    end

    @testset "Endpoint evaluation in the driver" begin
        head = """
        [globals]
        connect_timeout = 5
        strict_host_key_checking = "accept-new"

        [push]
        local_source_dir = "."
        require_clean_git = false

        [pull]
        local_destination_root = "harvest"
        """
        markers = "RSYNC_OK\nDIR_EXISTS\nOUT_EXISTS"
        mktempdir() do dir
            identity = joinpath(dir, "id_test")
            write(identity, "stub key\n")
            chmod(identity, 0o600)
            function write_config(name, targets)
                path = joinpath(dir, name)
                write(path, head * targets)
                chmod(path, 0o600)
                return path
            end
            function key_entry(name, host, remote_dir)
                return "\n[[targets]]\nname = \"$(name)\"\nhost = \"$(host)\"\n" *
                       "auth = \"key\"\nidentity_file = \"$(identity)\"\n" *
                       "remote_dir = \"$(remote_dir)\"\n"
            end

            # Two aliases of one host: the lexical check passes, the evaluated one refuses
            aliases = write_config("aliases.toml",
                                   key_entry("hpc", "hpc", "/scratch/shared/campaign") *
                                   key_entry("hpc-login", "hpc-login",
                                             "/scratch/shared/campaign"))
            hostnames = "hpc=login.example.org,hpc-login=login.example.org"
            for arguments in (["probe"], ["probe", "--target", "hpc"])
                outcome = with_stub_binaries(; g_hostnames=hostnames) do _
                    return invoke_driver(arguments, aliases)
                end
                @test outcome.exitcode == 1
                @test occursin("same host and port", outcome.output)
            end
            # Distinct hosts behind the aliases are accepted
            outcome = with_stub_binaries(; stdout_text=markers) do _
                return invoke_driver(["probe"], aliases)
            end
            @test outcome.exitcode == 0

            # A failing ssh -G stops the run
            single = write_config("single.toml",
                                  key_entry("hpc", "hpc", "/scratch/shared/campaign"))
            outcome = with_stub_binaries(; g_exit_code=255, stdout_text=markers) do _
                return invoke_driver(["probe"], single)
            end
            @test outcome.exitcode == 1
            @test occursin("could not evaluate its configuration", outcome.output)

            # A jump host from the ssh configuration is reported for a password target
            scenario = joinpath(dir, "scenario.toml")
            write(scenario, SCENARIO_CONFIG)
            chmod(scenario, 0o600)
            plain = with_stub_binaries(; stdout_text=markers) do _
                return invoke_driver(["probe"], scenario)
            end
            routed = with_stub_binaries(; stdout_text=markers,
                                        g_proxyjump="admin@gw.example.org") do _
                return invoke_driver(["probe"], scenario)
            end
            @test routed.exitcode == plain.exitcode
            @test occursin("jump host", routed.output)
            @test !occursin("jump host", plain.output)

            # The user of a key target without one comes from ssh -G
            homeless = write_config("homeless.toml",
                                    key_entry("hpc", "hpc", "/home/stubuser"))
            outcome = with_stub_binaries(; stdout_text=markers) do _
                return invoke_driver(["clean", "--yes"], homeless)
            end
            @test outcome.exitcode == 1
            @test occursin("protected path", outcome.output)

            # A push of a key target claims the directory and transfers without sshpass
            pushed = with_stub_binaries(; stdout_text=markers) do args_file
                outcome = invoke_driver(["push"], single)
                return (; outcome, lines=recorded_invocations(args_file),
                        queries=recorded_config_queries(args_file))
            end
            @test pushed.outcome.exitcode == 0
            @test !isempty(pushed.queries)
            @test !any(occursin("sshpass", line) for line in pushed.lines)
            @test !any(startswith("-d 0 "), pushed.lines)
            @test any(startswith(line, "-n ") && occursin(".sshdatabridge-target", line)
                      for line in pushed.lines)
            @test any(startswith("-a --partial"), pushed.lines)
        end
    end

    # Opt-in: runs an unprivileged sshd on 127.0.0.1 with throwaway keys.
    if get(ENV, "SSHDATABRIDGE_SSHD_TESTS", "") == "1"
        include("sshd_integration.jl")
    end
end
