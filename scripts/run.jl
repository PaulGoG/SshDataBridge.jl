#!/usr/bin/env julia
# Thin entry point: activates the package environment and runs SshDataBridge.main.

using Pkg
Pkg.activate(dirname(@__DIR__); io=devnull)
Pkg.instantiate(; io=devnull)

using SshDataBridge

exit(SshDataBridge.main(ARGS))
