"""
    run_authenticated(cmd::Cmd, password::AbstractString)

Run `cmd`, whose first words must be `sshpass -d 0`, feeding `password` followed by a
newline through standard input so that the secret never appears in any process
environment or argument vector. Returns `(; exitcode, stdout, stderr)`; a non-zero exit
status is reported, not thrown. `Base.IOError` raised while writing the password is
swallowed because it only means the child exited before reading it (for example a refused
connection); `Base.IOError` raised while spawning propagates.
"""
function run_authenticated(cmd::Cmd, password::AbstractString)
    out_buffer = IOBuffer()
    err_buffer = IOBuffer()
    process = open(pipeline(ignorestatus(cmd); stdout=out_buffer, stderr=err_buffer), "w")
    try
        write(process.in, password)
        write(process.in, '\n')
    catch err
        err isa Base.IOError || rethrow()
    end
    close(process.in)
    wait(process)
    return (; exitcode=Int(process.exitcode), stdout=String(take!(out_buffer)),
            stderr=String(take!(err_buffer)))
end

"""
    run_captured(cmd::Cmd)

Run a command that needs no credentials, capturing standard output and standard error.
Returns `(; exitcode, stdout, stderr)`; a non-zero exit status is reported, not thrown.
"""
function run_captured(cmd::Cmd)
    out_buffer = IOBuffer()
    err_buffer = IOBuffer()
    process = run(pipeline(ignorestatus(cmd); stdout=out_buffer, stderr=err_buffer))
    return (; exitcode=Int(process.exitcode), stdout=String(take!(out_buffer)),
            stderr=String(take!(err_buffer)))
end

"""
    command_string(cmd::Cmd)::String

Render the argument vector of `cmd` as a POSIX-shell-quoted string. The environment of
`cmd` is deliberately omitted, so credentials can never be serialized through this
function; use it for every log line and dry-run message that shows a command.
"""
command_string(cmd::Cmd)::String = Base.shell_escape_posixly(cmd.exec...)
