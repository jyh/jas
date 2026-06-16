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

(** The cycle-guard set threaded through evaluation. Carried as an
    explicit parameter so all five apps break reference cycles
    identically (REFERENCE_GRAPH.md section 3). *)
module VisitSet : Set.S with type elt = string

(** Stable-id inputs reached by reference rather than containment, in
    deterministic order. Empty for [Compound_shape] (its inputs are
    owned operands); the referenced target for [Reference]. *)
val dependencies : Element.live_variant -> Element.element_ref list

(** Build an [element_resolver] from a document's top-level layers.
    Indexes the id-bearing descendants of each layer (top-level layer
    ids are not Phase-1 resolution targets, so the walk starts at each
    layer's children). First-occurrence wins per id. Intended to be
    rebuilt on demand by the canvas render each paint, so by-id
    references resolve while drawing. Mirrors Rust [register_ref_index].
    See REFERENCE_GRAPH.md Phase 1b. *)
val resolver_of_document : Element.element array -> element_resolver

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

(** Replace a compound shape with Polygon elements derived from its
    evaluated geometry. Each polygon carries the compound shape's
    own paint; rings with fewer than 3 points are dropped. *)
val expand : Element.compound_shape -> float -> Element.element list

(** Inverse of Make. Returns the operand array verbatim. *)
val release : Element.compound_shape -> Element.element array
