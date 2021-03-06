# DOT Language
# ============

function nfa2dot(nfa::NFA)
    buf = IOBuffer()
    println(buf, "digraph {")
    println(buf, "  graph [ rankdir = LR ];")
    println(buf, "  0 -> 1;")
    println(buf, "  0 [ shape = point ];")
    serial = 0
    serials = Dict(nfa.start => (serial += 1))

    function trace(s, label)
        for t in s.trans[label]
            if !haskey(serials, t)
                serials[t] = (serial += 1)
                push!(unvisited, t)
            end
            actions = s.actions[(label, t)]
            println(buf, "  $(serials[s]) -> $(serials[t]) [ label = \"$(label2str(label, actions))\" ];")
        end
    end

    unvisited = Set([nfa.start])
    while !isempty(unvisited)
        s = pop!(unvisited)
        for l in 0x00:0xff
            trace(s, l)
        end
        trace(s, :eps)
    end
    for (node, serial) in serials
        shape = node == nfa.final ? "doublecircle" : "circle"
        println(buf, "  $(serial) [ shape = $(shape) ];")
    end
    println(buf, "}")
    return @compat String(take!(buf))
end

function dfa2dot(dfa::DFA)
    buf = IOBuffer()
    println(buf, "digraph {")
    println(buf, "  graph [ rankdir = LR ];")
    println(buf, "  start -> 1;")
    println(buf, "  start [ shape = point ];")
    println(buf, "  final [ shape = point ];")
    serial = 0
    serials = Dict(dfa.start => (serial += 1))
    unvisited = Set([dfa.start])
    while !isempty(unvisited)
        s = pop!(unvisited)
        for (l, (t, as)) in compact_transition(s.next)
            if !haskey(serials, t)
                serials[t] = (serial += 1)
                push!(unvisited, t)
            end
            label = label2str(l, as)
            println(buf, "  $(serials[s]) -> $(serials[t]) [ label = \"$(label)\" ];")
        end
        if s.final
            label = label2str(:eof, s.eof_actions)
            println(buf, "  $(serials[s]) -> final [ label = \"$(label)\", style = dashed ];")
        end
    end
    for (node, serial) in serials
        shape = node.final ? "doublecircle" : "circle"
        println(buf, "  $(serial) [ shape = $(shape) ];")
    end
    println(buf, "}")
    return @compat String(take!(buf))
end

function label2str(label, actions)
    if isempty(actions)
        return label2str(label)
    else
        return string(label2str(label), '/', actions2str(actions))
    end
end

function label2str(label)
    if label == :eps
        return "ε"
    elseif label == :eof
        return "EOF"
    elseif isa(label, ByteSet)
        label = compact_labels(label)
        ss = []
        for range in label
            s = first(range)
            if s ≤ 0x7f
                s = repr(Char(s))
            else
                s = repr(s)
            end
            if length(range) ≥ 2
                t = last(range)
                if t ≤ 0x7f
                    t = repr(Char(t))
                else
                    t = repr(t)
                end
                s = string(s, ':', t)
            end
            push!(ss, escape_string(s))
        end
        return join(ss, ',')
    else
        return escape_string(repr(label))
    end
end

function actions2str(actions)
    return join(sorted_unique_action_names(actions), ',')
end
