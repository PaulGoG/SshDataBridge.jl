# The driver against an unprivileged OpenSSH server on 127.0.0.1, with throwaway keys.
# Every file lives in one temporary directory. OpenSSH reads ~/.ssh regardless of $HOME,
# so the client is isolated by a wrapper on PATH that passes -F to every ssh started.

@testset "Loopback sshd" begin
    function locate(name)
        path = Sys.which(name)
        path === nothing && error("SSHDATABRIDGE_SSHD_TESTS=1, but $(name) was not found")
        return abspath(path)
    end
    ssh = locate("ssh")
    ssh_keygen = locate("ssh-keygen")
    ssh_agent = locate("ssh-agent")
    ssh_add = locate("ssh-add")
    locate("rsync")
    # sshd re-executes itself and must be started by its absolute path
    sshd = Sys.which("sshd")
    if sshd === nothing && isfile("/usr/sbin/sshd")
        sshd = "/usr/sbin/sshd"
    end
    sshd === nothing && error("SSHDATABRIDGE_SSHD_TESTS=1, but sshd was not found")
    sshd = abspath(sshd)

    mktempdir() do lab
        chmod(lab, 0o700)
        quiet(cmd) = run(pipeline(cmd; stdin=devnull, stdout=devnull, stderr=devnull))
        function keygen(path, passphrase)
            return quiet(Cmd([ssh_keygen, "-q", "-t", "ed25519", "-N", passphrase, "-C",
                              "", "-f", path]))
        end

        host_key = joinpath(lab, "host_ed25519")
        keygen(host_key, "")
        # The space exercises the quoting of the rsync remote-shell string
        mkpath(joinpath(lab, "keys dir"))
        plain_key = joinpath(lab, "keys dir", "id_plain")
        keygen(plain_key, "")
        enc_key = joinpath(lab, "id_enc")
        keygen(enc_key, "labpass")

        authorized_keys = joinpath(lab, "authorized_keys")
        write(authorized_keys,
              read(plain_key * ".pub", String) * read(enc_key * ".pub", String))
        chmod(authorized_keys, 0o600)

        askpass = joinpath(lab, "askpass_pass")
        write(askpass, "#!/bin/sh\necho labpass\n")
        chmod(askpass, 0o700)

        sshd_config = joinpath(lab, "sshd_config")
        sshd_log = joinpath(lab, "sshd.log")
        pid_file = joinpath(lab, "sshd.pid")
        function write_sshd_config(port)
            write(sshd_config, """
                  Port $(port)
                  ListenAddress 127.0.0.1
                  HostKey $(host_key)
                  PidFile $(pid_file)
                  AuthorizedKeysFile $(authorized_keys)
                  UsePAM no
                  StrictModes no
                  PasswordAuthentication yes
                  KbdInteractiveAuthentication no
                  PubkeyAuthentication yes
                  LogLevel VERBOSE
                  """)
            return nothing
        end
        function log_tail()
            isfile(sshd_log) || return "(no sshd log)"
            return join(last(readlines(sshd_log), 20), "\n")
        end

        port = 0
        process = nothing
        for _ in 1:10
            port = rand(20000:60000)
            write_sshd_config(port)
            rm(pid_file; force=true)
            candidate = run(pipeline(`$sshd -D -f $(sshd_config) -E $(sshd_log)`;
                                     stdin=devnull, stdout=devnull, stderr=devnull);
                            wait=false)
            deadline = time() + 5
            while !isfile(pid_file) && process_running(candidate) && time() < deadline
                sleep(0.1)
            end
            if process_running(candidate) && isfile(pid_file)
                process = candidate
                break
            end
            if process_running(candidate)
                kill(candidate)
                wait(candidate)
                error("sshd neither wrote its pid file nor exited within 5 s:\n" *
                      log_tail())
            end
        end
        process === nothing && error("sshd did not start in 10 attempts:\n" * log_tail())

        agent_pid = nothing
        try
            ssh_config = joinpath(lab, "ssh_config")
            write(ssh_config, """
                  Host *
                    UserKnownHostsFile $(joinpath(lab, "known_hosts"))
                    GlobalKnownHostsFile /dev/null
                    IdentitiesOnly yes
                    ConnectTimeout 5
                  Host labalias
                    HostName 127.0.0.1
                    Port $(port)
                  Host labshared
                    HostName localhost
                    Port $(port)
                  Host jumphost
                    HostName 127.0.0.1
                    Port $(port)
                    IdentityFile $(enc_key)
                  Host unknownjump
                    HostName 127.0.0.1
                    Port $(port)
                    HostKeyAlias sshdatabridge-unknown-jump
                    IdentityFile "$(plain_key)"
                  Host passwordjump
                    HostName 127.0.0.1
                    Port $(port)
                    IdentityFile $(joinpath(lab, "no-such-key"))
                  """)
            bin = joinpath(lab, "bin")
            mkpath(bin)
            wrapper = joinpath(bin, "ssh")
            write(wrapper,
                  "#!/bin/sh\nexec $(Base.shell_escape_posixly(ssh)) -F " *
                  "$(Base.shell_escape_posixly(ssh_config)) \"\$@\"\n")
            chmod(wrapper, 0o700)

            project = joinpath(lab, "project")
            mkpath(joinpath(project, "src"))
            write(joinpath(project, "src", "run.jl"), "println(\"sim\")\n")
            write(joinpath(project, "input.csv"), "data\n")
            harvest = joinpath(lab, "harvest")
            campaign = joinpath(lab, "remote", "campaign")

            toml_string(s) = "\"" * escape_string(s, "\"") * "\""
            function key_target(name, host, identity, remote_dir; port=nothing,
                                proxy_jump=nothing)
                lines = ["", "[[targets]]", "name = $(toml_string(name))",
                         "host = $(toml_string(host))"]
                port === nothing || push!(lines, "port = $(port)")
                push!(lines, "auth = \"key\"", "identity_file = $(toml_string(identity))")
                proxy_jump === nothing ||
                    push!(lines, "proxy_jump = $(toml_string(proxy_jump))")
                push!(lines, "remote_dir = $(toml_string(remote_dir))")
                return join(lines, "\n") * "\n"
            end
            function write_config(name, targets)
                path = joinpath(lab, name * ".toml")
                write(path, """
                      [push]
                      local_source_dir = $(toml_string(project))
                      use_gitignore = false
                      [pull]
                      local_destination_root = $(toml_string(harvest))
                      output_subdir = "output"
                      """ * join(targets))
                chmod(path, 0o600)
                return path
            end

            # No desktop askpass dialog may appear, should a test regress; a test may set an
            # askpass program and a display of its own to see whether ssh would call it.
            function drive(args; agent=nothing, askpass=nothing, display=nothing)
                o = IOBuffer()
                e = IOBuffer()
                started = time()
                code = withenv("PATH" => bin * ":" * ENV["PATH"], "SSH_AUTH_SOCK" => agent,
                               "SSH_ASKPASS" => askpass, "SSH_ASKPASS_REQUIRE" => nothing,
                               "DISPLAY" => display, "WAYLAND_DISPLAY" => nothing) do
                    return SshDataBridge.main(args; io=o, err=e)
                end
                return (; code, out=String(take!(o)), err=String(take!(e)),
                        seconds=time() - started)
            end

            alpha = key_target("alpha", "127.0.0.1", plain_key, campaign; port=port)

            # An ssh_config alias of the same host and port is refused after evaluation
            endpoints = write_config("endpoints",
                                     [alpha,
                                      key_target("alias", "labalias", plain_key, campaign)])
            r = drive(["probe", "--config", endpoints])
            @test r.code == 1
            @test occursin("same host and port", r.err)

            # Two names of one machine pass the endpoint check: shared storage
            shared = write_config("shared",
                                  [alpha,
                                   key_target("beta", "labshared", plain_key, campaign)])
            r = drive(["probe", "--config", shared])
            @test r.code == 0
            @test occursin("2 ready", r.out)

            marker = joinpath(campaign, ".sshdatabridge-target")
            r = drive(["push", "--config", shared, "--target", "alpha"])
            @test r.code == 0
            @test isfile(marker) && read(marker, String) == "alpha\n"
            @test isfile(joinpath(campaign, "input.csv"))
            @test isfile(joinpath(campaign, "src", "run.jl"))

            # The claim of alpha refuses beta
            r = drive(["push", "--config", shared, "--target", "beta"])
            @test r.code == 2
            @test occursin("is in use by target 'alpha'", r.out)
            @test read(marker, String) == "alpha\n"

            result = joinpath(campaign, "output", "result.csv")
            mkpath(dirname(result))
            write(result, "42\n")
            r = drive(["clean", "--config", shared, "--target", "beta", "--yes"])
            @test r.code == 2
            @test occursin("in use by target 'alpha'", r.out)
            @test isfile(result)

            r = drive(["pull", "--config", shared, "--target", "alpha", "--clean-remote",
                       "--yes"])
            @test r.code == 0
            harvested = joinpath(harvest, "alpha", "result.csv")
            @test isfile(harvested) && read(harvested, String) == "42\n"
            harvested_markers = [joinpath(root, file)
                                 for (root, _, files) in walkdir(harvest)
                                 for file in files if file == ".sshdatabridge-target"]
            @test isempty(harvested_markers)
            @test !ispath(campaign)

            # An encrypted key without agent fails at once instead of prompting
            locked = write_config("locked",
                                  [key_target("locked", "127.0.0.1", enc_key,
                                              joinpath(lab, "remote", "locked");
                                              port=port)])
            r = drive(["probe", "--config", locked])
            @test r.code == 2
            @test r.seconds < 10
            @test occursin("Permission denied", r.out)
            @test occursin("allows no prompt", r.out)

            # The passphrase prompt of the jump host is refused as well. The caller's
            # environment offers a recording askpass and a display, as a desktop session
            # does; without the package's own askpass setting the jump host's ssh, which
            # BatchMode does not reach and which has no terminal here, would run it.
            recorder = joinpath(lab, "askpass_record")
            asked = joinpath(lab, "askpass.log")
            write(recorder,
                  "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> $(Base.shell_escape_posixly(asked))\nexit 1\n")
            chmod(recorder, 0o700)
            jumped = write_config("jumped",
                                  [key_target("jumped", "labalias", plain_key,
                                              joinpath(lab, "remote", "jumped");
                                              proxy_jump="jumphost")])
            r = drive(["probe", "--config", jumped]; askpass=recorder,
                      display=":sshdatabridge-test")
            @test r.code == 2
            @test r.seconds < 10
            @test !isfile(asked)
            @test occursin("prompt refused", r.out)
            @test occursin("Enter passphrase for key", r.out)
            @test occursin("allows no prompt", r.out)

            # A jump host that asks for a password receives no attempt: the refusal ends
            # the ssh that asked instead of letting it send an empty password
            failed_passwords() = count(line -> occursin("Failed password", line),
                                       readlines(sshd_log))
            before = failed_passwords()
            password_jumped = write_config("passwordjump",
                                           [key_target("pwjumped", "labalias", plain_key,
                                                       joinpath(lab, "remote", "pwjumped");
                                                       proxy_jump="passwordjump")])
            r = drive(["probe", "--config", password_jumped]; askpass=recorder,
                      display=":sshdatabridge-test")
            @test r.code == 2
            @test r.seconds < 10
            @test occursin("prompt refused", r.out) && occursin("password", r.out)
            @test !isfile(asked)
            sleep(0.5)
            @test failed_passwords() == before

            # strict_host_key_checking does not reach the jump host: an unknown jump-host
            # key fails at once, without a confirmation dialog, and the message says why
            unknown = write_config("unknownjump",
                                   [key_target("unknown", "labalias", plain_key,
                                               joinpath(lab, "remote", "unknown");
                                               proxy_jump="unknownjump")])
            r = drive(["probe", "--config", unknown]; askpass=recorder,
                      display=":sshdatabridge-test")
            @test r.code == 2
            @test r.seconds < 10
            @test occursin("authenticity of host", r.out)
            @test occursin("does not reach a jump host", r.out)
            @test !isfile(asked)

            socket = joinpath(lab, "agent.sock")
            agent_output = read(pipeline(`$ssh_agent -s -a $socket`; stdin=devnull),
                                String)
            agent_match = match(r"SSH_AGENT_PID=(\d+)", agent_output)
            agent_match === nothing && error("ssh-agent printed no SSH_AGENT_PID")
            agent_pid = parse(Int, agent_match[1])
            withenv("SSH_AUTH_SOCK" => socket, "SSH_ASKPASS" => askpass,
                    "SSH_ASKPASS_REQUIRE" => "force", "DISPLAY" => nothing) do
                return quiet(`$ssh_add $enc_key`)
            end
            r = drive(["probe", "--config", jumped]; agent=socket)
            @test r.code == 0
        finally
            if agent_pid !== nothing
                run(pipeline(ignorestatus(`kill $agent_pid`); stdout=devnull,
                             stderr=devnull))
            end
            kill(process)
            wait(process)
            if get(ENV, "SSHDATABRIDGE_SSHD_VERBOSE", "") == "1" && isfile(sshd_log)
                @info "sshd log" log=read(sshd_log, String)
            end
        end
    end
end
