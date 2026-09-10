using Pkg
Pkg.activate(@__DIR__; io=devnull)
# Julia 1.11 and later read the package from the [sources] entry of Project.toml; Julia
# 1.10 does not know that section and needs an explicit develop.
VERSION < v"1.11" && Pkg.develop(PackageSpec(; path=dirname(@__DIR__)); io=devnull)
Pkg.instantiate(; io=devnull)
