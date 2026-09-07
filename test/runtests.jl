using Test
using SshDataBridge
using Aqua
using JET
using ExplicitImports

const STUB_SCRIPT = raw"""
#!/bin/sh
if [ "$3" = "rsync" ]; then
    code="${STUB_RSYNC_EXIT_CODE:-${STUB_EXIT_CODE:-0}}"
else
    code="${STUB_EXIT_CODE:-0}"
fi
if [ -n "${STUB_ARGS_FILE:-}" ]; then
    printf '%s\n' "$*" >> "$STUB_ARGS_FILE"
fi
printf '%s\n' "${STUB_STDOUT:-}"
printf '%s\n' "${STUB_STDERR:-stub stderr}" >&2
exit "$code"
"""

"""
    with_stub_binaries(f; exit_code, rsync_exit_code, stdout_text, stderr_text)

Run `f(args_file)` with stub `sshpass`, `ssh`, and `rsync` executables placed first on
`PATH`. The stubs print `stdout_text` and `stderr_text`, append their argument vector to
`args_file`, and exit with `exit_code` (or `rsync_exit_code` when the third argument is
`rsync`, i.e. for transfer commands).
"""
function with_stub_binaries(f; exit_code::Integer=0,
                            rsync_exit_code::Union{Nothing, Integer}=nothing,
                            stdout_text::AbstractString="",
                            stderr_text::AbstractString="stub stderr")
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
                "STUB_STDOUT" => stdout_text,
                "STUB_STDERR" => stderr_text,
                "STUB_ARGS_FILE" => args_file) do
            return f(args_file)
        end
    end
end

recorded_invocations(args_file) = isfile(args_file) ? readlines(args_file) : String[]

@testset "SshDataBridge.jl" begin
    @testset "Static Code Quality Analysis (QA)" begin
        @testset "Aqua.jl" begin
            Aqua.test_all(SshDataBridge)
        end

        @testset "JET.jl Static Analysis" begin
            JET.test_package(SshDataBridge; target_modules=[SshDataBridge])
        end

        @testset "ExplicitImports.jl" begin
            @test ExplicitImports.check_no_implicit_imports(SshDataBridge) === nothing
            @test ExplicitImports.check_no_stale_explicit_imports(SshDataBridge) === nothing
        end
    end

    @testset "Field Validation & Boundary Handling" begin
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

        for host in ("localhost", "node01.cluster.local", "10.0.0.1", "::1",
                     "2001:db8::10", "[2001:db8::10]", "a-b.example.org.")
            @test BridgeTarget("N", host, 22, "u", "p", "/d/e").host == host
        end

        function valid_target(; name="N1", host="192.168.1.50", port=22, user="admin",
                              password="pass", remote_dir="/dir/sub", output_subdir="out",
                              policy=nothing)
            return BridgeTarget(name, host, port, user, password, remote_dir,
                                output_subdir, policy)
        end
        @test valid_target() isa BridgeTarget
        for name in ("", "-lead", "bad/name", "..", "a b", "x"^65)
            @test_throws ArgumentError valid_target(; name=name)
        end
        for host in ("", "192.168.1.1 0", "-bad.example", "a..b", "host_name", "x"^254,
                     "bad;rm -rf /", "\$(id)")
            @test_throws ArgumentError valid_target(; host=host)
        end
        @test_throws ArgumentError valid_target(; port=0)
        @test_throws ArgumentError valid_target(; port=70000)
        for user in ("", "admin user", "-x", "a@b", "x"^33, "u;id")
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
        for dir in ("", "rel/dir", "/", "//", "/a/../b", "/a\nb")
            @test_throws ArgumentError valid_target(; remote_dir=dir)
        end
        for sub in ("", "/abs", "../up", "a/../b", "a\tb")
            @test_throws ArgumentError valid_target(; output_subdir=sub)
        end
        @test_throws ArgumentError valid_target(; policy="invalid_policy")

        g_valid = GlobalOptions(15, "yes", true, 5000)
        @test g_valid.connect_timeout == 15
        @test g_valid.strict_host_key_checking == "yes"
        @test g_valid.compress == true
        @test g_valid.bandwidth_limit == 5000
        @test_throws ArgumentError GlobalOptions(0, "accept-new", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "invalid_policy", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "accept-new", true, -10)

        p_valid = PushOptions("/local/src", ["*.tmp"], true, true)
        @test p_valid.local_source_dir == "/local/src"
        @test p_valid.excludes == ["*.tmp"]
        @test p_valid.require_clean_git == true
        @test p_valid.use_gitignore == true
        @test PushOptions("/x").excludes == SshDataBridge.DEFAULT_PUSH_EXCLUDES
        @test_throws ArgumentError PushOptions("")
        @test_throws ArgumentError PushOptions("/x", [""])
        @test_throws ArgumentError PushOptions("/x", ["a\nb"])
        @test_throws ArgumentError PushOptions("/x", Any[1])

        pull_valid = PullOptions("/local/dest", "output_dir", ["*.csv"], ["*.tmp"],
                                 :backup, true)
        @test pull_valid.local_destination_root == "/local/dest"
        @test pull_valid.output_subdir == "output_dir"
        @test pull_valid.includes == ["*.csv"]
        @test pull_valid.excludes == ["*.tmp"]
        @test pull_valid.collision_strategy == :backup
        @test pull_valid.clean_remote_after_pull == true
        @test PullOptions("/x").excludes == SshDataBridge.DEFAULT_PULL_EXCLUDES
        @test PullOptions("/x").purge_scope == :output
        @test PullOptions("/x", "output", String[], String[], :resume, false,
                          :project).purge_scope == :project
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

    @testset "TOML Configuration Ingestion" begin
        toml_content = """
        [globals]
        connect_timeout = 20
        strict_host_key_checking = "yes"
        compress = false
        bandwidth_limit = 1024

        [push]
        local_source_dir = "./src_payload"
        excludes = [".git", "data/output"]
        require_clean_git = true

        [pull]
        local_destination_root = "./harvested_data"
        output_subdir = "results"
        includes = ["*.jld2", "*.csv"]
        excludes = ["*.tmp"]
        collision_strategy = "backup"
        clean_remote_after_pull = true
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

            @test occursin("src_payload", config.push.local_source_dir)
            @test config.push.excludes == [".git", "data/output"]
            @test config.push.require_clean_git == true

            @test occursin("harvested_data", config.pull.local_destination_root)
            @test config.pull.output_subdir == "results"
            @test config.pull.includes == ["*.jld2", "*.csv"]
            @test config.pull.excludes == ["*.tmp"]
            @test config.pull.collision_strategy == :backup
            @test config.pull.clean_remote_after_pull == true
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
        @test_throws ArgumentError parse_config(Dict{String, Any}("pull" =>
                                                                      Dict{String, Any}("purge_scope" => "everything"),
                                                                  "targets" =>
                                                                      Any[Dict{String, Any}("host" => "10.0.0.1",
                                                                                            "user" => "u",
                                                                                            "password" => "p",
                                                                                            "remote_dir" => "/a/b")]))

        # Malformed TOML, unknown keys, wrong types, and missing mandatory keys fail fast
        mktemp() do path, io
            write(io, "[globals]\nconnect_timeout = [1,\n")
            close(io)
            @test_throws ArgumentError load_config(path)
        end
        @test_throws ArgumentError load_config(joinpath(@__DIR__, "does-not-exist.toml"))

        minimal_target() = Dict{String, Any}("host" => "10.0.0.1", "user" => "u",
                                             "password" => "p", "remote_dir" => "/a/b")
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

        @test parse_config(Dict{String, Any}("targets" => Any[minimal_target()])) isa
              BridgeConfig
        @test occursin("'typo'",
                       config_error_message(Dict{String, Any}("typo" => 1,
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("[pull]",
                       config_error_message(Dict{String, Any}("pull" =>
                                                                  Dict{String, Any}("purge_scopes" => "output"),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("[[targets]] entry #1",
                       config_error_message(Dict{String, Any}("targets" =>
                                                                  Any[merge(minimal_target(),
                                                                            Dict("hostname" => "x"))])))
        @test occursin("must be an integer",
                       config_error_message(Dict{String, Any}("globals" =>
                                                                  Dict{String, Any}("connect_timeout" => "10"),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("must be an integer",
                       config_error_message(Dict{String, Any}("targets" =>
                                                                  Any[merge(minimal_target(),
                                                                            Dict("port" =>
                                                                                     true))])))
        @test occursin("must be a boolean",
                       config_error_message(Dict{String, Any}("globals" =>
                                                                  Dict{String, Any}("compress" =>
                                                                                        1),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("must be a string",
                       config_error_message(Dict{String, Any}("pull" =>
                                                                  Dict{String, Any}("purge_scope" =>
                                                                                        3),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("array of strings",
                       config_error_message(Dict{String, Any}("push" =>
                                                                  Dict{String, Any}("excludes" => "x"),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("Entry #2",
                       config_error_message(Dict{String, Any}("push" =>
                                                                  Dict{String, Any}("excludes" =>
                                                                                        Any["a",
                                                                                            2]),
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("must be a table",
                       config_error_message(Dict{String, Any}("globals" => 5,
                                                              "targets" =>
                                                                  Any[minimal_target()])))
        @test occursin("array of tables",
                       config_error_message(Dict{String, Any}("targets" => "x")))
        @test occursin("entry #1 must be a table",
                       config_error_message(Dict{String, Any}("targets" => Any[1])))
        for mandatory in ("host", "user", "password", "remote_dir")
            incomplete = minimal_target()
            delete!(incomplete, mandatory)
            message = config_error_message(Dict{String, Any}("targets" => Any[incomplete]))
            @test occursin("'[[targets]] entry #1.$(mandatory)' is mandatory", message)
        end

        # Relative local paths resolve against the configuration directory; ~ expands
        resolved = parse_config(Dict{String, Any}("push" =>
                                                      Dict{String, Any}("local_source_dir" => "src"),
                                                  "pull" =>
                                                      Dict{String, Any}("local_destination_root" => "~/harvest"),
                                                  "targets" => Any[minimal_target()]);
                                config_dir="/cfg/dir")
        @test resolved.push.local_source_dir == "/cfg/dir/src"
        @test resolved.pull.local_destination_root == joinpath(homedir(), "harvest")
        @test resolved.targets[1].name == "Target-1"
        @test resolved.targets[1].port == 22
    end

    @testset "Git Working Tree Requirement" begin
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

    @testset "Command Construction & Collision Strategies" begin
        globals = GlobalOptions(12, "accept-new", true, 2048)
        push_opts = PushOptions("/local/workspace", [".git", "*.tmp"], false)
        pull_opts_resume = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"],
                                       :resume, false)
        target = BridgeTarget("RTX-Node", "10.0.0.5", 2222, "worker", "p@ssword#1",
                              "/srv/sim_01", "results")

        push_cmd = build_push_command(target, globals, push_opts)
        @test push_cmd.exec[1:4] == ["sshpass", "-d", "0", "rsync"]
        @test push_cmd.env === nothing
        @test "-av" in push_cmd.exec
        @test "--partial" in push_cmd.exec
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
        @test push_cmd.exec[end - 1] == "/local/workspace/"
        @test push_cmd.exec[end] == "worker@10.0.0.5:/srv/sim_01/"

        pull_cmd = build_pull_command(target, globals, pull_opts_resume,
                                      "/local/harvest/RTX-Node")
        @test pull_cmd.exec[1:4] == ["sshpass", "-d", "0", "rsync"]
        @test pull_cmd.env === nothing
        @test "--include=*.csv" in pull_cmd.exec
        @test "--exclude=*.tmp" in pull_cmd.exec
        @test pull_cmd.exec[end - 1] == "worker@10.0.0.5:/srv/sim_01/results/"
        @test pull_cmd.exec[end] == "/local/harvest/RTX-Node/"

        # IPv6 literals are bracketed for rsync endpoints only
        ipv6_target = BridgeTarget("V6", "2001:db8::10", 22, "worker", "pw", "/srv/sim")
        ipv6_push = build_push_command(ipv6_target, globals, push_opts)
        @test ipv6_push.exec[end] == "worker@[2001:db8::10]:/srv/sim/"
        @test SshDataBridge.build_ssh_command(ipv6_target, globals, "true").exec[end - 1] ==
              "worker@2001:db8::10"

        @test purge_path(target, :output) == "/srv/sim_01/results"
        @test purge_path(target, :project) == "/srv/sim_01"
        @test_throws ArgumentError purge_path(target, :bogus)

        # Remote commands are POSIX-quoted and use ssh -n with a single password prompt
        spaced = BridgeTarget("Spaced", "10.0.0.9", 22, "worker", "pw", "/srv/sim a",
                              "out b")
        probe_cmd = SshDataBridge.build_ssh_command(spaced, globals,
                                                    SshDataBridge.build_probe_script(spaced))
        @test probe_cmd.exec[1:5] == ["sshpass", "-d", "0", "ssh", "-n"]
        @test "NumberOfPasswordPrompts=1" in probe_cmd.exec
        @test occursin("test -d '/srv/sim a'", probe_cmd.exec[end])
        @test occursin("test -d '/srv/sim a/out b'", probe_cmd.exec[end])

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
    end

    @testset "Credential Handling & Redaction" begin
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

        # A missing executable propagates as an IOError
        @test_throws Base.IOError run_authenticated(`definitely-missing-binary-xyz`,
                                                    password)

        # command_string never renders the environment
        secret_cmd = setenv(`echo hello`, "SSHPASS" => password)
        @test command_string(secret_cmd) == "echo hello"
        @test !occursin(password, command_string(secret_cmd))
        @test command_string(`rm -rf -- "/a b"`) == "rm -rf -- '/a b'"

        # Printed representations of targets and results are redacted
        @test sprint(show, target) ==
              "BridgeTarget(\"Node-A\", admin@10.0.0.1:22, remote_dir = \"/rem/sim_a\", output_subdir = \"output\", password = <redacted>)"
        @test !occursin(password, repr(target))
        @test !occursin(password, sprint(show, MIME("text/plain"), target))
        probe = ProbeResult(target, true, true, true, true, true, "ok")
        @test !occursin(password, sprint(show, probe))
        transfer = TransferResult(target, :push, true, 0, 1.0, "ok")
        @test !occursin(password, sprint(show, transfer))
        @test !occursin(password, repr([transfer]))
    end

    @testset "Process Execution (stub binaries)" begin
        globals = GlobalOptions(10, "accept-new", false, 0)
        push_opts = PushOptions("/local/src", String[".git"], false)
        target = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "pw-A", "/rem/sim a")

        with_stub_binaries(; stdout_text="RSYNC_OK\nDIR_EXISTS\nOUT_MISSING") do args_file
            result = probe_target(target, globals)
            @test result.ssh_ok
            @test result.rsync_ok
            @test result.remote_dir_exists
            @test !result.remote_output_dir_exists
            @test result.success
            @test occursin("remote output dir missing", result.message)
            invocation = only(recorded_invocations(args_file))
            @test occursin("test -d '/rem/sim a'", invocation)
            @test occursin("-n -p 22", invocation)
        end

        with_stub_binaries(; exit_code=255, stderr_text="Connection refused") do _
            result = probe_target(target, globals)
            @test !result.ssh_ok
            @test !result.success
            @test occursin("255", result.message)
            @test occursin("Connection refused", result.message)
        end

        with_stub_binaries() do args_file
            directory = ensure_remote_directory(target, globals, "/rem/sim a")
            @test directory.success
            @test directory.exitcode == 0
            @test occursin("mkdir -p -- '/rem/sim a'",
                           only(recorded_invocations(args_file)))
        end

        with_stub_binaries(; exit_code=1, stderr_text="mkdir: permission denied") do _
            directory = ensure_remote_directory(target, globals, "/rem/sim a")
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

            # A failing remote mkdir stops the push before rsync runs
            with_stub_binaries(; exit_code=1, rsync_exit_code=0,
                               stderr_text="mkdir failed") do args_file
                result = push_target(target, config)
                @test !result.success
                @test result.exit_code == 1
                @test occursin("Remote directory creation failed", result.message)
                @test length(recorded_invocations(args_file)) == 1
            end

            with_stub_binaries() do _
                results = push_all_targets(config)
                @test length(results) == 1
                @test results[1].success
                @test results[1].exit_code == 0
            end

            with_stub_binaries(; exit_code=255, stderr_text="timed out") do _
                result = pull_target(target, config)
                @test !result.success
                @test result.exit_code == 255
                @test occursin("timed out", result.message)
                @test isdir(joinpath(harvest_root, "Node-A"))
            end

            with_stub_binaries() do args_file
                result = pull_target(target, config; clean_remote=true)
                @test result.success
                @test occursin("Harvested successfully", result.message)
                @test occursin("purged", result.message)
                invocations = recorded_invocations(args_file)
                @test length(invocations) == 2
                @test occursin("rm -rf -- '/rem/sim a/output'", invocations[2])
            end

            # A filtered harvest never purges, whatever the flags say
            filtered_opts = PullOptions(harvest_root, "output", ["*.csv"], String[],
                                        :resume, true)
            filtered_config = BridgeConfig(globals, push_opts, filtered_opts, [target])
            with_stub_binaries() do args_file
                result = pull_target(target, filtered_config; clean_remote=true)
                @test result.success
                @test occursin("purge skipped", result.message)
                @test length(recorded_invocations(args_file)) == 1
            end

            # Project scope removes the base directory
            with_stub_binaries() do args_file
                result = clean_remote_target(target, globals; scope=:project)
                @test result.success
                @test occursin("project scope", result.message)
                @test occursin("rm -rf -- '/rem/sim a'",
                               only(recorded_invocations(args_file)))
            end
            project_opts = PullOptions(harvest_root, "output", String[], String[], :resume,
                                       false, :project)
            project_config = BridgeConfig(globals, push_opts, project_opts, [target])
            with_stub_binaries() do args_file
                results = clean_all_remote_targets(project_config)
                @test only(results).success
                @test occursin("rm -rf -- '/rem/sim a'",
                               only(recorded_invocations(args_file)))
            end

            with_stub_binaries(; exit_code=1, stderr_text="rm: cannot remove") do _
                result = clean_remote_target(target, globals)
                @test !result.success
                @test result.exit_code == 1
                @test occursin("rm: cannot remove", result.message)
            end

            with_stub_binaries() do _
                results = pull_all_targets(config)
                @test length(results) == 1
                @test results[1].success
            end
        end

        # No password may reach any stub through the environment or the arguments
        with_stub_binaries() do args_file
            probe_target(target, globals)
            @test !occursin("pw-A", read(args_file, String))
        end

        mktempdir() do empty_dir
            withenv("PATH" => empty_dir) do
                @test_throws MissingBinaryError check_local_binaries()
                missing_error = try
                    check_local_binaries()
                    nothing
                catch err
                    err
                end
                @test occursin("ssh, sshpass, rsync", sprint(showerror, missing_error))
            end
        end
    end

    @testset "Dry-Run Dispatch" begin
        globals = GlobalOptions(10, "accept-new", true, 0)
        push_opts = PushOptions("/local/src", String[".git"], false)
        pull_opts = PullOptions("/local/dst", "output", String[], String[], :resume, true)
        target1 = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "p1-secret", "/rem/sim_a")
        target2 = BridgeTarget("Node-B", "10.0.0.2", 22, "admin", "p2-secret", "/rem/sim_b")
        config = BridgeConfig(globals, push_opts, pull_opts, [target1, target2])

        push_results = push_all_targets(config; dry_run=true)
        @test length(push_results) == 2
        @test all(r -> r.success, push_results)
        @test all(r -> r.action == :push, push_results)
        @test all(r -> occursin("Dry run: sshpass -d 0 rsync", r.message), push_results)

        pull_results = pull_all_targets(config; dry_run=true, clean_remote=true)
        @test length(pull_results) == 2
        @test all(r -> r.success, pull_results)
        @test all(r -> r.action == :pull, pull_results)
        @test all(r -> occursin("Dry run: sshpass -d 0 rsync", r.message), pull_results)
        @test all(r -> occursin("post-pull purge of '/rem/sim_", r.message), pull_results)
        @test occursin("post-pull purge of '/rem/sim_a/output'", pull_results[1].message)

        filtered_config = BridgeConfig(globals, push_opts,
                                       PullOptions("/local/dst", "output", ["*.csv"],
                                                   String[], :resume, true),
                                       [target1, target2])
        filtered_results = pull_all_targets(filtered_config; dry_run=true)
        @test all(r -> occursin("purge skipped", r.message), filtered_results)

        project_config = BridgeConfig(globals, push_opts,
                                      PullOptions("/local/dst", "output", String[],
                                                  String[], :resume, true, :project),
                                      [target1, target2])
        project_clean = clean_all_remote_targets(project_config; dry_run=true)
        @test endswith(project_clean[1].message, "'rm -rf -- /rem/sim_a'")

        clean_results = clean_all_remote_targets(config; dry_run=true)
        @test length(clean_results) == 2
        @test all(r -> r.success, clean_results)
        @test all(r -> r.action == :clean, clean_results)
        @test endswith(clean_results[1].message, "'rm -rf -- /rem/sim_a/output'")
        @test occursin("ssh -n -p 22", clean_results[1].message)

        for result in vcat(push_results, pull_results, clean_results)
            @test !occursin("secret", result.message)
            @test !occursin("secret", sprint(show, result))
        end
    end
end
