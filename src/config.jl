"""
    parse_config(dict::AbstractDict{String, Any}; config_dir::AbstractString = pwd())::BridgeConfig

Parse a raw configuration dictionary into a strictly validated `BridgeConfig` instance.
"""
function parse_config(dict::AbstractDict{String, Any};
                      config_dir::AbstractString=pwd())::BridgeConfig
    # 1. Parse Globals
    globals_raw = get(dict, "globals", Dict{String, Any}())
    globals = GlobalOptions(get(globals_raw, "connect_timeout", 10),
                            get(globals_raw, "strict_host_key_checking", "accept-new"),
                            get(globals_raw, "compress", true),
                            get(globals_raw, "bandwidth_limit", 0))

    # 2. Parse Push Options
    push_raw = get(dict, "push", Dict{String, Any}())
    local_source = get(push_raw, "local_source_dir", ".")
    # Resolve relative paths against configuration directory
    resolved_source = isabspath(local_source) ? local_source :
                      normpath(joinpath(config_dir, local_source))
    push_excludes_raw = get(push_raw, "excludes", DEFAULT_PUSH_EXCLUDES)
    push_excludes = String[String(strip(string(e))) for e in push_excludes_raw]
    require_clean_git = get(push_raw, "require_clean_git", false)
    use_gitignore = get(push_raw, "use_gitignore", true)
    push_opts = PushOptions(resolved_source, push_excludes, require_clean_git,
                            use_gitignore)

    # 3. Parse Pull Options
    pull_raw = get(dict, "pull", Dict{String, Any}())
    local_dest = get(pull_raw, "local_destination_root", "data/harvested_results")
    resolved_dest = isabspath(local_dest) ? local_dest :
                    normpath(joinpath(config_dir, local_dest))
    default_output_subdir = get(pull_raw, "output_subdir", "output")
    pull_includes_raw = get(pull_raw, "includes", Any[])
    pull_includes = String[String(strip(string(i))) for i in pull_includes_raw]
    pull_excludes_raw = get(pull_raw, "excludes", DEFAULT_PULL_EXCLUDES)
    pull_excludes = String[String(strip(string(e))) for e in pull_excludes_raw]
    collision_strategy_raw = Symbol(get(pull_raw, "collision_strategy", "resume"))
    clean_remote_after_pull = get(pull_raw, "clean_remote_after_pull", false)
    purge_scope_raw = Symbol(get(pull_raw, "purge_scope", "output"))
    pull_opts = PullOptions(resolved_dest,
                            default_output_subdir,
                            pull_includes,
                            pull_excludes,
                            collision_strategy_raw,
                            clean_remote_after_pull,
                            purge_scope_raw)

    # 4. Parse Targets
    targets_raw = get(dict, "targets", nothing)
    if targets_raw === nothing || !isa(targets_raw, AbstractVector) || isempty(targets_raw)
        throw(ArgumentError("Configuration must contain a non-empty [[targets]] list."))
    end

    targets = BridgeTarget[]
    for (idx, t_dict) in enumerate(targets_raw)
        if !isa(t_dict, AbstractDict)
            throw(ArgumentError("Target #$(idx) must be a dictionary/table."))
        end
        name = get(t_dict, "name", "Target-$(idx)")
        host = get(t_dict, "host", "")
        port = get(t_dict, "port", 22)
        user = get(t_dict, "user", "")
        password = get(t_dict, "password", "")
        remote_dir = get(t_dict, "remote_dir", "")
        output_subdir = get(t_dict, "output_subdir", default_output_subdir)
        strict_host_key_checking = get(t_dict, "strict_host_key_checking", nothing)

        target = BridgeTarget(name,
                              host,
                              port,
                              user,
                              password,
                              remote_dir,
                              output_subdir,
                              strict_host_key_checking)
        push!(targets, target)
    end

    return BridgeConfig(globals, push_opts, pull_opts, targets)
end

"""
    load_config(path::AbstractString)::BridgeConfig

Load, parse, and validate a TOML configuration file from disk.
"""
function load_config(path::AbstractString)::BridgeConfig
    if !isfile(path)
        throw(ArgumentError("Configuration file does not exist at specified path: $(path)"))
    end
    parsed_toml = TOML.parsefile(path)
    config_dir = dirname(abspath(path))
    return parse_config(parsed_toml; config_dir=config_dir)
end
