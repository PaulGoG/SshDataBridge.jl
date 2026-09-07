const VALID_HOST_KEY_POLICIES = ("accept-new", "yes", "no")
const VALID_COLLISION_STRATEGIES = (:resume, :backup, :abort)
const VALID_PURGE_SCOPES = (:output, :project)

const HOSTNAME_PATTERN = r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$"
const IPV6_PATTERN = r"^\[?(?=[0-9A-Fa-f:.]*[0-9A-Fa-f])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:\.[0-9]{1,3}){0,3}\]?$"
const USERNAME_PATTERN = r"^[A-Za-z_][A-Za-z0-9._-]{0,31}$"
const TARGET_NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
const CONTROL_CHARACTER_PATTERN = r"[\x00-\x1f\x7f]"
const MAX_HOSTNAME_LENGTH = 253

# First path components under which recursive remote deletion is refused.
const PROTECTED_ROOT_COMPONENTS = ("bin", "boot", "dev", "etc", "lib", "lib64", "opt",
                                   "proc", "root", "run", "sbin", "srv", "sys", "usr",
                                   "var")

"""
    is_valid_host(host::AbstractString)::Bool

Whether `host` is a syntactically valid DNS hostname, IPv4 address, or IPv6 literal
(optionally bracketed).
"""
function is_valid_host(host::AbstractString)::Bool
    return length(host) <= MAX_HOSTNAME_LENGTH &&
           (occursin(HOSTNAME_PATTERN, host) || occursin(IPV6_PATTERN, host))
end

"""
    has_control_characters(text::AbstractString)::Bool

Whether `text` contains ASCII control characters, which are never legitimate in the
configuration fields and would corrupt the generated shell commands.
"""
has_control_characters(text::AbstractString)::Bool = occursin(CONTROL_CHARACTER_PATTERN,
                                                              text)

"""
    has_parent_segment(path::AbstractString)::Bool

Whether `path` contains a `..` segment.
"""
has_parent_segment(path::AbstractString)::Bool = any(==(".."), split(path, '/'))

"""
    validate_remote_directory(path::AbstractString, key::AbstractString,
                              context::AbstractString)

Require an absolute remote directory without control characters, `..` segments, or the
filesystem root. `key` and `context` name the offending parameter in the error message.
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
    if isempty(rstrip(path, '/'))
        throw(ArgumentError("'$(key)' must not be the filesystem root ($(context))."))
    end
    return nothing
end

"""
    validate_relative_subdirectory(path::AbstractString, key::AbstractString,
                                   context::AbstractString)

Require a non-empty relative path without control characters or `..` segments.
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
    return nothing
end

"""
    validate_patterns(patterns::AbstractVector, key::AbstractString)

Require every `rsync` include or exclude pattern to be a non-empty string without control
characters.
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
    end
    return nothing
end

"""
    validate_bridge_target_fields(name, host, port, user, password, remote_dir,
                                  output_subdir, strict_host_key_checking)

Verify every field of a remote target: `name` must be a valid directory name, `host` a
hostname or IP literal, `port` within `1:65535`, `user` a POSIX user name, `password`
non-empty and free of control characters, `remote_dir` an absolute path, `output_subdir` a
relative path, and `strict_host_key_checking` one of the accepted policies. Throws
`ArgumentError` on the first violation; error messages never include the password.
"""
function validate_bridge_target_fields(name::AbstractString,
                                       host::AbstractString,
                                       port::Integer,
                                       user::AbstractString,
                                       password::AbstractString,
                                       remote_dir::AbstractString,
                                       output_subdir::AbstractString,
                                       strict_host_key_checking::Union{AbstractString,
                                                                       Nothing})
    if !occursin(TARGET_NAME_PATTERN, name)
        throw(ArgumentError("Target 'name' must start with a letter or digit and contain only letters, digits, '.', '_', or '-' (at most 64 characters) because it names the local harvest directory (received: '$(name)')."))
    end
    context = "target '$(name)'"
    if !is_valid_host(host)
        throw(ArgumentError("Target 'host' must be a DNS hostname, an IPv4 address, or an IPv6 literal (received: '$(host)'; $(context))."))
    end
    if !(1 <= port <= 65535)
        throw(ArgumentError("Target 'port' must be an integer in 1:65535 (received: $(port); $(context))."))
    end
    if !occursin(USERNAME_PATTERN, user)
        throw(ArgumentError("Target 'user' must be a POSIX user name: a letter or underscore followed by at most 31 letters, digits, '.', '_', or '-' (received: '$(user)'; $(context))."))
    end
    if isempty(password)
        throw(ArgumentError("Target 'password' must not be empty ($(context))."))
    end
    if has_control_characters(password)
        throw(ArgumentError("Target 'password' must not contain control characters ($(context))."))
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
                            bandwidth_limit::Integer)

Verify the global transport parameters. Throws `ArgumentError` on violation.
"""
function validate_global_options(connect_timeout::Integer,
                                 strict_host_key_checking::AbstractString,
                                 bandwidth_limit::Integer)
    if connect_timeout < 1
        throw(ArgumentError("Global 'connect_timeout' must be a positive integer in seconds (received: $(connect_timeout))."))
    end
    if !(strict_host_key_checking in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Global 'strict_host_key_checking' must be one of $(VALID_HOST_KEY_POLICIES) (received: '$(strict_host_key_checking)')."))
    end
    if bandwidth_limit < 0
        throw(ArgumentError("Global 'bandwidth_limit' must be a non-negative integer in KB/s (received: $(bandwidth_limit))."))
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
        throw(ArgumentError("Recursive deletion refused on critical path '$(path)'."))
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
