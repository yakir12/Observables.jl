module Observables

export Observable, on, off, onany, onall, connect!, obsid, async_latest, throttle
export Consume, ObserverFunction, AbstractObservable

import Base.Iterators.filter

if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@optlevel"))
    @eval Base.Experimental.@optlevel 0
end

# @nospecialize "blocks" codegen but not necessarily inference. This forces inference
# to drop specific information about an argument.
if isdefined(Base, :inferencebarrier)
    const inferencebarrier = Base.inferencebarrier
else
    inferencebarrier(x) = Ref{Any}(x)[]
end

abstract type AbstractObservable{T} end

const addhandler_callbacks = []
const removehandler_callbacks = []

"""
    obs = Observable(val; ignore_equal_values=false)
    obs = Observable{T}(val; ignore_equal_values=false)

Like a `Ref`, but updates can be watched by adding a handler using [`on`](@ref) or [`map`](@ref).
Set `ignore_equal_values=true` to not trigger an event for `observable[] = new_value` if `isequel(observable[], new_value)`.
"""
mutable struct Observable{T} <: AbstractObservable{T}

    listeners::Vector{Pair{Int, Any}}
    inputs::Vector{Any}  # for map!ed Observables
    ignore_equal_values::Bool
    val::T

    function Observable{T}(; ignore_equal_values::Bool=false) where {T}
        return new{T}(Pair{Int, Any}[], [], ignore_equal_values)
    end
    function Observable{T}(@nospecialize(val); ignore_equal_values::Bool=false) where {T}
        return new{T}(Pair{Int, Any}[], [], ignore_equal_values, val)
    end
end

"""
    obsid(observable::Observable)

Gets a unique id for an observable.
"""
obsid(observable::Observable) = string(objectid(observable))
obsid(obs::AbstractObservable) = obsid(observe(obs))

function Base.getproperty(obs::Observable, field::Symbol)
    if field === :id
        return obsid(obs)
    else
        getfield(obs, field)
    end
end

Observable(val::T; ignore_equal_values::Bool=false) where {T} = Observable{T}(val; ignore_equal_values)

Base.eltype(::AbstractObservable{T}) where {T} = T

function observe(obs::AbstractObservable)
    error("observe not defined for AbstractObservable $(typeof(obs))")
end
observe(x::Observable) = x
Base.getindex(obs::AbstractObservable) = getindex(observe(obs))
Base.setindex!(obs::AbstractObservable, val) = setindex!(observe(obs), val)
listeners(obs::AbstractObservable) = listeners(observe(obs))
listeners(observable::Observable) = observable.listeners

"""
    observable[] = val

Updates the value of an `Observable` to `val` and call its listeners.
"""
function Base.setindex!(@nospecialize(observable::Observable), @nospecialize(val))
    if observable.ignore_equal_values
        isequal(observable.val, val) && return
    end
    observable.val = val
    return notify(observable)
end

"""
    observable[]

Returns the current value of `observable`.
"""
Base.getindex(observable::Observable) = observable.val

### Utilities

"""
    to_value(x::Union{Any, AbstractObservable})
Extracts the value of an observable, and returns the object if it's not an observable!
"""
to_value(x) = isa(x, AbstractObservable) ? x[] : x  # noninferrable dispatch is faster if there is only one Method


function register_callback(@nospecialize(observable), priority::Int, @nospecialize(f))
    ls = listeners(observable)::Vector{Pair{Int, Any}}
    idx = searchsortedlast(ls, priority; by=first, rev=true)
    insert!(ls, idx + 1, priority => f)
    return
end

function Base.convert(::Type{P}, observable::AbstractObservable) where P <: Observable
    result = P(observable[])
    on(x-> result[] = x, observable)
    return result
end

function Base.copy(observable::Observable{T}) where T
    result = Observable{T}(observable[])
    on(x-> result[] = x, observable)
    return result
end

Base.convert(::Type{T}, x::T) where {T<:Observable} = x  # resolves ambiguity with convert(::Type{T}, x::T) in base/essentials.jl
Base.convert(::Type{T}, x) where {T<:Observable} = T(x)
Base.convert(::Type{Observable{Any}}, x::AbstractObservable{Any}) = x
Base.convert(::Type{Observables.Observable{Any}}, x::Observables.Observable{Any}) = x

struct Consume
    x::Bool
end
Consume() = Consume(true)

"""
    notify(observable::AbstractObservable)

Update all listeners of `observable`.
Returns true if an event got consumed before notifying every listener.
"""
function Base.notify(@nospecialize(observable::AbstractObservable))
    val = observable[]
    for (_, f) in listeners(observable)::Vector{Pair{Int, Any}}
        result = Base.invokelatest(f, val)
        if result isa Consume && result.x
            # stop calling callbacks if event got consumed
            return true
        end
    end
    return false
end

function Base.show(io::IO, x::Observable{T}) where T
    println(io, "Observable{$T} with $(length(x.listeners)) listeners. Value:")
    if isdefined(x, :val)
        show(io, x.val)
    else
        print(io, "not assigned yet!")
    end
end

Base.show(io::IO, ::MIME"application/prs.juno.inline", x::Observable) = x

"""
    mutable struct ObserverFunction <: Function

Fields:

    f::Function
    observable::AbstractObservable
    weak::Bool

`ObserverFunction` is intended as the return value for `on` because
we can remove the created closure from `obsfunc.observable`'s listener vectors when
ObserverFunction goes out of scope - as long as the `weak` flag is set.
If the `weak` flag is not set, nothing happens
when the ObserverFunction goes out of scope and it can be safely ignored.
It can still be useful because it is easier to call `off(obsfunc)` instead of `off(observable, f)`
to release the connection later.
"""
mutable struct ObserverFunction <: Function
    f::Any
    observable::AbstractObservable
    weak::Bool

    function ObserverFunction(@nospecialize(f), @nospecialize(observable::AbstractObservable), weak::Bool)
        obsfunc = new(f, observable, weak)
        # If the weak flag is set, deregister the function f from the observable
        # storing it in its listeners once the ObserverFunction is garbage collected.
        # This should free all resources associated with f unless there
        # is another reference to it somewhere else.
        weak && finalizer(off, obsfunc)
        return obsfunc
    end
end

function Base.show(io::IO, obsf::ObserverFunction)
    showdflt(io, @nospecialize(f), obs) = print(io, "ObserverFunction `", f, "` operating on ", obs)

    nm = string(nameof(obsf.f))
    if !occursin('#', nm)
        showdflt(io, obsf.f, obsf.observable)
    else
        mths = methods(obsf.f)
        if length(mths) == 1
            m = first(mths)
            print(io, "ObserverFunction defined at ", m.file, ":", m.line, " operating on ", obsf.observable)
        else
            showdflt(io, obsf.f, obsf.observable)
        end
    end
end
Base.show(io::IO, ::MIME"text/plain", obsf::ObserverFunction) = show(io, obsf)
Base.print(io::IO, obsf::ObserverFunction) = show(io, obsf)   # Base.print is specialized for ::Function


"""
    on(f, observable::AbstractObservable; weak = false, priority=0, update=false)::ObserverFunction

Adds function `f` as listener to `observable`. Whenever `observable`'s value
is set via `observable[] = val`, `f` is called with `val`.

Returns an [`ObserverFunction`](@ref) that wraps `f` and `observable` and allows to
disconnect easily by calling `off(observerfunction)` instead of `off(f, observable)`.
If instead you want to compute a new `Observable` from an old one, use [`map(f, ::Observable)`](@ref).

If `weak = true` is set, the new connection will be removed as soon as the returned `ObserverFunction`
is not referenced anywhere and is garbage collected. This is useful if some parent object
makes connections to outside observables and stores the resulting `ObserverFunction` instances.
Then, once that parent object is garbage collected, the weak
observable connections are removed automatically.

# Example

```jldoctest; setup=:(using Observables)
julia> obs = Observable(0)
Observable{Int} with 0 listeners. Value:
0

julia> on(obs) do val
           println("current value is ", val)
       end
(::Observables.ObserverFunction) (generic function with 0 methods)

julia> obs[] = 5;
current value is 5
```

One can also give the callback a priority, to enable always calling a specific callback before/after others, independent of the order of registration.
The callback with the highest priority gets called first, the default is zero, and the whole range of Int can be used.
So one can do:

```julia
julia> obs = Observable(0)
julia> on(obs; priority=-1) do x
           println("Hi from first added")
       end
julia> on(obs) do x
           println("Hi from second added")
       end
julia> obs[] = 2
Hi from second added
Hi from first added
```

If you set `update=true`, on will call f(obs[]) immediately:
```julia
julia> on(Observable(1); update=true) do x
    println("hi")
end
hi
```

"""
function on(@nospecialize(f), @nospecialize(observable::AbstractObservable); weak::Bool = false, priority::Int = 0, update::Bool = false)::ObserverFunction
    register_callback(observable, priority, f)
    #
    for g in addhandler_callbacks
        g(f, observable)
    end

    update && f(observable[])
    # Return a ObserverFunction so that the caller is responsible
    # to keep a reference to it around as long as they want the connection to
    # persist. If the ObserverFunction is garbage collected, f will be released from
    # observable's listeners as well.
    return ObserverFunction(f, observable, weak)
end

"""
    off(observable::AbstractObservable, f)

Removes `f` from listeners of `observable`.

Returns `true` if `f` could be removed, otherwise `false`.
"""
function off(@nospecialize(observable::AbstractObservable), @nospecialize(f))
    callbacks = listeners(observable)
    for (i, (prio, f2)) in enumerate(callbacks)
        if f === f2
            deleteat!(callbacks, i)
            for g in removehandler_callbacks
                g(observable, f)
            end
            return true
        end
    end
    return false
end

function off(@nospecialize(observable::AbstractObservable), obsfunc::ObserverFunction)
    # remove the function inside obsfunc as usual
    off(observable, obsfunc.f)
end

"""
    off(obsfunc::ObserverFunction)

Remove the listener function `obsfunc.f` from the listeners of `obsfunc.observable`.
Once `obsfunc` goes out of scope, this should allow `obsfunc.f` and all the values
it might have closed over to be garbage collected (unless there
are other references to it).
"""
function off(obsfunc::ObserverFunction)
    off(obsfunc.observable, obsfunc)
end

"""
    onany(f, args...)

Calls `f` on updates to any observable refs in `args`.
`args` may contain any number of `Observable` objects.
`f` will be passed the values contained in the refs as the respective argument.
All other objects in `args` are passed as-is.

See also: [`on`](@ref).
"""
function onany(f, args...; weak::Bool = false, priority::Int=0)
    function callback(@nospecialize(x))
        f(map(to_value, args)...)
    end
    obsfuncs = ObserverFunction[]
    for observable in args
        if observable isa AbstractObservable
            obsfunc = on(callback, observable; weak=weak, priority=priority)
            push!(obsfuncs, obsfunc)
        end
    end
    return obsfuncs
end


onall(f) = error("onall needs at least two observables")
onall(f, obs1) = error("onall needs at least two observables")

"""
    onall(f, args...)

Calls `f` on updates to all observable refs in `args`.
`f` is called only if *all* (as opposed to any) observable refs in `args` are updated at least once.
`args` may contain any number of `Observable` objects.
`f` will be passed the values contained in the refs as the respective argument.
All other objects in `args` are passed as-is.

See also: [`on`](@ref).
"""
function onall(f, observables...; condition=(old, new)-> true)
    updated = fill(false, length(observables))
    for (i, observable) in enumerate(observables)
        old = observable[]
        on(observable) do new_value
            if condition(old, new_value)
                updated[i] = true
                if all(updated)
                    f(to_value.(observables)...)
                    fill!(updated, false)
                end
            end
            old = new_value
        end
    end
end

"""
    map!(f, observable::AbstractObservable, args...; update::Bool=true)

Updates `observable` with the result of calling `f` with values extracted from args.
`args` may contain any number of `Observable` objects.
`f` will be passed the values contained in the refs as the respective argument.
All other objects in `args` are passed as-is.

By default `observable` gets updated immediately, but this can be suppressed by specifying `update=false`.

# Example

We'll create an observable that can hold an arbitrary number:

```jldoctest map!; setup=:(using Observables)
julia> obs = Observable{Number}(3)
Observable{Number} with 0 listeners. Value:
3
```

Now,

```jldoctest map!
julia> obsrt1 = map(sqrt, obs)
Observable{Float64} with 0 listeners. Value:
1.7320508075688772
```

creates an `Observable{Float64}`, which will fail to update if we set `obs[] = 3+4im`.
However,

```jldoctest map!
julia> obsrt2 = map!(sqrt, Observable{Number}(), obs)
Observable{Number} with 0 listeners. Value:
1.7320508075688772
```

can handle any number type for which `sqrt` is defined.
"""
@inline function Base.map!(@nospecialize(f), observable::AbstractObservable, os...; update::Bool=true)
    # note: the @inline prevents de-specialization due to the splatting
    obsfuncs = onany(os...) do args...
        observable[] = Base.invokelatest(f, args...)
    end
    appendinputs!(observable, obsfuncs)
    if update
        observable[] = f(map(to_value, os)...)
    end
    return observable
end

function appendinputs!(@nospecialize(observable), obsfuncs::Vector{ObserverFunction})  # latency: separating this from map! allows dropping the specialization on `f`
    if !isdefined(observable, :inputs)
        observable.inputs = obsfuncs
    else
        append!(observable.inputs, obsfuncs)
    end
    return observable
end

"""
    connect!(o1::AbstractObservable, o2::AbstractObservable)

Forwards all updates from `o2` to `o1`.

See also [`Observables.ObservablePair`](@ref).
"""
connect!(o1::AbstractObservable, o2::AbstractObservable) = on(x-> o1[] = x, o2; update=true)

"""
    obs = map(f, arg1::AbstractObservable, args...; ignore_equal_values=false)

Creates a new observable `obs` which contains the result of `f` applied to values
extracted from `arg1` and `args` (i.e., `f(arg1[], ...)`.
`arg1` must be an observable for dispatch reasons. `args` may contain any number of `Observable` objects.
`f` will be passed the values contained in the observables as the respective argument.
All other objects in `args` are passed as-is.

If you don't need the value of `obs`, and just want to run `f` whenever the
arguments update, use [`on`](@ref) or [`onany`](@ref) instead.

# Example

```jldoctest; setup=:(using Observables)
julia> obs = Observable([1,2,3]);

julia> map(length, obs)
Observable{$Int} with 0 listeners. Value:
3
```
"""
@inline function Base.map(f::F, arg1::AbstractObservable, args...; ignore_equal_values=false) where F
    # note: the @inline prevents de-specialization due to the splatting
    obs = Observable(f(arg1[], map(to_value, args)...); ignore_equal_values=ignore_equal_values)
    map!(f, obs, arg1, args...; update=false)
    return obs
end


"""
    async_latest(observable::AbstractObservable, n=1)

Returns an `Observable` which drops all but
the last `n` updates to `observable` if processing the updates
takes longer than the interval between updates.

This is useful if you want to pass the updates from,
say, a slider to a plotting function that takes a while to
compute. The plot will directly compute the last frame
skipping the intermediate ones.

# Example:
```
observable = Observable(0)
function compute_something(x)
    for i=1:10^8 rand() end # simulate something expensive
    println("updated with \$x")
end
o_latest = async_latest(observable, 1)
on(compute_something, o_latest) # compute something on the latest update

for i=1:5
    observable[] = i
end
```
"""
function async_latest(input::AbstractObservable{T}, n=1) where T
    buffer = T[]
    cond = Condition()
    lck  = ReentrantLock() # advisory lock for access to buffer
    output = Observable{T}(input[]) # output

    @async while true
        while true # while !isempty(buffer) but with a lock
            # transact a pop
            lock(lck)
            if isempty(buffer)
                unlock(lck)
                break
            end
            upd = pop!(buffer)
            unlock(lck)

            output[] = upd
        end
        wait(cond)
    end

    on(input) do val
        lock(lck)
        if length(buffer) < n
            push!(buffer, val)
        else
            while length(buffer) >= n
                pop!(buffer)
            end
            pushfirst!(buffer, val)
        end
        unlock(lck)
        notify(cond)
    end

    output
end

# TODO: overload broadcast on v0.6
include("observablepair.jl")
include("flatten.jl")
include("time.jl")
include("macros.jl")

# Look up the source location of `do` block Observable MethodInstances
function methodlist(@nospecialize(ft::Type))
    return Base.MethodList(ft.name.mt)
end

methodlist(mi::Core.MethodInstance) = methodlist(Base.unwrap_unionall(mi.specTypes).parameters[1])
methodlist(obsf::ObserverFunction) = methodlist(obsf.f)
methodlist(@nospecialize(f::Function)) = methodlist(typeof(f))

Base.precompile(obsf::ObserverFunction) = precompile(obsf.f, (eltype(obsf.observable),))
function Base.precompile(observable::Observable)
    tf = true
    T = eltype(observable)
    for f in observable.listeners
        precompile(f, (T,))
    end
    if isdefined(observable, :inputs)
        for obsf in observable.inputs
            tf &= precompile(obsf)
        end
    end
    return tf
end

precompile(Core.convert, (Type{Observable{Any}}, Observable{Any}))
precompile(Base.copy, (Type{Observable{Any}},))

end # module
