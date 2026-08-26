struct FieldDesc
    name::String
    type::Int
    offset::Int
end

struct PrimitiveTypeDesc
    name::String
    signed::Bool
    bits::Int
    size::Int
    alignment::Int
end

struct StructDesc
    name::String
    size::Int
    alignment::Int
    fields::Vector{FieldDesc}
end

struct PointerDesc
    name::String
    pointee_type::Union{Int, Nothing} # type of pointee (`void *` stores `nothing`)
end

struct ArrayDesc
    name::String
    element_type::Int
    count::Int
    size::Int
    alignment::Int
end

struct ArgDesc
    name::String
    type::Int
    isva::Bool  # is this a varargs argument?
end

struct MethodDesc
    symbol::String # exported C symbol
    name::String   # full method name w/ args
    return_type::Union{Int, Nothing} # `nothing` = `void` (see `PointerDesc`)
    args::Vector{ArgDesc}
end

const TypeDesc = Union{StructDesc, PointerDesc, PrimitiveTypeDesc, ArrayDesc}

function from_json(::Type{PrimitiveTypeDesc}, type::AbstractDict{String, Any})
    return PrimitiveTypeDesc(
	type["name"],
	type["signed"],
	type["bits"],
	type["size"],
	type["alignment"],
    )
end

function from_json(::Type{StructDesc}, type::AbstractDict{String, Any})
    return StructDesc(
        type["name"],
        type["size"],
        type["alignment"],
        FieldDesc[
            FieldDesc(
                field["name"],
                field["type_id"],
                field["offset"]
            )
            for field in type["fields"]
        ]
    )
end

function from_json(::Type{PointerDesc}, json::AbstractDict{String, Any})
    return PointerDesc(json["name"], json["pointee_type_id"])
end

function from_json(::Type{ArrayDesc}, json::AbstractDict{String, Any})
    return ArrayDesc(
        json["name"],
        json["element_type_id"],
        json["count"],
        json["size"],
        json["alignment"],
    )
end

function from_json(::Type{TypeDesc}, json::AbstractDict{String, Any})
    kind = json["kind"]::String
    if kind === "primitive"
        return from_json(PrimitiveTypeDesc, json)
    elseif kind === "struct"
        return from_json(StructDesc, json)
    elseif kind === "pointer"
        return from_json(PointerDesc, json)
    elseif kind === "array"
        return from_json(ArrayDesc, json)
    else
        error("unexpected kind '$(json["kind"])' in type metadata")
    end
end

function from_json(::Type{MethodDesc}, method::AbstractDict{String, Any})
    return MethodDesc(
        method["symbol"],
        method["name"],
        method["returns"]["type_id"],
        ArgDesc[
            ArgDesc(
                arg["name"],
                arg["type_id"],
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
            if desc.pointee_type !== nothing && pointer_filter(id)
                add_edge!(g, desc.pointee_type, id)
            else
                # Pointee types do not affect pointer layout.
            end
        elseif desc isa ArrayDesc
            add_edge!(g, desc.element_type, id)
        elseif desc isa PrimitiveTypeDesc
            # Struct fields record primitive dependencies.
        end
    end
    return g
end

"""
    sort_declarations!(typedescs) -> forward_declarations

Sort `typedescs` by type dependency (for example, type A containing type B in a
field), so that each descriptor appears after its dependencies. The sort modifies
`typedescs` in place.

Return the type IDs that require C forward declarations because of recursion.
"""
function sort_declarations!(typedescs::OrderedDict{Int, TypeDesc})
    # Identify recursive parts of the graph, which require forward declarations.
    recursive_types = BitSet()

    full_type_graph = build_type_graph(typedescs; pointer_filter = Returns(true))
    for scc in strongly_connected_components(full_type_graph)
        length(scc) == 1 && continue
        for type_id in scc
            push!(recursive_types, type_id)
        end
    end

    # Remove pointer dependencies within recursive types to produce an acyclic graph.
    # The removed dependencies become forward declarations.
    type_graph = build_type_graph(typedescs; pointer_filter = (id)->!in(id, recursive_types))

    # Emit declarations in topological order so dependencies precede their users.
    order_to_emit = zeros(length(typedescs))
    for (pos, desc_id) in enumerate(topological_sort(type_graph))
        # Build the permutation used to sort `typedescs` below.
        order_to_emit[desc_id] = pos
    end
    sort!(typedescs; by=(id)->order_to_emit[id])

    # Compute the required forward declarations.
    forwarddecls = BitSet()
    for id in recursive_types
        desc = typedescs[id]
        desc isa StructDesc || continue
        for field in desc.fields
            dep = field.type
            while dep !== nothing && typedescs[dep] isa PointerDesc
                # Follow pointer chains.
                dep = (typedescs[dep]::PointerDesc).pointee_type
            end
            # A `void *` has no declaration to forward-declare for its pointee.
            dep === nothing && continue
            order_to_emit[id] ≥ order_to_emit[dep] && continue
            # Forward-declare dependencies emitted later.
            push!(forwarddecls, dep)
        end
    end

    return forwarddecls
end

"""
    ABIInfo

# Fields

- `typeinfo`: type descriptors in declaration order.
- `forward_declared`: type IDs requiring C forward declarations.
- `entrypoints`: exported functions.
"""
struct ABIInfo
    typeinfo::OrderedDict{Int, TypeDesc}
    forward_declared::BitSet
    entrypoints::Vector{MethodDesc}
end

function Base.show(io::IO, info::ABIInfo)
    print(io, "ABIInfo(", length(info.typeinfo), " types, ",
              length(info.entrypoints), " entrypoints)")
end

function Base.show(io::IO, ::MIME"text/plain", info::ABIInfo)
    print(io, nameof(ABIInfo))
    print(io, "(...) object, with ")
    print(io, length(info.typeinfo), " types and ")
    print(io, length(info.entrypoints), " entrypoints.\n")
    println(io, "  Types:")
    for desc in values(info.typeinfo)
	println(io, "    ∘ ", desc.name)
    end
    println(io, "  Entrypoints:")
    for desc in info.entrypoints
	print(io, "    ∘ ")
	println(io, desc.name)
    end
end


"""
    abi_info = parse_abi_info(parsed::AbstractDict)

Build an [`ABIInfo`](@ref) from a parsed `juliac` ABI-info JSON document. `parsed`
is the dictionary returned by `JSON.parsefile` (or `JSON.parse`) on such a file.

See [`read_abi_info`](@ref) for the file-based convenience.
"""
function parse_abi_info(parsed::AbstractDict)
    # Extract type descriptors.
    typedescs = OrderedDict{Int, TypeDesc}()
    for type in parsed["types"]
        id = Int(type["id"]::Integer)
        typedescs[id] = from_json(TypeDesc, type)
    end

    # Collect entrypoints.
    entrypoints = MethodDesc[]
    for method in parsed["functions"]
        push!(entrypoints, from_json(MethodDesc, method))
    end

    forward_declared = sort_declarations!(typedescs)

    return ABIInfo(typedescs, forward_declared, entrypoints)
end

"""
    abi_info = read_abi_info(filename::AbstractString)
    abi_info = read_abi_info(io::IO)

Read and parse a `juliac` ABI-info JSON file, returning an [`ABIInfo`](@ref).
The first form is equivalent to `parse_abi_info(JSON.parsefile(filename))`;
the second reads the document from a stream.
"""
read_abi_info(filename::AbstractString) = parse_abi_info(JSON.parsefile(filename))
read_abi_info(io::IO) = parse_abi_info(JSON.parse(read(io, String)))
