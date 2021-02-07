function mutate(x::T; kws...) where T
    for field in keys(kws)
        if !(field in fieldnames(T))
            error("$(T.name) has no field $field")
        end
    end
    return T([get(kws, fn, getfield(x, fn)) for fn in fieldnames(T)]...)
end

function map_product(f, args...; kws...)
    ks = keys(kws)
    n_pos = length(args)
    map(Iterators.product(args..., values(kws)...)) do x
        pos_args = x[1:n_pos]; kw_args = x[n_pos+1:end]
        f(pos_args...; Dict(zip(ks, kw_args))...)
    end
end

call(f) = f()

function logspace(low, high, n)
    x = range(0, 1, length=n)
    @. exp(log(low) + x * (log(high) - log(low)))
end

function softmax!(x)
    x .= exp.(x .- maximum(x))
    x ./= sum(x)
end
softmax(x) = softmax!(copy(x))

function softmax!(x, i)
    x .= exp.(x .- maximum(x))
    x[i] / sum(x)
end

dictkeys(d::Dict) = (collect(keys(d))...,)
dictvalues(d::Dict) = (collect(values(d))...,)

namedtuple(d::Dict{String,T}) where {T} =
    NamedTuple{Symbol.(dictkeys(d))}(dictvalues(d))
namedtuple(d::Dict{Symbol,T}) where {T} =
    NamedTuple{dictkeys(d)}(dictvalues(d))
namedtuple(x) = namedtuple(Dict(fn => getfield(x, fn) for fn in fieldnames(typeof(x))))

Base.map(f::Function) = xs -> map(f, xs)
Base.map(f::Type) = xs -> map(f, xs)
Base.map(f, d::Dict) = [f(k, v) for (k, v) in d]

Base.filter(f::Function) = xs -> filter(f, xs)

Base.dropdims(idx::Int...) = X -> dropdims(X, dims=idx)
Base.reshape(idx::Union{Int,Colon}...) = x -> reshape(x, idx...)


valmap(f, d::Dict) = Dict(k => f(v) for (k, v) in d)
# valmap(f, d::OrderedDict) = OrderedDict(k => f(v) for (k, v) in d)
# valmap(f, d::T) where T <: AbstractDict = T(k => f(v) for (k, v) in d)

valmap(f) = d->valmap(f, d)
keymap(f, d::Dict) = Dict(f(k) => v for (k, v) in d)
juxt(fs...) = x -> Tuple(f(x) for f in fs)
repeatedly(f, n) = [f() for i in 1:n]

nanreduce(f, x) = f(filter(!isnan, x))
nanmean(x) = nanreduce(mean, x)
nanstd(x) = nanreduce(std, x)

function Base.write(fn)
    obj -> open(fn, "w") do f
        write(f, string(obj))
    end
end

function writev(fn)
    x -> begin
        write(fn, x)
        run(`du -h $fn`)
    end
end

# type2dict(x::T) where T = Dict(fn=>getfield(x, fn) for fn in fieldnames(T))

function mutate(x::T; kws...) where T
    for field in keys(kws)
        if !(field in fieldnames(T))
            error("$(T.name) has no field $field")
        end
    end
    return T([get(kws, fn, getfield(x, fn)) for fn in fieldnames(T)]...)
end

getfields(x) = (getfield(x, f) for f in fieldnames(typeof(x)))
