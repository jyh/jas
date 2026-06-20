(** LiveElement framework helpers.

    Evaluates [Element.compound_shape] operand trees through the
    boolean algorithm, computes bounds of the result, and installs the
    [Element.live_bounds_hook] at module init time. See
    [transcripts/BOOLEAN.md] § Live element framework. *)

(** Default geometric tolerance in points. Matches the Precision
    default in the Boolean Options dialog. Equals 0.01 mm. *)
val default_precision : float

(** Resolves a stable element id to the element it currently names.
    Lets the geometry layer evaluate by-id references without depending
    on Model / Document. See REFERENCE_GRAPH.md section 2.1. *)
type element_resolver = Element.element_ref -> Element.element option

(** A resolver that resolves nothing. Used on the resolver-unaware call
    paths so existing geometry behavior is unchanged: a reference
    resolved through it is treated as dangling. *)
val null_resolver : element_resolver

(** Resolves a concept pack id to its generator — a closure from the instance's
    parameters (a JSON object) to the generated [x,y] point list. Built by a
    layer that has the expression evaluator + workspace registry, so the
    geometry layer stays decoupled from both (CONCEPTS.md). The OCaml analogue
    of Rust's [resolver.resolve_concept] + [expr::eval]. *)
type concept_resolver = string -> (Yojson.Safe.t -> (float * float) list) option

(** A concept resolver that resolves nothing (Generated -> empty geometry). *)
val null_concept_resolver : concept_resolver

(** The cycle-guard set threaded through evaluation. Carried as an
    explicit parameter so all five apps break reference cycles
    identically (REFERENCE_GRAPH.md section 3). *)
module VisitSet : Set.S with type elt = string

(** Stable-id inputs reached by reference rather than containment, in
    deterministic order. Empty for [Compound_shape] (its inputs are
    owned operands); the referenced target for [Reference]. *)
val dependencies : Element.live_variant -> Element.element_ref list

(** The persistent map backing the id->element index: a [Map.Make(String)]
    keyed by [Element.element_ref]. Exposed so callers (the Model gate) can
    compare two indices by value via {!Id_map.equal}. *)
module Id_map : Map.S with type key = string

(** Persistent id->element index (REFERENCE_GRAPH.md section 2.4, Phase
    4b). A pure function of the document, carried on the Model paired with
    the snapshot so paint reads it without rebuilding and undo carries it in
    O(1) (structure sharing). Sorted, O(log n) lookup. Mirrors the Rust
    [IdIndex]; per section 2.3 apps may differ in the persistent-map type. *)
type id_index = Element.element Id_map.t

(** Build the persistent id->element index from a document's [layers] and
    [symbols]. The SINGLE canonical walk (section 2.3): both the live-index
    builder and the gate oracle, so its values are bit-identical to the old
    per-paint rebuild and resolve() results are unchanged. Layers are
    indexed at each layer's children (top-level layer ids are not Phase-1
    targets); each master is indexed directly (its own id is a target),
    masters sorted by id first. First-occurrence wins per id. Mirrors Rust
    [rebuild_id_index]. *)
val rebuild_id_index :
  Element.element array -> Element.element array -> id_index

(** Build an [element_resolver] that reads an already-built persistent
    index (an O(1) borrow; no rebuild). The hot paint path passes the
    Model's companion index here. Mirrors the Rust [RenderResolver]. *)
val resolver_of_index : id_index -> element_resolver

(** Build an [element_resolver] from a document's top-level layers.
    Indexes the id-bearing descendants of each layer (top-level layer
    ids are not Phase-1 resolution targets, so the walk starts at each
    layer's children). First-occurrence wins per id. Equivalent to
    [resolver_of_index (rebuild_id_index layers [||])]. Mirrors Rust
    [register_ref_index]. See REFERENCE_GRAPH.md Phase 1b. *)
val resolver_of_document : Element.element array -> element_resolver

(** Build an [element_resolver] spanning a document's [layers] AND its
    off-canvas master store [symbols] (SYMBOLS.md section 2) by rebuilding
    the index from scratch. Layers are indexed as in {!resolver_of_document}
    (descendants only); each master is indexed directly (its OWN id is a
    valid target, since a master is reached only through a reference).
    Masters are sorted by id first so a duplicate-id master resolves
    deterministically. Equivalent to [resolver_of_index (rebuild_id_index
    layers symbols)]; the hot paint path uses {!resolver_of_index} with the
    Model's persistent index instead. *)
val resolver_of_layers_and_symbols :
  Element.element array -> Element.element array -> element_resolver

(** Ring-aware path flattening. MoveTo starts a new ring; ClosePath
    finalizes. Open subpaths finalize at the next MoveTo or end.
    Rings with fewer than 3 points are dropped. Bezier / quad use
    20 steps; Smooth / Arc approximate as a line to the endpoint.

    Exposed so [Path_ops] can bridge [Element.path_command] lists
    into the boolean module's [polygon_set] shape — see
    BLOB_BRUSH_TOOL.md Commit pipeline. *)
val flatten_path_to_rings :
  Element.path_command list -> Boolean.polygon_set

(** Flatten a document element into a polygon set for the boolean
    algorithm. See BOOLEAN.md § Geometry and precision for per-kind
    handling. Resolves no references (passes [null_resolver]). *)
val element_to_polygon_set :
  Element.element -> float -> Boolean.polygon_set

(** Resolver-aware flattening. Identical to [element_to_polygon_set]
    except by-id references resolve through the resolver, with the visit
    set breaking cycles. *)
val element_to_polygon_set_with :
  ?concept_resolver:concept_resolver ->
  Element.element -> float -> element_resolver ->
  VisitSet.t ref -> Boolean.polygon_set

(** Dispatch a boolean operation across an arbitrary number of
    operands. See BOOLEAN.md § Operand and paint rules. *)
val apply_operation :
  Element.compound_operation ->
  Boolean.polygon_set list ->
  Boolean.polygon_set

(** Tight bounding box of a polygon set. Returns (0, 0, 0, 0) for
    empty input. *)
val bounds_of_polygon_set :
  Boolean.polygon_set -> float * float * float * float

(** Evaluate a compound shape's operand tree through the boolean
    algorithm at the given precision. Resolves no references. *)
val evaluate :
  Element.compound_shape -> float -> Boolean.polygon_set

(** Resolver-aware evaluation of a compound shape. Threads the resolver
    and cycle-guard set so a referenced operand resolves through the
    resolver. *)
val evaluate_with :
  Element.compound_shape -> float -> element_resolver ->
  VisitSet.t ref -> Boolean.polygon_set

(** Resolver-aware evaluation of a reference: resolve the target and
    return its geometry. A cycle (target already being visited) or a
    dangling reference (unresolved) yields an empty set — never a
    failure (REFERENCE_GRAPH.md section 3). *)
val reference_evaluate :
  Element.reference_elem -> float -> element_resolver ->
  VisitSet.t ref -> Boolean.polygon_set

(** Resolver-aware replay of a recorded element: resolve each input by
    stable id, replay the recipe (copy / translate) against them, and
    return the derived output geometry. A dangling input or a cycle yields
    an empty set — never a failure (RECORDED_ELEMENTS.md). Mirrors Rust
    [RecordedElem::evaluate_with]. *)
val recorded_evaluate :
  Element.recorded_elem -> float -> element_resolver ->
  VisitSet.t ref -> Boolean.polygon_set

(** Resolver-aware evaluation of a generated (concept-instance) element:
    resolve the concept's generator via [concept_resolver], run it over the
    instance parameters, and return the resulting ring (empty if unresolved or
    fewer than two points). Mirrors Rust [GeneratedElem::evaluate_with]. *)
val generated_evaluate :
  Element.generated_elem -> float -> concept_resolver -> Boolean.polygon_set

(** Normalize a captured journal op-segment into a recorded recipe
    (RECORDED_ELEMENTS.md section 1 / section 4): rewrite selection-relative
    ops (select_rect / copy_selection / move_selection) into the
    input-addressed form, tracking the working selection. Returns
    [(recipe, input_ids)] — the normalized ops and the distinct non-[$]
    refs the recipe rebinds, in first-seen order. Mirrors Rust
    [capture_recipe]. *)
val capture_recipe :
  Element.recorded_op list -> Element.recorded_op list * string list

(** Phase 4c reference-geometry recompute cache (REFERENCE_GRAPH.md section
    2.3 — a PER-APP perf cache; equivalence is pinned on resolve() RESULTS,
    which it never alters, gated by an [assert (cached = fresh)] on every hit).
    Generation-epoch the cache: clears every entry when [generation] differs
    from the current epoch. Called at the paint entry with [Model#generation]
    (bumped on every mutation / undo / redo). *)
val set_recompute_cache_generation : int -> unit

(** True iff the element's owned subtree contains a Reference anywhere (the
    purity test that decides whether a target's geometry may be cached).
    Exposed for the Phase-4c tests. *)
val subtree_has_reference : Element.element -> bool

(** Observable recompute-cache state for a [(target_id, precision)] slot. *)
type recompute_cache_state = Pure_state | Has_refs_state

(** Test/introspection: the cache state for [(target_id, precision)], or
    [None] if no entry exists. *)
val recompute_cache_state_for_test :
  string -> float -> recompute_cache_state option

(** Test-only: drop all recompute-cache entries and reset the epoch to 0. *)
val clear_recompute_cache_for_test : unit -> unit

(** Replace a compound shape with Polygon elements derived from its
    evaluated geometry. Each polygon carries the compound shape's
    own paint; rings with fewer than 3 points are dropped. *)
val expand : Element.compound_shape -> float -> Element.element list

(** Inverse of Make. Returns the operand array verbatim. *)
val release : Element.compound_shape -> Element.element array
