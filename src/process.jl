"""
    exit_status(process::Base.Process)::Int

Exit status of a finished process: its exit code, or `128 + signal` when a signal
terminated it, which Julia otherwise reports as exit code 0.
"""
function exit_status(process::Base.Process)::Int
    return process.termsignal == 0 ? Int(process.exitcode) : 128 + Int(process.termsignal)
end

"""
    drain(pipe::Pipe)::Task

Close the write end of `pipe` that the parent holds and return a task that reads the pipe
to end-of-file as a `String`. To be called once the child has been started.
"""
function drain(pipe::Pipe)::Task
    close(pipe.in)
    return @async read(pipe, String)
end

"""
    run_authenticated(cmd::Cmd, password::AbstractString)

Run `cmd`, whose first words must be `sshpass -d 0`, feeding `password` followed by a
newline through standard input so that the secret never appears in any process
environment or argument vector. Returns `(; exitcode, stdout, stderr)` and throws
nothing: a non-zero exit status is reported, a signal-terminated child reports
`128 + signal`, and a command that cannot be started reports `-1` with the reason in
`stderr`. `Base.IOError` raised while writing the password is ignored, because it only
means the child exited before reading it (for example a refused connection).

Both streams are read to end-of-file. Buffers handed to `pipeline` are not enough on
Julia 1.10, where `wait` returns when the child exits, not when its output has been
copied, so that the output could be read incomplete or empty.
"""
function run_authenticated(cmd::Cmd, password::AbstractString)
    out = Pipe()
    err = Pipe()
    process = try
        open(pipeline(ignorestatus(cmd); stdout=out, stderr=err), "w")
    catch e
        e isa Base.IOError || rethrow()
        close(out)
        close(err)
        return (; exitcode=-1, stdout="",
                stderr="could not start $(first(cmd.exec)): $(sprint(showerror, e))")
    end
    stdout_reader = drain(out)
    stderr_reader = drain(err)
    try
        write(process.in, password)
        write(process.in, '\n')
    catch e
        e isa Base.IOError || rethrow()
    end
    close(process.in)
    wait(process)
    return (; exitcode=exit_status(process), stdout=fetch(stdout_reader)::String,
            stderr=fetch(stderr_reader)::String)
end

"""
    run_captured(cmd::Cmd)

Run a command that needs no credentials, with standard input from `devnull`, capturing
standard output and standard error, both read to end-of-file as in
[`run_authenticated`](@ref). Returns `(; exitcode, stdout, stderr)` and throws nothing: a
non-zero exit status is reported, a signal-terminated child reports `128 + signal`, and a
command that cannot be started reports `-1` with the reason in `stderr`.
"""
function run_captured(cmd::Cmd)
    out = Pipe()
    err = Pipe()
    process = try
        run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=out, stderr=err); wait=false)
    catch e
        e isa Base.IOError || rethrow()
        close(out)
        close(err)
        return (; exitcode=-1, stdout="",
                stderr="could not start $(first(cmd.exec)): $(sprint(showerror, e))")
    end
    stdout_reader = drain(out)
    stderr_reader = drain(err)
    wait(process)
    return (; exitcode=exit_status(process), stdout=fetch(stdout_reader)::String,
            stderr=fetch(stderr_reader)::String)
end

"""
    run_target(cmd::Cmd, target::BridgeTarget)

Run a command of `target` and return `(; exitcode, stdout, stderr)`; the one place that
decides how the command receives its credential. A password target runs through
[`run_authenticated`](@ref), which feeds the password to `sshpass`; a key target runs
through [`run_captured`](@ref), ssh authenticating without a secret from this package.
"""
function run_target(cmd::Cmd, target::BridgeTarget)
    if target.auth == :password
        return run_authenticated(cmd, target.password::String)
    end
    return run_captured(cmd)
end

"""
    command_string(cmd::Cmd)::String

Render the argument vector of `cmd` as a POSIX-shell-quoted string. The environment of
`cmd` is not rendered, so the result is safe to print or log.
"""
command_string(cmd::Cmd)::String = Base.shell_escape_posixly(cmd.exec...)

"""
    map_targets(f, targets::AbstractVector{BridgeTarget}, ::Type{R})::Vector{R}

Apply `f` to every target on its own task and return the results in target order. Every
task runs to completion before an exception of any of them propagates, so a failure on
one target neither interrupts the others nor leaves a remote command unfinished.
"""
function map_targets(f, targets::AbstractVector{BridgeTarget},
                     ::Type{R})::Vector{R} where {R}
    results = Vector{R}(undef, length(targets))
    @sync for (index, target) in enumerate(targets)
        @async results[index] = f(target)
    end
    return results
end
