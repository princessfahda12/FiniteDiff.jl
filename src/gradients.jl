struct GradientCache{CacheType1, CacheType2, CacheType3, fdtype, returntype, inplace}
    fx :: CacheType1
    c1 :: CacheType2
    c2 :: CacheType3
end

function GradientCache(
    df         :: AbstractArray{<:Number},
    x          :: Union{<:Number, AbstractArray{<:Number}},
    fx         :: Union{Void,<:Number,AbstractArray{<:Number}} = nothing,
    c1         :: Union{Void,AbstractArray{<:Number}} = nothing,
    c2         :: Union{Void,AbstractArray{<:Number}} = nothing,
    fdtype     :: Type{T1} = Val{:central},
    returntype :: Type{T2} = eltype(x),
    inplace    :: Type{Val{T3}} = Val{true}) where {T1,T2,T3}

    if fdtype!=Val{:forward} && typeof(fx)!=Void
        warn("Pre-computed function values are only useful for fdtype == Val{:forward}.")
        _fx = nothing
    else
        # more runtime sanity checks?
        _fx = fx
    end

    if typeof(x)<:AbstractArray # the vector->scalar case
        # need cache arrays for epsilon (c1) and x1 (c2)
        if fdtype!=Val{:complex} # complex-mode FD only needs one cache, for x+eps*im
            if typeof(c1)==Void || eltype(c1)!=real(eltype(x))
                _c1 = zeros(real(eltype(x)), size(x))
            else
                _c1 = c1
            end
            if typeof(c2)!=typeof(x) || size(c2)!=size(x)
                _c2 = similar(x)
            else
                _c2 = c2
            end
        else
            if !(returntype<:Real)
                fdtype_error(returntype)
            else
                _c1 = x + 0*im
                _c2 = nothing
            end
        end

    else # the scalar->vector case
        # need cache arrays for fx1 and fx2, except in complex mode, which needs one complex array
        if fdtype != Val{:complex}
            if typeof(c1)==Void || size(c1) != size(df)
                _c1 = similar(df)
            else
                _c1 = c1
            end
            if fdtype == Val{:forward} && typeof(fx) != Void
                _c2 = nothing
            else
                if typeof(c2) != typeof(df) || size(c2) != size(df)
                    _c2 = similar(df)
                else
                    _c2 = c2
                end
            end
        else
            if typeof(c1)==Void || size(c1)!=size(df)
                _c1 = zeros(Complex{eltype(x)}, size(df))
            else
                _c1 = c1
            end
            _c2 = nothing
        end
    end
    GradientCache{typeof(_fx),typeof(_c1),typeof(_c2),fdtype,returntype,inplace}(_fx,_c1,_c2)
end

function finite_difference_gradient(f, x, fdtype::Type{T1}=Val{:central},
    returntype::Type{T2}=eltype(x), inplace::Type{Val{T3}}=Val{true},
    fx::Union{Void,AbstractArray{<:Number}}=nothing,
    c1::Union{Void,AbstractArray{<:Number}}=nothing,
    c2::Union{Void,AbstractArray{<:Number}}=nothing) where {T1,T2,T3}

    if typeof(x) <: AbstractArray
        df = zeros(returntype, size(x))
    else
        if inplace == Val{true}
            if typeof(fx)==Void && typeof(c1)==Void && typeof(c2)==Void
                error("In the scalar->vector in-place map case, at least one of fx, c1 or c2 must be provided, otherwise we cannot infer the return size.")
            else
                if     c1 != nothing    df = similar(c1)
                elseif fx != nothing    df = similar(fx)
                elseif c2 != nothing    df = similar(c2)
                end
            end
        else
            df = similar(f(x))
        end
    end
    cache = GradientCache(df,x,fx,c1,c2,fdtype,returntype,inplace)
    finite_difference_gradient!(df,f,x,cache)
end

function finite_difference_gradient!(df, f, x, fdtype::Type{T1}=Val{:central},
    returntype::Type{T2}=eltype(x), inplace::Type{Val{T3}}=Val{true},
    fx::Union{Void,AbstractArray{<:Number}}=nothing,
    c1::Union{Void,AbstractArray{<:Number}}=nothing,
    c2::Union{Void,AbstractArray{<:Number}}=nothing,
    ) where {T1,T2,T3}

    cache = GradientCache(df,x,fx,c1,c2,fdtype,returntype,inplace)
    finite_difference_gradient!(df,f,x,cache)
end

function finite_difference_gradient(f,x,
    cache::GradientCache{T1,T2,T3,fdtype,returntype,inplace}) where {T1,T2,T3,fdtype,returntype,inplace}

    if typeof(x) <: AbstractArray
        df = zeros(returntype, size(x))
    else
        df = zeros(cache.c1)
    end
    finite_difference_gradient!(df,f,x,cache)
    df
end

# vector of derivatives of a vector->scalar map by each component of a vector x
# this ignores the value of "inplace", because it doesn't make much sense
function finite_difference_gradient!(df::AbstractArray{<:Number}, f, x::AbstractArray{<:Number},
    cache::GradientCache{T1,T2,T3,fdtype,returntype,inplace}) where {T1,T2,T3,fdtype,returntype,inplace}

    # NOTE: in this case epsilon is a vector, we need two arrays for epsilon and x1
    # c1 denotes epsilon, c2 is x1, pre-set to the values of x by the cache constructor
    fx, c1, c2 = cache.fx, cache.c1, cache.c2
    if fdtype != Val{:complex}
        epsilon_factor = compute_epsilon_factor(fdtype, eltype(x))
        @. c1 = compute_epsilon(fdtype, x, epsilon_factor)
        copy!(c2,x)
    end
    if fdtype == Val{:forward}
        @inbounds for i ∈ eachindex(x)
            c2[i] += c1[i]
            if typeof(fx) != Void
                df[i] = (f(c2) - fx) / c1[i]
            else
                df[i]  = (f(c2) - f(x)) / c1[i]
            end
            c2[i] -= c1[i]
        end
    elseif fdtype == Val{:central}
        @inbounds for i ∈ eachindex(x)
            c2[i] += c1[i]
            x[i]  -= c1[i]
            df[i]  = (f(c2) - f(x)) / (2*c1[i])
            c2[i] -= c1[i]
            x[i]  += c1[i]
        end
    elseif fdtype == Val{:complex} && returntype <: Real
        copy!(c1,x)
        epsilon_complex = eps(real(eltype(x)))
        # we use c1 here to avoid typing issues with x
        @inbounds for i ∈ eachindex(x)
            c1[i] += im*epsilon_complex
            df[i]  = imag(f(c1)) / epsilon_complex
            c1[i] -= im*epsilon_complex
        end
    else
        fdtype_error(returntype)
    end
    df
end

# vector of derivatives of a scalar->vector map
# this is effectively a vector of partial derivatives, but we still call it a gradient
function finite_difference_gradient!(df::AbstractArray{<:Number}, f, x::Number,
    cache::GradientCache{T1,T2,T3,fdtype,returntype,inplace}) where {T1,T2,T3,fdtype,returntype,inplace}

    # NOTE: in this case epsilon is a scalar, we need two arrays for fx1 and fx2
    # c1 denotes fx1, c2 is fx2, sizes guaranteed by the cache constructor
    fx, c1, c2 = cache.fx, cache.c1, cache.c2

    if fdtype == Val{:forward}
        epsilon_factor = compute_epsilon_factor(fdtype, eltype(x))
        epsilon = compute_epsilon(Val{:forward}, x, epsilon_factor)
        if inplace == Val{true}
            f(c1, x+epsilon)
        else
            c1 .= f(x+epsilon)
        end
        if typeof(fx) != Void
            @. df = (c1 - fx) / epsilon
        else
            if inplace == Val{true}
                f(c2, x)
            else
                c2 .= f(x)
            end
            @. df = (c1 - c2) / epsilon
        end
    elseif fdtype == Val{:central}
        epsilon_factor = compute_epsilon_factor(fdtype, eltype(x))
        epsilon = compute_epsilon(Val{:central}, x, epsilon_factor)
        if inplace == Val{true}
            f(c1, x+epsilon)
            f(c2, x-epsilon)
        else
            c1 .= f(x+epsilon)
            c2 .= f(x-epsilon)
        end
        @. df = (c1 - c2) / (2*epsilon)
    elseif fdtype == Val{:complex} && returntype <: Real
        epsilon_complex = eps(real(eltype(x)))
        if inplace == Val{true}
            f(c1, x+im*epsilon_complex)
        else
            c1 .= f(x+im*epsilon_complex)
        end
        @. df = imag(c1) / epsilon_complex
    else
        fdtype_error(returntype)
    end
    df
end