
#
# ComputeNodes represent a computation
#
# `compute` methods for MapPartNode and Partitioned need to be
# implemented by a data node provider (see data-nodes/dist-memory.jl for an example)
#

import Base: map, reduce, filter, IdFun

export Broadcast, Partitioned, reducebykey, mappart, foreach

### Distributing data ###

immutable Partitioned{T, P<:AbstractPartition} <: ComputeNode
    obj::T
    partition::P
end
Partitioned(x::AbstractArray) = Partitioned(x, CutDim{ndims(x)}())
Broadcast(x) = Partitioned(x, Bcast())

### MapParts ###

immutable MapPartNode{T<:Tuple, F} <: ComputeNode
    f::F
    input::T
end

"""
    mappart(f, nodes::AbstractNode...)

Apply `f` on corresponding chunks of `nodes`. Other compute nodes
fall back to mappart to `compute`.
"""
mappart(f, ns::Tuple) = MapPartNode(f, ns)
mappart(f, ns::AbstractNode...) = MapPartNode(f, ns)

tuplize(t::Tuple) = t
tuplize(t) = (t,)

function compute(ctx, x::MapPartNode)
   compute(ctx, MapPartNode(x.f, map(inp -> compute(ctx, inp), x.input)))
end

### ForEach node ###

immutable ForeachNode{T<:Tuple, F} <: ComputeNode
    f::F
    input::T
end

foreach(f, xs::AbstractNode...) = ForeachNode(f, xs)

function foreach_seq(f, args...)
    for i=1:length(args[1])
        f([a[i] for a in args]...)
    end
end

function compute(ctx, node::ForeachNode)
    compute(ctx, mappart(part -> foreach_seq(node.f, part), node.input))
end

### Map ###

immutable MapNode{T<:Tuple, F} <: ComputeNode
    f::F
    input::T
end

map(f, ns::AbstractNode...) = MapNode(f, ns)

function compute(ctx, node::MapNode)
    compute(ctx, mappart((localparts...) -> map(node.f, localparts...), node.input))
end

### Fused Map-reduce ###

immutable MapReduceNode{T<:Tuple, F, O, X} <: ComputeNode
    f::F
    op::O
    v0::X
    input::T
end

mapreduce(f, op, v0, input...) = MapReduceNode(f, op, v0, input)
reduce(op, v0, node::AbstractNode) = MapReduceNode(IdFun(), op, v0, node)

# Mapreduce on multiple arguments
function mapreduce(f, op, v0, X...)
    n = length(X[1])
    acc = v0
    for i=1:n
        acc = op(acc, f([x[i] for x in X]...))
    end
end

function compute(ctx, node::MapReduceNode)
    mapped = gather(ctx, mappart((parts...) -> mapreduce(node.f, node.op, node.v0, parts...), node.input))
    reduce(node.f, node.v0, mapped)
end

### Filter ###

immutable FilterNode{N<:AbstractNode, F} <: ComputeNode
    f::F
    input::N
end

filter(f, x::AbstractNode) = FilterNode(f, x)

function compute(ctx, node::FilterNode)
    compute(ctx, mappart(part -> filter(node.f, part), node))
end

### GroupBy ###

immutable MapReduceByKey{N<:Tuple, F, O, T} <: ComputeNode
    f::F
    op::O
    v0::T
    input::N
end

reducebykey(op, v0, input) = MapReduceByKey(IdFun(), op, v0, input)
mapreducebykey(f, op, v0, input) = MapReduceByKey(f, v0, input)

function mapreducebykey_seq(f, op,  v0, itr, dict=Dict())
    for x in itr
        k, v = f(x)
        dict[k] = op(get(dict, k, v0), v)
    end
    dict
end

reducebykey_seq(op, v0, itr,dict=Dict()) = mapreducebykey_seq(IdFun(), op, v0, itr, dict)

function compute(ctx, node::MapReduceByKey)
    parts = mappart((part) -> mapreducebykey_seq(node.f, node.op, node.v0, part), node.input)
    reduce((acc, chunk) -> reducebykey_seq(node.op, node.v0, chunk, acc), Dict(), gather(ctx, parts))
end
