# Collects every conversion helper and handler the MATLAB gateway emits, over
# all fixtures, so one golden pins them all. A gateway golden pins only the
# carriers its own fixture happens to use.

"""
    matlab_function_blocks(text) -> Vector{Pair{String, String}}

The `jlw_in_*`, `jlw_out_*` and `jlw_call_*` definitions in a gateway, each
paired with the name it defines.
"""
function matlab_function_blocks(text::AbstractString)
    found = Pair{String, String}[]
    lines = split(text, '\n')
    for (i, line) in pairs(lines)
        startswith(line, "static ") || continue
        name = match(r"(jlw_(?:in|out|call)_\w+)", line)
        isnothing(name) && continue
        stop = findnext(==("}"), lines, i)
        push!(found, name[1] => join(lines[i:stop], '\n'))
    end
    return found
end

"""
    matlab_emitted_blocks(dir) -> String

Every distinct helper and handler the fixtures in `dir` produce, in name
order.
"""
function matlab_emitted_blocks(dir::AbstractString)
    fixtures = sort(filter(endswith(".json"), readdir(dir)))
    found = Pair{String, String}[]
    for fixture in fixtures
        startswith(fixture, "bindinginfo_") || continue
        abi = cd(() -> JuliaLibWrapping.read_abi_info(fixture), dir)
        path = mktempdir()
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = joinpath(path, "libdemo_mex.c")
        append!(found, matlab_function_blocks(read(gateway, String)))
    end
    return join(last.(sort!(unique!(found))), "\n\n") * "\n"
end
