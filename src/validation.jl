const VALID_HOST_KEY_POLICIES = ("accept-new", "yes", "no")
const VALID_COLLISION_STRATEGIES = (:resume, :backup, :abort)
const VALID_PURGE_SCOPES = (:output, :project)
const VALID_AUTH_METHODS = (:password, :key)

# Defaults shared by the option constructors and the configuration parser.
const DEFAULT_CONNECT_TIMEOUT = 10
const DEFAULT_HOST_KEY_POLICY = "accept-new"
const DEFAULT_COMPRESS = true
const DEFAULT_BANDWIDTH_LIMIT = 0
# ssh drops a connection after interval * (count_max + 1) seconds without an answer from
# the server, 60 s here, instead of letting it block a transfer for up to about two hours
# (Linux TCP keepalive defaults).
const DEFAULT_SERVER_ALIVE_INTERVAL = 15
const DEFAULT_SERVER_ALIVE_COUNT_MAX = 3
const DEFAULT_PORT = 22
const DEFAULT_PUSH_EXCLUDES = String[".git", ".github", ".vscode", "*.swp", "*~"]
const DEFAULT_USE_GITIGNORE = true
const DEFAULT_REQUIRE_CLEAN_GIT = false
const DEFAULT_OUTPUT_SUBDIR = "output"
# Only patterns that cannot plausibly name a result file: a purge destroys what the
# excludes leave on the node.
const DEFAULT_PULL_EXCLUDES = String["*.tmp", "*~"]
const DEFAULT_COLLISION_STRATEGY = :resume
const DEFAULT_CLEAN_REMOTE_AFTER_PULL = false
# A campaign deploys code that must not stay on the nodes, so a purge removes the whole
# project directory unless the configuration narrows it.
const DEFAULT_PURGE_SCOPE = :project

# The patterns end in \z, not $, which would also match before a final newline.
const HOSTNAME_PATTERN = r"^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?\z"
const IPV6_PATTERN = r"^(?=[0-9A-Fa-f:.]*[0-9A-Fa-f])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:\.[0-9]{1,3}){0,3}\z"
const USERNAME_PATTERN = r"^[A-Za-z_][A-Za-z0-9._-]{0,31}\z"
const TARGET_NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z"
const CONTROL_CHARACTER_PATTERN = r"[\x00-\x1f\x7f]"
const MAX_HOSTNAME_LENGTH = 253

# One hop of an `ssh -J` specification: [user@]host[:port], IPv6 hosts in brackets.
const PROXY_JUMP_HOP_PATTERN = r"^(?:(?<user>[^@]+)@)?(?<host>\[[^\]]+\]|[^:\[\]@]+)(?::(?<port>[0-9]{1,5}))?\z"

# A host whose labels are all numbers is an address to the C library, which reads a field
# with a leading zero as octal and one with a leading 0x as hexadecimal. Both forms are
# refused, so that a numeric host has the value it shows. A trailing dot leaves such a host
# numeric: it is no DNS name, and the C library reads no address from it either.
const NUMERIC_HOST_PATTERN = r"^(?:0[xX][0-9A-Fa-f]*|[0-9]+)(?:\.(?:0[xX][0-9A-Fa-f]*|[0-9]+))*\.?\z"
const NON_DECIMAL_FIELD_PATTERN = r"(?:^|\.)0[0-9xX]"

# rsync expands these characters in a remote path on the node, with or without
# --secluded-args, whereas the ssh commands of this package quote every path literally.
const RSYNC_WILDCARD_PATTERN = r"[*?\[\]]"

# First path components under which recursive remote deletion is refused.
const PROTECTED_ROOT_COMPONENTS = ("bin", "boot", "dev", "etc", "lib", "lib64", "opt",
                                   "proc", "root", "run", "sbin", "srv", "sys", "usr",
                                   "var")

"""
    is_valid_host(host::AbstractString)::Bool

Whether `host` is a syntactically valid DNS hostname, ssh_config `Host` alias, IPv4
address, or IPv6 literal (without square brackets, which `ssh` does not strip from
`user@host`). Names and aliases are dot-separated labels of letters, digits, `_`, and
interior hyphens; a leading `-` never matches, so that a host is never read as an `ssh`
option.
"""
function is_valid_host(host::AbstractString)::Bool
    return length(host) <= MAX_HOSTNAME_LENGTH &&
           (occursin(HOSTNAME_PATTERN, host) || occursin(IPV6_PATTERN, host))
end

"""
    target_label(host::AbstractString, user::Union{Nothing, AbstractString})::String

Destination as `ssh` receives it: `user@host`, or `host` alone when `user` is `nothing`
and ssh_config or the local account name supplies it. Used in messages and as the last
argument of the `ssh` command.
"""
function target_label(host::AbstractString, user::Union{Nothing, AbstractString})::String
    return user === nothing ? String(host) : "$(user)@$(host)"
end

"""
    is_valid_proxy_jump(spec::AbstractString)::Bool

Whether `spec` is a jump-host specification accepted for `ssh -J`: one or more
`[user@]host[:port]` hops separated by commas, an IPv6 host enclosed in square brackets,
or exactly `none`, which disables a `ProxyJump` or `ProxyCommand` set in ~/.ssh/config.
Each user must be a valid account name, each host a valid host name, alias, or IPv4
address (an IPv6 literal only in brackets), and each port lie in `1:65535`. Empty
specifications and hops, control characters, and `ssh://` URIs are refused. A bracketed
IPv6 host is accepted in the last hop only: OpenSSH inserts the hops before the last
unquoted into the command it builds for the last jump host and runs that command with
the user's shell (`\$SHELL -c`), which would read the brackets as a glob pattern. The
other characters a hop admits (letters, digits, `.`, `_`, `-`, `@`, `:`, `,`) are not
special to the usual shells.
"""
function is_valid_proxy_jump(spec::AbstractString)::Bool
    spec == "none" && return true
    occursin(CONTROL_CHARACTER_PATTERN, spec) && return false
    hops = split(spec, ',')
    for (index, hop) in enumerate(hops)
        m = match(PROXY_JUMP_HOP_PATTERN, hop)
        m === nothing && return false
        user = m[:user]
        if user !== nothing && !occursin(USERNAME_PATTERN, user)
            return false
        end
        # The host group is not optional: it captured whenever the hop matched.
        host = m[:host]::AbstractString
        if startswith(host, '[')
            index == length(hops) || return false
            occursin(IPV6_PATTERN, chop(host; head=1, tail=1)) || return false
        elseif occursin(':', host) || !is_valid_host(host)
            return false
        end
        port = m[:port]
        if port !== nothing
            number = tryparse(Int, port)
            (number !== nothing && 1 <= number <= 65535) || return false
        end
    end
    return true
end

"""
    has_non_decimal_address_field(host::AbstractString)::Bool

Whether `host` is a numeric address with a field in octal or hexadecimal notation
(`192.0.2.012`, `0xc0.0.2.10`), which the C library accepts and reads by another value
than the decimal one.
"""
function has_non_decimal_address_field(host::AbstractString)::Bool
    return occursin(NUMERIC_HOST_PATTERN, host) && occursin(NON_DECIMAL_FIELD_PATTERN, host)
end

"""
    has_control_characters(text::AbstractString)::Bool

Whether `text` contains an ASCII control character (0x00 to 0x1f, or 0x7f).
"""
has_control_characters(text::AbstractString)::Bool = occursin(CONTROL_CHARACTER_PATTERN,
                                                              text)

"""
    has_parent_segment(path::AbstractString)::Bool

Whether `path` contains a `..` segment.
"""
has_parent_segment(path::AbstractString)::Bool = any(==(".."), split(path, '/'))

"""
    has_rsync_wildcards(path::AbstractString)::Bool

Whether `path` contains `*`, `?`, `[`, or `]`. rsync would expand them on the node, so
that a transfer could act on another directory than the one named, while the purge
removes the path as written.
"""
has_rsync_wildcards(path::AbstractString)::Bool = occursin(RSYNC_WILDCARD_PATTERN, path)

"""
    paths_overlap(a::AbstractString, b::AbstractString)::Bool

Whether two normalized absolute paths name the same directory or one lies below the
other. The comparison is lexical and does not follow symbolic links.
"""
function paths_overlap(a::AbstractString, b::AbstractString)::Bool
    return a == b || startswith(a, b * "/") || startswith(b, a * "/")
end

"""
    is_numeric_host(host::AbstractString)::Bool

Whether `host` can only be an IP address: it contains a `:`, or every label is a number,
with or without a trailing dot. An all-numeric name is not a DNS name (RFC 3696, section
2).
"""
function is_numeric_host(host::AbstractString)::Bool
    return occursin(':', host) || occursin(NUMERIC_HOST_PATTERN, host)
end

# Linux value of AF_INET6; the package runs on Linux only.
const ADDRESS_FAMILY_INET6 = Cint(10)

"""
    numeric_address(host::AbstractString)::Union{Tuple{Int, UInt128}, Nothing}

The address of a numeric `host` as the C library reads it, and therefore as ssh connects
to it: `(6, value)` for an IPv6 literal (`inet_pton`), `(4, value)` for an IPv4 address,
shortened forms such as `192.0.522` included (`inet_aton`). An IPv4 address mapped into
IPv6 (`::ffff:a.b.c.d`) is returned as that IPv4 address. `nothing` when `host` is not
numeric or the C library does not read it as an address.
"""
function numeric_address(host::AbstractString)::Union{Tuple{Int, UInt128}, Nothing}
    is_numeric_host(host) || return nothing
    has_control_characters(host) && return nothing
    if occursin(':', host)
        bytes = zeros(UInt8, 16)
        status = @ccall inet_pton(ADDRESS_FAMILY_INET6::Cint, host::Cstring,
                                  bytes::Ptr{UInt8})::Cint
        status == 1 || return nothing
        value = foldl((acc, byte) -> (acc << 8) | byte, bytes; init=UInt128(0))
        return (value >> 32) == 0xffff ? (4, value & 0xffffffff) : (6, value)
    end
    address = Ref{UInt32}(0)
    status = @ccall inet_aton(host::Cstring, address::Ref{UInt32})::Cint
    return status == 0 ? nothing : (4, UInt128(ntoh(address[])))
end

"""
    node_key(host::AbstractString, port::Integer)::Tuple{String, Int}

Identity of an ssh endpoint when targets are compared: the host and the port. A host
name is taken in lower case without a trailing dot. An IP address is taken by its value
(see [`numeric_address`](@ref)), so that its spellings give one key: IPv6 groups written
in full or compressed, in either letter case, an IPv4 address mapped into IPv6, a
shortened IPv4 form. A name and its address, or two names of one machine, are not
recognized as the same node.
"""
function node_key(host::AbstractString, port::Integer)::Tuple{String, Int}
    name = lowercase(String(rstrip(host, '.')))
    address = numeric_address(name)
    key = address === nothing ? name : "ipv$(address[1]):$(string(address[2]; base=16))"
    return (key, Int(port))
end

"""
    validate_remote_directory(path::AbstractString, key::AbstractString,
                              context::AbstractString)

Require an absolute remote directory without control characters, `..` segments, or rsync
wildcard characters, other than the filesystem root in any spelling (`/`, `//`, `/.`).
`key` and `context` name the offending parameter in the error message.
"""
function validate_remote_directory(path::AbstractString, key::AbstractString,
                                   context::AbstractString)
    if isempty(path)
        throw(ArgumentError("'$(key)' must be a non-empty absolute path ($(context))."))
    end
    if !startswith(path, '/')
        throw(ArgumentError("'$(key)' must be an absolute path (received: '$(path)'; $(context))."))
    end
    if has_control_characters(path)
        throw(ArgumentError("'$(key)' must not contain control characters ($(context))."))
    end
    if has_parent_segment(path)
        throw(ArgumentError("'$(key)' must not contain '..' segments (received: '$(path)'; $(context))."))
    end
    if has_rsync_wildcards(path)
        throw(ArgumentError("'$(key)' must not contain '*', '?', '[', or ']', which rsync expands on the node (received: '$(path)'; $(context))."))
    end
    if isempty(rstrip(normpath(path), '/'))
        throw(ArgumentError("'$(key)' must not be the filesystem root ($(context))."))
    end
    return nothing
end

"""
    validate_relative_subdirectory(path::AbstractString, key::AbstractString,
                                   context::AbstractString)

Require a non-empty relative path without control characters, `..` segments, or rsync
wildcard characters.
"""
function validate_relative_subdirectory(path::AbstractString, key::AbstractString,
                                        context::AbstractString)
    if isempty(path)
        throw(ArgumentError("'$(key)' must be a non-empty relative path ($(context))."))
    end
    if startswith(path, '/')
        throw(ArgumentError("'$(key)' must be relative, not absolute (received: '$(path)'; $(context))."))
    end
    if has_control_characters(path)
        throw(ArgumentError("'$(key)' must not contain control characters ($(context))."))
    end
    if has_parent_segment(path)
        throw(ArgumentError("'$(key)' must not contain '..' segments (received: '$(path)'; $(context))."))
    end
    if has_rsync_wildcards(path)
        throw(ArgumentError("'$(key)' must not contain '*', '?', '[', or ']', which rsync expands on the node (received: '$(path)'; $(context))."))
    end
    return nothing
end

"""
    validate_patterns(patterns::AbstractVector, key::AbstractString)

Require every `rsync` include or exclude pattern to be a non-empty string without control
characters, and one that rsync takes as a pattern: it reads a leading `+ ` or `- ` as an
include or exclude rule of its own, and a lone `!` as the instruction to drop every
earlier rule.
"""
function validate_patterns(patterns::AbstractVector, key::AbstractString)
    for (idx, pattern) in enumerate(patterns)
        if !(pattern isa AbstractString)
            throw(ArgumentError("'$(key)' entry #$(idx) must be a string (received: $(typeof(pattern)))."))
        end
        if isempty(pattern)
            throw(ArgumentError("'$(key)' entry #$(idx) must not be empty."))
        end
        if has_control_characters(pattern)
            throw(ArgumentError("'$(key)' entry #$(idx) must not contain control characters."))
        end
        if pattern == "!" || startswith(pattern, "+ ") || startswith(pattern, "- ")
            throw(ArgumentError("'$(key)' entry #$(idx) ('$(pattern)') is not a plain pattern: rsync reads a leading '+ ' or '- ' and a lone '!' as filter rules of their own."))
        end
    end
    return nothing
end

"""
    expand_identity_file(path::AbstractString, context::AbstractString)::String

Expand a leading `~` of `path` to the home directory, as `expanduser` does. A path that
starts with `~` followed by anything but `/` (`~user/...`) is refused with an
`ArgumentError` naming the key and, through `context`, the target, since only the own
home directory is expanded.
"""
function expand_identity_file(path::AbstractString, context::AbstractString)::String
    if startswith(path, '~') && !(path == "~" || startswith(path, "~/"))
        throw(ArgumentError("Target 'identity_file' may start with '~/', but not with '~user': only the own home directory is expanded (received: '$(path)'; $(context))."))
    end
    return expanduser(path)
end

"""
    validate_identity_file(path::AbstractString, context::AbstractString)

Require `path`, already expanded by [`expand_identity_file`](@ref), to name a key file
that `ssh` opens as given and that the remote-shell string of rsync can carry: free of
control characters, of single quotes, and of `%` and `\$`, which `ssh` expands in an
identity path (`%d`, `\${HOME}`) after the check made here, absolute, and a regular file.
A private key must have no group or other permission bits, which `ssh` refuses for a key
of its owner; a public key (`.pub`), which selects the key of an agent or a security
token, is exempt. The file content is never read. Throws `ArgumentError` naming the
violated condition, also when the path cannot be inspected; `context` names the target
in the message.
"""
function validate_identity_file(path::AbstractString, context::AbstractString)
    if has_control_characters(path)
        throw(ArgumentError("Target 'identity_file' must not contain control characters ($(context))."))
    end
    if occursin('\'', path)
        throw(ArgumentError("Target 'identity_file' must not contain a single quote, which the remote-shell string of rsync cannot carry ($(context))."))
    end
    if occursin('%', path) || occursin('$', path)
        throw(ArgumentError("Target 'identity_file' must not contain '%' or '\$': ssh expands them in an identity path and would open another file (received: '$(path)'; $(context))."))
    end
    if !startswith(path, '/')
        throw(ArgumentError("Target 'identity_file' must be an absolute path or start with '~' (received: '$(path)'; $(context))."))
    end
    # The ArgumentError is thrown outside the catch block so that no cause is chained.
    failure = nothing
    present = try
        isfile(path)
    catch err
        err isa Base.IOError || rethrow()
        failure = err
        false
    end
    # libuv reports an error as the negated errno on Unix.
    if failure !== nothing
        throw(ArgumentError("Target 'identity_file' '$(path)' cannot be inspected: $(Libc.strerror(-failure.code)) ($(context))."))
    end
    if !present
        throw(ArgumentError("Target 'identity_file' '$(path)' is not a regular file ($(context))."))
    end
    mode = filemode(path) & 0o777
    if !endswith(path, ".pub") && mode & 0o077 != 0
        throw(ArgumentError("Target 'identity_file' '$(path)' is accessible to group or others (mode $(string(mode; base=8, pad=3))); ssh refuses such a private key: chmod 600 '$(path)' ($(context))."))
    end
    return nothing
end

"""
    validate_bridge_target_fields(name, host, port, user, auth, password, identity_file,
                                  proxy_jump, remote_dir, output_subdir,
                                  strict_host_key_checking)

Verify every field of a remote target: `name` must be a valid directory name, `host` a
hostname, ssh_config alias, or IP literal, `port` (when set) within `1:65535`, `user`
(when set) a POSIX user name, and `auth` one of `:password` or `:key`. A password target
requires a non-empty `password` free of control characters, admits no `identity_file`,
and admits `proxy_jump` only as `"none"`, since `sshpass` would hand the password to a
jump host that asks for one. A key target admits no `password`, an `identity_file` that passes
[`validate_identity_file`](@ref), and a `proxy_jump` that passes
[`is_valid_proxy_jump`](@ref). `remote_dir` must be an absolute path, `output_subdir` a
relative path, and `strict_host_key_checking` one of the accepted policies. Throws
`ArgumentError` on the first violation; error messages never include the password.
"""
function validate_bridge_target_fields(name::AbstractString,
                                       host::AbstractString,
                                       port::Union{Nothing, Integer},
                                       user::Union{Nothing, AbstractString},
                                       auth::Symbol,
                                       password::Union{Nothing, AbstractString},
                                       identity_file::Union{Nothing, AbstractString},
                                       proxy_jump::Union{Nothing, AbstractString},
                                       remote_dir::AbstractString,
                                       output_subdir::AbstractString,
                                       strict_host_key_checking::Union{AbstractString,
                                                                       Nothing})
    if !occursin(TARGET_NAME_PATTERN, name)
        throw(ArgumentError("Target 'name' must start with a letter or digit and contain only letters, digits, '.', '_', or '-' (at most 64 characters) because it names the local harvest directory (received: '$(name)')."))
    end
    context = "target '$(name)'"
    if has_non_decimal_address_field(host)
        throw(ArgumentError("Target 'host' is a numeric address with a field in octal or hexadecimal notation; write every field in decimal (received: '$(host)'; $(context))."))
    end
    if !is_valid_host(host)
        throw(ArgumentError("Target 'host' must be a DNS hostname, an IPv4 address, or an IPv6 literal (received: '$(host)'; $(context))."))
    end
    if is_numeric_host(host) && numeric_address(host) === nothing
        throw(ArgumentError("Target 'host' is numeric but not an IP address that the C library reads (received: '$(host)'; $(context))."))
    end
    if port !== nothing && !(1 <= port <= 65535)
        throw(ArgumentError("Target 'port' must be an integer in 1:65535 (received: $(port); $(context))."))
    end
    if user !== nothing && !occursin(USERNAME_PATTERN, user)
        throw(ArgumentError("Target 'user' must be a POSIX user name: a letter or underscore followed by at most 31 letters, digits, '.', '_', or '-' (received: '$(user)'; $(context))."))
    end
    if !(auth in VALID_AUTH_METHODS)
        throw(ArgumentError("Target 'auth' must be \"password\" or \"key\" (received: '$(auth)'; $(context))."))
    end
    if auth == :password
        if password === nothing
            throw(ArgumentError("Target 'password' is mandatory with auth = \"password\" ($(context))."))
        end
        if isempty(password)
            throw(ArgumentError("Target 'password' must not be empty ($(context))."))
        end
        if has_control_characters(password)
            throw(ArgumentError("Target 'password' must not contain control characters ($(context))."))
        end
        if identity_file !== nothing
            throw(ArgumentError("Target 'identity_file' applies to auth = \"key\" only ($(context))."))
        end
        if proxy_jump !== nothing && proxy_jump != "none"
            throw(ArgumentError("Target 'proxy_jump' is not available with auth = \"password\" except as \"none\": sshpass answers the first password prompt it sees, and a jump host asking for a password would receive the target's password; use auth = \"key\" ($(context))."))
        end
    else
        if password !== nothing
            throw(ArgumentError("Target 'password' must not be set with auth = \"key\" ($(context))."))
        end
        identity_file === nothing || validate_identity_file(identity_file, context)
        if proxy_jump !== nothing && !is_valid_proxy_jump(proxy_jump)
            throw(ArgumentError("Target 'proxy_jump' must be one or more [user@]host[:port] hops separated by commas, an IPv6 address in brackets only in the last hop, or \"none\" (received: '$(proxy_jump)'; $(context))."))
        end
    end
    validate_remote_directory(remote_dir, "remote_dir", context)
    validate_relative_subdirectory(output_subdir, "output_subdir", context)
    if strict_host_key_checking !== nothing &&
       !(strict_host_key_checking in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Target 'strict_host_key_checking' must be one of $(VALID_HOST_KEY_POLICIES) (received: '$(strict_host_key_checking)'; $(context))."))
    end
    return nothing
end

"""
    validate_global_options(connect_timeout::Integer, strict_host_key_checking::AbstractString,
                            bandwidth_limit::Integer, server_alive_interval::Integer,
                            server_alive_count_max::Integer)

Verify the global transport parameters. Throws `ArgumentError` on violation.
"""
function validate_global_options(connect_timeout::Integer,
                                 strict_host_key_checking::AbstractString,
                                 bandwidth_limit::Integer,
                                 server_alive_interval::Integer,
                                 server_alive_count_max::Integer)
    if connect_timeout < 1
        throw(ArgumentError("Global 'connect_timeout' must be a positive integer in seconds (received: $(connect_timeout))."))
    end
    if !(strict_host_key_checking in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Global 'strict_host_key_checking' must be one of $(VALID_HOST_KEY_POLICIES) (received: '$(strict_host_key_checking)')."))
    end
    if bandwidth_limit < 0
        throw(ArgumentError("Global 'bandwidth_limit' must be a non-negative integer in KiB/s (received: $(bandwidth_limit))."))
    end
    if server_alive_interval < 0
        throw(ArgumentError("Global 'server_alive_interval' must be a non-negative integer in seconds (received: $(server_alive_interval))."))
    end
    if server_alive_count_max < 1
        throw(ArgumentError("Global 'server_alive_count_max' must be a positive integer (received: $(server_alive_count_max))."))
    end
    return nothing
end

"""
    validate_push_options(local_source_dir::AbstractString)

Verify the deployment parameters. Throws `ArgumentError` on violation.
"""
function validate_push_options(local_source_dir::AbstractString)
    if isempty(local_source_dir)
        throw(ArgumentError("Push parameter 'local_source_dir' must be a non-empty path."))
    end
    if has_control_characters(local_source_dir)
        throw(ArgumentError("Push parameter 'local_source_dir' must not contain control characters."))
    end
    return nothing
end

"""
    validate_pull_options(local_destination_root::AbstractString,
                          output_subdir::AbstractString, collision_strategy::Symbol,
                          purge_scope::Symbol)

Verify the harvesting parameters. Throws `ArgumentError` on violation.
"""
function validate_pull_options(local_destination_root::AbstractString,
                               output_subdir::AbstractString,
                               collision_strategy::Symbol,
                               purge_scope::Symbol)
    if isempty(local_destination_root)
        throw(ArgumentError("Pull parameter 'local_destination_root' must be a non-empty path."))
    end
    if has_control_characters(local_destination_root)
        throw(ArgumentError("Pull parameter 'local_destination_root' must not contain control characters."))
    end
    validate_relative_subdirectory(output_subdir, "output_subdir", "[pull] section")
    if !(collision_strategy in VALID_COLLISION_STRATEGIES)
        throw(ArgumentError("Pull parameter 'collision_strategy' must be one of $(VALID_COLLISION_STRATEGIES) (received: :$(collision_strategy))."))
    end
    if !(purge_scope in VALID_PURGE_SCOPES)
        throw(ArgumentError("Pull parameter 'purge_scope' must be one of $(VALID_PURGE_SCOPES) (received: :$(purge_scope))."))
    end
    return nothing
end

"""
    validate_remote_path_safety(path::AbstractString, user::AbstractString)

Verify that `path` may be removed recursively on a remote host. The path must be
absolute, free of control characters and `..` segments, at least two components deep,
and neither the filesystem root, `/root`, `/home`, the home directory of `user`, nor
located under a protected system directory (`/usr`, `/etc`, `/var`, ...). Throws
`ArgumentError` otherwise.
"""
function validate_remote_path_safety(path::AbstractString, user::AbstractString)
    if isempty(path)
        throw(ArgumentError("Remote path for deletion must not be empty."))
    end
    if !startswith(path, '/')
        throw(ArgumentError("Remote path '$(path)' must be absolute for recursive deletion."))
    end
    if has_control_characters(path)
        throw(ArgumentError("Remote path for deletion must not contain control characters."))
    end
    if has_parent_segment(path)
        throw(ArgumentError("Remote path '$(path)' must not contain '..' segments."))
    end
    normalized = rstrip(normpath(path), '/')
    if normalized in ("", "/root", "/home", "/home/$(user)")
        throw(ArgumentError("Recursive deletion refused for protected path '$(path)'."))
    end
    components = filter(!isempty, split(normalized, '/'))
    if first(components) in PROTECTED_ROOT_COMPONENTS
        throw(ArgumentError("Recursive deletion refused under protected system directory '/$(first(components))' (path '$(path)')."))
    end
    if length(components) < 2
        throw(ArgumentError("Remote path '$(path)' is too shallow for recursive deletion (at least two path components are required)."))
    end
    return nothing
end
