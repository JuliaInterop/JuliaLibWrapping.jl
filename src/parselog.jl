struct FieldDesc
    name::String
    type::String
    offset::Int
end
function Base.show(io::IO, field::FieldDesc)
    print(io, field.name, "::", field.type, "[", field.offset, "]")
end

struct TypeDesc
    name::String
    fields::Vector{FieldDesc}
    size::Int
end
function Base.show(io::IO, type::TypeDesc)
    print(io, type.name, "(", join(type.fields, ", "), ") (", type.size, " bytes)")
end

struct ArgDesc
    name::String
    type::String
    isva::Bool  # is this a varargs argument?
end
function Base.show(io::IO, arg::ArgDesc)
    print(io, arg.name, "::", arg.type)
    if arg.isva
        print(io, "...")
    end
end

struct MethodDesc
    name::String
    return_type::String
    args::Vector{ArgDesc}
end

function Base.show(io::IO, method::MethodDesc)
    print(io, method.name, "(", join(method.args, ", "), ")::", method.return_type)
end

const rexsize = r"^(\d+) bytes$"
const rexfield = r"^  (.+)::(.+)\[(\d+)\]$"
const rexmethod = r"^(.+)\((.*)\)::(.+)$"
const rexarg = r"^(.+)::(.+)(\.\.\.)?$"

"""
    entrypoints, typedescs = parselog(filename::String)

Extract the signatures of the entrypoints and nonstandard types from a log file.
"""
function parselog(filename::String)
    entrypoints = MethodDesc[]
    typedescs = OrderedDict{String, TypeDesc}()

    open(filename) do f
        handling_types = false
        while !eof(f)
            line = rstrip(readline(f))
            if isempty(line)
                handling_types = true
                continue
            elseif handling_types
                current_type = line
                fields = FieldDesc[]
                line = rstrip(readline(f))  # Read the next line for type details
                m = match(rexsize, line)
                while m === nothing
                    m = match(rexfield, line)
                    field_name = m.captures[1]
                    field_type = m.captures[2]
                    field_offset = parse(Int, m.captures[3])
                    push!(fields, FieldDesc(field_name, field_type, field_offset))
                    line = rstrip(readline(f))
                    m = match(rexsize, line)
                end
                type_size = parse(Int, m.captures[1])
                typedescs[current_type] = TypeDesc(current_type, fields, type_size)
            else   # methods
                m = match(rexmethod, line)
                method_name = m.captures[1]
                args_str = m.captures[2]
                return_type = m.captures[3]

                args = ArgDesc[]
                for arg_str in split(args_str, ",")
                    arg_str = strip(arg_str)
                    if isempty(arg_str)
                        continue
                    end
                    m = match(rexarg, arg_str)
                    arg_name = m.captures[1]
                    arg_type = m.captures[2]
                    isva = length(m.captures) > 2 && m.captures[3] !== nothing  # Check for varargs
                    push!(args, ArgDesc(arg_name, arg_type, isva))
                end

                push!(entrypoints, MethodDesc(method_name, return_type, args))
            end
        end
    end

    # Sort the types by building a dependency graph
    g = SimpleDiGraph(length(typedescs))
    name2idx = Dict(name => i for (i, name) in enumerate(keys(typedescs)))
    for (i, (_, type)) in enumerate(typedescs)
        for field in type.fields
            dep = get(name2idx, field.type, nothing)
            if dep !== nothing
                add_edge!(g, i, dep)
            end
        end
    end
    function lt(a, b)
        # if neither is a declared type, compare by name
        haskey(typedescs, a) || haskey(typedescs, b) || return a < b
        # if one is not declared, it comes first
        !haskey(typedescs, a) && return true
        !haskey(typedescs, b) && return false
        # otherwise, a < b if there is a path from b to a
        ia, ib = name2idx[a], name2idx[b]
        has_path(g, ib, ia) && return true
        has_path(g, ia, ib) && return false
        return a < b  # if no path, compare by name
    end
    sort!(typedescs; lt)

    return entrypoints, typedescs
end
parselog(filename::AbstractString) = parselog(String(filename)::String)
