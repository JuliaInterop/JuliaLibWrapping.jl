module abi_stress

# Fixture package whose `juliac` ABI matches test/bindinginfo_libsimple.json.
# Deliberately contrived to exercise ABI corners — recursive types through
# pointer indirection, parametric structs, by-value struct arguments, pointer
# arguments — so the wrapper emitters have something to chew on. This is a
# stress fixture, not a tutorial example.

struct CArray{T,N}
    dims::NTuple{N,Int32}
    data::Ptr{T}
end
const CVector{T} = CArray{T,1}

struct CVectorPair{T}
    from::CVector{T}
    to::CVector{T}
end

struct CTree{T}
    children::CVector{CTree{T}}
end

struct MyTwoVec
    x::Int32
    y::Int32
end

Base.@ccallable function tree_size(tree::CTree{Float64})::Int
    n = 1
    for i in 1:tree.children.dims[1]
        n += tree_size(unsafe_load(tree.children.data, i))
    end
    return n
end

Base.@ccallable function copyto_and_sum(fromto::CVectorPair{Float32})::Float32
    s = 0f0
    n = min(fromto.from.dims[1], fromto.to.dims[1])
    for i in 1:n
        v = unsafe_load(fromto.from.data, i)
        unsafe_store!(fromto.to.data, v, i)
        s += v
    end
    return s
end

Base.@ccallable function countsame(list::Ptr{MyTwoVec}, n::Int32)::Int32
    c = Int32(0)
    for i in 1:n
        v = unsafe_load(list, i)
        c += (v.x == v.y) ? Int32(1) : Int32(0)
    end
    return c
end

# Exercises the N=3 case: the JuliaLibWrapping wrapper emitters generate the
# rank-agnostic CArray helpers, and juliac's "array" ABI kind carries the
# `NTuple{3,Int32}` shape.
Base.@ccallable function sum3d(a::CArray{Float64,3})::Float64
    s = 0.0
    n = Int(a.dims[1]) * Int(a.dims[2]) * Int(a.dims[3])
    for i in 1:n
        s += unsafe_load(a.data, i)
    end
    return s
end

end
