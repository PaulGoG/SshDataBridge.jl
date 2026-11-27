# Binaries every action needs; `sshpass` is added when a password target is configured.
const REQUIRED_LOCAL_BINARIES = ("ssh", "rsync")

# SSH_ASKPASS_REQUIRE, on which the prompt refusal of key targets rests, appeared in 8.4.
const MINIMUM_OPENSSH_VERSION = v"8.4"

"""
    openssh_version()::Union{Nothing, VersionNumber}

Version of the `ssh` client in `PATH` as `ssh -V` reports it (`OpenSSH_9.9p2, ...` gives
`v"9.9"`), or `nothing` when `ssh` cannot be run or is not OpenSSH.
"""
function openssh_version()::Union{Nothing, VersionNumber}
    # run_captured reads both streams to end-of-file; see run_authenticated on Julia 1.10
    outcome = run_captured(`ssh -V`)
    m = match(r"OpenSSH_(\d+)\.(\d+)", outcome.stderr * outcome.stdout)
    m === nothing && return nothing
    # Both groups are mandatory, so they captured whenever the pattern matched
    return VersionNumber(parse(Int, m[1]::AbstractString), parse(Int, m[2]::AbstractString))
end

"""
    check_local_binaries(targets::AbstractVector{BridgeTarget})

Verify that `ssh` and `rsync` are available in `PATH`, and `sshpass` as well when a
password target is among `targets`. Throws [`MissingBinaryError`](@ref) naming the
missing binaries otherwise. When a key target is among `targets`, `ssh` must be OpenSSH
8.4 or newer, whose `SSH_ASKPASS_REQUIRE` keeps every prompt off the terminal (see
[`prompt_refusal_environment`](@ref)), and [`prompt_refusal_program`](@ref) must be able
to run; an older or unidentified client, or a program that cannot be executed, is
refused with an `ArgumentError`.
"""
function check_local_binaries(targets::AbstractVector{BridgeTarget})
    required = any(target -> target.auth == :password, targets) ?
               ("ssh", "sshpass", "rsync") : REQUIRED_LOCAL_BINARIES
    missing_binaries = String[bin for bin in required if Sys.which(bin) === nothing]
    isempty(missing_binaries) || throw(MissingBinaryError(missing_binaries))
    check_key_target_prerequisites(targets)
    return nothing
end

"""
    check_key_target_prerequisites(targets::AbstractVector{BridgeTarget})

When a key target is among `targets`, require what every command of a key target rests
on: OpenSSH 8.4 or newer ([`check_openssh_version`](@ref)) and a prompt-refusal program
that runs ([`prompt_refusal_program`](@ref)); throws their `ArgumentError` otherwise.
Part of [`check_local_binaries`](@ref), and run on its own by the dry runs of
[`push_all_targets`](@ref), [`pull_all_targets`](@ref), and
[`clean_all_remote_targets`](@ref), which need no binaries but still build the commands.
"""
function check_key_target_prerequisites(targets::AbstractVector{BridgeTarget})
    if any(target -> target.auth == :key, targets)
        check_openssh_version()
        prompt_refusal_program()
    end
    return nothing
end

"""
    check_openssh_version()

Throw an `ArgumentError` unless the `ssh` in `PATH` reports OpenSSH 8.4 or newer, the
first release that honours `SSH_ASKPASS_REQUIRE`, on which the prompt refusal of key
targets rests.
"""
function check_openssh_version()
    version = openssh_version()
    if version === nothing || version < MINIMUM_OPENSSH_VERSION
        found = version === nothing ? "an ssh that does not report an OpenSSH version" :
                "OpenSSH $(version.major).$(version.minor)"
        throw(ArgumentError("Key targets need OpenSSH $(MINIMUM_OPENSSH_VERSION.major).$(MINIMUM_OPENSSH_VERSION.minor) or newer on this machine, whose SSH_ASKPASS_REQUIRE keeps the prompts of jump hosts off the terminal; found $(found)."))
    end
    return nothing
end

"""
    resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String

Return the effective host key policy of `target`, honoring its override when present.
"""
function resolve_target_policy(target::BridgeTarget, globals::GlobalOptions)::String
    return target.strict_host_key_checking !== nothing ? target.strict_host_key_checking :
           globals.strict_host_key_checking
end

"""
    keepalive_options(globals::GlobalOptions)::Vector{String}

ssh options that drop a connection the server has stopped answering:
`-o ServerAliveInterval=<s> -o ServerAliveCountMax=<n>`. Empty when
`server_alive_interval` is `0`, so that the ssh client configuration applies; an explicit
`ServerAliveInterval=0` on the command line would override it.
"""
function keepalive_options(globals::GlobalOptions)::Vector{String}
    globals.server_alive_interval == 0 && return String[]
    return String["-o", "ServerAliveInterval=$(globals.server_alive_interval)",
                  "-o", "ServerAliveCountMax=$(globals.server_alive_count_max)"]
end

# Run by ssh in place of a prompt of a key target. An askpass that merely fails makes ssh
# answer with an empty string, an empty password at a jump host that asks for one, so the
# program ends the ssh that asked, after reporting the first line of the prompt.
const PROMPT_REFUSAL_SCRIPT = """
    #!/bin/sh
    # ssh passes one argument, the prompt; two are the self-test of prompt_refusal_program
    [ "\$#" -eq 2 ] && [ "\$1" = --self-test ] && exit 0
    printf 'prompt refused, auth = "key" allows none: %s\\n' "\$(printf '%s\\n' "\$1" | head -n 1)" >&2
    kill -TERM "\$PPID"
    exit 1
    """

# Marker of the report above, matched by the probe to explain a failure.
const PROMPT_REFUSAL_REPORT = "prompt refused, auth = \"key\" allows none"

const PROMPT_REFUSAL_PROGRAM = Ref("")
const PROMPT_REFUSAL_LOCK = ReentrantLock()

"""
    check_prompt_refusal_program(path::AbstractString)

Run the prompt-refusal program at `path` in its self-test mode, two arguments, which ssh
never passes, and throw an `ArgumentError` unless it exits 0: ssh answers a prompt with
an empty string when it cannot execute the program, for instance from a file system
mounted `noexec`, which is the empty password the program exists to prevent.
"""
function check_prompt_refusal_program(path::AbstractString)
    if run_captured(Cmd([String(path), "--self-test", "sshdatabridge"])).exitcode != 0
        throw(ArgumentError("Key targets need the prompt-refusal program of SshDataBridge, but $(path) cannot be executed (a file system mounted noexec?); set TMPDIR to a directory that allows execution."))
    end
    return nothing
end

"""
    prompt_refusal_program()::String

Path of an executable copy of the prompt-refusal script, written on first use into a
private temporary directory that Julia removes at exit, and written again when the copy
has gone. A new copy must pass [`check_prompt_refusal_program`](@ref), and the ssh in `PATH`
[`check_openssh_version`](@ref); throws the `ArgumentError` of either otherwise.
"""
function prompt_refusal_program()::String
    return lock(PROMPT_REFUSAL_LOCK) do
        path = PROMPT_REFUSAL_PROGRAM[]
        if isempty(path) || !isfile(path)
            check_openssh_version()
            path = joinpath(mktempdir(; prefix="sshdatabridge-"), "refuse-prompt")
            write(path, PROMPT_REFUSAL_SCRIPT)
            chmod(path, 0o700)
            check_prompt_refusal_program(path)
            PROMPT_REFUSAL_PROGRAM[] = path
        end
        return path
    end
end

"""
    prompt_refusal_environment()::Vector{Pair{String, String}}

Environment of the commands of a key target: `SSH_ASKPASS` set to
[`prompt_refusal_program`](@ref) and `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4, which
[`check_local_binaries`](@ref) requires for key targets). `BatchMode` does not reach the
ssh that `ProxyJump` starts for a jump host, which receives only `-l`, `-p`, `-F`, and
`-v`; it inherits the environment, however. Every prompt anywhere on the route therefore
goes to the program, which reports it on standard error and terminates the ssh that
asked, so that the connection fails at once, without reading the terminal and without
sending an empty answer.
"""
function prompt_refusal_environment()::Vector{Pair{String, String}}
    return Pair{String, String}["SSH_ASKPASS" => prompt_refusal_program(),
                                "SSH_ASKPASS_REQUIRE" => "force"]
end

"""
    target_command(target::BridgeTarget, arguments::Vector{String})::Cmd

Command that runs `arguments`, which start with `"ssh"` or `"rsync"`, for `target`:
prefixed with `sshpass -d 0` for a password target, which reads the password from
standard input (see [`run_authenticated`](@ref)), with `SSH_ASKPASS_REQUIRE=never`, since
with `prefer` or `force` in the caller's environment ssh would ask an askpass program
instead of the terminal that `sshpass` answers; with the environment of
[`prompt_refusal_environment`](@ref) for a key target.
"""
function target_command(target::BridgeTarget, arguments::Vector{String})::Cmd
    if target.auth == :password
        return addenv(Cmd(vcat(String["sshpass", "-d", "0"], arguments)),
                      "SSH_ASKPASS_REQUIRE" => "never")
    end
    return addenv(Cmd(arguments), prompt_refusal_environment()...)
end

"""
    ssh_options(target::BridgeTarget, globals::GlobalOptions)::Vector{String}

`ssh` options shared by the direct commands, the rsync transport, and `ssh -G`: the port
when the target sets one, host-key policy, connection timeout, keepalive (see
[`keepalive_options`](@ref)), then the authentication options of the target.

A password target pins authentication to passwords. Public-key authentication is
disabled and the preferred methods are keyboard-interactive and password, so that an
agent holding many keys cannot exhaust the server's authentication attempts and an
encrypted key cannot raise a passphrase prompt that `sshpass` does not answer; one
password prompt is allowed.

A key target sets `BatchMode=yes`, so that ssh fails instead of prompting, followed by
`-i <identity_file> -o IdentitiesOnly=yes` and `-J <proxy_jump>` when these are set;
everything else is left to ~/.ssh/config. `proxy_jump = "none"`, the one value a password
target admits, is passed as `-o ProxyCommand=none`, which overrides both a `ProxyJump`
and a `ProxyCommand` of ~/.ssh/config (`-J none` overrides only the former).
"""
function ssh_options(target::BridgeTarget, globals::GlobalOptions)::Vector{String}
    policy = resolve_target_policy(target, globals)
    options = String[]
    target.port === nothing || push!(options, "-p", string(target.port))
    push!(options, "-o", "StrictHostKeyChecking=$(policy)",
          "-o", "ConnectTimeout=$(globals.connect_timeout)")
    append!(options, keepalive_options(globals))
    if target.auth == :password
        push!(options, "-o", "PubkeyAuthentication=no",
              "-o", "PreferredAuthentications=keyboard-interactive,password",
              "-o", "NumberOfPasswordPrompts=1")
    else
        push!(options, "-o", "BatchMode=yes")
        if target.identity_file !== nothing
            push!(options, "-i", target.identity_file, "-o", "IdentitiesOnly=yes")
        end
    end
    if target.proxy_jump == "none"
        push!(options, "-o", "ProxyCommand=none")
    elseif target.proxy_jump !== nothing
        push!(options, "-J", target.proxy_jump)
    end
    return options
end

"""
    remote_shell(script::AbstractString)::String

Wrap `script` as `sh -c '<script>'`, so that it runs under a POSIX shell whatever the
login shell of the remote account.
"""
remote_shell(script::AbstractString)::String = "sh -c " * Base.shell_escape_posixly(script)

"""
    build_ssh_command(target::BridgeTarget, globals::GlobalOptions,
                      remote_command::AbstractString)::Cmd

Construct the `ssh -n ...` invocation that executes `remote_command` on `target`, with
the options of [`ssh_options`](@ref), wrapped by [`target_command`](@ref): a password
target runs `sshpass -d 0 ssh -n ...`, and the password is not part of the command;
[`run_authenticated`](@ref) supplies it through standard input at execution time.
"""
function build_ssh_command(target::BridgeTarget, globals::GlobalOptions,
                           remote_command::AbstractString)::Cmd
    return target_command(target,
                          String["ssh", "-n", ssh_options(target, globals)...,
                                 target_label(target.host, target.user),
                                 String(remote_command)])
end

"""
    SshEndpoint

The configuration that `ssh -G` evaluates for a target: the host it connects to, the
port, the user, and the route.

# Fields
- `hostname::String`: host name or address ssh connects to, after ssh_config `HostName`.
- `port::Int`: SSH daemon port.
- `user::String`: remote user name.
- `proxy_jump::Union{Nothing, String}`: effective `ProxyJump`; `nothing` when none.
- `proxy_command::Union{Nothing, String}`: effective `ProxyCommand`; `nothing` when none.
"""
struct SshEndpoint
    hostname::String
    port::Int
    user::String
    proxy_jump::Union{Nothing, String}
    proxy_command::Union{Nothing, String}
end

"""
    ssh_config_command(target::BridgeTarget, globals::GlobalOptions)::Cmd

`ssh -G` with the options of [`ssh_options`](@ref), the destination of `target`, and the
remote command `sh -c true`: ssh prints the configuration it would use and never
connects, so the command needs neither `sshpass` nor the environment of
[`prompt_refusal_environment`](@ref). The remote command makes ssh evaluate the session
as the commands of the package are evaluated, a command session, which `Match
sessiontype` (OpenSSH 10.0) tells apart from an interactive one. A `Match command` block
that tells the shell commands of the package from rsync's `rsync --server` is not seen.
`-o RemoteCommand=none` keeps a `RemoteCommand` of the host's block from making the query
fail ("Cannot execute command-line and remote command"); the commands of such a target
still fail, that target alone.
"""
function ssh_config_command(target::BridgeTarget, globals::GlobalOptions)::Cmd
    return Cmd(String["ssh", "-G", ssh_options(target, globals)..., "-o",
                      "RemoteCommand=none", target_label(target.host, target.user),
                      remote_shell("true")])
end

"""
    parse_ssh_config(text::AbstractString)::SshEndpoint

Read the output of `ssh -G`: one `key value` line per option, the key in lower case. The
first occurrence of a key counts. `hostname`, `port`, and `user` are required, and the
port must be an integer in `1:65535`; `proxyjump` and `proxycommand` absent or `none`
give `nothing`. Throws `ArgumentError` otherwise.
"""
function parse_ssh_config(text::AbstractString)::SshEndpoint
    values = Dict{String, String}()
    for line in eachline(IOBuffer(text))
        parts = split(line, ' '; limit=2)
        key = lowercase(String(parts[1]))
        value = length(parts) == 2 ? String(parts[2]) : ""
        haskey(values, key) || (values[key] = value)
    end
    for key in ("hostname", "port", "user")
        haskey(values, key) || throw(ArgumentError("ssh -G printed no '$(key)' line."))
    end
    port = tryparse(Int, values["port"])
    if port === nothing || !(1 <= port <= 65535)
        throw(ArgumentError("ssh -G printed the port '$(values["port"])', which is not an integer in 1:65535."))
    end
    jump = get(values, "proxyjump", "none")
    command = get(values, "proxycommand", "none")
    return SshEndpoint(values["hostname"], port, values["user"],
                       lowercase(jump) == "none" ? nothing : jump,
                       lowercase(command) == "none" ? nothing : command)
end

"""
    resolve_endpoint(target::BridgeTarget, globals::GlobalOptions)::SshEndpoint

Evaluate the configuration of `target` with [`ssh_config_command`](@ref) and read it
with [`parse_ssh_config`](@ref). Throws `ArgumentError` naming the target when ssh exits
with a non-zero status or its output cannot be read.
"""
function resolve_endpoint(target::BridgeTarget, globals::GlobalOptions)::SshEndpoint
    outcome = run_captured(ssh_config_command(target, globals))
    if outcome.exitcode != 0
        throw(ArgumentError("Target '$(target.name)': ssh could not evaluate its configuration (exit code $(outcome.exitcode)): $(strip(outcome.stderr))"))
    end
    # The ArgumentError is thrown outside the catch block so that no cause is chained.
    failure = nothing
    endpoint = try
        parse_ssh_config(outcome.stdout)
    catch err
        err isa ArgumentError || rethrow()
        failure = err
        nothing
    end
    if failure !== nothing
        throw(ArgumentError("Target '$(target.name)': $(failure.msg)"))
    end
    return endpoint::SshEndpoint
end

"""
    resolve_endpoints(config::BridgeConfig)::Vector{SshEndpoint}

Evaluate the configuration of every target in order, one after the other, see
[`resolve_endpoint`](@ref). Throws [`MissingBinaryError`](@ref) when `ssh` is not in
`PATH`, and `ArgumentError` for the first target whose configuration cannot be evaluated.
"""
function resolve_endpoints(config::BridgeConfig)::Vector{SshEndpoint}
    Sys.which("ssh") === nothing && throw(MissingBinaryError(["ssh"]))
    return SshEndpoint[resolve_endpoint(target, config.globals)
                       for target in config.targets]
end

"""
    check_endpoint_overlaps(targets::AbstractVector{BridgeTarget},
                            endpoints::AbstractVector{SshEndpoint})

Repeat the overlap rule of [`BridgeConfig`](@ref) on the configuration that ssh evaluates:
`endpoints[i]` belongs to `targets[i]`. Two targets whose endpoints have the same
[`node_key`](@ref) of host name and port must not have overlapping remote directories,
so that an ssh_config alias and the name it stands for, or a port that only ~/.ssh/config
sets, cannot hide two targets on one node. Throws `ArgumentError` for the first such
pair, `DimensionMismatch` when the lengths differ.

The route (`ProxyJump`, `ProxyCommand`) is deliberately not part of the key: two routes to
one machine must not pass. Two machines with one private name behind different gateways
are refused as well; this false refusal is the safe error, and distinct remote
directories avoid it.
"""
function check_endpoint_overlaps(targets::AbstractVector{BridgeTarget},
                                 endpoints::AbstractVector{SshEndpoint})
    if length(targets) != length(endpoints)
        throw(DimensionMismatch("check_endpoint_overlaps received $(length(targets)) targets and $(length(endpoints)) endpoints."))
    end
    for index in eachindex(targets), other_index in (index + 1):lastindex(targets)
        t1 = targets[index]
        t2 = targets[other_index]
        e1 = endpoints[index]
        e2 = endpoints[other_index]
        if node_key(e1.hostname, e1.port) == node_key(e2.hostname, e2.port) &&
           paths_overlap(t1.remote_dir, t2.remote_dir)
            throw(ArgumentError("Targets '$(t1.name)' and '$(t2.name)' reach the same host and port ($(e1.hostname):$(e1.port)) and their remote directories overlap ('$(t1.remote_dir)' and '$(t2.remote_dir)'): the purge of one would remove the output of the other before it is harvested. Use one target per project directory."))
        end
    end
    return nothing
end

"""
    remote_output_directory(target::BridgeTarget)::String

Absolute path of the output directory of `target` on the remote host, without a trailing
slash. `normpath` keeps one when `output_subdir` ends in a `.` segment, and a purge of
`link/` would empty the directory behind a symbolic link that the purge script refuses.
"""
function remote_output_directory(target::BridgeTarget)::String
    return String(rstrip(normpath(joinpath(target.remote_dir, target.output_subdir)), '/'))
end

"""
    build_probe_script(target::BridgeTarget)::String

Shell script executed on the remote host by [`probe_target`](@ref). It reports whether
`rsync` is installed and whether the base and output directories exist; every path is
POSIX-quoted.
"""
function build_probe_script(target::BridgeTarget)::String
    base_dir = Base.shell_escape_posixly(target.remote_dir)
    output_dir = Base.shell_escape_posixly(remote_output_directory(target))
    return join(["command -v rsync >/dev/null 2>&1 && echo RSYNC_OK || echo RSYNC_MISSING",
                 "test -d $(base_dir) && echo DIR_EXISTS || echo DIR_MISSING",
                 "test -d $(output_dir) && echo OUT_EXISTS || echo OUT_MISSING"], "; ")
end

"""
    probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult

Check SSH reachability of `target`, the presence of `rsync` on the remote host, and the
existence of the base and output directories. Connection, authentication, and spawn
failures are reported through the result, never thrown; only a key target whose
prerequisites fail ([`check_key_target_prerequisites`](@ref)) raises their
`ArgumentError` when its command is built. A key target refused with
`Permission denied`, or whose route raised a prompt (see
[`prompt_refusal_environment`](@ref)), gets a hint in the message: no prompt is allowed,
so the key must be in the agent, or a master connection must be open when the host asks
for a second factor. A key target that fails with `Host key verification failed`, or
whose route asked to confirm a host key, gets one as well: the confirmation cannot be
answered, and `strict_host_key_checking` is not passed on to jump hosts, whose host-key
policy comes from `~/.ssh/config`. Both hints name the interactive command of
[`interactive_ssh_command`](@ref).
"""
function probe_target(target::BridgeTarget, globals::GlobalOptions)::ProbeResult
    cmd = build_ssh_command(target, globals, remote_shell(build_probe_script(target)))
    outcome = run_target(cmd, target)

    ssh_ok = outcome.exitcode == 0
    rsync_ok = occursin("RSYNC_OK", outcome.stdout)
    remote_dir_exists = occursin("DIR_EXISTS", outcome.stdout)
    remote_output_dir_exists = occursin("OUT_EXISTS", outcome.stdout)

    messages = String[]
    if !ssh_ok
        detail = "ssh exited with code $(outcome.exitcode): $(strip(outcome.stderr))"
        refused = occursin(PROMPT_REFUSAL_REPORT, outcome.stderr)
        host_key = occursin("Host key verification failed", outcome.stderr) ||
                   (refused && occursin("authenticity of host", outcome.stderr))
        if target.auth == :key && host_key
            detail *= "; auth = \"key\" cannot confirm a host key, and strict_host_key_checking does not reach a jump host: if the key is unknown, record it with one interactive login ($(interactive_ssh_command(target))); a changed key needs your own check"
        elseif target.auth == :key &&
               (refused || occursin("Permission denied", outcome.stderr))
            detail *= "; auth = \"key\" allows no prompt: load the key into the agent, or, if the host asks for a second factor, set ControlMaster and ControlPath for it in ~/.ssh/config and open a master connection first ($(interactive_ssh_command(target; master=true)))"
        end
        push!(messages, detail)
    else
        rsync_ok || push!(messages, "rsync not installed on the node")
        remote_dir_exists ||
            push!(messages, "base directory missing ('$(target.remote_dir)')")
        remote_output_dir_exists ||
            push!(messages,
                  "output directory missing ('$(remote_output_directory(target))')")
    end
    message = isempty(messages) ? "All remote diagnostics passed." : join(messages, "; ")
    return ProbeResult(target, ssh_ok && rsync_ok, ssh_ok, rsync_ok, remote_dir_exists,
                       remote_output_dir_exists, message)
end

"""
    interactive_ssh_command(target::BridgeTarget; master::Bool=false)::String

The `ssh` command line, POSIX-quoted, with which the user reaches `target` interactively
along the same route as the package: its port, identity file, and jump hosts, without
`BatchMode`. With `master = true` it opens a background connection (`-fN`), which serves
later connections when ~/.ssh/config sets `ControlMaster` and `ControlPath` for the host.
Used in the hints of [`probe_target`](@ref).
"""
function interactive_ssh_command(target::BridgeTarget; master::Bool=false)::String
    arguments = String["ssh"]
    master && push!(arguments, "-fN")
    target.port === nothing || push!(arguments, "-p", string(target.port))
    if target.identity_file !== nothing
        push!(arguments, "-i", target.identity_file, "-o", "IdentitiesOnly=yes")
    end
    if target.proxy_jump == "none"
        push!(arguments, "-o", "ProxyCommand=none")
    elseif target.proxy_jump !== nothing
        push!(arguments, "-J", target.proxy_jump)
    end
    push!(arguments, target_label(target.host, target.user))
    return Base.shell_escape_posixly(arguments...)
end

"""
    probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}

Probe every configured target concurrently.
"""
function probe_all_targets(config::BridgeConfig)::Vector{ProbeResult}
    check_local_binaries(config.targets)
    return map_targets(target -> probe_target(target, config.globals), config.targets,
                       ProbeResult)
end

# Name of the file in the project directory that records the target which deployed there.
const OWNERSHIP_MARKER = ".sshdatabridge-target"

"""
    claim_script(remote_dir::AbstractString, name::AbstractString)::String

One-line POSIX shell script, run under `sh -c`, that creates `remote_dir` with
`mkdir -p` and claims it for the target `name` through the ownership marker
`remote_dir/.sshdatabridge-target`, which holds the name of the target. An absent marker
is written to a temporary file named after the node and the shell's process ID, then
hard-linked into place; the link is atomic and fails when the marker exists, also over
NFS, where `O_EXCL` is not reliable on every server (open(2)). Of two concurrent claims
of one directory exactly one marker is written, and both read it back rather than trust
the status of `ln`, which NFS can report as failed after a lost reply. The physical
location of the directory is resolved, and the claim is refused when a marker of another
target lies in any ancestor or anywhere below it, so that a directory nested in the tree
of another target is caught as well. That check runs before the marker is written and,
by a claim whose link created the marker (the marker and its temporary file are one
inode, which holds after a lost NFS reply as well), again afterwards: of two concurrent
claims of nested directories each writes its own marker before its second check, so at
least one of them sees the other's marker, removes its own, and refuses (both may
refuse). A claim that found the marker in place, or lost the link to a concurrent claim
of the same name, never removes it. The script
exits 0 when the marker names `name`, 1 when the directory or the marker cannot be
created, entered, or read (a file system without hard links included), and 97 when the
marker, or one above or below the directory, names another target: the nodes share
storage, or two targets name one directory or nested ones. The refusal states its reason
on standard error. `remote_dir` and `name` are POSIX-quoted.
"""
function claim_script(remote_dir::AbstractString, name::AbstractString)::String
    directory = Base.shell_escape_posixly(remote_dir)
    owner = Base.shell_escape_posixly(name)
    marker = OWNERSHIP_MARKER
    return join(["d=$(directory)",
                 "n=$(owner)",
                 "m=\"\$d/$(marker)\"",
                 "mkdir -p -- \"\$d\" || exit 1",
                 "r=\$(cd -- \"\$d\" && pwd -P) || exit 1",
                 # k: refuses (status 97) when a marker of another target lies above or below
                 "k() { x=\$r; while [ \"\$x\" != / ]; do x=\$(dirname -- \"\$x\"); if [ -f \"\$x/$(marker)\" ]; then o=\$(cat -- \"\$x/$(marker)\") || o='?'; if [ \"\$o\" != \"\$n\" ]; then echo \"push refused: \$d lies inside \$x, which is in use by target '\$o'\" >&2; return 97; fi; fi; done; f=\$(find \"\$r\" -type f -name $(marker) ! -path \"\$r/$(marker)\" ! -exec grep -qxF -e \"\$n\" {} \\; -print 2>/dev/null | head -n 1); if [ -n \"\$f\" ]; then echo \"push refused: \$d contains \$f of another target\" >&2; return 97; fi; return 0; }",
                 "k || exit 97",
                 "w=0",
                 "if [ ! -f \"\$m\" ]; then t=\"\$m.\$(uname -n).\$\$\"; printf '%s\\n' \"\$n\" > \"\$t\" || exit 1; ln -- \"\$t\" \"\$m\" 2>/dev/null; if [ \"\$t\" -ef \"\$m\" ]; then w=1; fi; rm -f -- \"\$t\"; fi",
                 "if [ ! -f \"\$m\" ]; then echo \"push refused: \$m could not be created; the claim needs a file system with hard links\" >&2; exit 1; fi",
                 "o=\$(cat -- \"\$m\") || exit 1",
                 "if [ \"\$o\" != \"\$n\" ]; then echo \"push refused: \$d is in use by target '\$o': the nodes share storage, or two targets name one directory\" >&2; exit 97; fi",
                 # A claim that wrote its marker checks again, against a nested claim made meanwhile
                 "if [ \$w = 1 ] && ! k; then rm -f -- \"\$m\"; exit 97; fi",
                 "exit 0"], "; ")
end

"""
    claim_remote_directory(target::BridgeTarget, globals::GlobalOptions)

Create `target.remote_dir` on the node and claim it for `target` with the script of
[`claim_script`](@ref). Returns `(; success, exitcode, stderr)`; exit code 97 means that
the directory belongs to another target.
"""
function claim_remote_directory(target::BridgeTarget, globals::GlobalOptions)
    script = claim_script(target.remote_dir, target.name)
    cmd = build_ssh_command(target, globals, remote_shell(script))
    outcome = run_target(cmd, target)
    return (; success=outcome.exitcode == 0, exitcode=outcome.exitcode,
            stderr=outcome.stderr)
end

"""
    purge_path(target::BridgeTarget, scope::Symbol)::String

Remote directory removed by a purge of `target`: the output directory for
`scope == :output`, the whole project directory for `scope == :project`.
"""
function purge_path(target::BridgeTarget, scope::Symbol)::String
    if scope == :output
        return remote_output_directory(target)
    elseif scope == :project
        return target.remote_dir
    end
    return throw(ArgumentError("Purge scope must be one of $(VALID_PURGE_SCOPES) (received: :$(scope))."))
end

"""
    purge_script(path::AbstractString, name::AbstractString)::String

One-line POSIX shell script that removes `path` recursively on the node for the target
`name`. It exits 0 when the path does not exist. It exits 98, deleting nothing, when the
path is a symbolic link, whose removal would leave the deployed tree in place; when the
path or the home directory of the account cannot be entered (a file, or a directory
without search permission), so that their physical locations cannot be compared; and
when the path is a directory that contains the home directory, which the lexical rules
of [`validate_remote_path_safety`](@ref) cannot see. It also exits 98 when an ownership
marker of another target (see [`claim_script`](@ref)) lies in the physical location of
the path or in any of its ancestors, or anywhere below it. Without any marker of `name`
on the path the purge proceeds and notes this on standard error (`purge note:`). Each
refusal states its reason on standard error. `path` and `name` are POSIX-quoted, `path`
without a trailing slash, so that the link test sees a link and not the directory behind
it.
"""
function purge_script(path::AbstractString, name::AbstractString)::String
    quoted = Base.shell_escape_posixly(rstrip(path, '/'))
    owner = Base.shell_escape_posixly(name)
    marker = OWNERSHIP_MARKER
    return join(["p=$(quoted)",
                 "n=$(owner)",
                 "if [ -L \"\$p\" ]; then echo \"purge refused: \$p is a symbolic link\" >&2; exit 98; fi",
                 "[ -e \"\$p\" ] || exit 0",
                 "r=\$(cd -- \"\$p\" && pwd -P) && h=\$(cd && pwd -P) || { echo \"purge refused: \$p or the home directory cannot be entered\" >&2; exit 98; }",
                 "case \"\$h/\" in \"\$r\"/*) echo \"purge refused: \$p contains the home directory\" >&2; exit 98;; esac",
                 "x=\$r; own=; while :; do if [ -f \"\$x/$(marker)\" ]; then o=\$(cat -- \"\$x/$(marker)\") || o='?'; if [ \"\$o\" = \"\$n\" ]; then own=1; else echo \"purge refused: \$x is in use by target '\$o'\" >&2; exit 98; fi; fi; [ \"\$x\" = / ] && break; x=\$(dirname -- \"\$x\"); done",
                 "f=\$(find \"\$r\" -type f -name $(marker) ! -path \"\$r/$(marker)\" ! -exec grep -qxF -e \"\$n\" {} \\; -print 2>/dev/null | head -n 1)",
                 "if [ -n \"\$f\" ]; then echo \"purge refused: \$f belongs to another target\" >&2; exit 98; fi",
                 "[ -n \"\$own\" ] || echo \"purge note: no ownership marker of target '\$n' on the path\" >&2",
                 "rm -rf -- \"\$p\""], "; ")
end

"""
    clean_remote_target(target::BridgeTarget, globals::GlobalOptions;
                        scope::Symbol=:project, dry_run::Bool=false)::TransferResult

Remove the directory selected by `scope` (see [`purge_path`](@ref)) on the remote host
with the script of [`purge_script`](@ref), run under `sh -c`; the default removes the
whole project directory. The path is checked with [`validate_remote_path_safety`](@ref)
before any command is issued, against `target.user` or, when the target leaves the user
to ~/.ssh/config, the user that [`resolve_endpoint`](@ref) evaluates. A refusal, by that
check, by the evaluation, or by the script, is reported as a failed result. A purge that
found no ownership marker of the target on the path says so in its message.
"""
function clean_remote_target(target::BridgeTarget, globals::GlobalOptions;
                             scope::Symbol=DEFAULT_PURGE_SCOPE,
                             dry_run::Bool=false)::TransferResult
    t_start = time()
    path = purge_path(target, scope)
    try
        user = target.user === nothing ? resolve_endpoint(target, globals).user :
               target.user
        validate_remote_path_safety(path, user)
    catch err
        err isa ArgumentError || rethrow()
        return TransferResult(target, :clean, false, -1, 0.0,
                              "Safety refusal: $(sprint(showerror, err))")
    end

    cmd = build_ssh_command(target, globals, remote_shell(purge_script(path, target.name)))
    if dry_run
        return TransferResult(target, :clean, true, 0, 0.0,
                              "Dry run: $(command_string(cmd))")
    end

    outcome = run_target(cmd, target)
    duration = time() - t_start
    success = outcome.exitcode == 0
    message = if success
        note = occursin("purge note:", outcome.stderr) ?
               " Note: no ownership marker of this target was found on the path (deployed before ownership markers, or never pushed)." :
               ""
        "Remote directory '$(path)' ($(scope) scope) purged in $(round(duration; digits=2)) s." *
        note
    else
        "purge exited with code $(outcome.exitcode): $(strip(outcome.stderr))"
    end
    return TransferResult(target, :clean, success, outcome.exitcode, duration, message)
end

"""
    clean_all_remote_targets(config::BridgeConfig; dry_run::Bool=false)::Vector{TransferResult}

Purge the directory selected by `config.pull.purge_scope` on all configured targets
concurrently.
"""
function clean_all_remote_targets(config::BridgeConfig;
                                  dry_run::Bool=false)::Vector{TransferResult}
    dry_run ? check_key_target_prerequisites(config.targets) :
    check_local_binaries(config.targets)
    scope = config.pull.purge_scope
    @info "Purging remote directories" total_targets=length(config.targets) scope=scope dry_run=dry_run
    return map_targets(target -> clean_remote_target(target, config.globals; scope=scope,
                                                     dry_run=dry_run), config.targets,
                       TransferResult)
end
