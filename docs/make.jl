#!/usr/bin/env julia
# Build the documentation into docs/build. On CI, deploydocs then pushes it to the
# gh-pages branch; anywhere else it does nothing.

include("activate.jl")

using Documenter
using SshDataBridge

makedocs(; sitename="SshDataBridge.jl",
         modules=[SshDataBridge],
         authors="Paul-Adrian Gogîță",
         format=Documenter.HTML(; canonical="https://PaulGoG.github.io/SshDataBridge.jl",
                                edit_link="main",
                                prettyurls=get(ENV, "CI", "false") == "true"),
         pages=["Home" => "index.md",
                "Configuration" => "configuration.md",
                "Library API" => "api.md",
                "Internals" => "internals.md"],
         checkdocs=:all)

deploydocs(; repo="github.com/PaulGoG/SshDataBridge.jl", devbranch="main")
