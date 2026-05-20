module abi_stress

# Fixture package whose `juliac` ABI matches test/bindinginfo_libsimple.json.
# Deliberately contrived to exercise ABI corners — recursive types through
# pointer indirection, parametric structs, by-value struct arguments, pointer
# arguments — so the wrapper emitters have something to chew on. This is a
# stress fixture, not a tutorial example.

struct CVector{T}
    length::Int32
    data::Ptr{T}
end

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
    for i in 1:tree.children.length
        n += tree_size(unsafe_load(tree.children.data, i))
    end
    return n
end

Base.@ccallable function copyto_and_sum(fromto::CVectorPair{Float32})::Float32
    s = 0f0
    n = min(fromto.from.length, fromto.to.length)
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

end
