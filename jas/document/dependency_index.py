"""Derived DEPENDENCY INDEX over the by-id reference graph
(REFERENCE_GRAPH.md §3 — Phase 3 graph structure).

A **pure function of the** ``Document``: it carries no authoritative state,
is never stored on the ``Model``, never serialized into the document codecs,
and never compared. It is rebuilt on demand (the Phase 1-3 strategy per
REFERENCE_GRAPH.md §2.4); no consumer caches it yet.

It exposes, for the **by-id reference graph only**:

- ``deps``       -- ``id -> sorted list of target ids it directly references``
- ``rdeps``      -- ``id -> sorted list of ids that reference it`` (reverse of deps)
- ``dangling``   -- sorted list of *referencing* ids whose target id is not
                    present/targetable
- ``cycles``     -- sorted list of ids that participate in a cycle
- ``topo_order`` -- a deterministic topological ordering (dependencies-first) of
                    the by-id graph; the only intentionally-non-sorted output

## Operands are OPAQUE to the by-id graph (locked design)

The node walk recurses into Group/Layer children **only**, never into a
``CompoundShape``'s operands. Per REFERENCE_GRAPH.md a compound's operands are
*owned* (they appear under ``operands``, not ``children``), and
``CompoundShape.dependencies()`` is ``[]``. So the **targetable set** of ids is
exactly the ids found by walking ``layers + Group/Layer children`` -- *not*
operand-nested ids. This mirrors the render-time resolver
(``geometry.live._collect_ref_ids``), which likewise recurses only via the
``children`` attribute (which only Group/Layer have), never into operands. A
reference whose target is an operand-nested id is therefore **dangling** (it is
not in the targetable set) -- this is what pins the operands-opaque decision.

## Determinism

Every map is built with explicitly sorted keys and every value list is sorted,
so the output is inherently ordered. The cycle DFS iterates neighbors in
**sorted** order. No part of the output relies on dict insertion order.

## ``topo_order`` (Phase 4a -- REFERENCE_GRAPH.md §8)

A deterministic, dependencies-first topological ordering of the by-id graph,
computed by Kahn's algorithm with sorted-id tie-breaking (see
:func:`_topo_order`). It is the recompute schedule a future incremental phase
(P4c) will walk. The ordering is the *only* intentionally-non-sorted output:
its sequence IS the data. The ALGORITHM IS LOCKED and must be byte-identical
across all four apps -- it is the highest cross-language desync risk here.

## Deferred (NOT implemented here)

- **Write-time cycle rejection** -- no authoring op can form a cycle yet
  (``create_reference`` only links to an existing target), and eval-time
  cycle-break (the threaded visited-set in ``geometry.live``) already handles
  imported cycles. A write-time guard is an additive Phase-3+ nicety.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from document.document import Document
    from geometry.element import Element


@dataclass(frozen=True)
class DependencyIndex:
    """The derived dependency index of a ``Document``'s by-id reference graph.

    All maps and lists are built sorted so the structure serializes
    deterministically. Rebuilt on demand via :func:`dependency_index` /
    :meth:`DependencyIndex.build`; never stored or compared. Mirrors the Rust
    ``DependencyIndex`` struct.
    """

    # id -> sorted list of target ids it directly references (out-edges).
    # Only id-bearing elements with non-empty dependencies() appear.
    deps: dict[str, list[str]] = field(default_factory=dict)
    # id -> sorted list of ids that reference it (in-edges; reverse of deps).
    # Only *targetable* ids (present in the node walk) appear, so a reference to
    # an absent or operand-nested id contributes no rdeps entry.
    rdeps: dict[str, list[str]] = field(default_factory=dict)
    # Sorted list of *referencing* ids at least one of whose dependencies()
    # targets is not in the targetable set (absent, or operand-opaque).
    dangling: list[str] = field(default_factory=list)
    # Sorted, de-duplicated list of ids that lie on a cycle in the deps graph
    # (a node that can reach itself). A self-target (R -> R) is a cycle.
    cycles: list[str] = field(default_factory=list)
    # A deterministic topological ordering of the by-id graph,
    # **dependencies-first** (a reference's target precedes the reference).
    # Computed by Kahn's algorithm with sorted-id tie-breaking; cycle members
    # (== `cycles`) are appended at the end in sorted-id order. This is the ONLY
    # field whose order is NOT alphabetical -- its sequence IS the data (the
    # recompute schedule). The algorithm is LOCKED; see :func:`_topo_order`.
    topo_order: list[str] = field(default_factory=list)

    @staticmethod
    def build(doc: "Document") -> "DependencyIndex":
        """Build the dependency index for ``doc``. Alias for
        :func:`dependency_index`."""
        return dependency_index(doc)


def _element_dependencies(elem: "Element") -> list[str]:
    """Out-edges of a single element: a Reference's target, or empty for every
    other kind. ``CompoundShape.dependencies()`` is ``[]`` (its operands are
    owned), so a compound contributes no out-edges even though it owns
    id-bearing operands. Every element exposes ``dependencies()`` via the
    ``LiveElement`` base default, so a plain ``getattr`` fallback keeps
    non-Live elements (which lack the method) edge-free."""
    deps_fn = getattr(elem, "dependencies", None)
    if deps_fn is None:
        return []
    return list(deps_fn())


def _walk(
    elem: "Element",
    targetable: set[str],
    out_edges: dict[str, list[str]],
) -> None:
    """Walk ``elem`` in canonical pre-order, recursing into **Group/Layer
    children only** (operands live under a separately-named ``operands`` field
    and are never entered -- the operands-opaque rule). Records, for every
    id-bearing element, its id in ``targetable`` and its out-edges in
    ``out_edges``.

    First-occurrence-wins on a duplicate id (matches the resolver and the
    import-time uniqueness invariant; duplicates do not occur in a well-formed
    document)."""
    eid = getattr(elem, "id", None)
    if eid is not None:
        # Insert the node into the targetable set (first occurrence wins).
        if eid not in targetable:
            targetable.add(eid)
            edges = _element_dependencies(elem)
            if edges:
                out_edges[eid] = edges
    # Only Group/Layer expose a `children` attribute; CompoundShape's operands
    # live under `operands`, so they are never walked (operands-opaque).
    children = getattr(elem, "children", None)
    if children is not None:
        for child in children:
            _walk(child, targetable, out_edges)


def dependency_index(doc: "Document") -> DependencyIndex:
    """Build the :class:`DependencyIndex` for ``doc``. A pure, allocation-only
    function; no document state is mutated. See the module docs for the locked
    semantics. Mirrors the Rust ``dependency_index``."""
    # Phase 1: gather the node set (targetable ids) and raw out-edges by walking
    # layers + Group/Layer children (operands stay opaque), THEN the master
    # store (SYMBOLS.md §6). Including doc.symbols puts master ids in the
    # targetable set so an instance -> master is not dangling, and
    # rdeps[master] lists the master's instances. Masters are walked with the
    # SAME operands-opaque discipline as layers; their OWN id is targetable (a
    # master is reached only through a reference). Sorted by id first for
    # deterministic first-occurrence-wins on the (well-formed: impossible)
    # duplicate-id case.
    targetable: set[str] = set()
    out_edges: dict[str, list[str]] = {}
    for layer in doc.layers:
        _walk(layer, targetable, out_edges)
    sorted_masters = sorted(
        doc.symbols, key=lambda m: getattr(m, "id", None) or "")
    for master in sorted_masters:
        _walk(master, targetable, out_edges)

    # Phase 2: build deps (sorted out-edges) and rdeps (reverse), and collect
    # dangling (any out-edge target missing from the targetable set).
    deps: dict[str, list[str]] = {}
    rdeps: dict[str, list[str]] = {}
    dangling: set[str] = set()

    # Iterate out_edges by sorted id for determinism (rdeps value lists are
    # appended in this order, then re-sorted below regardless).
    for eid in sorted(out_edges.keys()):
        edges = sorted(set(out_edges[eid]))
        for target in edges:
            if target in targetable:
                # Reverse edge: only targetable ids get an rdeps entry, so an
                # absent / operand-nested target contributes none.
                rdeps.setdefault(target, []).append(eid)
            else:
                # Target not in the node walk -> this referencing id is dangling
                # (absent target, or operand-nested = operands-opaque).
                dangling.add(eid)
        deps[eid] = edges

    # Normalize rdeps value lists to sorted + deduped.
    rdeps = {
        k: sorted(set(v))
        for k, v in sorted(rdeps.items())
    }

    # Phase 3: cycles -- every id that can reach itself in the deps graph.
    cycles = _find_cycle_members(deps)

    # Phase 4a: the dependencies-first topological ordering (recompute schedule).
    # Computed from the same deps/rdeps graph; cycle members trail in sorted
    # order. The algorithm is LOCKED across all four apps.
    topo = _topo_order(deps, rdeps, cycles)

    return DependencyIndex(
        deps=deps,
        rdeps=rdeps,
        dangling=sorted(dangling),
        cycles=cycles,
        topo_order=topo,
    )


def _topo_order(
    deps: dict[str, list[str]],
    rdeps: dict[str, list[str]],
    cycles: list[str],
) -> list[str]:
    """Compute the deterministic, **dependencies-first** topological ordering of
    the by-id reference graph (REFERENCE_GRAPH.md §8 Phase 4a). The recompute
    schedule a future incremental phase walks: a reference's target always
    precedes the reference.

    **This algorithm is LOCKED and must be byte-identical across all four apps.**
    It is the highest cross-language desync risk in this module.

    Kahn's algorithm with SORTED-ID tie-breaking, processed LEVEL-BY-LEVEL:

    - **NODES** = the sorted set of all ids that are a ``deps``-key OR an
      ``rdeps``-key (every id that is a source or a *present* target of an edge).
      Dangling / operand-opaque targets (referenced but not present/targetable,
      i.e. they appear in ``deps`` values but are not nodes) are NOT nodes and
      create NO topo edge.
    - Each node's **dependency count** = the number of its ``deps`` targets that
      ARE nodes (present). Edges to non-node targets are ignored.
    - Take the WHOLE current ready set (every un-emitted node whose remaining
      dependency count is 0), emit it in sorted-id order, and decrement the
      remaining count of every node that depends on an emitted node (its
      ``rdeps``). Nodes freed during this level become ready only for the NEXT
      level -- a node freed by emitting ``a`` is NOT eligible to slot in before
      the rest of ``a``'s level. (This is what the LOCKED worked example pins:
      emitting {a,r3,r4} as one level frees r1,r2 for the next level, so the
      order is a,r3,r4,r1,r2 -- NOT a,r1,r2,r3,r4.) Ties ALWAYS by sorted id.
    - **Cycle remnants:** any nodes that never reach dependency-count 0 are
      appended at the END in sorted-id order. These are the nodes blocked by a
      cycle: every cycle member (the ``cycles`` set) PLUS any node that
      transitively depends on a cycle (e.g. ``tail -> c1`` where c1<->c2 --
      ``tail`` never frees). ``cycles`` is therefore a SUBSET of the remnants,
      not the whole set; the operational rule is "any node that never reaches
      count 0".

    Result: dependencies before dependents, fully deterministic.

    ``deps``/``rdeps``/``cycles`` are the already-built (sorted) members of the
    index. Mirrors the Rust ``topo_order``."""
    # NODES: sorted union of deps-keys and rdeps-keys. A sorted set keeps
    # iteration deterministic and de-duplicated.
    nodes_set: set[str] = set(deps.keys()) | set(rdeps.keys())
    nodes: list[str] = sorted(nodes_set)

    # Remaining dependency count per node: number of its deps targets that are
    # themselves nodes (present). Non-node (dangling/opaque) targets are ignored.
    remaining: dict[str, int] = {}
    for node in nodes:
        targets = deps.get(node, [])
        remaining[node] = sum(1 for t in targets if t in nodes_set)

    emitted: set[str] = set()
    order: list[str] = []

    # Level-by-level Kahn loop. Each pass snapshots the CURRENT ready set (all
    # un-emitted nodes with remaining count 0), emits it in sorted-id order, and
    # only then applies the decrements its emissions cause -- so newly-freed
    # nodes wait for the next level. Iterating the sorted `nodes` list yields the
    # ready set already in sorted order. A node blocked by a cycle never reaches
    # count 0, so the loop terminates when no node is ready.
    while True:
        # Snapshot this level's ready set (sorted, since `nodes` is sorted).
        level = [
            n for n in nodes
            if n not in emitted and remaining.get(n) == 0
        ]
        if not level:
            break  # no node ready -> remaining un-emitted are cyclic
        # Emit the whole level in sorted order, marking each emitted first so
        # decrements below cannot re-add a same-level node.
        for node in level:
            order.append(node)
            emitted.add(node)
        # Apply this level's decrements AFTER emitting the level, so a node
        # freed now only becomes ready on the NEXT iteration.
        for node in level:
            dependents = rdeps.get(node)
            if dependents is not None:
                for dep in dependents:
                    if dep in remaining:
                        # A present dependent always had this node counted, so
                        # the count is > 0 here; the max(0, ...) guard keeps it
                        # sound even on a (impossible) double-count.
                        remaining[dep] = max(0, remaining[dep] - 1)

    # Remnants: any node never emitted is blocked by a cycle -- either it is ON
    # a cycle (it is in `cycles`) OR it transitively DEPENDS on a cycle and so
    # can never reach count 0 (e.g. `tail -> c1` where c1<->c2). Both kinds are
    # appended at the END in sorted-id order. `cycles` is a SUBSET of these
    # remnants, not necessarily the whole set; we therefore derive the remnants
    # from the un-emitted nodes directly (the operational rule "any node that
    # never reaches dependency-count 0"), which keeps the order deterministic and
    # dependencies-first for the entire acyclic prefix. Iterating the sorted
    # `nodes` list yields the remnants already in sorted-id order.
    assert all(c not in emitted for c in cycles), (
        "every cycle member must remain un-emitted (a subset of the remnants)")
    for node in nodes:
        if node not in emitted:
            order.append(node)

    return order


def _find_cycle_members(deps: dict[str, list[str]]) -> list[str]:
    """Return the sorted, de-duplicated set of node ids that lie on a cycle in
    the deps graph (a node that can reach itself).

    Algorithm: a single DFS over the deps edges with **sorted** neighbor
    iteration (for determinism), tracking the current recursion stack. When an
    edge reaches a node already on the stack, every node from that node to the
    top of the stack is a cycle member; they are collected. A self-target
    (R -> R) is detected the same way (the neighbor equals the current node,
    which is on the stack). Edges to non-deps ids (leaf or dangling targets) are
    skipped -- they cannot start a cycle. Mirrors the Rust
    ``find_cycle_members``."""
    on_cycle: set[str] = set()
    visited: set[str] = set()

    # Iterate roots in sorted order; each DFS visits in sorted neighbor order
    # (deps values are pre-sorted in dependency_index).
    for start in sorted(deps.keys()):
        if start not in visited:
            stack: list[str] = []
            _dfs_cycles(start, deps, visited, stack, on_cycle)

    return sorted(on_cycle)


def _dfs_cycles(
    node: str,
    deps: dict[str, list[str]],
    visited: set[str],
    stack: list[str],
    on_cycle: set[str],
) -> None:
    visited.add(node)
    stack.append(node)

    neighbors = deps.get(node)
    if neighbors is not None:
        # `neighbors` is already sorted; iterate it directly for determinism.
        for nxt in neighbors:
            if nxt in stack:
                # Back-edge into the current stack: everything from `nxt` to the
                # top of the stack is on this cycle (covers self-target too,
                # where `nxt == node` and it is the top of the stack).
                pos = stack.index(nxt)
                for member in stack[pos:]:
                    on_cycle.add(member)
            elif nxt not in visited:
                _dfs_cycles(nxt, deps, visited, stack, on_cycle)
            # else: already fully explored, not on the current stack -> no cycle
            # reachable through it that we have not already recorded.

    stack.pop()


# --------------------------------------------------------------------------- #
# Reference-aware delete: orphaned-references predicate                         #
# --------------------------------------------------------------------------- #
#
# REFERENCE_GRAPH.md -- the equivalence-critical core of reference-aware delete
# (the confirm dialog is a later step). A pure graph query over the same by-id
# reference graph the index exposes, so it lives here next to ``rdeps``.


def _collect_ids(elem: "Element", ids: set[str]) -> None:
    """Collect every id-bearing element id within ``elem``'s subtree, recursing
    into **Group/Layer children only** -- the SAME walk discipline as
    :func:`_walk`: a ``CompoundShape``'s operands are opaque (only Group/Layer
    expose a ``children`` attribute; operands live under ``operands`` and are
    never entered), so an id that exists only inside an operand is not a node and
    is not collected. The set de-dups inherently (first occurrence still
    inserts it)."""
    eid = getattr(elem, "id", None)
    if eid is not None:
        ids.add(eid)
    children = getattr(elem, "children", None)
    if children is not None:
        for child in children:
            _collect_ids(child, ids)


def orphaned_references(
    doc: "Document", deletion_paths: list[list[int]]
) -> list[str]:
    """Answer "if I delete these elements, which live references (instances)
    elsewhere would be orphaned -- left pointing at a now-deleted target?".

    Returns the **sorted, de-duplicated** ids of references that point at an id
    which is being deleted but are not themselves in the deletion set.

    Algorithm (REFERENCE_GRAPH.md, locked semantics):

    1. ``deleted_ids`` -- the id-bearing ids within every deletion subtree.
       Each path is resolved via ``doc.get_element`` (invalid paths skipped --
       ``get_element`` raises on an out-of-range / non-Group path), then walked
       with the operands-opaque discipline (:func:`_collect_ids`); an id only
       inside a ``CompoundShape`` operand is therefore NOT a deleted target.
    2. Build ``idx = dependency_index(doc)``. For each deleted target ``t``, its
       referrers are ``idx.rdeps[t]`` (only *targetable* ids ever get an rdeps
       entry, so an operand-nested target contributes none).
    3. ``orphaned = { r in rdeps[t] for all deleted t : r not in deleted_ids }``
       -- references whose target is being deleted but which survive the delete.

    Consequences: deleting an element with no external referrers returns ``[]``;
    deleting a target together with its only referrer returns ``[]`` for that
    pair (the referrer is itself deleted); deleting an instance returns ``[]``
    (an instance has no ``rdeps``); deleting a group orphans the external
    referrers of any referenced element it contains. Mirrors the Rust
    ``orphaned_references``."""
    # Step 1: gather the id-bearing ids inside every deletion subtree.
    deleted_ids: set[str] = set()
    for path in deletion_paths:
        try:
            elem = doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            # Invalid paths are skipped (no element resolves).
            continue
        _collect_ids(elem, deleted_ids)

    # Step 2/3: for each deleted target, collect its referrers that are NOT
    # themselves being deleted.
    idx = dependency_index(doc)
    orphaned: set[str] = set()
    for t in deleted_ids:
        referrers = idx.rdeps.get(t)
        if referrers is not None:
            for r in referrers:
                if r not in deleted_ids:
                    orphaned.add(r)
    return sorted(orphaned)


# --------------------------------------------------------------------------- #
# Canonical JSON serializer                                                    #
# --------------------------------------------------------------------------- #
#
# Mirrors the hand-rolled canonical-JSON pattern used by
# `workspace.workspace_test_json._JsonObj` (sorted keys, sorted arrays).
# Deliberately NOT `json.dumps`: the five sibling apps hand-roll the identical
# shape, and the output must be byte-identical. There are no floats here, but
# the object/array/string-escape conventions match the _JsonObj serializer
# exactly (compact, sorted keys, `\\` then `\"` escaped).


def _escape(s: str) -> str:
    """Escape a string for embedding in a canonical-JSON string literal.
    Matches ``_JsonObj.str`` (backslash then double-quote)."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _map_json(m: dict[str, list[str]]) -> str:
    """Render ``{id: [sorted ids]}`` with sorted keys and sorted value lists."""
    entries = []
    for k in sorted(m.keys()):
        items = ",".join(f'"{_escape(s)}"' for s in m[k])
        entries.append(f'"{_escape(k)}":[{items}]')
    return "{" + ",".join(entries) + "}"


def _array_json(v: list[str]) -> str:
    """Render a string array verbatim (preserving the input list's order). Used
    for the already-sorted ``cycles``/``dangling`` arrays AND for ``topo_order``,
    whose order is deliberately the topological sequence (NOT sorted) -- its
    order is the data, so it must be rendered as-is."""
    items = ",".join(f'"{_escape(s)}"' for s in v)
    return "[" + items + "]"


def dependency_index_to_test_json(idx: DependencyIndex) -> str:
    """Serialize a :class:`DependencyIndex` to canonical JSON: an object with
    the sorted keys ``cycles``, ``dangling``, ``deps``, ``rdeps``,
    ``topo_order``; ``deps``/``rdeps`` as objects of sorted id keys to sorted id
    arrays; ``cycles``/``dangling`` as sorted arrays; ``topo_order`` as an array
    IN TOPOLOGICAL ORDER (NOT sorted -- its order is the data).

    Byte-identical to what the sibling apps hand-roll (and the
    ``dependency_index.json`` fixture). The top-level KEYS appear in alphabetical
    order (``cycles`` < ``dangling`` < ``deps`` < ``rdeps`` < ``topo_order``) to
    match the ``_JsonObj`` sorted-key convention; only the ``topo_order`` VALUE
    is unsorted. Mirrors the Rust ``dependency_index_to_test_json``."""
    return (
        "{"
        f'"cycles":{_array_json(idx.cycles)},'
        f'"dangling":{_array_json(idx.dangling)},'
        f'"deps":{_map_json(idx.deps)},'
        f'"rdeps":{_map_json(idx.rdeps)},'
        f'"topo_order":{_array_json(idx.topo_order)}'
        "}"
    )


# Prevent pytest from collecting the public builders as tests (they start
# with neither `test_` nor are test functions, but the json helper is safe).
dependency_index_to_test_json.__test__ = False  # type: ignore[attr-defined]
