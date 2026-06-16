(** Derived DEPENDENCY INDEX over the by-id reference graph
    (REFERENCE_GRAPH.md section 3 — Phase 3 graph structure).

    A {b pure function of the [Document]}: it carries no authoritative
    state, is never stored on the [Model], never serialized into a
    document codec, and never compared. It is rebuilt on demand (the
    Phase 1-3 strategy per REFERENCE_GRAPH.md section 2.4); no consumer
    caches it yet.

    It exposes, for the {b by-id reference graph only}:

    - [deps]     — id to the sorted list of target ids it directly references
    - [rdeps]    — id to the sorted list of ids that reference it (reverse of deps)
    - [dangling] — sorted list of {i referencing} ids whose target id is not
                   present in the targetable set (absent, or operand-nested)
    - [cycles]   — sorted list of ids that participate in a cycle

    {2 Operands are OPAQUE to the by-id graph (locked design)}

    The node walk recurses into Group / Layer children {b only}, never
    into a [Compound_shape]'s operands. A compound's operands are owned
    ([Live.dependencies] is empty for a compound), so the {b targetable
    set} of ids is exactly the ids found by walking
    [layers + Group/Layer children] — {i not} operand-nested ids. This
    mirrors the render resolver ([Live.resolver_children], which likewise
    does not recurse into operands). A reference whose target is an
    operand-nested id is therefore {b dangling}.

    {2 Determinism}

    Every map is keyed and iterated in sorted order and every value list
    is sorted, so the output is inherently ordered. The cycle DFS
    iterates neighbors in {b sorted} order. No part of the output relies
    on hash-table iteration order.

    {2 Deferred (NOT implemented here)}

    - [topo_order] — the Phase 4 recompute ordering (a topological sort
      of the deps DAG, with cycles broken). Deferred until a consumer
      needs a recompute schedule.
    - Write-time cycle rejection — no authoring op can form a cycle yet
      ([create_reference] only links to an existing target), and the
      eval-time cycle-break (the threaded visit set in [Live]) already
      handles imported cycles. A write-time guard is an additive
      Phase-3+ nicety. *)

(** The derived dependency index of a [Document]'s by-id reference graph.
    All maps and lists are sorted so the structure serializes
    deterministically. Rebuilt on demand via {!build}; never stored or
    compared. *)
type t = {
  deps : (string * string list) list;
    (** [id -> sorted list of target ids it directly references]
        (out-edges), sorted by id. Only id-bearing elements with a
        non-empty dependency list appear. *)
  rdeps : (string * string list) list;
    (** [id -> sorted list of ids that reference it] (in-edges; reverse
        of [deps]), sorted by id. Only {b targetable} ids appear, so a
        reference to an absent or operand-nested id contributes no
        [rdeps] entry. *)
  dangling : string list;
    (** Sorted list of {i referencing} ids at least one of whose
        dependency targets is not in the targetable set (absent, or
        operand-opaque). *)
  cycles : string list;
    (** Sorted, de-duplicated list of ids that lie on a cycle in the
        [deps] graph (a node that can reach itself). A self-target
        ([R -> R]) is a cycle. *)
}

(** Build the dependency index for [doc]. A pure, allocation-only
    function; no document state is mutated. *)
val build : Document.document -> t

(** Serialize a {!t} to canonical JSON: an object with the sorted keys
    [cycles], [dangling], [deps], [rdeps]; [deps] / [rdeps] as objects of
    sorted id keys to sorted id arrays; [cycles] / [dangling] as sorted
    arrays. Byte-identical to what the sibling apps hand-roll (and the
    [dependency_index.json] fixture). *)
val to_test_json : t -> string

(** Reference-aware delete: answer "if I delete the elements at these
    paths, which live references elsewhere would be orphaned — left
    pointing at a now-deleted target?".

    Returns the {b sorted, de-duplicated} ids of references that point at
    an id which is being deleted but are not themselves in the deletion
    set. A pure graph query over the same by-id reference graph {!build}
    exposes (REFERENCE_GRAPH.md, locked semantics):

    + Collect the id-bearing ids within every deletion subtree, recursing
      into Group / Layer children {b only} (a [Compound_shape]'s operands
      are opaque, the SAME discipline as the index walk), so an id only
      inside an operand is NOT a deleted target. Each path is resolved via
      {!Document.get_element}; an invalid / not-found path is skipped.
    + Build the index. For each deleted target [t], its referrers are
      [rdeps[t]] (only targetable ids get an [rdeps] entry).
    + Keep the referrers that are not themselves being deleted.

    Consequences: deleting an element with no external referrers returns
    [[]]; deleting a target together with its only referrer returns [[]]
    for that pair; deleting an instance returns [[]] (an instance has no
    [rdeps]); deleting a group orphans the external referrers of any
    referenced element it contains. *)
val orphaned_references : Document.document -> int list list -> string list
