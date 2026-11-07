# deflate-level round-trip fuzzer: writes raw deflate streams for Python zlib
# usage: julia deflate_fuzz.jl OUTDIR
include(joinpath(@__DIR__, "..", "bmp2png.jl"))

out = ARGS[1]
mkpath(out)
using Random; rnd = Random.MersenneTwister(42)

cases = Dict{String,Vector{UInt8}}()
cases["empty"] = UInt8[]
cases["one"]   = UInt8[0xAB]
cases["two"]   = UInt8[0xAB, 0xCD]
cases["three"] = UInt8[1, 2, 3]
cases["five_rand"] = rand(rnd, UInt8, 5)
cases["tiny_rand"] = rand(rnd, UInt8, 100)
cases["rand_1k"] = rand(rnd, UInt8, 1000)
cases["rand_70k"] = rand(rnd, UInt8, 70000)          # crosses stored chunk boundary
cases["rand_200k"] = rand(rnd, UInt8, 200000)        # multi-block, stored-heavy
cases["zeros_1k"] = zeros(UInt8, 1000)
cases["zeros_70k"] = zeros(UInt8, 70000)
cases["zeros_200k"] = zeros(UInt8, 200000)
cases["text"] = repeat(Vector{UInt8}(codeunits("the quick brown fox jumps over the lazy dog. ")), 500)
cases["ramp"] = UInt8[mod(i, 256) for i in 1:100000]
# PNG-like filtered stream: rows of (filterbyte, small deltas)
rows = UInt8[]
for r in 1:300
    push!(rows, UInt8(r % 5))
    for x in 1:767
        push!(rows, UInt8(mod(x * r, 11)))
    end
end
cases["filterish"] = rows
# a mid-size random buffer (stored blocks chosen, single + multi chunk)
cases["rand_65535"] = rand(rnd, UInt8, 65535)
cases["rand_65536"] = rand(rnd, UInt8, 65536)
cases["rand_65537"] = rand(rnd, UInt8, 65537)

for (name, buf) in cases
    for lv in (1, 4, 9)
        data, _ = deflate(buf, lv)
        open(joinpath(out, "$(name)_L$(lv).def"), "w") do io
            write(io, data)
        end
    end
    open(joinpath(out, "$(name)_raw.bin"), "w") do io
        write(io, buf)
    end
end
println("wrote ", length(cases), " cases x 3 levels")
