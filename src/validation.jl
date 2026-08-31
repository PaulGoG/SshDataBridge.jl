const VALID_HOST_KEY_POLICIES = ("accept-new", "yes", "no")
const VALID_COLLISION_STRATEGIES = (:resume, :backup, :abort)

"""
    validate_bridge_target_fields(
        name::AbstractString,
        host::AbstractString,
        port::Integer,
        user::AbstractString,
        password::AbstractString,
        remote_dir::AbstractString,
        output_subdir::AbstractString,
        strict_host_key_checking::Union{AbstractString, Nothing},
    )

Verify validity and boundaries of fields defining a remote bridge target.
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
    if isempty(strip(name))
        throw(ArgumentError("Target 'name' must be a non-empty string."))
    end
    if isempty(strip(host))
        throw(ArgumentError("Target 'host' must be a non-empty string for target '$(name)'."))
    end
    if occursin(r"\s", host)
        throw(ArgumentError("Target 'host' must not contain whitespace characters (received: '$(host)')."))
    end
    if !(1 <= port <= 65535)
        throw(ArgumentError("Target 'port' must be an integer in range 1:65535 (received: $(port) for target '$(name)')."))
    end
    if isempty(strip(user))
        throw(ArgumentError("Target 'user' must be a non-empty string for target '$(name)'."))
    end
    if occursin(r"\s", user)
        throw(ArgumentError("Target 'user' must not contain whitespace characters (received: '$(user)')."))
    end
    if isempty(password)
        throw(ArgumentError("Target 'password' must not be empty for target '$(name)'."))
    end
    if isempty(strip(remote_dir))
        throw(ArgumentError("Target 'remote_dir' must be a non-empty string for target '$(name)'."))
    end
    if isempty(strip(output_subdir))
        throw(ArgumentError("Target 'output_subdir' must be a non-empty string for target '$(name)'."))
    end
    if strict_host_key_checking !== nothing &&
       !(strict_host_key_checking in VALID_HOST_KEY_POLICIES)
        throw(ArgumentError("Target 'strict_host_key_checking' must be one of $(VALID_HOST_KEY_POLICIES) (received: '$(strict_host_key_checking)')."))
    end
    return nothing
end

"""
    validate_global_options(
        connect_timeout::Integer,
        strict_host_key_checking::AbstractString,
        bandwidth_limit::Integer,
    )

Verify validity of global network and transport parameters.
"""
function validate_global_options(connect_timeout::Integer,
                                 strict_host_key_checking::AbstractString,
                                 bandwidth_limit::Integer)
    if connect_timeout < 1
        throw(ArgumentError("Global 'connect_timeout' must be a positive integer (received: $(connect_timeout))."))
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

Verify validity of deployment parameters.
"""
function validate_push_options(local_source_dir::AbstractString)
    if isempty(strip(local_source_dir))
        throw(ArgumentError("Push parameter 'local_source_dir' must be a non-empty string."))
    end
    return nothing
end

"""
    validate_pull_options(
        local_destination_root::AbstractString,
        output_subdir::AbstractString,
        collision_strategy::Symbol,
    )

Verify validity of results retrieval parameters.
"""
function validate_pull_options(local_destination_root::AbstractString,
                               output_subdir::AbstractString,
                               collision_strategy::Symbol)
    if isempty(strip(local_destination_root))
        throw(ArgumentError("Pull parameter 'local_destination_root' must be a non-empty string."))
    end
    if isempty(strip(output_subdir))
        throw(ArgumentError("Pull parameter 'output_subdir' must be a non-empty string."))
    end
    if !(collision_strategy in VALID_COLLISION_STRATEGIES)
        throw(ArgumentError("Pull parameter 'collision_strategy' must be one of $(VALID_COLLISION_STRATEGIES) (received: :$(collision_strategy))."))
    end
    return nothing
end
