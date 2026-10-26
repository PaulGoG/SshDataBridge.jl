"""
    exit_status(process::Base.Process)::Int

Exit status of a finished process: its exit code, or `128 + signal` when a signal
terminated it, which Julia otherwise reports as exit code 0.
"""
function exit_status(process::Base.Process)::Int
    return process.termsignal == 0 ? Int(process.exitcode) : 128 + Int(process.termsignal)
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
"""
function run_authenticated(cmd::Cmd, password::AbstractString)
    out_buffer = IOBuffer()
    err_buffer = IOBuffer()
    process = try
        open(pipeline(ignorestatus(cmd); stdout=out_buffer, stderr=err_buffer), "w")
    catch err
        err isa Base.IOError || rethrow()
        return (; exitcode=-1, stdout="",
                stderr="could not start $(first(cmd.exec)): $(sprint(showerror, err))")
    end
    try
        write(process.in, password)
        write(process.in, '\n')
    catch err
        err isa Base.IOError || rethrow()
    end
    close(process.in)
    wait(process)
    return (; exitcode=exit_status(process), stdout=String(take!(out_buffer)),
            stderr=String(take!(err_buffer)))
end

"""
    run_captured(cmd::Cmd)

Run a command that needs no credentials, capturing standard output and standard error.
Returns `(; exitcode, stdout, stderr)`; a non-zero exit status is reported, not thrown,
and a signal-terminated child reports `128 + signal`.
"""
function run_captured(cmd::Cmd)
    out_buffer = IOBuffer()
    err_buffer = IOBuffer()
    process = run(pipeline(ignorestatus(cmd); stdout=out_buffer, stderr=err_buffer))
    return (; exitcode=exit_status(process), stdout=String(take!(out_buffer)),
            stderr=String(take!(err_buffer)))
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
