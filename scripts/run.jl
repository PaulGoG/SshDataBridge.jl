#!/usr/bin/env julia
# Thin entry point: activates the package environment and runs SshDataBridge.main.

include(joinpath(@__DIR__, "..", "activate.jl"))

using SshDataBridge

exit(SshDataBridge.main(ARGS))
