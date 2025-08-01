using JSON

struct FieldDesc
    name::String
    type::Int
    offset::Int
end

struct PrimitiveTypeDesc
    # TODO: support custom primitive types?
    name::String
end

struct StructDesc
    name::String
    size::Int
    alignment::Int
    fields::Vector{FieldDesc}
end

struct PointerDesc
    name::String
    pointee_type::Int # type of pointee
end

struct ArgDesc
    name::String
    type::Int
    isva::Bool  # is this a varargs argument?
end

struct MethodDesc
    symbol::String # exported C symbol
    name::String   # full method name w/ args
    return_type::Int
    args::Vector{ArgDesc}
end

const TypeDesc = Union{StructDesc, PointerDesc, PrimitiveTypeDesc}

function from_json(::Type{PrimitiveTypeDesc}, type::Dict{String,Any})
    return PrimitiveTypeDesc(type["name"])
end

function from_json(::Type{StructDesc}, type::Dict{String, Any})
    return StructDesc(
        type["name"],
        type["size"],
        type["alignment"],
        FieldDesc[
            FieldDesc(
                field["name"],
                field["type"],
                field["offset"]
            )
            for field in type["fields"]
        ]
    )
end

function from_json(::Type{PointerDesc}, json::Dict{String, Any})
    return PointerDesc(json["name"], json["pointee"])
end

function from_json(::Type{TypeDesc}, json::Dict{String, Any})
    kind = json["kind"]::String
    if kind === "primitive"
        return from_json(PrimitiveTypeDesc, json)
    elseif kind === "struct"
        return from_json(StructDesc, json)
    elseif kind === "pointer"
        return from_json(PointerDesc, json)
    else # unreachable
        @assert false "unexpected kind '$(json["kind"])' in type metadata"
    end
end

function from_json(::Type{MethodDesc}, method::Dict{String, Any})
    return MethodDesc(
        method["symbol"],
        method["name"],
        method["returns"]["type"],
        ArgDesc[
            ArgDesc(
                arg["name"],
                arg["type"],
                #= isva =# false
            )
            for arg in method["arguments"]
        ],
    )
end

function build_type_graph(typedescs::OrderedDict{Int, TypeDesc};
                          pointer_filter::Function)
    g = SimpleDiGraph(length(typedescs))
    for (id, desc) in pairs(typedescs)
        if desc isa StructDesc
            for field in desc.fields
                add_edge!(g, field.type, id)
            end
        elseif desc isa PointerDesc
            if pointer_filter(id)
                add_edge!(g, desc.pointee_type, id)
            else
                # pointee types don't affect data layout (no edges to add)
            end
        elseif desc isa PrimitiveTypeDesc
            # dependency is tracked from the `struct` side
        end
    end
    return g
end

"""
    entrypoints, typedescs = parselog(filename::String)

Extract the signatures of the entrypoints and nonstandard types from a log file.
"""
function parselog(filename::String)
    abi_info = JSON.Parser.parsefile(filename)

    # Extract all the type descriptors
    typedescs = OrderedDict{Int, TypeDesc}()
    for type in abi_info["types"]
        id = type["id"]::Int
        typedescs[id] = from_json(TypeDesc, type)
    end

    # Then collect the methods
    entrypoints = MethodDesc[]
    for method in abi_info["functions"]
        push!(entrypoints, from_json(MethodDesc, method))
    end

    # First we have to identify the parts of the graph where we have type-recursion and
    # therefore have to use forward-declarations instead of just sorting declarations.
    recursive_types = BitSet()

    full_type_graph = build_type_graph(typedescs; pointer_filter = (id)->true)
    for scc in strongly_connected_components(full_type_graph)
        length(scc) == 1 && continue
        for type_id in scc
            push!(recursive_types, type_id)
        end
    end

    # Now that we know the recursive types, we can restrict them from treating their pointers
    # as a type dependency and re-build a type-graph that is acyclic (these deleted dependencies
    # will later become a forward-declaration)
    type_graph = build_type_graph(typedescs; pointer_filter = (id)->!in(id, recursive_types))

    # We now have an acyclic type-dependency graph, and we have to emit our declarations in a
    # topological order. This guarantees that if a type A has a dependency on type B, type B
    # will appear before type A.
    order_to_emit = zeros(length(typedescs))
    for (pos, desc_id) in enumerate(topological_sort(type_graph))
        # poor man's permute!(typedescs, topological_sort(g))
        order_to_emit[desc_id] = pos
    end
    sort!(typedescs; by=(id)->order_to_emit[id])

    # Finally, we just need to compute the set of required forward declarations.
    forwarddecls = BitSet()
    for id in recursive_types
        desc = typedescs[id]
        desc isa StructDesc || continue
        for field in desc.fields
            dep = field.type
            while typedescs[dep] isa PointerDesc
                # 'dereference' any pointer type
                dep = (typedescs[dep]::PointerDesc).pointee_type
            end
            order_to_emit[id] ≥ order_to_emit[dep] && continue
            # this struct refers (through 1 or more pointers) to a type that will
            # be emitted after it, so that type must be forward-declared.
            push!(forwarddecls, dep)
        end
    end

    return entrypoints, typedescs, forwarddecls
end
parselog(filename::AbstractString) = parselog(String(filename)::String)
