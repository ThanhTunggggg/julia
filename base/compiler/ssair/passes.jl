function compact_exprtype(compact, value)
    if isa(value, Union{SSAValue, OldSSAValue})
        return types(compact)[value]
    elseif isa(value, Argument)
        return compact.ir.argtypes[value.n]
    end
    exprtype(value, compact.ir, compact.ir.mod)
end

struct SSADefUse
    uses::Vector{Int}
    defs::Vector{Int}
end
SSADefUse() = SSADefUse(Int[], Int[])

function try_compute_fieldidx(typ, use_expr)
    field = use_expr.args[3]
    isa(field, QuoteNode) && (field = field.value)
    isa(field, Union{Int, Symbol}) || return nothing
    if isa(field, Symbol)
        field = fieldindex(typ, field, false)
        field == 0 && return nothing
    elseif isa(field, Integer)
        (1 <= field <= fieldcount(typ)) || return nothing
    end
    return field
end

function lift_defuse(cfg::CFG, ssa::SSADefUse)
    SSADefUse(
        Int[block_for_inst(cfg, x) for x in ssa.uses],
        Int[block_for_inst(cfg, x) for x in ssa.defs])
end

function find_curblock(domtree, allblocks, curblock)
    # TODO: This can be much faster by looking at current level and only
    # searching for those blocks in a sorted order
    while !(curblock in allblocks)
        curblock = domtree.idoms[curblock]
    end
    curblock
end

function val_for_def_expr(ir, def, fidx)
    if isexpr(ir[SSAValue(def)], :new)
        return ir[SSAValue(def)].args[1+fidx]
    else
        # The use is whatever the setfield was
        return ir[SSAValue(def)].args[4]
    end
end

function compute_value_for_block(ir, domtree, allblocks, du, phinodes, fidx, curblock)
    curblock = find_curblock(domtree, allblocks, curblock)
    def = reduce(max, 0, stmt for stmt in du.defs if block_for_inst(ir.cfg, stmt) == curblock)
    def == 0 ? phinodes[curblock] : val_for_def_expr(ir, def, fidx)
end

function compute_value_for_use(ir, domtree, allblocks, du, phinodes, fidx, use_idx)
    # Find the first dominating def
    curblock = stmtblock = block_for_inst(ir.cfg, use_idx)
    curblock = find_curblock(domtree, allblocks, curblock)
    defblockdefs = [stmt for stmt in du.defs if block_for_inst(ir.cfg, stmt) == curblock]
    def = 0
    if !isempty(defblockdefs)
        if curblock != stmtblock
            # Find the last def in this block
            def = maximum(defblockdefs)
        else
            # Find the last def before our use
            def = mapreduce(x->x >= use_idx ? 0 : x, max, defblockdefs)
        end
    end
    if def == 0
        if !haskey(phinodes, curblock)
            # If this happens, we need to search the predecessors for defs. Which
            # one doesn't matter - if it did, we'd have had a phinode
            return compute_value_for_block(ir, domtree, allblocks, du, phinodes, fidx, first(ir.cfg.blocks[stmtblock].preds))
        end
        # The use is the phinode
        return phinodes[curblock]
    else
        return val_for_def_expr(ir, def, fidx)
    end
end

function getfield_elim_pass!(ir::IRCode, domtree)
    compact = IncrementalCompact(ir)
    insertions = Vector{Any}()
    defuses = IdDict{Int, Tuple{IdSet{Int}, SSADefUse}}()
    for (idx, stmt) in compact
        isa(stmt, Expr) || continue
        is_getfield = false
        # Step 1: Check whether the statement we're looking at is a getfield/setfield!
        if is_known_call(stmt, setfield!, ir, ir.mod)
            is_setfield = true
        elseif is_known_call(stmt, getfield, ir, ir.mod)
            is_getfield = true
        else
            continue
        end
        isa(stmt.args[2], SSAValue) || continue
        ## Normalize the field argument to getfield/setfield
        field = stmt.args[3]
        isa(field, QuoteNode) && (field = field.value)
        isa(field, Union{Int, Symbol}) || continue
        orig_defidx = defidx = stmt.args[2].id

        # Step 2: Figure out what the struct is defined as
        def = compact[defidx]
        typeconstraint = types(compact)[defidx]
        phi_locs = Tuple{Int, Int}[]
        ## Track definitions through PiNode/PhiNode
        found_def = false
        ## Track which PhiNodes, SSAValue intermediaries
        ## we forwarded through.
        intermediaries = IdSet{Int}()
        while true
            if isa(def, PiNode)
                push!(intermediaries, defidx)
                typeconstraint = typeintersect(typeconstraint, def.typ)
                if isa(def.val, SSAValue)
                    defidx = def.val.id
                    def = compact[defidx]
                else
                    def = def.val
                end
                continue
            elseif isa(def, PhiNode)
                # For now, we don't track setfields structs through phi nodes
                is_getfield || break
                possible_predecessors = collect(Iterators.filter(1:length(def.edges)) do n
                    isassigned(def.values, n) || return false
                    value = def.values[n]
                    edge_typ = compact_exprtype(compact, value)
                    return edge_typ ⊑ typeconstraint
                end)
                # For now, only look at unique predecessors
                if length(possible_predecessors) == 1
                    n = possible_predecessors[1]
                    pred = def.edges[n]
                    val = def.values[n]
                    if isa(val, SSAValue)
                        push!(phi_locs, (pred, defidx))
                        defidx = val.id
                        def = compact[defidx]
                    elseif def == val
                        # This shouldn't really ever happen, but
                        # patterns like this can occur in dead code,
                        # so bail out.
                        break
                    else
                        def = val
                    end
                    continue
                end
            elseif isa(def, SSAValue)
                push!(intermediaries, defidx)
                defidx = def.id
                def = compact[def.id]
                continue
            end
            found_def = true
            break
        end
        found_def || continue
        if !is_getfield
            mid, defuse = get!(defuses, defidx, (IdSet{Int}(), SSADefUse()))
            push!(defuse.defs, idx)
            union!(mid, intermediaries)
            continue
        end
        # Step 3: Check if the definition we eventually end up at is either
        # a tuple(...) call or Expr(:new) and perform replacement.
        if isa(def, Expr) && is_known_call(def, tuple, ir, ir.mod) && isa(field, Int) && 1 <= field < length(def.args)
            forwarded = def.args[1+field]
        elseif isexpr(def, :new)
            typ = def.typ
            if isa(typ, UnionAll)
                typ = unwrap_unionall(typ)
            end
            isa(typ, DataType) || continue
            if typ.mutable
                mid, defuse = get!(defuses, defidx, (IdSet{Int}(), SSADefUse()))
                push!(defuse.uses, idx)
                union!(mid, intermediaries)
                continue
            end
            field = try_compute_fieldidx(typ, stmt)
            field === nothing && continue
            forwarded = def.args[1+field]
        else
            continue
        end
        # Step 4: Remember any phinodes we need to insert
        if !isempty(phi_locs) && isa(forwarded, SSAValue)
            # TODO: We have have to use BB ids for phi_locs
            # to avoid index invalidation.
            push!(insertions, (idx, phi_locs))
        end
        compact[idx] = forwarded
    end
    ir = finish(compact)
    @Base.show length(defuses)
    # Now go through any mutable structs and see which ones we can eliminate
    for (idx, (intermediaries, defuse)) in defuses
        intermediaries = collect(intermediaries)
        # Check if there are any uses we did not account for. If so, the variable
        # escapes and we cannot eliminate the allocation. This works, because we're guaranteed
        # not to include any intermediaries that have dead uses. As a result, missing uses will only ever
        # show up in the nuses_total count.
        nleaves = length(defuse.uses) + length(defuse.defs)
        nuses_total = compact.used_ssas[idx] + mapreduce(idx->compact.used_ssas[idx], +, 0, intermediaries) - length(intermediaries)
        @Base.show (nleaves, nuses_total)
        nleaves == nuses_total || continue
        # Find the type for this allocation
        defexpr = ir[SSAValue(idx)]
        isexpr(defexpr, :new) || continue
        typ = defexpr.typ
        if isa(typ, UnionAll)
            typ = unwrap_unionall(typ)
        end
        # Could still end up here if we tried to setfield! and immutable, which would
        # error at runtime, but is not illegal to have in the IR.
        typ.mutable || continue
        # Partition defuses by field
        fielddefuse = SSADefUse[SSADefUse() for _ = 1:fieldcount(typ)]
        ok = true
        for use in defuse.uses
            field = try_compute_fieldidx(typ, ir[SSAValue(use)])
            field === nothing && (ok = false; break)
            push!(fielddefuse[field].uses, use)
        end
        ok || continue
        for use in defuse.defs
            field = try_compute_fieldidx(typ, ir[SSAValue(use)])
            field === nothing && (ok = false; break)
            push!(fielddefuse[field].defs, use)
        end
        ok || continue
        # Everything accounted for. Go field by field and perform idf
        for (fidx, du) in pairs(fielddefuse)
            ftyp = fieldtype(typ, fidx)
            if !isempty(du.uses)
                push!(du.defs, idx)
                ldu = lift_defuse(ir.cfg, du)
                phiblocks = idf(ir.cfg, ldu, domtree)
                phinodes = IdDict{Int, SSAValue}()
                for b in phiblocks
                    n = PhiNode()
                    phinodes[b] = insert_node!(ir, first(ir.cfg.blocks[b].stmts), ftyp, n)
                end
                # Now go through all uses and rewrite them
                allblocks = sort(vcat(phiblocks, ldu.defs))
                for stmt in du.uses
                    ir[SSAValue(stmt)] = compute_value_for_use(ir, domtree, allblocks, du, phinodes, fidx, stmt)
                end
                for b in phiblocks
                    for p in ir.cfg.blocks[b].preds
                        n = ir[phinodes[b]]
                        push!(n.edges, p)
                        push!(n.values, compute_value_for_block(ir, domtree,
                            allblocks, du, phinodes, fidx, p))
                    end
                end
            end
            for stmt in du.defs
                stmt == idx && continue
                ir[SSAValue(stmt)] = nothing
            end
            continue
        end
    end
    for (idx, phi_locs) in insertions
        # For non-dominating load-store forward, we may have to insert extra phi nodes
        # TODO: Can use the domtree to eliminate unnecessary phis, but ok for now
        forwarded = ir.stmts[idx]
        if isa(forwarded, SSAValue)
            forwarded_typ = ir.types[forwarded.id]
            for (pred, pos) in reverse!(phi_locs)
                node = PhiNode()
                push!(node.edges, pred)
                push!(node.values, forwarded)
                forwarded = insert_node!(ir, pos, forwarded_typ, node)
            end
        end
        ir.stmts[idx] = forwarded
    end
    ir
end

function type_lift_pass!(ir::IRCode)
    type_ctx_uses = Vector{Vector{Int}}[]
    has_non_type_ctx_uses = IdSet{Int}()
    lifted_undef = IdDict{Int, SSAValue}()
    for (idx, stmt) in pairs(ir.stmts)
        if stmt isa Expr && (stmt.head === :isdefined || stmt.head === :undefcheck)
            val = (stmt.head === :isdefined) ? stmt.args[1] : stmt.args[2]
            # undef can only show up by being introduced in a phi
            # node, so lift all phi nodes that have maybe undef values
            processed = IdDict{Int, SSAValue}()
            if !isa(val, SSAValue)
                if stmt.head === :undefcheck
                    ir.stmts[idx] = nothing
                end
                continue
            end
            worklist = Tuple{Int, SSAValue, Int}[(val.id, SSAValue(0), 0)]
            stmt_id = val.id
            while isa(ir.stmts[stmt_id], PiNode)
                stmt_id = ir.stmts[stmt_id].val.id
            end
            def = ir.stmts[stmt_id]
            if !isa(def, PhiNode)
                if stmt.head === :isdefined
                    ir.stmts[idx] = true
                else
                    ir.stmts[idx] = nothing
                end
                continue
            end
            if !haskey(lifted_undef, stmt_id)
                first = true
                while !isempty(worklist)
                    item, which, use = pop!(worklist)
                    def = ir.stmts[item]
                    edges = copy(def.edges)
                    values = Vector{Any}(uninitialized, length(edges))
                    new_phi = length(values) == 0 ? false : insert_node!(ir, item, Bool, PhiNode(edges, values))
                    processed[item] = new_phi
                    if first
                        lifted_undef[stmt_id] = new_phi
                        first = false
                    end
                    for i = 1:length(edges)
                        if !isassigned(def.values, i)
                            val = false
                        elseif !isa(def.values[i], SSAValue)
                            val = true
                        else
                            id = def.values[i].id
                            if !isa(ir.types[id], MaybeUndef)
                                val = true
                            else
                                while isa(ir.stmts[id], PiNode)
                                    id = ir.stmts[id].val.id
                                end
                                if isa(ir.stmts[id], PhiNode)
                                    if haskey(processed, id)
                                        val = processed[id]
                                    else
                                        push!(worklist, (id, new_phi, i))
                                        continue
                                    end
                                else
                                    val = true
                                end
                            end
                        end
                        values[i] = val
                    end
                    if which !== SSAValue(0)
                        ir[which].values[use] = new_phi
                    end
                end
            end
            if stmt.head === :isdefined
                ir.stmts[idx] = lifted_undef[stmt_id]
            else
                ir.stmts[idx] = Expr(:throw_undef_if_not, stmt.args[1], lifted_undef[stmt_id])
            end
        end
    end
    ir
end