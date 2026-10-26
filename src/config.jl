const TOP_LEVEL_KEYS = ("globals", "push", "pull", "targets")
const GLOBALS_KEYS = ("connect_timeout", "strict_host_key_checking", "compress",
                      "bandwidth_limit", "server_alive_interval", "server_alive_count_max")
const PUSH_KEYS = ("local_source_dir", "excludes", "includes", "use_gitignore",
                   "require_clean_git")
const PULL_KEYS = ("local_destination_root", "output_subdir", "includes", "excludes",
                   "collision_strategy", "clean_remote_after_pull", "purge_scope")
const TARGET_KEYS = ("name", "host", "port", "user", "password", "remote_dir",
                     "output_subdir", "strict_host_key_checking")

"""
    reject_unknown_keys(table::AbstractDict, allowed, context::AbstractString)

Throw `ArgumentError` listing every key of `table` that is not in `allowed`, so that
misspelled configuration keys fail before a run starts.
"""
function reject_unknown_keys(table::AbstractDict, allowed, context::AbstractString)
    unknown = sort!([string(k) for k in keys(table) if !(string(k) in allowed)])
    if !isempty(unknown)
        throw(ArgumentError("Unknown key(s) in $(context): $(join(("'$(k)'" for k in unknown), ", ")). Allowed keys: $(join(allowed, ", "))."))
    end
    return nothing
end

"""
    typed_value(table::AbstractDict, key::AbstractString, ::Type{T}, default, context) where {T}

Return `table[key]` if present, otherwise `default`, checking that the value is a `T`.
A boolean is never accepted for a numeric `T`, although `Bool <: Integer` in Julia, so
that `port = true` cannot silently become port 1. Throws `ArgumentError` naming
`context.key` on a type mismatch.
"""
function typed_value(table::AbstractDict, key::AbstractString, ::Type{T}, default,
                     context::AbstractString) where {T}
    value = get(table, key, default)
    if !(value isa T) || (value isa Bool && T !== Bool)
        location = isempty(context) ? key : "$(context).$(key)"
        throw(ArgumentError("Configuration key '$(location)' must be of type $(T); received $(typeof(value))."))
    end
    return value
end

"""
    required_value(table::AbstractDict, key::AbstractString, ::Type{T}, context) where {T}

Return `table[key]` checked to be a `T`; throws `ArgumentError` if the key is absent.
"""
function required_value(table::AbstractDict, key::AbstractString, ::Type{T},
                        context::AbstractString) where {T}
    if !haskey(table, key)
        throw(ArgumentError("Configuration table $(context) is missing the mandatory key '$(key)'."))
    end
    return typed_value(table, key, T, nothing, context)
end

"""
    resolve_local_path(path::AbstractString, config_dir::AbstractString)::String

Expand a leading `~` and resolve a relative `path` against `config_dir`.
"""
function resolve_local_path(path::AbstractString, config_dir::AbstractString)::String
    expanded = expanduser(path)
    return isabspath(expanded) ? String(expanded) : normpath(joinpath(config_dir, expanded))
end

"""
    parse_config(dict::AbstractDict; config_dir::AbstractString=pwd())::BridgeConfig

Build a validated [`BridgeConfig`](@ref) from a parsed TOML dictionary. Every table is
checked for unknown keys and every value for its expected type. `[push].local_source_dir`,
`[pull].local_destination_root`, and the target keys `name`, `host`, `user`, `password`,
and `remote_dir` are mandatory; every other key has a default. Relative local paths are
resolved against `config_dir`.
"""
function parse_config(dict::AbstractDict; config_dir::AbstractString=pwd())::BridgeConfig
    reject_unknown_keys(dict, TOP_LEVEL_KEYS, "the top level")

    globals_table = typed_value(dict, "globals", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(globals_table, GLOBALS_KEYS, "[globals]")
    globals = GlobalOptions(typed_value(globals_table, "connect_timeout", Integer,
                                        DEFAULT_CONNECT_TIMEOUT, "[globals]"),
                            typed_value(globals_table, "strict_host_key_checking",
                                        AbstractString, DEFAULT_HOST_KEY_POLICY,
                                        "[globals]"),
                            typed_value(globals_table, "compress", Bool, DEFAULT_COMPRESS,
                                        "[globals]"),
                            typed_value(globals_table, "bandwidth_limit", Integer,
                                        DEFAULT_BANDWIDTH_LIMIT, "[globals]"),
                            typed_value(globals_table, "server_alive_interval", Integer,
                                        DEFAULT_SERVER_ALIVE_INTERVAL, "[globals]"),
                            typed_value(globals_table, "server_alive_count_max", Integer,
                                        DEFAULT_SERVER_ALIVE_COUNT_MAX, "[globals]"))

    push_table = typed_value(dict, "push", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(push_table, PUSH_KEYS, "[push]")
    push_opts = PushOptions(resolve_local_path(required_value(push_table,
                                                              "local_source_dir",
                                                              AbstractString, "[push]"),
                                               config_dir),
                            typed_value(push_table, "excludes", AbstractVector,
                                        DEFAULT_PUSH_EXCLUDES, "[push]"),
                            typed_value(push_table, "require_clean_git", Bool,
                                        DEFAULT_REQUIRE_CLEAN_GIT, "[push]"),
                            typed_value(push_table, "use_gitignore", Bool,
                                        DEFAULT_USE_GITIGNORE, "[push]"),
                            typed_value(push_table, "includes", AbstractVector, String[],
                                        "[push]"))

    pull_table = typed_value(dict, "pull", AbstractDict, Dict{String, Any}(), "")
    reject_unknown_keys(pull_table, PULL_KEYS, "[pull]")
    pull_opts = PullOptions(resolve_local_path(required_value(pull_table,
                                                              "local_destination_root",
                                                              AbstractString, "[pull]"),
                                               config_dir),
                            typed_value(pull_table, "output_subdir", AbstractString,
                                        DEFAULT_OUTPUT_SUBDIR, "[pull]"),
                            typed_value(pull_table, "includes", AbstractVector, String[],
                                        "[pull]"),
                            typed_value(pull_table, "excludes", AbstractVector,
                                        DEFAULT_PULL_EXCLUDES, "[pull]"),
                            Symbol(typed_value(pull_table, "collision_strategy",
                                               AbstractString,
                                               String(DEFAULT_COLLISION_STRATEGY),
                                               "[pull]")),
                            typed_value(pull_table, "clean_remote_after_pull", Bool,
                                        DEFAULT_CLEAN_REMOTE_AFTER_PULL, "[pull]"),
                            Symbol(typed_value(pull_table, "purge_scope", AbstractString,
                                               String(DEFAULT_PURGE_SCOPE), "[pull]")))

    if !haskey(dict, "targets")
        throw(ArgumentError("Configuration is missing the mandatory [[targets]] array."))
    end
    targets_raw = dict["targets"]
    if !(targets_raw isa AbstractVector) || isempty(targets_raw)
        throw(ArgumentError("Configuration key 'targets' must be a non-empty array of [[targets]] tables."))
    end

    targets = Vector{BridgeTarget}(undef, length(targets_raw))
    for (index, entry) in enumerate(targets_raw)
        context = "[[targets]] entry #$(index)"
        if !(entry isa AbstractDict)
            throw(ArgumentError("$(context) is not a table."))
        end
        reject_unknown_keys(entry, TARGET_KEYS, context)
        targets[index] = BridgeTarget(required_value(entry, "name", AbstractString,
                                                     context),
                                      required_value(entry, "host", AbstractString,
                                                     context),
                                      typed_value(entry, "port", Integer, DEFAULT_PORT,
                                                  context),
                                      required_value(entry, "user", AbstractString,
                                                     context),
                                      required_value(entry, "password", AbstractString,
                                                     context),
                                      required_value(entry, "remote_dir", AbstractString,
                                                     context),
                                      typed_value(entry, "output_subdir", AbstractString,
                                                  pull_opts.output_subdir, context),
                                      typed_value(entry, "strict_host_key_checking",
                                                  Union{Nothing, AbstractString}, nothing,
                                                  context))
    end

    return BridgeConfig(globals, push_opts, pull_opts, targets)
end

"""
    load_config(path::AbstractString)::BridgeConfig

Read, parse, and validate the TOML configuration file at `path`. TOML syntax errors and
every validation failure are reported as `ArgumentError`. A file readable by group or
others is refused, because it holds passwords.
"""
function load_config(path::AbstractString)::BridgeConfig
    if !isfile(path)
        throw(ArgumentError("Configuration file does not exist: $(path)"))
    end
    mode = filemode(path) & 0o777
    if mode & 0o077 != 0
        throw(ArgumentError("Configuration file '$(path)' is readable by other users (mode $(string(mode; base=8, pad=3))). It holds passwords; set it to mode 600: chmod 600 '$(path)'"))
    end
    parsed = try
        TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("Failed to parse TOML configuration '$(path)': $(sprint(showerror, err))"))
    end
    return parse_config(parsed; config_dir=dirname(abspath(path)))
end
