# Code Generator
# ==============

# Variables:
#   * `p::Int`: position of current data
#   * `p_end::Int`: end position of data
#   * `p_eof::Int`: end position of file stream
#   * `cs::Int`: current state

function generate_init_code(machine::Machine)
    return quote
        p::Int = 1
        p_end::Int = 0
        p_eof::Int = -1
        cs::Int = $(machine.start_state)
    end
end

function generate_exec_code(machine::Machine; actions=nothing, code::Symbol=:table, check::Bool=true, clean::Bool=false)
    if actions == nothing
        actions = Dict{Symbol,Expr}()
    elseif actions == :debug
        actions = debug_actions(machine)
    elseif isa(actions, Associative{Symbol,Expr})
        # ok
    else
        throw(ArgumentError("invalid actions argument"))
    end

    if code == :table
        code = generate_table_code(machine, actions, check)
    elseif code == :inline
        code = generate_inline_code(machine, actions, check)
    elseif code == :goto
        code = generate_goto_code(machine, actions, check)
    else
        throw(ArgumentError("invalid code: $(code)"))
    end

    if clean
        return cleanup(code)
    else
        return code
    end
end

function generate_table_code(machine::Machine, actions::Associative{Symbol,Expr}, check::Bool)
    action_dispatch_code, action_table = generate_action_dispatch_code(machine, actions)
    trans_table = generate_transition_table(machine)
    getbyte_code = generate_geybyte_code(check)
    act_code = :(@inbounds act = $(action_table)[(cs - 1) << 8 + l + 1])
    cs_code = :(@inbounds cs = $(trans_table)[(cs - 1) << 8 + l + 1])
    eof_action_code = generate_eof_action_code(machine, actions)
    @assert size(action_table, 1) == size(trans_table, 1) == 256
    return quote
        while p ≤ p_end && cs > 0
            $(getbyte_code)
            $(act_code)
            $(cs_code)
            $(action_dispatch_code)
            p += 1
        end
        if p > p_eof ≥ 0 && cs ∈ $(machine.final_states)
            $(eof_action_code)
            cs = 0
        elseif cs < 0
            p -= 1
        end
    end
end

function generate_transition_table(machine::Machine)
    trans_table = Matrix{Int}(256, length(machine.states))
    for j in 1:size(trans_table, 2)
        trans_table[:,j] = -j
    end
    for (s, trans) in machine.transitions
        for (l, (t, _)) in trans
            trans_table[l+1,s] = t
        end
    end
    return trans_table
end

function generate_action_dispatch_code(machine::Machine, actions::Associative{Symbol,Expr})
    action_table = Matrix{Int}(256, length(machine.states))
    fill!(action_table, 0)
    action_ids = Dict{Vector{Symbol},Int}()
    for s in machine.states
        for (l, (t, as)) in machine.transitions[s]
            if isempty(as)
                continue
            elseif !haskey(action_ids, as)
                action_ids[as] = length(action_ids) + 1
            end
            action_table[l+1,s] = action_ids[as]
        end
    end
    default = :()
    action_dispatch_code = foldr(default, collect(action_ids)) do as_id, els
        as, id = as_id
        action_code = rewrite_special_macros(generate_action_code(as, actions), false)
        return Expr(:if, :(act == $(id)), action_code, els)
    end
    return action_dispatch_code, action_table
end

function generate_inline_code(machine::Machine, actions::Associative{Symbol,Expr}, check::Bool)
    trans_code = generate_transition_code(machine, actions)
    eof_action_code = generate_eof_action_code(machine, actions)
    getbyte_code = generate_geybyte_code(check)
    return quote
        while p ≤ p_end && cs > 0
            $(getbyte_code)
            $(trans_code)
            p += 1
        end
        if p > p_eof ≥ 0 && cs ∈ $(machine.final_states)
            $(eof_action_code)
            cs = 0
        elseif cs < 0
            p -= 1
        end
    end
end

function generate_transition_code(machine::Machine, actions::Associative{Symbol,Expr})
    default = :(cs = -cs)
    return foldr(default, collect(machine.transitions)) do s_trans, els
        s, trans = s_trans
        then = foldr(default, compact_transition(trans)) do branch, els′
            l, (t, as) = branch
            if isempty(as)
                then′ = :(cs = $(t))
            else
                action_code = rewrite_special_macros(generate_action_code(as, actions), false)
                then′ = :(cs = $(t); $(action_code))
            end
            return Expr(:if, label_condition(l), then′, els′)
        end
        return Expr(:if, state_condition(s), then, els)
    end
end

function compact_transition{T}(trans::Dict{UInt8,T})
    revtrans = Dict{T,Vector{UInt8}}()
    for (l, t_as) in trans
        if !haskey(revtrans, t_as)
            revtrans[t_as] = UInt8[]
        end
        push!(revtrans[t_as], l)
    end
    return [(ByteSet(ls), t_as) for (t_as, ls) in revtrans]
end

function generate_goto_code(machine::Machine, actions::Associative{Symbol,Expr}, check::Bool)
    actions_in = make_actions_in(machine)
    action_label = Dict(s => Dict{Vector{Symbol},Symbol}() for s in machine.states)
    for s in machine.states
        for (i, as) in enumerate(keys(actions_in[s]))
            action_label[s][as] = Symbol("state_", s, "_action_", i)
        end
    end

    blocks = Expr[]
    for s in machine.states
        block = Expr(:block)
        for (names, label) in action_label[s]
            if isempty(names)
                continue
            end
            append_code!(block, quote
                @label $(label)
                $(rewrite_special_macros(generate_action_code(names, actions), false, Nullable(s)))
                @goto $(Symbol("state_", s))
            end)
        end
        append_code!(block, quote
            @label $(Symbol("state_", s))
            p += 1
            if p > p_end
                cs = $(s)
                @goto exit
            end
        end)
        default = :(cs = $(-s); @goto exit)
        dispatch_code = foldr(default, compact_transition(machine.transitions[s])) do branch, els
            ls, (t, as) = branch
            if isempty(as)
                goto_code = :(@goto $(Symbol("state_", t)))
            else
                goto_code = :(@goto $(action_label[t][as]))
            end
            return Expr(:if, label_condition(ls), goto_code, els)
        end
        append_code!(block, quote
            @label $(Symbol("state_case_", s))
            $(generate_geybyte_code(check))
            $(dispatch_code)
        end)
        push!(blocks, block)
    end

    enter_code = foldr(:(@goto exit), machine.states) do s, els
        return Expr(:if, :(cs == $(s)), :(@goto $(Symbol("state_case_", s))), els)
    end

    eof_action_code = rewrite_special_macros(generate_eof_action_code(machine, actions), true)

    return quote
        if p > p_end
            @goto exit
        end
        $(enter_code)
        $(Expr(:block, blocks...))
        @label exit
        if p > p_eof ≥ 0 && cs ∈ $(machine.final_states)
            $(eof_action_code)
            cs = 0
        elseif cs < 0
            p -= 1
        end
    end
end

function append_code!(block::Expr, code::Expr)
    @assert block.head == :block
    @assert code.head == :block
    append!(block.args, code.args)
    return block
end

function generate_eof_action_code(machine::Machine, actions::Associative{Symbol,Expr})
    return foldr(:(), collect(machine.eof_actions)) do s_as, els
        s, as = s_as
        action_code = rewrite_special_macros(generate_action_code(as, actions), true)
        Expr(:if, state_condition(s), action_code, els)
    end
end

function generate_action_code(names::Vector{Symbol}, actions::Associative{Symbol,Expr})
    return Expr(:block, (actions[n] for n in names)...)
end

function generate_geybyte_code(docheck::Bool)
    block = Expr(:block)
    if docheck
        append_code!(block, quote
            if !$(check)(data, p)
                throw(BoundsError(data, p))
            end
        end)
    end
    append_code!(block, quote
        l = $(getbyte)(data, p)
    end)
    return block
end

function state_condition(s::Int)
    return :(cs == $(s))
end

function label_condition(set::ByteSet)
    label = compact_labels(set)
    return foldr((range, cond) -> Expr(:||, :(l in $(range)), cond), :(false), label)
end

function compact_labels(set::ByteSet)
    labels = collect(set)
    labels′ = UnitRange{UInt8}[]
    while !isempty(labels)
        lo = shift!(labels)
        hi = lo
        while !isempty(labels) && first(labels) == hi + 1
            hi = shift!(labels)
        end
        push!(labels′, lo:hi)
    end
    return labels′
end

function make_actions_in(machine::Machine)
    actions_in = Dict(t => Dict{Vector{Symbol},Set{UInt8}}() for t in machine.states)
    for s in machine.states
        for (l, (t, as)) in machine.transitions[s]
            #push!(actions_in[t], as)
            if !haskey(actions_in[t], as)
                actions_in[t][as] = Set{UInt8}()
            end
            push!(actions_in[t][as], l)
        end
    end
    return actions_in
end

function rewrite_special_macros(ex::Expr, eof_action::Bool, cs::Nullable{Int}=Nullable{Int}())
    args = []
    for arg in ex.args
        if arg == :(@escape)
            if eof_action
                # pass
            elseif !isnull(cs)  # used by the goto code generator
                push!(args, quote
                    cs = $(get(cs))
                    p += 1
                    @goto exit
                end)
            else
                push!(args, quote
                    p += 1
                    break
                end)
            end
        elseif isa(arg, Expr)
            push!(args, rewrite_special_macros(arg, eof_action, cs))
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

function cleanup(ex::Expr)
    args = []
    for arg in ex.args
        if isa(arg, Expr)
            if arg.head == :line
                # pass
            elseif ex.head == :block && arg.head == :block
                append!(args, cleanup(arg).args)
            else
                push!(args, cleanup(arg))
            end
        else
            push!(args, arg)
        end
    end
    return Expr(ex.head, args...)
end

function debug_actions(machine::Machine)
    actions = Set{Symbol}()
    for trans in values(machine.transitions)
        for (_, as) in values(trans)
            union!(actions, as)
        end
    end
    for as in values(machine.eof_actions)
        union!(actions, as)
    end
    function log_expr(name)
        return :(push!(logger, $(QuoteNode(name))))
    end
    return Dict(name => log_expr(name) for name in actions)
end


# Accessors
# ---------

@inline function check(data::String, p::Integer)
    return 1 ≤ p ≤ sizeof(data)
end

@inline function getbyte(data::String, p::Integer)
    return unsafe_load(pointer(data), p)
end

@inline function check(data::AbstractVector{UInt8}, p::Integer)
    return 1 ≤ p ≤ endof(data)
end

@inline function getbyte(data::AbstractVector{UInt8}, p::Integer)
    @inbounds return data[p]
end
