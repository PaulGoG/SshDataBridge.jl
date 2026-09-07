const TOP_LEVEL_KEYS = ("globals", "push", "pull", "targets")
const GLOBALS_KEYS = ("connect_timeout", "strict_host_key_checking", "compress",
                      "bandwidth_limit")
const PUSH_KEYS = ("local_source_dir", "excludes", "use_gitignore", "require_clean_git")
const PULL_KEYS = ("local_destination_root", "output_subdir", "includes", "excludes",
                   "collision_strategy", "clean_remote_after_pull", "purge_scope")
const TARGET_KEYS = ("name", "host", "port", "user", "password", "remote_dir",
                     "output_subdir", "strict_host_key_checking")

"""
    reject_unknown_keys(table::AbstractDict, allowed, location::AbstractString)

Throw `ArgumentError` naming the first key of `table` that is not listed in `allowed`, so
that misspelled configuration keys fail before a run starts.
"""
function reject_unknown_keys(table::AbstractDict, allowed, location::AbstractString)
    for key in keys(table)
        if !(key in allowed)
            throw(ArgumentError("Unknown configuration key '$(key)' in $(location). Allowed keys: $(join(allowed, ", "))."))
        end
    end
    return nothing
end

"""
    configuration_table(dict::AbstractDict, key::AbstractString)::Dict{String, Any}

Return the sub-table `dict[key]` with string keys, or an empty table when the key is
absent. Throws `ArgumentError` when the value is not a table.
"""
function configuration_table(dict::AbstractDict, key::AbstractString)::Dict{String, Any}
    haskey(dict, key) || return Dict{String, Any}()
    value = dict[key]
    if !(value isa AbstractDict)
        throw(ArgumentError("Configuration section '[$(key)]' must be a table; received $(typeof(value))."))
    end
    return Dict{String, Any}(String(k) => v for (k, v) in value)
end

"""
    optional_string(table, key, default::String, location)::String

Read a string-valued key with a default; throws `ArgumentError` on a wrong type.
"""
function optional_string(table::AbstractDict, key::AbstractString, default::String,
                         location::AbstractString)::String
    haskey(table, key) || return default
    value = table[key]
    if !(value isa AbstractString)
        throw(ArgumentError("Configuration key '$(location).$(key)' must be a string; received $(typeof(value))."))
    end
    return String(value)
end

"""
    optional_string_or_nothing(table, key, location)::Union{String, Nothing}

Read an optional string-valued key without a default; throws `ArgumentError` on a wrong
type.
"""
function optional_string_or_nothing(table::AbstractDict, key::AbstractString,
                                    location::AbstractString)::Union{String, Nothing}
    haskey(table, key) || return nothing
    return optional_string(table, key, "", location)
end

"""
    required_string(table, key, location)::String

Read a mandatory string-valued key; throws `ArgumentError` when absent or of a wrong type.
"""
function required_string(table::AbstractDict, key::AbstractString,
                         location::AbstractString)::String
    if !haskey(table, key)
        throw(ArgumentError("Configuration key '$(location).$(key)' is mandatory but missing."))
    end
    return optional_string(table, key, "", location)
end

"""
    optional_integer(table, key, default::Int, location)::Int

Read an integer-valued key with a default; booleans are rejected although they are
integers in Julia. Throws `ArgumentError` on a wrong type.
"""
function optional_integer(table::AbstractDict, key::AbstractString, default::Int,
                          location::AbstractString)::Int
    haskey(table, key) || return default
    value = table[key]
    if !(value isa Integer) || value isa Bool
        throw(ArgumentError("Configuration key '$(location).$(key)' must be an integer; received $(typeof(value))."))
    end
    return Int(value)
end

"""
    optional_bool(table, key, default::Bool, location)::Bool

Read a boolean-valued key with a default; throws `ArgumentError` on a wrong type.
"""
function optional_bool(table::AbstractDict, key::AbstractString, default::Bool,
                       location::AbstractString)::Bool
    haskey(table, key) || return default
    value = table[key]
    if !(value isa Bool)
        throw(ArgumentError("Configuration key '$(location).$(key)' must be a boolean; received $(typeof(value))."))
    end
    return value
end

"""
    optional_string_array(table, key, default::Vector{String}, location)::Vector{String}

Read an array of strings with a default; throws `ArgumentError` when the value is not an
array or when any entry is not a string.
"""
function optional_string_array(table::AbstractDict, key::AbstractString,
                               default::Vector{String},
                               location::AbstractString)::Vector{String}
    haskey(table, key) || return default
    value = table[key]
    if !(value isa AbstractVector)
        throw(ArgumentError("Configuration key '$(location).$(key)' must be an array of strings; received $(typeof(value))."))
    end
    for (idx, item) in enumerate(value)
        if !(item isa AbstractString)
            throw(ArgumentError("Entry #$(idx) of configuration key '$(location).$(key)' must be a string; received $(typeof(item))."))
        end
    end
    return String[String(item) for item in value]
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
checked for unknown keys and every value for its expected type; mandatory target keys are
reported by name. Relative local paths are resolved against `config_dir`.
"""
function parse_config(dict::AbstractDict; config_dir::AbstractString=pwd())::BridgeConfig
    reject_unknown_keys(dict, TOP_LEVEL_KEYS, "the top level")

    globals_raw = configuration_table(dict, "globals")
    reject_unknown_keys(globals_raw, GLOBALS_KEYS, "[globals]")
    globals = GlobalOptions(optional_integer(globals_raw, "connect_timeout", 10,
                                             "[globals]"),
                            optional_string(globals_raw, "strict_host_key_checking",
                                            "accept-new", "[globals]"),
                            optional_bool(globals_raw, "compress", true, "[globals]"),
                            optional_integer(globals_raw, "bandwidth_limit", 0,
                                             "[globals]"))

    push_raw = configuration_table(dict, "push")
    reject_unknown_keys(push_raw, PUSH_KEYS, "[push]")
    push_opts = PushOptions(resolve_local_path(optional_string(push_raw,
                                                               "local_source_dir", ".",
                                                               "[push]"), config_dir),
                            optional_string_array(push_raw, "excludes",
                                                  DEFAULT_PUSH_EXCLUDES, "[push]"),
                            optional_bool(push_raw, "require_clean_git", false, "[push]"),
                            optional_bool(push_raw, "use_gitignore", true, "[push]"))

    pull_raw = configuration_table(dict, "pull")
    reject_unknown_keys(pull_raw, PULL_KEYS, "[pull]")
    pull_opts = PullOptions(resolve_local_path(optional_string(pull_raw,
                                                               "local_destination_root",
                                                               "data/harvested_results",
                                                               "[pull]"), config_dir),
                            optional_string(pull_raw, "output_subdir", "output", "[pull]"),
                            optional_string_array(pull_raw, "includes", String[],
                                                  "[pull]"),
                            optional_string_array(pull_raw, "excludes",
                                                  DEFAULT_PULL_EXCLUDES, "[pull]"),
                            Symbol(optional_string(pull_raw, "collision_strategy",
                                                   "resume", "[pull]")),
                            optional_bool(pull_raw, "clean_remote_after_pull", false,
                                          "[pull]"),
                            Symbol(optional_string(pull_raw, "purge_scope", "output",
                                                   "[pull]")))

    if !haskey(dict, "targets")
        throw(ArgumentError("Configuration must contain at least one [[targets]] entry."))
    end
    targets_raw = dict["targets"]
    if !(targets_raw isa AbstractVector)
        throw(ArgumentError("Configuration key 'targets' must be an array of tables; received $(typeof(targets_raw))."))
    end
    if isempty(targets_raw)
        throw(ArgumentError("Configuration must contain at least one [[targets]] entry."))
    end

    targets = BridgeTarget[]
    for (idx, entry) in enumerate(targets_raw)
        location = "[[targets]] entry #$(idx)"
        if !(entry isa AbstractDict)
            throw(ArgumentError("$(location) must be a table; received $(typeof(entry))."))
        end
        table = Dict{String, Any}(String(k) => v for (k, v) in entry)
        reject_unknown_keys(table, TARGET_KEYS, location)
        push!(targets,
              BridgeTarget(optional_string(table, "name", "Target-$(idx)", location),
                           required_string(table, "host", location),
                           optional_integer(table, "port", 22, location),
                           required_string(table, "user", location),
                           required_string(table, "password", location),
                           required_string(table, "remote_dir", location),
                           optional_string(table, "output_subdir", pull_opts.output_subdir,
                                           location),
                           optional_string_or_nothing(table, "strict_host_key_checking",
                                                      location)))
    end

    return BridgeConfig(globals, push_opts, pull_opts, targets)
end

"""
    load_config(path::AbstractString)::BridgeConfig

Read, parse, and validate the TOML configuration file at `path`. TOML syntax errors and
every validation failure are reported as `ArgumentError`.
"""
function load_config(path::AbstractString)::BridgeConfig
    if !isfile(path)
        throw(ArgumentError("Configuration file does not exist: $(path)"))
    end
    parsed = try
        TOML.parsefile(path)
    catch err
        err isa TOML.ParserError || rethrow()
        throw(ArgumentError("Failed to parse TOML configuration '$(path)': $(sprint(showerror, err))"))
    end
    return parse_config(parsed; config_dir=dirname(abspath(path)))
end
