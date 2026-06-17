import Foundation

/// Derived DEPENDENCY INDEX over the by-id reference graph
/// (REFERENCE_GRAPH.md §3 — Phase 3 graph structure).
///
/// A **pure function of the `Document`**: it carries no authoritative state,
/// is never stored on the `Model`, never serialized into the document codecs,
/// and never compared. It is rebuilt on demand (the Phase 1–3 strategy per
/// REFERENCE_GRAPH.md §2.4); no consumer caches it yet.
///
/// It exposes, for the **by-id reference graph only**:
///
/// - `deps`      — `id -> sorted list of target ids it directly references`
/// - `rdeps`     — `id -> sorted list of ids that reference it` (reverse of deps)
/// - `dangling`  — sorted list of *referencing* ids whose target id is not
///                 present/targetable
/// - `cycles`    — sorted list of ids that participate in a cycle
/// - `topoOrder` — a deterministic topological ordering (dependencies-first) of
///                 the by-id graph; the only intentionally-non-sorted output
///
/// ## Operands are OPAQUE to the by-id graph (locked design)
///
/// The node walk recurses into Group/Layer children **only**, never into a
/// `CompoundShape`'s operands. Per REFERENCE_GRAPH.md a compound's operands are
/// *owned* (containment), and `LiveVariant.dependencies` is `[]` for a compound.
/// So the **targetable set** of ids is exactly the ids found by walking
/// `layers + Group/Layer children` — *not* operand-nested ids. This mirrors the
/// render-time resolver (`RebuildResolver.collect` in `Document.swift`), which
/// likewise recurses into Group/Layer children only and never enters Live
/// operands. A reference whose target is an operand-nested id is therefore
/// **dangling** (it is not in the targetable set) — this is what pins the
/// operands-opaque decision.
///
/// ## Determinism
///
/// Swift `Dictionary`/`Set` iterate in an unspecified order, so every map key
/// list and every value list is sorted **explicitly** before it reaches the
/// output. The cycle DFS iterates neighbors in sorted order. No part of the
/// output relies on hash-iteration order. Mirrors Rust's `BTreeMap`/sorted-`Vec`
/// structure, which is inherently ordered.
///
/// ## `topoOrder` (Phase 4a — REFERENCE_GRAPH.md §8)
///
/// A deterministic, dependencies-first topological ordering of the by-id graph,
/// computed by Kahn's algorithm with sorted-id tie-breaking (see
/// ``computeTopoOrder(_:_:_:)``). It is the recompute schedule a future incremental
/// phase (P4c) will walk. The ordering is the *only* intentionally-non-sorted
/// output: its sequence IS the data. The ALGORITHM IS LOCKED and must be
/// byte-identical across all four apps — it is the highest cross-language desync
/// risk here.
///
/// ## Deferred (NOT implemented here)
///
/// - **Write-time cycle rejection** — no authoring op can form a cycle yet
///   (`Controller.createReference` only links to an existing target), and the
///   eval-time cycle-break (the threaded `VisitSet` in `LiveElement.swift`)
///   already handles imported cycles. A write-time guard is an additive
///   Phase-3+ nicety.

// MARK: - DependencyIndex

/// The derived dependency index of a `Document`'s by-id reference graph.
///
/// All maps and lists are normalized to sorted order at build time so the
/// structure serializes deterministically. Rebuilt on demand via
/// ``DependencyIndex/build(_:)``; never stored or compared. Mirrors Rust
/// `DependencyIndex`.
public struct DependencyIndex: Equatable {
    /// `id -> sorted list of target ids it directly references` (out-edges).
    /// Only id-bearing elements with non-empty `dependencies` appear.
    public let deps: [String: [String]]
    /// `id -> sorted list of ids that reference it` (in-edges; reverse of
    /// `deps`). Only **targetable** ids (present in the node walk) appear, so a
    /// reference to an absent or operand-nested id contributes no `rdeps` entry.
    public let rdeps: [String: [String]]
    /// Sorted list of *referencing* ids at least one of whose `dependencies`
    /// targets is not in the targetable set (absent, or operand-opaque).
    public let dangling: [String]
    /// Sorted, de-duplicated list of ids that lie on a cycle in the `deps`
    /// graph (a node that can reach itself). A self-target (`R -> R`) is a cycle.
    public let cycles: [String]
    /// A deterministic topological ordering of the by-id graph,
    /// **dependencies-first** (a reference's target precedes the reference).
    /// Computed by Kahn's algorithm with sorted-id tie-breaking; cycle members
    /// (== `cycles`) are appended at the end in sorted-id order. This is the
    /// ONLY field whose order is NOT alphabetical — its sequence IS the data
    /// (the recompute schedule). The algorithm is LOCKED; see
    /// ``computeTopoOrder(_:_:_:)``.
    public let topoOrder: [String]

    public init(deps: [String: [String]] = [:],
                rdeps: [String: [String]] = [:],
                dangling: [String] = [],
                cycles: [String] = [],
                topoOrder: [String] = []) {
        self.deps = deps
        self.rdeps = rdeps
        self.dangling = dangling
        self.cycles = cycles
        self.topoOrder = topoOrder
    }

    /// Build the dependency index for `doc`. A pure, allocation-only function;
    /// no document state is mutated. See the type docs for the locked semantics.
    public static func build(_ doc: Document) -> DependencyIndex {
        // Phase 1: gather the node set (targetable ids) and raw out-edges by
        // walking layers + Group/Layer children (operands stay opaque), THEN
        // the master store (SYMBOLS.md §6). Including doc.symbols puts master
        // ids in the targetable set so an instance -> master is not dangling,
        // and rdeps[master] lists the master's instances. Masters are walked
        // with the SAME operands-opaque discipline as layers; their OWN id is
        // targetable (a master is reached only through a reference). Sorted by
        // id first for deterministic first-occurrence-wins on the (well-formed:
        // impossible) duplicate-id case.
        var targetable = Set<String>()
        var outEdges: [String: [String]] = [:]
        for layer in doc.layers {
            // Drive the recursive walk on the Layer wrapped as an Element, so a
            // top-level layer's own id is recorded just like Rust's
            // `walk(layer)` over an `Element::Layer`.
            walk(.layer(layer), &targetable, &outEdges)
        }
        let sortedMasters = doc.symbols.sorted { ($0.id ?? "") < ($1.id ?? "") }
        for master in sortedMasters {
            walk(master, &targetable, &outEdges)
        }

        // Phase 2: build `deps` (sorted out-edges) and `rdeps` (reverse), and
        // collect `dangling` (any out-edge target missing from targetable).
        var deps: [String: [String]] = [:]
        var rdeps: [String: [String]] = [:]
        var dangling = Set<String>()

        // Iterate out-edge source ids in sorted order for determinism (Swift
        // dictionary iteration is unordered; Rust's BTreeMap is sorted).
        for id in outEdges.keys.sorted() {
            var sorted = outEdges[id]!.sorted()
            // dedup adjacent (the list is now sorted).
            sorted = dedupSorted(sorted)
            for target in sorted {
                if targetable.contains(target) {
                    // Reverse edge: only targetable ids get an `rdeps` entry, so
                    // an absent / operand-nested target contributes none.
                    rdeps[target, default: []].append(id)
                } else {
                    // Target not in the node walk -> this referencing id is
                    // dangling (absent target, or operand-nested = opaque).
                    dangling.insert(id)
                }
            }
            deps[id] = sorted
        }

        // Normalize rdeps value lists to sorted + deduped.
        for key in rdeps.keys {
            rdeps[key] = dedupSorted(rdeps[key]!.sorted())
        }

        // Phase 3: cycles — every id that can reach itself in the `deps` graph.
        let cycles = findCycleMembers(deps)

        // Phase 4a: the dependencies-first topological ordering (recompute
        // schedule). Computed from the same `deps`/`rdeps` graph; cycle members
        // trail in sorted order. The algorithm is LOCKED across all four apps.
        let topo = computeTopoOrder(deps, rdeps, cycles)

        return DependencyIndex(
            deps: deps,
            rdeps: rdeps,
            dangling: dangling.sorted(),
            cycles: cycles,
            topoOrder: topo
        )
    }
}

// MARK: - Reference-aware delete: orphaned-references predicate
//
// REFERENCE_GRAPH.md — the equivalence-critical core of reference-aware delete
// (the confirm dialog is a later step). A pure graph query over the same by-id
// reference graph the index exposes, so it lives here next to `rdeps`. Mirrors
// Rust `orphaned_references` in `document/dependency_index.rs`.

extension DependencyIndex {
    /// Collect every id-bearing element id within `elem`'s subtree, recursing
    /// into **Group/Layer children only** — the SAME walk discipline as
    /// ``walk(_:_:_:)``: a `CompoundShape`'s operands are opaque (the node walk
    /// never enters them), so an id that exists only inside an operand is not a
    /// node and is not collected. The set de-dups inherently.
    private static func collectIds(_ elem: Element, _ ids: inout Set<String>) {
        if let id = elem.id {
            ids.insert(id)
        }
        switch elem {
        case .group(let g):
            for child in g.children { collectIds(child, &ids) }
        case .layer(let l):
            for child in l.children { collectIds(child, &ids) }
        default:
            break
        }
    }

    /// Answer "if I delete these elements, which live references (instances)
    /// elsewhere would be orphaned — left pointing at a now-deleted target?".
    ///
    /// Returns the **sorted, de-duplicated** ids of references that point at an
    /// id which is being deleted but are not themselves in the deletion set.
    ///
    /// Algorithm (REFERENCE_GRAPH.md, locked semantics):
    /// 1. `deletedIds` — the id-bearing ids within every deletion subtree.
    ///    Each path is resolved via ``Document/tryGetElement(_:)`` (invalid
    ///    paths skipped), then walked with the operands-opaque discipline
    ///    (``collectIds(_:_:)``); an id only inside a `CompoundShape` operand is
    ///    therefore NOT a deleted target.
    /// 2. Build `idx = DependencyIndex.build(doc)`. For each deleted target `t`,
    ///    its referrers are `idx.rdeps[t]` (only **targetable** ids ever get an
    ///    rdeps entry, so an operand-nested target contributes none).
    /// 3. `orphaned = { r in rdeps[t] for all deleted t : r not in deletedIds }`
    ///    — references whose target is being deleted but which survive the delete.
    ///
    /// Consequences: deleting an element with no external referrers returns
    /// `[]`; deleting a target together with its only referrer returns `[]` for
    /// that pair (the referrer is itself deleted); deleting an instance returns
    /// `[]` (an instance has no `rdeps`); deleting a group orphans the external
    /// referrers of any referenced element it contains.
    public static func orphanedReferences(_ doc: Document, _ deletionPaths: [ElementPath]) -> [String] {
        // Step 1: gather the id-bearing ids inside every deletion subtree.
        var deletedIds = Set<String>()
        for path in deletionPaths {
            if let elem = doc.tryGetElement(path) {
                collectIds(elem, &deletedIds)
            }
            // Invalid paths are skipped (no element resolves).
        }

        // Step 2/3: for each deleted target, collect its referrers that are NOT
        // themselves being deleted.
        let idx = DependencyIndex.build(doc)
        var orphaned = Set<String>()
        for t in deletedIds {
            if let referrers = idx.rdeps[t] {
                for r in referrers where !deletedIds.contains(r) {
                    orphaned.insert(r)
                }
            }
        }
        return orphaned.sorted()
    }

    /// The body text for the reference-aware-orphan confirm dialog, given the
    /// orphan count `n` (`= orphanedReferences(...).count`) and the gerund
    /// `verb` naming the action ("Deleting" or "Cutting"). Verbatim wording is
    /// cross-language-pinned so every app's warn dialog reads identically:
    /// `"<Verb> will leave N live instance(s) empty."`. The singular/plural
    /// noun toggles on `n == 1`. Centralized here so the Swift delete call
    /// sites (Edit-menu Delete, keyboard Delete/Backspace, Layers-panel
    /// context-menu Delete) and the cut call site cannot drift in wording.
    public static func orphanWarningBody(_ n: Int, verb: String) -> String {
        "\(verb) will leave \(n) live \(n == 1 ? "instance" : "instances") empty."
    }
}

// MARK: - Node walk

/// Out-edges of a single element: a `Reference`'s target, or empty for every
/// other kind. A compound's `dependencies` is `[]` (its operands are owned), so
/// a compound contributes no out-edges even though it owns id-bearing operands.
private func elementDependencies(_ elem: Element) -> [ElementRef] {
    switch elem {
    case .live(let v):
        // `LiveVariant.dependencies` already returns the reference's target and
        // `[]` for a compound; this is the single source of truth.
        return v.dependencies
    default:
        return []
    }
}

/// Walk `elem` in canonical pre-order, recursing into **Group/Layer children
/// only** (operands are never entered — the operands-opaque rule, matching
/// `RebuildResolver.collect`). Records, for every id-bearing element, its id in
/// `targetable` and its out-edges in `outEdges`.
///
/// First-occurrence-wins on a duplicate id (matches the resolver and the
/// import-time uniqueness invariant; duplicates do not occur in a well-formed
/// document).
private func walk(_ elem: Element,
                  _ targetable: inout Set<String>,
                  _ outEdges: inout [String: [String]]) {
    if let id = elem.id {
        // Insert the node into the targetable set (first occurrence wins).
        let isFirst = targetable.insert(id).inserted
        if isFirst {
            let edges = elementDependencies(elem).map { $0.id }
            if !edges.isEmpty {
                outEdges[id] = edges
            }
        }
    }
    // Recurse into Group/Layer children ONLY — never a compound's operands.
    switch elem {
    case .group(let g):
        for child in g.children { walk(child, &targetable, &outEdges) }
    case .layer(let l):
        for child in l.children { walk(child, &targetable, &outEdges) }
    default:
        break
    }
}

// MARK: - Topological ordering (Phase 4a — LOCKED)

/// Compute the deterministic, **dependencies-first** topological ordering of the
/// by-id reference graph (REFERENCE_GRAPH.md §8 Phase 4a). The recompute
/// schedule a future incremental phase walks: a reference's target always
/// precedes the reference.
///
/// **This algorithm is LOCKED and must be byte-identical across all four apps.**
/// It is the highest cross-language desync risk in this module.
///
/// Kahn's algorithm with SORTED-ID tie-breaking, processed LEVEL-BY-LEVEL:
///
/// - **NODES** = the sorted set of all ids that are a `deps`-key OR an
///   `rdeps`-key (every id that is a source or a *present* target of an edge).
///   Dangling / operand-opaque targets (referenced but not present/targetable,
///   i.e. they appear in `deps` values but are not nodes) are NOT nodes and
///   create NO topo edge.
/// - Each node's **dependency count** = the number of its `deps` targets that
///   ARE nodes (present). Edges to non-node targets are ignored.
/// - Take the WHOLE current ready set (every un-emitted node whose remaining
///   dependency count is 0), emit it in sorted-id order, and decrement the
///   remaining count of every node that depends on an emitted node (its
///   `rdeps`). Nodes freed during this level become ready only for the NEXT
///   level — a node freed by emitting `a` is NOT eligible to slot in before
///   the rest of `a`'s level. (This is what the LOCKED worked example pins:
///   emitting {a,r3,r4} as one level frees r1,r2 for the next level, so the
///   order is a,r3,r4,r1,r2 — NOT a,r1,r2,r3,r4.) Ties ALWAYS by sorted id.
/// - **Cycle remnants:** any nodes that never reach dependency-count 0 are
///   appended at the END in sorted-id order. These are the nodes blocked by a
///   cycle: every cycle member (the `cycles` set) PLUS any node that
///   transitively depends on a cycle (e.g. `tail -> c1` where c1<->c2 — `tail`
///   never frees). `cycles` is therefore a SUBSET of the remnants, not the whole
///   set; the operational rule is "any node that never reaches count 0".
///
/// Result: dependencies before dependents, fully deterministic.
///
/// `deps`/`rdeps`/`cycles` are the already-built (sorted) members of the index.
/// `cycles` is passed (and asserted as a subset of the remnants) for parity with
/// the sibling apps; the remnants themselves are derived from the un-emitted
/// nodes, not from `cycles`.
private func computeTopoOrder(_ deps: [String: [String]],
                              _ rdeps: [String: [String]],
                              _ cycles: [String]) -> [String] {
    // NODES: sorted union of deps-keys and rdeps-keys. A Set de-duplicates;
    // sorting it gives the deterministic node order used throughout.
    var nodeSet = Set<String>()
    for k in deps.keys { nodeSet.insert(k) }
    for k in rdeps.keys { nodeSet.insert(k) }
    let nodes = nodeSet.sorted()

    // Remaining dependency count per node: number of its deps targets that are
    // themselves nodes (present). Non-node (dangling/opaque) targets are ignored.
    var remaining: [String: Int] = [:]
    for node in nodes {
        let count = (deps[node] ?? []).filter { nodeSet.contains($0) }.count
        remaining[node] = count
    }

    var emitted = Set<String>()
    var order: [String] = []
    order.reserveCapacity(nodes.count)

    // Level-by-level Kahn loop. Each pass snapshots the CURRENT ready set (all
    // un-emitted nodes with remaining count 0), emits it in sorted-id order, and
    // only then applies the decrements its emissions cause — so newly-freed
    // nodes wait for the next level. Iterating the sorted `nodes` array yields
    // the ready set already in sorted order. A node blocked by a cycle never
    // reaches count 0, so the loop terminates when no node is ready.
    while true {
        // Snapshot this level's ready set (sorted, since `nodes` is sorted).
        let level = nodes.filter { !emitted.contains($0) && remaining[$0] == 0 }
        if level.isEmpty {
            break  // no node ready -> remaining un-emitted are cyclic
        }
        // Emit the whole level in sorted order, marking each emitted first so
        // decrements below cannot re-add a same-level node.
        for node in level {
            order.append(node)
            emitted.insert(node)
        }
        // Apply this level's decrements AFTER emitting the level, so a node
        // freed now only becomes ready on the NEXT iteration.
        for node in level {
            if let dependents = rdeps[node] {
                for dep in dependents {
                    if let c = remaining[dep] {
                        // Saturating guard: a present dependent always had this
                        // node counted, so c > 0 here; the max(0,...) keeps it
                        // sound even on an (impossible) double-count.
                        remaining[dep] = max(0, c - 1)
                    }
                }
            }
        }
    }

    // Remnants: any node never emitted is blocked by a cycle — either it is ON
    // a cycle (it is in `cycles`) OR it transitively DEPENDS on a cycle and so
    // can never reach count 0 (e.g. `tail -> c1` where c1<->c2). Both kinds are
    // appended at the END in sorted-id order. `cycles` is a SUBSET of these
    // remnants, not necessarily the whole set; we therefore derive the remnants
    // from the un-emitted nodes directly (the operational rule "any node that
    // never reaches dependency-count 0"), which keeps the order deterministic
    // and dependencies-first for the entire acyclic prefix. Iterating the sorted
    // `nodes` array yields the remnants already in sorted-id order.
    assert(cycles.allSatisfy { !emitted.contains($0) },
           "every cycle member must remain un-emitted (a subset of the remnants)")
    for node in nodes where !emitted.contains(node) {
        order.append(node)
    }

    return order
}

// MARK: - Cycle detection

/// Drop adjacent duplicates from a SORTED array.
private func dedupSorted(_ a: [String]) -> [String] {
    var out: [String] = []
    out.reserveCapacity(a.count)
    for x in a where out.last != x { out.append(x) }
    return out
}

/// Return the sorted, de-duplicated set of node ids that lie on a cycle in the
/// `deps` graph (a node that can reach itself).
///
/// Algorithm: a single DFS over the deps edges with **sorted** neighbor
/// iteration (for determinism), tracking the current recursion stack. When an
/// edge reaches a node already on the stack, every node from that node to the
/// top of the stack is a cycle member; they are collected. A self-target
/// (`R -> R`) is detected the same way (the neighbor equals the current node,
/// which is on the stack). Output is sorted and de-duplicated. Edges to
/// non-`deps` ids (leaf or dangling targets) are skipped — they cannot start a
/// cycle. O(V + E) over the deps graph. Mirrors Rust `find_cycle_members`.
private func findCycleMembers(_ deps: [String: [String]]) -> [String] {
    var onCycle = Set<String>()
    var visited = Set<String>()

    // Visit roots in sorted order; each DFS visits in sorted neighbor order
    // (deps values are pre-sorted at build time).
    for start in deps.keys.sorted() where !visited.contains(start) {
        var stack: [String] = []
        dfsCycles(start, deps, &visited, &stack, &onCycle)
    }

    return onCycle.sorted()
}

private func dfsCycles(_ node: String,
                       _ deps: [String: [String]],
                       _ visited: inout Set<String>,
                       _ stack: inout [String],
                       _ onCycle: inout Set<String>) {
    visited.insert(node)
    stack.append(node)

    if let neighbors = deps[node] {
        // `neighbors` is already sorted; iterate it directly for determinism.
        for next in neighbors {
            if let pos = stack.firstIndex(of: next) {
                // Back-edge into the current stack: everything from `pos` to the
                // top of the stack is on this cycle (covers self-target too,
                // where `next == node` and `pos` is the top).
                for member in stack[pos...] { onCycle.insert(member) }
            } else if !visited.contains(next) {
                dfsCycles(next, deps, &visited, &stack, &onCycle)
            }
            // else: already fully explored, not on the current stack -> no cycle
            // reachable through it that we have not already recorded.
        }
    }

    stack.removeLast()
}

// MARK: - Canonical JSON serializer

/// Serialize a ``DependencyIndex`` to canonical JSON: an object with the sorted
/// keys `cycles`, `dangling`, `deps`, `rdeps`, `topo_order`; `deps`/`rdeps` as
/// objects of sorted id keys to sorted id arrays; `cycles`/`dangling` as sorted
/// arrays; `topo_order` as an array IN TOPOLOGICAL ORDER (NOT sorted — its order
/// is the data).
///
/// Byte-identical to what the sibling apps hand-roll (and the
/// `dependency_index.json` fixture). The top-level KEYS appear in alphabetical
/// order (`cycles` < `dangling` < `deps` < `rdeps` < `topo_order`) to match the
/// `JsonObj` sorted-key convention; only the `topo_order` VALUE is unsorted.
/// Deliberately hand-rolled, not `JSONSerialization`: the four sibling apps emit
/// the identical shape and the output must be byte-identical. Mirrors the
/// sorted-keys / `\\`-then-`"` escaping convention of the `JsonObj` builder in
/// `WorkspaceTestJson.swift` (the same pattern as `menuStructureJson`).
public func dependencyIndexToTestJson(_ idx: DependencyIndex) -> String {
    // Keys emitted in sorted (alphabetical) order: cycles, dangling, deps,
    // rdeps, topo_order. Only topo_order's array value is non-sorted (it is the
    // topological sequence itself).
    "{\"cycles\":\(arrayJson(idx.cycles)),"
        + "\"dangling\":\(arrayJson(idx.dangling)),"
        + "\"deps\":\(mapJson(idx.deps)),"
        + "\"rdeps\":\(mapJson(idx.rdeps)),"
        + "\"topo_order\":\(arrayJson(idx.topoOrder))}"
}

/// Escape a string for embedding in a canonical-JSON string literal. Matches
/// `WorkspaceTestJson.swift`'s `JsonObj.str` (backslash then double-quote).
private func escapeJson(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Render a string array verbatim (preserving the input's order). Used for the
/// already-sorted `cycles`/`dangling` arrays AND for `topoOrder`, whose order is
/// deliberately the topological sequence (NOT sorted) — its order is the data,
/// so it must be rendered as-is.
private func arrayJson(_ v: [String]) -> String {
    let items = v.map { "\"\(escapeJson($0))\"" }
    return "[\(items.joined(separator: ","))]"
}

/// Render `{id: [sorted ids]}` with keys sorted and value lists already sorted.
private func mapJson(_ m: [String: [String]]) -> String {
    let entries = m.keys.sorted().map { k -> String in
        let items = m[k]!.map { "\"\(escapeJson($0))\"" }
        return "\"\(escapeJson(k))\":[\(items.joined(separator: ","))]"
    }
    return "{\(entries.joined(separator: ","))}"
}
