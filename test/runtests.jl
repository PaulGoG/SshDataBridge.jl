using Test
using SshDataBridge
using Aqua
using JET
using ExplicitImports
using TOML: TOML

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
        # Valid Target
        t = BridgeTarget("Node-01",
                         "192.168.1.50",
                         22,
                         "admin",
                         "secret",
                         "/opt/sims",
                         "results",
                         "accept-new")
        @test t.name == "Node-01"
        @test t.host == "192.168.1.50"
        @test t.port == 22
        @test t.user == "admin"
        @test t.password == "secret"
        @test t.remote_dir == "/opt/sims"
        @test t.output_subdir == "results"
        @test t.strict_host_key_checking == "accept-new"

        # Default output_subdir
        t_default = BridgeTarget("Node-02", "10.0.0.1", 2222, "root", "toor", "/tmp/sim")
        @test t_default.output_subdir == "output"
        @test t_default.strict_host_key_checking === nothing

        # Target Validation Failures
        @test_throws ArgumentError BridgeTarget("",
                                                "192.168.1.50",
                                                22,
                                                "admin",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1", "", 22, "admin", "pass", "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.1 0",
                                                22,
                                                "admin",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                0,
                                                "admin",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                70000,
                                                "admin",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "admin user",
                                                "pass",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "admin",
                                                "",
                                                "/dir")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "admin",
                                                "pass",
                                                "")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "admin",
                                                "pass",
                                                "/dir",
                                                "")
        @test_throws ArgumentError BridgeTarget("N1",
                                                "192.168.1.50",
                                                22,
                                                "admin",
                                                "pass",
                                                "/dir",
                                                "out",
                                                "invalid_policy")

        # Global Options Validation
        g_valid = GlobalOptions(15, "yes", true, 5000)
        @test g_valid.connect_timeout == 15
        @test g_valid.strict_host_key_checking == "yes"
        @test g_valid.compress == true
        @test g_valid.bandwidth_limit == 5000

        @test_throws ArgumentError GlobalOptions(0, "accept-new", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "invalid_policy", true, 0)
        @test_throws ArgumentError GlobalOptions(10, "accept-new", true, -10)

        # Push Options Validation
        p_valid = PushOptions("/local/src", ["*.tmp"], true)
        @test p_valid.local_source_dir == "/local/src"
        @test p_valid.excludes == ["*.tmp"]
        @test p_valid.require_clean_git == true
        @test_throws ArgumentError PushOptions("")

        # Pull Options Validation
        pull_valid = PullOptions("/local/dest",
                                 "output_dir",
                                 ["*.csv"],
                                 ["*.tmp"],
                                 :backup,
                                 true)
        @test pull_valid.local_destination_root == "/local/dest"
        @test pull_valid.output_subdir == "output_dir"
        @test pull_valid.includes == ["*.csv"]
        @test pull_valid.excludes == ["*.tmp"]
        @test pull_valid.collision_strategy == :backup
        @test pull_valid.clean_remote_after_pull == true

        @test_throws ArgumentError PullOptions("")
        @test_throws ArgumentError PullOptions("/local/dest", "")
        @test_throws ArgumentError PullOptions("/local/dest",
                                               "output",
                                               String[],
                                               String[],
                                               :invalid_strategy)

        # Remote Path Safety Validation
        @test validate_remote_path_safety("/home/user/campaigns/sim01", "user") === nothing
        @test validate_remote_path_safety("/scratch/paulgog/batch1", "paulgog") === nothing
        @test_throws ArgumentError validate_remote_path_safety("", "user")
        @test_throws ArgumentError validate_remote_path_safety("/", "user")
        @test_throws ArgumentError validate_remote_path_safety("/root", "user")
        @test_throws ArgumentError validate_remote_path_safety("/home", "user")
        @test_throws ArgumentError validate_remote_path_safety("/home/user", "user")
        @test_throws ArgumentError validate_remote_path_safety("/home/user/", "user")
        @test_throws ArgumentError validate_remote_path_safety("~", "user")
        @test_throws ArgumentError validate_remote_path_safety("/single", "user")
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
            @test t2.output_subdir == "results"  # Inherited from [pull].output_subdir
            @test t2.strict_host_key_checking == "accept-new"
        end

        # Missing target array
        @test_throws ArgumentError parse_config(Dict{String, Any}("globals" => Dict()))
        # Empty target array
        @test_throws ArgumentError parse_config(Dict{String, Any}("targets" => Any[]))
    end

    @testset "Command Construction & Collision Strategies" begin
        globals = GlobalOptions(12, "accept-new", true, 2048)
        push_opts = PushOptions("/local/workspace", [".git", "*.tmp"], false)
        pull_opts_resume = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"],
                                       :resume, false)
        pull_opts_backup = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"],
                                       :backup, true)
        pull_opts_abort = PullOptions("/local/harvest", "output", ["*.csv"], ["*.tmp"],
                                      :abort, false)

        target = BridgeTarget("RTX-Node",
                              "10.0.0.5",
                              2222,
                              "paulgog",
                              "p@ssword#1",
                              "/srv/sim_01",
                              "results")

        # Push Command Construction
        push_cmd = build_push_command(target, globals, push_opts)
        @test push_cmd.exec[1] == "sshpass"
        @test push_cmd.exec[2] == "-e"
        @test push_cmd.exec[3] == "rsync"
        @test "-av" in push_cmd.exec
        @test "--partial" in push_cmd.exec
        @test "-z" in push_cmd.exec
        @test "--bwlimit=2048" in push_cmd.exec
        @test "--exclude=.git" in push_cmd.exec
        @test "--exclude=*.tmp" in push_cmd.exec
        @test "-e" in push_cmd.exec
        @test any(occursin("ssh -p 2222", arg) for arg in push_cmd.exec)
        @test any(occursin("StrictHostKeyChecking=accept-new", arg)
                  for arg in push_cmd.exec)
        @test any(endswith(arg, "/srv/sim_01/") for arg in push_cmd.exec)
        @test push_cmd.env !== nothing
        @test any(startswith(e, "SSHPASS=") for e in push_cmd.env)

        # Pull Command Construction
        pull_cmd = build_pull_command(target, globals, pull_opts_resume,
                                      "/local/harvest/RTX-Node")
        @test pull_cmd.exec[1] == "sshpass"
        @test pull_cmd.exec[2] == "-e"
        @test pull_cmd.exec[3] == "rsync"
        @test "--include=*.csv" in pull_cmd.exec
        @test "--exclude=*.tmp" in pull_cmd.exec
        @test any(occursin("/srv/sim_01/results/", arg) for arg in pull_cmd.exec)
        @test any(occursin("/local/harvest/RTX-Node/", arg) for arg in pull_cmd.exec)

        # Collision Strategy Preparation
        mktempdir() do tmpdir
            pull_test_opts = PullOptions(tmpdir, "output", String[], String[], :resume,
                                         false)
            dest_dir = prepare_local_pull_directory(target, pull_test_opts)
            @test isdir(dest_dir)
            @test dest_dir == joinpath(tmpdir, "RTX-Node")

            # Write a marker file
            marker = joinpath(dest_dir, "test.txt")
            write(marker, "data")

            # Resume preserves directory
            dest_dir2 = prepare_local_pull_directory(target, pull_test_opts)
            @test isfile(marker)

            # Backup renames existing directory
            pull_backup_opts = PullOptions(tmpdir, "output", String[], String[], :backup,
                                           false)
            dest_dir3 = prepare_local_pull_directory(target, pull_backup_opts)
            @test isdir(dest_dir3)
            @test isdir("$(dest_dir3)#1")
            @test isfile(joinpath("$(dest_dir3)#1", "test.txt"))

            # Abort throws exception
            pull_abort_opts = PullOptions(tmpdir, "output", String[], String[], :abort,
                                          false)
            @test_throws ErrorException prepare_local_pull_directory(target,
                                                                     pull_abort_opts)
        end
    end

    @testset "Dry-Run Dispatch & Cleanup Execution" begin
        globals = GlobalOptions(10, "accept-new", true, 0)
        push_opts = PushOptions("/local/src", String[".git"], false)
        pull_opts = PullOptions("/local/dst", "output", String[], String[], :resume, true)

        target1 = BridgeTarget("Node-A", "10.0.0.1", 22, "admin", "p1", "/rem/sim_a")
        target2 = BridgeTarget("Node-B", "10.0.0.2", 22, "admin", "p2", "/rem/sim_b")

        config = BridgeConfig(globals, push_opts, pull_opts, [target1, target2])

        # Push Dry Run
        push_results = push_all_targets(config; dry_run=true)
        @test length(push_results) == 2
        @test all(r -> r.success, push_results)
        @test all(r -> r.action == :push, push_results)
        @test all(r -> occursin("Dry run:", r.message), push_results)

        # Pull Dry Run with Post-Clean
        pull_results = pull_all_targets(config; dry_run=true, clean_remote=true)
        @test length(pull_results) == 2
        @test all(r -> r.success, pull_results)
        @test all(r -> r.action == :pull, pull_results)
        @test all(r -> occursin("Dry run:", r.message), pull_results)
        @test all(r -> occursin("Post-clean: rm -rf", r.message), pull_results)

        # Standalone Clean Dry Run
        clean_results = clean_all_remote_targets(config; dry_run=true)
        @test length(clean_results) == 2
        @test all(r -> r.success, clean_results)
        @test all(r -> r.action == :clean, clean_results)
        @test all(r -> occursin("rm -rf -- '/rem/sim_a'", clean_results[1].message),
                  clean_results)
    end
end
