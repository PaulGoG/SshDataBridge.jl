using Pkg
using TOML: TOML

const MANIFEST_PATH = joinpath(@__DIR__, "Manifest.toml")

# A manifest resolved by another Julia minor version may reference standard libraries that
# do not exist here, and Pkg.instantiate does not re-resolve it; discard it instead.
if isfile(MANIFEST_PATH)
    recorded = get(TOML.parsefile(MANIFEST_PATH), "julia_version", nothing)
    recorded_version = recorded === nothing ? nothing : VersionNumber(recorded)
    if recorded_version === nothing ||
       (recorded_version.major, recorded_version.minor) != (VERSION.major, VERSION.minor)
        rm(MANIFEST_PATH)
    end
end

Pkg.activate(@__DIR__; io=devnull)
Pkg.instantiate(; io=devnull)
