symconvert(::Type{Symbolics.Struct{T}}, x) where {T} = convert(T, x)
symconvert(::Type{T}, x) where {T} = convert(T, x)
symconvert(::Type{Real}, x::Integer) = convert(Float64, x)
symconvert(::Type{V}, x) where {V <: AbstractArray} = convert(V, symconvert.(eltype(V), x))

struct MTKParameters{T, D, C, E, N, F, G}
    tunable::T
    discrete::D
    constant::C
    dependent::E
    nonnumeric::N
    dependent_update_iip::F
    dependent_update_oop::G
end

function MTKParameters(
        sys::AbstractSystem, p, u0 = Dict(); tofloat = false, use_union = false)
    ic = if has_index_cache(sys) && get_index_cache(sys) !== nothing
        get_index_cache(sys)
    else
        error("Cannot create MTKParameters if system does not have index_cache")
    end
    all_ps = Set(unwrap.(full_parameters(sys)))
    union!(all_ps, default_toterm.(unwrap.(full_parameters(sys))))
    if p isa Vector && !(eltype(p) <: Pair) && !isempty(p)
        ps = full_parameters(sys)
        length(p) == length(ps) || error("Invalid parameters")
        p = ps .=> p
    end
    if p isa SciMLBase.NullParameters || isempty(p)
        p = Dict()
    end
    p = todict(p)
    defs = Dict(default_toterm(unwrap(k)) => v
    for (k, v) in defaults(sys)
    if unwrap(k) in all_ps || default_toterm(unwrap(k)) in all_ps)
    if eltype(u0) <: Pair
        u0 = todict(u0)
    elseif u0 isa AbstractArray && !isempty(u0)
        u0 = Dict(unknowns(sys) .=> vec(u0))
    elseif u0 === nothing || isempty(u0)
        u0 = Dict()
    end
    defs = merge(defs, u0)
    defs = merge(Dict(eq.lhs => eq.rhs for eq in observed(sys)), defs)
    bigdefs = merge(defs, p)
    p = merge(Dict(unwrap(k) => v for (k, v) in p),
        Dict(default_toterm(unwrap(k)) => v for (k, v) in p))
    p = Dict(unwrap(k) => fixpoint_sub(v, bigdefs) for (k, v) in p)
    for (sym, _) in p
        if iscall(sym) && operation(sym) === getindex &&
           first(arguments(sym)) in all_ps
            error("Scalarized parameter values ($sym) are not supported. Instead of `[p[1] => 1.0, p[2] => 2.0]` use `[p => [1.0, 2.0]]`")
        end
    end

    missing_params = Set()
    for idxmap in (ic.tunable_idx, ic.discrete_idx, ic.constant_idx, ic.nonnumeric_idx)
        for sym in keys(idxmap)
            sym isa Symbol && continue
            haskey(p, sym) && continue
            hasname(sym) && haskey(p, getname(sym)) && continue
            ttsym = default_toterm(sym)
            haskey(p, ttsym) && continue
            hasname(ttsym) && haskey(p, getname(ttsym)) && continue

            iscall(sym) && operation(sym) === getindex && haskey(p, arguments(sym)[1]) &&
                continue
            push!(missing_params, sym)
        end
    end

    isempty(missing_params) || throw(MissingParametersError(collect(missing_params)))

    tunable_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.tunable_buffer_sizes)
    disc_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.discrete_buffer_sizes)
    const_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.constant_buffer_sizes)
    dep_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.dependent_buffer_sizes)
    nonnumeric_buffer = Tuple(Vector{temp.type}(undef, temp.length)
    for temp in ic.nonnumeric_buffer_sizes)
    function set_value(sym, val)
        done = true
        if haskey(ic.tunable_idx, sym)
            i, j = ic.tunable_idx[sym]
            tunable_buffer[i][j] = val
        elseif haskey(ic.discrete_idx, sym)
            i, j = ic.discrete_idx[sym]
            disc_buffer[i][j] = val
        elseif haskey(ic.constant_idx, sym)
            i, j = ic.constant_idx[sym]
            const_buffer[i][j] = val
        elseif haskey(ic.dependent_idx, sym)
            i, j = ic.dependent_idx[sym]
            dep_buffer[i][j] = val
        elseif haskey(ic.nonnumeric_idx, sym)
            i, j = ic.nonnumeric_idx[sym]
            nonnumeric_buffer[i][j] = val
        elseif !isequal(default_toterm(sym), sym)
            done = set_value(default_toterm(sym), val)
        else
            done = false
        end
        return done
    end

    for (sym, val) in p
        sym = unwrap(sym)
        val = unwrap(val)
        ctype = symtype(sym)
        if symbolic_type(val) !== NotSymbolic()
            continue
        end
        val = symconvert(ctype, val)
        done = set_value(sym, val)
        if !done && Symbolics.isarraysymbolic(sym)
            if Symbolics.shape(sym) === Symbolics.Unknown()
                for i in eachindex(val)
                    set_value(sym[i], val[i])
                end
            else
                if size(sym) != size(val)
                    error("Got value of size $(size(val)) for parameter $sym of size $(size(sym))")
                end
                set_value.(collect(sym), val)
            end
        end
    end
    tunable_buffer = narrow_buffer_type.(tunable_buffer)
    disc_buffer = narrow_buffer_type.(disc_buffer)
    const_buffer = narrow_buffer_type.(const_buffer)
    # Don't narrow nonnumeric types
    nonnumeric_buffer = nonnumeric_buffer

    if has_parameter_dependencies(sys) &&
       (pdeps = parameter_dependencies(sys)) !== nothing
        pdeps = Dict(k => fixpoint_sub(v, pdeps) for (k, v) in pdeps)
        dep_exprs = ArrayPartition((Any[missing for _ in 1:length(v)] for v in dep_buffer)...)
        for (sym, val) in pdeps
            i, j = ic.dependent_idx[sym]
            dep_exprs.x[i][j] = unwrap(val)
        end
        dep_exprs = identity.(dep_exprs)
        p = reorder_parameters(ic, full_parameters(sys))
        oop, iip = build_function(dep_exprs, p...)
        update_function_iip, update_function_oop = RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(iip),
        RuntimeGeneratedFunctions.@RuntimeGeneratedFunction(oop)
        update_function_iip(ArrayPartition(dep_buffer), tunable_buffer..., disc_buffer...,
            const_buffer..., nonnumeric_buffer..., dep_buffer...)
        dep_buffer = narrow_buffer_type.(dep_buffer)
    else
        update_function_iip = update_function_oop = nothing
    end

    mtkps = MTKParameters{
        typeof(tunable_buffer), typeof(disc_buffer), typeof(const_buffer),
        typeof(dep_buffer), typeof(nonnumeric_buffer), typeof(update_function_iip),
        typeof(update_function_oop)}(tunable_buffer, disc_buffer, const_buffer, dep_buffer,
        nonnumeric_buffer, update_function_iip, update_function_oop)
    return mtkps
end

function narrow_buffer_type(buffer::AbstractArray)
    type = Union{}
    for x in buffer
        type = promote_type(type, typeof(x))
    end
    return convert.(type, buffer)
end

function narrow_buffer_type(buffer::AbstractArray{<:AbstractArray})
    buffer = narrow_buffer_type.(buffer)
    type = Union{}
    for x in buffer
        type = promote_type(type, eltype(x))
    end
    return broadcast.(convert, type, buffer)
end

function buffer_to_arraypartition(buf)
    return ArrayPartition(ntuple(i -> _buffer_to_arrp_helper(buf[i]), Val(length(buf))))
end

_buffer_to_arrp_helper(v::T) where {T} = _buffer_to_arrp_helper(eltype(T), v)
_buffer_to_arrp_helper(::Type{<:AbstractArray}, v) = buffer_to_arraypartition(v)
_buffer_to_arrp_helper(::Any, v) = v

function _split_helper(buf_v::T, recurse, raw, idx) where {T}
    _split_helper(eltype(T), buf_v, recurse, raw, idx)
end

function _split_helper(::Type{<:AbstractArray}, buf_v, ::Val{true}, raw, idx)
    map(b -> _split_helper(eltype(b), b, Val(false), raw, idx), buf_v)
end

function _split_helper(::Type{<:AbstractArray}, buf_v, ::Val{false}, raw, idx)
    _split_helper((), buf_v, (), raw, idx)
end

function _split_helper(_, buf_v, _, raw, idx)
    res = reshape(raw[idx[]:(idx[] + length(buf_v) - 1)], size(buf_v))
    idx[] += length(buf_v)
    return res
end

function split_into_buffers(raw::AbstractArray, buf, recurse = Val(true))
    idx = Ref(1)
    ntuple(i -> _split_helper(buf[i], recurse, raw, idx), Val(length(buf)))
end

function _update_tuple_helper(buf_v::T, raw, idx) where {T}
    _update_tuple_helper(eltype(T), buf_v, raw, idx)
end

function _update_tuple_helper(::Type{<:AbstractArray}, buf_v, raw, idx)
    ntuple(i -> _update_tuple_helper(buf_v[i], raw, idx), length(buf_v))
end

function _update_tuple_helper(::Any, buf_v, raw, idx)
    copyto!(buf_v, view(raw, idx[]:(idx[] + length(buf_v) - 1)))
    idx[] += length(buf_v)
    return nothing
end

function update_tuple_of_buffers(raw::AbstractArray, buf)
    idx = Ref(1)
    ntuple(i -> _update_tuple_helper(buf[i], raw, idx), Val(length(buf)))
end

SciMLStructures.isscimlstructure(::MTKParameters) = true

SciMLStructures.ismutablescimlstructure(::MTKParameters) = true

for (Portion, field) in [(SciMLStructures.Tunable, :tunable)
                         (SciMLStructures.Discrete, :discrete)
                         (SciMLStructures.Constants, :constant)
                         (Nonnumeric, :nonnumeric)]
    @eval function SciMLStructures.canonicalize(::$Portion, p::MTKParameters)
        as_vector = buffer_to_arraypartition(p.$field)
        repack = let as_vector = as_vector, p = p
            function (new_val)
                if new_val !== as_vector
                    update_tuple_of_buffers(new_val, p.$field)
                end
                if p.dependent_update_iip !== nothing
                    p.dependent_update_iip(ArrayPartition(p.dependent), p...)
                end
                p
            end
        end
        return as_vector, repack, true
    end

    @eval function SciMLStructures.replace(::$Portion, p::MTKParameters, newvals)
        @set! p.$field = split_into_buffers(newvals, p.$field)
        if p.dependent_update_oop !== nothing
            raw = p.dependent_update_oop(p...)
            @set! p.dependent = split_into_buffers(raw, p.dependent, Val(false))
        end
        p
    end

    @eval function SciMLStructures.replace!(::$Portion, p::MTKParameters, newvals)
        update_tuple_of_buffers(newvals, p.$field)
        if p.dependent_update_iip !== nothing
            p.dependent_update_iip(ArrayPartition(p.dependent), p...)
        end
        nothing
    end
end

function Base.copy(p::MTKParameters)
    tunable = Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf) for buf in p.tunable)
    discrete = Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf) for buf in p.discrete)
    constant = Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf) for buf in p.constant)
    dependent = Tuple(eltype(buf) <: Real ? copy(buf) : copy.(buf) for buf in p.dependent)
    nonnumeric = copy.(p.nonnumeric)
    return MTKParameters(
        tunable,
        discrete,
        constant,
        dependent,
        nonnumeric,
        p.dependent_update_iip,
        p.dependent_update_oop
    )
end

function SymbolicIndexingInterface.parameter_values(p::MTKParameters, pind::ParameterIndex)
    @unpack portion, idx = pind
    i, j, k... = idx
    if portion isa SciMLStructures.Tunable
        return isempty(k) ? p.tunable[i][j] : p.tunable[i][j][k...]
    elseif portion isa SciMLStructures.Discrete
        return isempty(k) ? p.discrete[i][j] : p.discrete[i][j][k...]
    elseif portion isa SciMLStructures.Constants
        return isempty(k) ? p.constant[i][j] : p.constant[i][j][k...]
    elseif portion === DEPENDENT_PORTION
        return isempty(k) ? p.dependent[i][j] : p.dependent[i][j][k...]
    elseif portion === NONNUMERIC_PORTION
        return isempty(k) ? p.nonnumeric[i][j] : p.nonnumeric[i][j][k...]
    else
        error("Unhandled portion $portion")
    end
end

function SymbolicIndexingInterface.set_parameter!(
        p::MTKParameters, val, idx::ParameterIndex)
    @unpack portion, idx, validate_size = idx
    i, j, k... = idx
    if portion isa SciMLStructures.Tunable
        if isempty(k)
            if validate_size && size(val) !== size(p.tunable[i][j])
                throw(InvalidParameterSizeException(size(p.tunable[i][j]), size(val)))
            end
            p.tunable[i][j] = val
        else
            p.tunable[i][j][k...] = val
        end
    elseif portion isa SciMLStructures.Discrete
        if isempty(k)
            if validate_size && size(val) !== size(p.discrete[i][j])
                throw(InvalidParameterSizeException(size(p.discrete[i][j]), size(val)))
            end
            p.discrete[i][j] = val
        else
            p.discrete[i][j][k...] = val
        end
    elseif portion isa SciMLStructures.Constants
        if isempty(k)
            if validate_size && size(val) !== size(p.constant[i][j])
                throw(InvalidParameterSizeException(size(p.constant[i][j]), size(val)))
            end
            p.constant[i][j] = val
        else
            p.constant[i][j][k...] = val
        end
    elseif portion === DEPENDENT_PORTION
        error("Cannot set value of dependent parameter")
    elseif portion === NONNUMERIC_PORTION
        if isempty(k)
            p.nonnumeric[i][j] = val
        else
            p.nonnumeric[i][j][k...] = val
        end
    else
        error("Unhandled portion $portion")
    end
    if p.dependent_update_iip !== nothing
        p.dependent_update_iip(ArrayPartition(p.dependent), p...)
    end
end

function _set_parameter_unchecked!(
        p::MTKParameters, val, idx::ParameterIndex; update_dependent = true)
    @unpack portion, idx = idx
    i, j, k... = idx
    if portion isa SciMLStructures.Tunable
        if isempty(k)
            p.tunable[i][j] = val
        else
            p.tunable[i][j][k...] = val
        end
    elseif portion isa SciMLStructures.Discrete
        if isempty(k)
            p.discrete[i][j] = val
        else
            p.discrete[i][j][k...] = val
        end
    elseif portion isa SciMLStructures.Constants
        if isempty(k)
            p.constant[i][j] = val
        else
            p.constant[i][j][k...] = val
        end
    elseif portion === DEPENDENT_PORTION
        if isempty(k)
            p.dependent[i][j] = val
        else
            p.dependent[i][j][k...] = val
        end
        update_dependent = false
    elseif portion === NONNUMERIC_PORTION
        if isempty(k)
            p.nonnumeric[i][j] = val
        else
            p.nonnumeric[i][j][k...] = val
        end
    else
        error("Unhandled portion $portion")
    end
    update_dependent && p.dependent_update_iip !== nothing &&
        p.dependent_update_iip(ArrayPartition(p.dependent), p...)
end

function narrow_buffer_type_and_fallback_undefs(oldbuf::Vector, newbuf::Vector)
    type = Union{}
    for i in eachindex(newbuf)
        isassigned(newbuf, i) || continue
        type = promote_type(type, typeof(newbuf[i]))
    end
    if type == Union{}
        type = eltype(oldbuf)
    end
    for i in eachindex(newbuf)
        isassigned(newbuf, i) && continue
        newbuf[i] = convert(type, oldbuf[i])
    end
    return convert(Vector{type}, newbuf)
end

function validate_parameter_type(ic::IndexCache, p, index, val)
    p = unwrap(p)
    if p isa Symbol
        p = get(ic.symbol_to_variable, p, nothing)
        if p === nothing
            @warn "No matching variable found for `Symbol` $p, skipping type validation."
            return nothing
        end
    end
    (; portion) = index
    # Nonnumeric parameters have to match the type
    if portion === NONNUMERIC_PORTION
        stype = symtype(p)
        val isa stype && return nothing
        throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
    stype = symtype(p)
    # Array parameters need array values...
    if stype <: AbstractArray && !isa(val, AbstractArray)
        throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
    # ... and must match sizes
    if stype <: AbstractArray && Symbolics.shape(p) !== Symbolics.Unknown() &&
       size(val) != size(p)
        throw(InvalidParameterSizeException(p, val))
    end
    # Early exit
    val isa stype && return nothing
    if stype <: AbstractArray
        # Arrays need handling when eltype is `Real` (accept any real array)
        etype = eltype(stype)
        if etype <: Real
            etype = Real
        end
        # This is for duals and other complicated number types
        etype = SciMLBase.parameterless_type(etype)
        eltype(val) <: etype || throw(ParameterTypeException(
            :validate_parameter_type, p, AbstractArray{etype}, val))
    else
        # Real check
        if stype <: Real
            stype = Real
        end
        stype = SciMLBase.parameterless_type(stype)
        val isa stype ||
            throw(ParameterTypeException(:validate_parameter_type, p, stype, val))
    end
end

function indp_to_system(indp)
    while hasmethod(symbolic_container, Tuple{typeof(indp)})
        indp = symbolic_container(indp)
    end
    return indp
end

function SymbolicIndexingInterface.remake_buffer(indp, oldbuf::MTKParameters, vals::Dict)
    newbuf = @set oldbuf.tunable = Tuple(Vector{Any}(undef, length(buf))
    for buf in oldbuf.tunable)
    @set! newbuf.discrete = Tuple(Vector{Any}(undef, length(buf))
    for buf in newbuf.discrete)
    @set! newbuf.constant = Tuple(Vector{Any}(undef, length(buf))
    for buf in newbuf.constant)
    @set! newbuf.nonnumeric = Tuple(Vector{Any}(undef, length(buf))
    for buf in newbuf.nonnumeric)

    # If the parameter buffer is an `MTKParameters` object, `indp` must eventually drill
    # down to an `AbstractSystem` using `symbolic_container`. We leverage this to get
    # the index cache.
    ic = get_index_cache(indp_to_system(indp))
    for (p, val) in vals
        idx = parameter_index(indp, p)
        validate_parameter_type(ic, p, idx, val)
        _set_parameter_unchecked!(
            newbuf, val, idx; update_dependent = false)
    end

    @set! newbuf.tunable = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.tunable, newbuf.tunable)
    @set! newbuf.discrete = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.discrete, newbuf.discrete)
    @set! newbuf.constant = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.constant, newbuf.constant)
    @set! newbuf.nonnumeric = narrow_buffer_type_and_fallback_undefs.(
        oldbuf.nonnumeric, newbuf.nonnumeric)
    if newbuf.dependent_update_oop !== nothing
        @set! newbuf.dependent = narrow_buffer_type_and_fallback_undefs.(
            oldbuf.dependent,
            split_into_buffers(
                newbuf.dependent_update_oop(newbuf...), oldbuf.dependent, Val(false)))
    end
    return newbuf
end

function DiffEqBase.anyeltypedual(
        p::MTKParameters, ::Type{Val{counter}} = Val{0}) where {counter}
    DiffEqBase.anyeltypedual(p.tunable)
end
function DiffEqBase.anyeltypedual(p::Type{<:MTKParameters{T}},
        ::Type{Val{counter}} = Val{0}) where {counter} where {T}
    DiffEqBase.__anyeltypedual(T)
end

_subarrays(v::AbstractVector) = isempty(v) ? () : (v,)
_subarrays(v::ArrayPartition) = v.x
_subarrays(v::Tuple) = v
_num_subarrays(v::AbstractVector) = 1
_num_subarrays(v::ArrayPartition) = length(v.x)
_num_subarrays(v::Tuple) = length(v)
# for compiling callbacks
# getindex indexes the vectors, setindex! linearly indexes values
# it's inconsistent, but we need it to be this way
function Base.getindex(buf::MTKParameters, i)
    i_orig = i
    if !isempty(buf.tunable)
        i <= _num_subarrays(buf.tunable) && return _subarrays(buf.tunable)[i]
        i -= _num_subarrays(buf.tunable)
    end
    if !isempty(buf.discrete)
        i <= _num_subarrays(buf.discrete) && return _subarrays(buf.discrete)[i]
        i -= _num_subarrays(buf.discrete)
    end
    if !isempty(buf.constant)
        i <= _num_subarrays(buf.constant) && return _subarrays(buf.constant)[i]
        i -= _num_subarrays(buf.constant)
    end
    if !isempty(buf.nonnumeric)
        i <= _num_subarrays(buf.nonnumeric) && return _subarrays(buf.nonnumeric)[i]
        i -= _num_subarrays(buf.nonnumeric)
    end
    if !isempty(buf.dependent)
        i <= _num_subarrays(buf.dependent) && return _subarrays(buf.dependent)[i]
        i -= _num_subarrays(buf.dependent)
    end
    throw(BoundsError(buf, i_orig))
end
function Base.setindex!(p::MTKParameters, val, i)
    function _helper(buf)
        done = false
        for v in buf
            if i <= length(v)
                v[i] = val
                done = true
            else
                i -= length(v)
            end
        end
        done
    end
    _helper(p.tunable) || _helper(p.discrete) || _helper(p.constant) ||
        _helper(p.nonnumeric) || throw(BoundsError(p, i))
    if p.dependent_update_iip !== nothing
        p.dependent_update_iip(ArrayPartition(p.dependent), p...)
    end
end

function Base.getindex(p::MTKParameters, pind::ParameterIndex)
    (; portion, idx) = pind
    i, j, k... = idx
    if isempty(k)
        indexer = (v) -> v[i][j]
    else
        indexer = (v) -> v[i][j][k...]
    end
    if portion isa SciMLStructures.Tunable
        indexer(p.tunable)
    elseif portion isa SciMLStructures.Discrete
        indexer(p.discrete)
    elseif portion isa SciMLStructures.Constants
        indexer(p.constant)
    elseif portion === DEPENDENT_PORTION
        indexer(p.dependent)
    elseif portion === NONNUMERIC_PORTION
        indexer(p.nonnumeric)
    else
        error("Unhandled portion ", portion)
    end
end

function Base.setindex!(p::MTKParameters, val, pind::ParameterIndex)
    SymbolicIndexingInterface.set_parameter!(p, val, pind)
end

function Base.iterate(buf::MTKParameters, state = 1)
    total_len = 0
    total_len += _num_subarrays(buf.tunable)
    total_len += _num_subarrays(buf.discrete)
    total_len += _num_subarrays(buf.constant)
    total_len += _num_subarrays(buf.nonnumeric)
    total_len += _num_subarrays(buf.dependent)
    if state <= total_len
        return (buf[state], state + 1)
    else
        return nothing
    end
end

function Base.:(==)(a::MTKParameters, b::MTKParameters)
    return a.tunable == b.tunable && a.discrete == b.discrete &&
           a.constant == b.constant && a.dependent == b.dependent &&
           a.nonnumeric == b.nonnumeric
end

# to support linearize/linearization_function
function jacobian_wrt_vars(pf::F, p::MTKParameters, input_idxs, chunk::C) where {F, C}
    tunable, _, _ = SciMLStructures.canonicalize(SciMLStructures.Tunable(), p)
    T = eltype(tunable)
    tag = ForwardDiff.Tag(pf, T)
    dualtype = ForwardDiff.Dual{typeof(tag), T, ForwardDiff.chunksize(chunk)}
    p_big = SciMLStructures.replace(SciMLStructures.Tunable(), p, dualtype.(tunable))
    p_closure = let pf = pf,
        input_idxs = input_idxs,
        p_big = p_big

        function (p_small_inner)
            for (i, val) in zip(input_idxs, p_small_inner)
                _set_parameter_unchecked!(p_big, val, i)
            end
            return if pf isa SciMLBase.ParamJacobianWrapper
                buffer = Array{dualtype}(undef, size(pf.u))
                pf(buffer, p_big)
                buffer
            else
                pf(p_big)
            end
        end
    end
    p_small = parameter_values.((p,), input_idxs)
    cfg = ForwardDiff.JacobianConfig(p_closure, p_small, chunk, tag)
    ForwardDiff.jacobian(p_closure, p_small, cfg, Val(false))
end

function as_duals(p::MTKParameters, dualtype)
    tunable = dualtype.(p.tunable)
    discrete = dualtype.(p.discrete)
    return MTKParameters{typeof(tunable), typeof(discrete)}(tunable, discrete)
end

const MISSING_PARAMETERS_MESSAGE = """
                                Some parameters are missing from the variable map.
                                Please provide a value or default for the following variables:
                                """

struct MissingParametersError <: Exception
    vars::Any
end

function Base.showerror(io::IO, e::MissingParametersError)
    println(io, MISSING_PARAMETERS_MESSAGE)
    println(io, e.vars)
end

function InvalidParameterSizeException(param, val)
    DimensionMismatch("InvalidParameterSizeException: For parameter $(param) expected value of size $(size(param)). Received value $(val) of size $(size(val)).")
end

function InvalidParameterSizeException(param::Tuple, val::Tuple)
    DimensionMismatch("InvalidParameterSizeException: Expected value of size $(param). Received value of size $(val).")
end

function ParameterTypeException(func, param, expected, val)
    TypeError(func, "Parameter $param", expected, val)
end
