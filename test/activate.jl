using Pkg
Pkg.activate(@__DIR__; io=devnull)
Pkg.develop(PackageSpec(; path=dirname(@__DIR__)); io=devnull)
Pkg.instantiate(; io=devnull)
