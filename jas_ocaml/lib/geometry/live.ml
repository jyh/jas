(** LiveElement framework helpers — port of jas_dioxus live.rs.
    See [transcripts/BOOLEAN.md] § Live element framework. *)

open Element

let default_precision = 0.0283

(* ------------------------------------------------------------------ *)
(* Reference resolution seam (REFERENCE_GRAPH.md section 2.1)          *)
(* ------------------------------------------------------------------ *)

(* Resolves a stable element id to the element it currently names. Lets
   the geometry layer evaluate by-id references without depending on
   Model / Document. Phase 1 backs this with a rebuild-on-demand
   resolver; the persistent-incremental index is Phase 4. *)
type element_resolver = element_ref -> element option

(* A resolver that resolves nothing. Used on the resolver-unaware call
   paths (and wherever no live references are present) so existing
   geometry behavior is unchanged: a reference resolved through it is
   treated as dangling. *)
let null_resolver : element_resolver = fun _ -> None

(* Resolves a concept pack id to its generator: a function from the instance's
   parameters (a JSON object) to the generated [x,y] point list. The closure is
   built by a layer that has the expression evaluator + the workspace registry
   (CONCEPTS.md), so the geometry layer stays decoupled from both — the OCaml
   analogue of Rust's resolver.resolve_concept + expr::eval. OCaml's
   [element_resolver] is a bare function, so concept resolution rides a SEPARATE
   optional resolver threaded through evaluation; resolver-unaware paths use
   [null_concept_resolver] (Generated -> empty, never a crash). *)
type concept_resolver = string -> (Yojson.Safe.t -> (float * float) list) option

let null_concept_resolver : concept_resolver = fun _ -> None

(* The cycle-guard set threaded through evaluation. Carried as an
   explicit parameter (never instance / thread state) so all five apps
   break reference cycles identically (REFERENCE_GRAPH.md section 3). *)
module VisitSet = Set.Make (String)

(* Stable-id inputs reached by reference rather than containment, in
   deterministic order. Default empty: containment kinds (Compound_shape)
   own their inputs and expose them as operands. The reference-graph
   index reads this; it is the only by-id edge source. *)
let dependencies (lv : live_variant) : element_ref list =
  match lv with
  | Compound_shape _ -> []
  | Reference r -> [ r.ref_target ]
  (* A recorded element rebinds its inputs by stable id (by-id edges), so
     the reference graph tracks them — like a reference. *)
  | Recorded rec_ -> rec_.rec_inputs
  (* A generated element is self-contained (concept id + params); no by-id
     inputs, so no dependency edges. *)
  | Generated _ -> []

(* ------------------------------------------------------------------ *)
(* Render-scoped resolver (REFERENCE_GRAPH.md Phase 1b)               *)
(* ------------------------------------------------------------------ *)

(* The id-bearing-descendant children of an element, in document order.
   Only Group / Layer expose children to the render id->element resolver;
   a CompoundShape's operands are OPAQUE to the by-id graph (operands are
   owned, not targetable), so the walk never recurses into them, and a
   reference does not own the element it names, so it has none. This
   mirrors Rust [Element::children] (None for Live) as used by
   [collect_ref_ids] and the dependency index, keeping render
   targetability in agreement with the reference-graph index. The eval
   path recurses operands directly via [evaluate_with] over [cs.operands],
   NOT via this function, so the operands stay reachable for evaluation. *)
let resolver_children (elem : element) : element list =
  match elem with
  | Group { children; _ } | Layer { children; _ } -> Array.to_list children
  | _ -> []

(* The stable id carried on an element, if any. *)
let resolver_id (elem : element) : element_ref option =
  match elem with
  | Rect { id; _ } | Circle { id; _ } | Ellipse { id; _ }
  | Line { id; _ } | Polyline { id; _ } | Polygon { id; _ }
  | Path { id; _ } | Text { id; _ } | Text_path { id; _ }
  | Group { id; _ } | Layer { id; _ } -> id
  | Live (Compound_shape cs) -> cs.id
  | Live (Reference r) -> r.ref_id
  | Live (Recorded rec_) -> rec_.rec_id
  | Live (Generated gen) -> gen.gen_id

(* Persistent id->element index (REFERENCE_GRAPH.md section 2.4, Phase 4b).
   [Map.Make(String)] gives O(log n) lookup/insert, O(1) structure-sharing
   on a stack snapshot (so each undo entry carries the index cheaply), and
   sorted iteration. It is a pure function of the document, so polymorphic
   structural [=] compares a Model-held index against a from-scratch rebuild
   for the debug gate (the [element] type has no functional fields). Mirrors
   the Rust [IdIndex] (an [rpds::RedBlackTreeMap]); per REFERENCE_GRAPH.md
   section 2.3 apps may differ in the concrete persistent-map type. *)
module Id_map = Map.Make (String)
type id_index = element Id_map.t

(* Walk [elem] and its id-bearing descendants, recording the first
   element seen for each id (first-occurrence wins, matching Rust
   [collect_ref_ids]; the unique-id invariant means there are no
   collisions in practice, this just makes the build deterministic).
   Threads the persistent map functionally (no mutation), so this is the
   pure builder shared by the live index and the gate oracle. *)
let rec collect_ref_ids (elem : element) (acc : id_index) : id_index =
  let acc =
    match resolver_id elem with
    | Some id -> if Id_map.mem id acc then acc else Id_map.add id elem acc
    | None -> acc
  in
  List.fold_left (fun acc child -> collect_ref_ids child acc)
    acc (resolver_children elem)

(* Build the persistent id->element index from a document's [layers] and
   [symbols]. This is the SINGLE canonical walk (REFERENCE_GRAPH.md section
   2.3): both the builder that populates the Model's companion index (so
   paint reads it without rebuilding) and the oracle the debug-assert gate
   compares against, so the resulting map's values are bit-identical to the
   pre-Phase-4b per-paint rebuild and resolve() results are unchanged.

   Indexes the id-bearing descendants of each top-level layer; top-level
   layer ids are not resolution targets in Phase 1 (references target
   shapes), so the layer walk starts at each layer's children.

   ALSO indexes [symbols] (SYMBOLS.md section 2): each master is walked
   with the same operands-opaque discipline so a reference instance can
   resolve a master by its [common.id]. Unlike layers, a master's OWN id
   is a valid target (a master is reached only through a reference), so
   each master is indexed directly (its own id + id-bearing descendants),
   not skipped like a top-level layer. Masters live off-canvas (not in
   [layers]), so indexing them here makes them resolvable WITHOUT ever
   making them painted. Masters are sorted by id before indexing so a
   duplicate-id master resolves deterministically (first-by-id wins).

   Mirrors Rust [rebuild_id_index]. *)
let rebuild_id_index
    (layers : element array) (symbols : element array) : id_index =
  let index =
    Array.fold_left (fun acc layer ->
      List.fold_left (fun acc child -> collect_ref_ids child acc)
        acc (resolver_children layer)
    ) Id_map.empty layers
  in
  let id_of_master m = match resolver_id m with Some s -> s | None -> "" in
  let sorted_masters =
    Array.to_list symbols
    |> List.stable_sort (fun a b -> String.compare (id_of_master a) (id_of_master b))
  in
  List.fold_left (fun acc master -> collect_ref_ids master acc)
    index sorted_masters

(* Build an [element_resolver] that reads an already-built persistent
   index (an O(1) borrow of the Model's companion index; no per-paint
   rebuild). Mirrors the Rust [RenderResolver] reading the installed
   [IdIndex]. *)
let resolver_of_index (index : id_index) : element_resolver =
  fun id -> Id_map.find_opt id index

(* Build an [element_resolver] from a document's [layers] and [symbols] by
   rebuilding the index from scratch. Retained for the resolver / symbols
   test fixtures and any call path without a precomputed index; the hot
   paint path uses {!resolver_of_index} with the Model's persistent index
   instead. Equivalent to [resolver_of_index (rebuild_id_index layers
   symbols)] — the single canonical walk. *)
let resolver_of_layers_and_symbols
    (layers : element array) (symbols : element array) : element_resolver =
  resolver_of_index (rebuild_id_index layers symbols)

(* Backwards-compatible wrapper indexing only [layers] (no master
   store). Equivalent to [resolver_of_layers_and_symbols layers [||]]. *)
let resolver_of_document (layers : element array) : element_resolver =
  resolver_of_layers_and_symbols layers [||]

(** Compute the number of segments required to approximate a circle
    of the given radius so the max perpendicular distance between
    the polyline and the arc is at most [precision]. *)
let segments_for_arc radius precision =
  if radius <= 0.0 || precision <= 0.0 then 32
  else
    let n = Float.pi *. sqrt (radius /. (2.0 *. precision)) in
    max 8 (int_of_float (Float.ceil n))

let circle_to_ring cx cy r precision =
  let n = segments_for_arc r precision in
  Array.init n (fun i ->
    let theta = 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
    (cx +. r *. cos theta, cy +. r *. sin theta))

let ellipse_to_ring cx cy rx ry precision =
  let n = segments_for_arc (max rx ry) precision in
  Array.init n (fun i ->
    let theta = 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
    (cx +. rx *. cos theta, cy +. ry *. sin theta))

(** Flatten path commands into one ring per subpath. MoveTo starts a
    new ring; ClosePath finalizes the current ring. Open subpaths are
    finalized at the next MoveTo or end of commands. Rings with fewer
    than 3 points are dropped. FLATTEN_STEPS = 20; matches the
    pre-existing path-flattening in this library. *)
let flatten_path_to_rings d =
  let steps = 20 in
  let rings = ref [] in
  let cur = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  let flush () =
    match !cur with
    | pts when List.length pts >= 3 ->
      rings := (Array.of_list (List.rev pts)) :: !rings;
      cur := []
    | _ -> cur := []
  in
  List.iter (function
    | MoveTo (x, y) ->
      flush ();
      cur := (x, y) :: !cur;
      cx := x; cy := y
    | LineTo (x, y) ->
      cur := (x, y) :: !cur;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      let sx, sy = !cx, !cy in
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt ** 3.0 *. sx
                 +. 3.0 *. mt ** 2.0 *. t *. x1
                 +. 3.0 *. mt *. t ** 2.0 *. x2
                 +. t ** 3.0 *. x in
        let py = mt ** 3.0 *. sy
                 +. 3.0 *. mt ** 2.0 *. t *. y1
                 +. 3.0 *. mt *. t ** 2.0 *. y2
                 +. t ** 3.0 *. y in
        cur := (px, py) :: !cur
      done;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      let sx, sy = !cx, !cy in
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt ** 2.0 *. sx +. 2.0 *. mt *. t *. x1 +. t ** 2.0 *. x in
        let py = mt ** 2.0 *. sy +. 2.0 *. mt *. t *. y1 +. t ** 2.0 *. y in
        cur := (px, py) :: !cur
      done;
      cx := x; cy := y
    | ClosePath -> flush ()
    | SmoothCurveTo (_, _, x, y)
    | SmoothQuadTo (x, y)
    | ArcTo (_, _, _, _, _, x, y) ->
      (* Approximate as line-to-endpoint, matching the existing
         flatten_path_commands behavior. *)
      cur := (x, y) :: !cur;
      cx := x; cy := y
  ) d;
  flush ();
  List.rev !rings

(* ------------------------------------------------------------------ *)
(* Phase 4c: reference-geometry recompute cache                        *)
(* ------------------------------------------------------------------ *)
(*
   PER-APP PERF CACHE. REFERENCE_GRAPH.md section 2.3 lets the cache strategy
   differ per app; equivalence is pinned on resolve() RESULTS, which this
   never alters (gated by [assert] on every Pure hit). Mirrors the Rust
   Phase-4c cache in [live.rs], adapted to this app's Option-B index strategy.

   What is cached: the RESOLVED TARGET's UNTRANSFORMED geometry —
   [element_to_polygon_set_with target precision ..]. Shared across every
   reference that names the same target, so the key is the TARGET (its id +
   the precision it was tessellated at), never the reference. The per-reference
   instance transform is applied AFTER the cached geometry, in
   [reference_evaluate_with].

   Why pure-geometry only (the crux): a target T that is a Group containing a
   Reference to X has geometry that changes when X is edited. Caching ONLY
   targets whose subtree contains NO Reference ([subtree_has_reference] is
   false) makes the geometry a pure function of the target's content at this
   generation, so the generation epoch is a complete invalidation signal.
   Ref-containing targets fall through to exact uncached eval (recorded
   [Has_refs] so a repeat lookup skips the purity walk but never serves
   cached geometry).

   Divergence from Rust (allowed by section 2.3): Rust additionally keys on the
   target's [Rc::as_ptr] (it pairs with the Rust-only incremental Rc-diff
   index). This app rebuilds the index at the mutation chokepoint (Option B),
   so within a generation the document is immutable and id -> geometry is
   fixed; the generation epoch alone is the complete signal and there is no
   pointer-identity check. The per-hit [assert (cached = fresh)] proves it.

   Lifetime + invalidation: a module-global cache that PERSISTS across paints,
   so no-edit repaints (pan / zoom / hover, plus the fill + selection-trace
   passes) reuse it. It is generation-epoched off [Model#generation], bumped on
   every mutation / undo / redo; [set_recompute_cache_generation] (the paint
   entry) clears all entries whenever the generation changes. Precision is part
   of the key (the two render passes may use different precision; coarse vs
   fine are different geometry, encoded via [Int64.bits_of_float]). *)

(* Observable cache state for a [(target_id, precision)] slot, for tests:
   [Pure_state] (geometry cached), [Has_refs_state] (recorded uncacheable),
   or absent (no entry). *)
type recompute_cache_state = Pure_state | Has_refs_state

(* One cache slot keyed by [(target_id, precision_bits)]. [Pure] holds the
   target's untransformed geometry, valid for the current epoch. [Has_refs]
   records that the target's subtree contains a nested reference, so its
   geometry is NOT cacheable; the entry exists only to short-circuit the purity
   walk on a repeat lookup — it never serves geometry. *)
type cache_entry =
  | Pure of Boolean.polygon_set
  | Has_refs

let recompute_cache_generation = ref 0
let recompute_cache : (string * int64, cache_entry) Hashtbl.t = Hashtbl.create 64

(* Generation-epoch the cache: if [generation] differs from the current epoch,
   clear every entry and adopt the new epoch. Called at the paint entry with
   [Model#generation]. Because the generation is bumped on every mutation /
   undo / redo, this drops the cache on any edit while preserving it across
   no-edit repaints. *)
let set_recompute_cache_generation generation =
  if !recompute_cache_generation <> generation then begin
    Hashtbl.clear recompute_cache;
    recompute_cache_generation := generation
  end

(* True iff [elem]'s OWNED subtree contains a Reference anywhere — the purity
   test deciding whether a target's geometry may be cached. Recurses Group /
   Layer children and Compound_shape operands (every containment edge
   [element_to_polygon_set_with] itself descends). A reference reached by-id is
   NOT part of the owned subtree, so this detects a Reference at its own node,
   it never follows one. *)
let rec subtree_has_reference (elem : element) : bool =
  match elem with
  | Live (Reference _) -> true
  | Live (Compound_shape cs) -> Array.exists subtree_has_reference cs.operands
  | Group { children; _ } | Layer { children; _ } ->
    Array.exists subtree_has_reference children
  | _ -> false

(* Test-only: report the cache state for [(target_id, precision)]. Lets the
   focused Phase-4c tests assert WHAT was cached, beyond the eval result. *)
let recompute_cache_state_for_test target_id precision =
  match
    Hashtbl.find_opt recompute_cache (target_id, Int64.bits_of_float precision)
  with
  | Some (Pure _) -> Some Pure_state
  | Some Has_refs -> Some Has_refs_state
  | None -> None

(* Test-only: drop all entries and reset the epoch to 0, so each focused test
   starts from an empty cache regardless of prior tests. *)
let clear_recompute_cache_for_test () =
  Hashtbl.clear recompute_cache;
  recompute_cache_generation := 0

(* Resolver-aware flattening. Identical to [element_to_polygon_set]
   except that by-id references resolve through [resolver], with
   [visiting] breaking cycles. The 2-arg [element_to_polygon_set]
   wrapper below passes [null_resolver], so existing call sites are
   behavior-identical. *)
let rec element_to_polygon_set_with
    ?(concept_resolver = null_concept_resolver) elem precision resolver visiting =
  match elem with
  | Rect { x; y; width; height; _ } ->
    [| (x, y); (x +. width, y); (x +. width, y +. height); (x, y +. height) |]
    :: []
  | Polygon { points; _ } ->
    if points = [] then []
    else [Array.of_list points]
  | Polyline { points; _ } ->
    (* Implicitly closed for even-odd fill. *)
    if points = [] then []
    else [Array.of_list points]
  | Circle { cx; cy; r; _ } -> [circle_to_ring cx cy r precision]
  | Ellipse { cx; cy; rx; ry; _ } -> [ellipse_to_ring cx cy rx ry precision]
  | Group { children; _ } | Layer { children; _ } ->
    Array.fold_left (fun acc child ->
      acc @ element_to_polygon_set_with ~concept_resolver child precision resolver visiting
    ) [] children
  | Live (Compound_shape cs) -> evaluate_with cs precision resolver visiting
  | Live (Reference r) -> reference_evaluate_with r precision resolver visiting
  | Live (Recorded rec_) -> recorded_evaluate_with rec_ precision resolver visiting
  | Live (Generated gen) -> generated_evaluate_with gen precision concept_resolver
  | Path { d; _ } | Text_path { d; _ } -> flatten_path_to_rings d
  (* Line has zero area; Text glyph flattening deferred. *)
  | Line _ | Text _ -> []

and apply_operation op operand_sets =
  match op, operand_sets with
  | _, [] -> []
  | Op_union, first :: rest ->
    List.fold_left Boolean.boolean_union first rest
  | Op_intersection, first :: rest ->
    List.fold_left Boolean.boolean_intersect first rest
  | Op_subtract_front, [x] -> x
  | Op_subtract_front, operands ->
    let rec split_last acc = function
      | [] -> failwith "impossible"
      | [x] -> List.rev acc, x
      | x :: xs -> split_last (x :: acc) xs
    in
    let survivors, cutter = split_last [] operands in
    List.fold_left (fun acc s ->
      Boolean.boolean_union acc (Boolean.boolean_subtract s cutter)
    ) [] survivors
  | Op_exclude, first :: rest ->
    List.fold_left Boolean.boolean_exclude first rest

(* Resolver-aware evaluation: flattens each operand (threading the
   resolver + cycle-guard set so a referenced operand resolves through
   [resolver]), then applies the boolean operation. *)
and evaluate_with cs precision resolver visiting =
  let operand_sets =
    Array.to_list cs.operands
    |> List.map (fun op ->
        element_to_polygon_set_with op precision resolver visiting)
  in
  apply_operation cs.operation operand_sets

(* Resolver-aware evaluation of a reference: resolve the target and
   return its geometry. A cycle (target already being visited) or a
   dangling reference (unresolved) yields an empty set — never a
   failure (REFERENCE_GRAPH.md section 3). *)
and reference_evaluate_with r precision resolver visiting =
  if VisitSet.mem r.ref_target !visiting then
    [] (* cycle: break at the re-entry edge *)
  else
    match resolver r.ref_target with
    | Some target ->
      visiting := VisitSet.add r.ref_target !visiting;
      (* Phase 4c: obtain the resolved target's UNTRANSFORMED geometry through
         the recompute cache (shared across all references to this target;
         cached only for pure-geometry targets). The per-reference instance
         transform is applied AFTER, below. *)
      let ps = cached_target_geometry r.ref_target target precision resolver visiting in
      visiting := VisitSet.remove r.ref_target !visiting;
      (* Symbols P4 (SYMBOLS.md section 4 / Fork F2): the instance transform
         field (distinct from [ref_transform], which renders as the CTM) is
         applied to the resolved geometry here, so an instance can be
         mirrored / scaled relative to its master. This single seam covers
         every consumer of the resolved set — both render sites, polygon-set,
         and compound-operand use. None yields the geometry unchanged (no
         transform, no double-apply). *)
      (match r.ref_instance_transform with
       | Some t ->
         List.map (fun ring ->
           Array.map (fun (x, y) -> apply_point t x y) ring
         ) ps
       | None -> ps)
    | None -> [] (* dangling: target not found *)

(* Obtain the resolved target's UNTRANSFORMED geometry via the recompute cache
   (Phase 4c). Caches only pure-geometry targets (no nested reference);
   ref-containing targets are evaluated fresh every time (recorded [Has_refs]).
   The per-reference instance transform is applied by the caller AFTER this
   returns. Correctness gate: on every Pure hit, [assert (cached = fresh)]
   (mirroring the Phase-4b index = rebuild gate); the fresh eval is inside the
   assert so it is elided under -noassert. *)
and cached_target_geometry target_id target precision resolver visiting =
  let key = (target_id, Int64.bits_of_float precision) in
  match Hashtbl.find_opt recompute_cache key with
  | Some (Pure geom) ->
    assert (
      let fresh_visit = ref VisitSet.empty in
      geom = element_to_polygon_set_with target precision resolver fresh_visit);
    geom
  | Some Has_refs ->
    (* Target contains a nested reference: never serve cached geometry. *)
    element_to_polygon_set_with target precision resolver visiting
  | None ->
    (* Cache miss: evaluate fresh, then record by purity. *)
    let fresh = element_to_polygon_set_with target precision resolver visiting in
    let entry = if subtree_has_reference target then Has_refs else Pure fresh in
    Hashtbl.replace recompute_cache key entry;
    fresh

(* Whole-element translate by [(dx, dy)]. A leaf primitive offsets its
   geometry; a Group / Layer translates each child; a reference / recorded
   element has no geometry of its own, so its move rides on common.transform
   via the [is_all] arm of [Element.move_control_points]. Mirrors the Rust
   [translate_element] used by recorded replay. *)
and recorded_translate_element elem dx dy =
  if dx = 0.0 && dy = 0.0 then elem
  else
    match elem with
    | Group { id; children; opacity; transform; locked; visibility; blend_mode;
              isolated_blending; knockout_group; _ } ->
      Group { name = None; id;
              children = Array.map (fun c -> recorded_translate_element c dx dy) children;
              opacity; transform; locked; visibility; blend_mode;
              mask = None; isolated_blending; knockout_group }
    | Layer { name; id; children; opacity; transform; locked; visibility; blend_mode;
              isolated_blending; knockout_group; _ } ->
      Layer { name; id;
              children = Array.map (fun c -> recorded_translate_element c dx dy) children;
              opacity; transform; locked; visibility; blend_mode;
              mask = None; isolated_blending; knockout_group }
    | Live (Reference _) | Live (Recorded _) ->
      (* No geometry of its own; the whole-element move rides on
         common.transform via the [is_all] arm in move_control_points. *)
      Element.move_control_points ~is_all:true elem [] dx dy
    | _ ->
      let n = Element.control_point_count elem in
      let indices = List.init n Fun.id in
      Element.move_control_points elem indices dx dy

(* Replay a recorded element's recipe against the resolved inputs and return
   the derived output geometry. A dangling input or a cycle (an input already
   being visited) yields an empty set — never a failure (REFERENCE_GRAPH.md
   section 3). Replay is a pure, deterministic function of the inputs
   (OP_LOG.md section 7). Mirrors the Rust RecordedElem::evaluate_with. *)
and recorded_evaluate_with (rec_ : recorded_elem) precision _resolver visiting =
  (* JSON param helpers (params is a Yojson object): a float at [k], or the
     string array at [k]. *)
  let num params k =
    match params with
    | `Assoc fields ->
      (match List.assoc_opt k fields with
       | Some (`Float f) -> f
       | Some (`Int i) -> float_of_int i
       | _ -> 0.0)
    | _ -> 0.0
  in
  let str_ids params k =
    match params with
    | `Assoc fields ->
      (match List.assoc_opt k fields with
       | Some (`List items) ->
         List.filter_map (function `String s -> Some s | _ -> None) items
       | _ -> [])
    | _ -> []
  in
  (* Resolve inputs into a working set keyed by stable id. A cycle breaks to
     empty at the re-entry edge; a dangling input yields empty. *)
  let working : (string, element) Hashtbl.t = Hashtbl.create 8 in
  let dangling = ref false in
  List.iter (fun input ->
    if not !dangling then begin
      if VisitSet.mem input !visiting then dangling := true
      else match _resolver input with
        | Some el -> Hashtbl.replace working input el
        | None -> dangling := true
    end
  ) rec_.rec_inputs;
  if !dangling then []
  else begin
    (* Replay. Derived (produced) elements are keyed by a capture-stable
       production-index handle [$n], so the recipe is independent of this
       element's own id. *)
    let output_ids = ref [] in
    let counter = ref 0 in
    List.iter (fun (op : recorded_op) ->
      match op.rop_op with
      | "copy" ->
        let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
        List.iter (fun src ->
          match Hashtbl.find_opt working src with
          | Some el ->
            let derived_id = Printf.sprintf "$%d" !counter in
            incr counter;
            let copy = recorded_translate_element el dx dy in
            Hashtbl.replace working derived_id copy;
            output_ids := derived_id :: !output_ids
          | None -> ()
        ) (str_ids op.rop_params "from")
      | "translate" ->
        let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
        List.iter (fun id ->
          match Hashtbl.find_opt working id with
          | Some el ->
            let moved = recorded_translate_element el dx dy in
            Hashtbl.replace working id moved
          | None -> ()
        ) (str_ids op.rop_params "ids")
      | _ -> () (* outside the replay-safe subset: skip *)
    ) rec_.rec_ops;
    (* Output = the derived elements' geometry, in derivation order. The
       produced elements are concrete; flatten them with no resolver. *)
    let ordered = List.rev !output_ids in
    List.fold_left (fun acc id ->
      match Hashtbl.find_opt working id with
      | Some el ->
        acc @ element_to_polygon_set_with el precision null_resolver
                (ref VisitSet.empty)
      | None -> acc
    ) [] ordered
  end

(* Evaluate a generated (concept-instance) element: resolve its concept's
   generator via [concept_resolver] (a params -> points closure built by a layer
   with the expression evaluator + registry), run it over [gen_params], and
   return the resulting ring. An unresolved concept, or a generator producing
   fewer than two points, yields an empty set — never a failure. Pure and
   deterministic. Mirrors Rust GeneratedElem::evaluate_with. *)
and generated_evaluate_with (gen : generated_elem) _precision
    (concept_resolver : concept_resolver) =
  match concept_resolver gen.gen_concept_id with
  | None -> []
  | Some gen_fn ->
    let points = gen_fn gen.gen_params in
    if List.length points < 2 then [] else [ Array.of_list points ]

(* Resolver-aware generated-element evaluation, exposed for tests / future render
   wiring. Mirrors Rust GeneratedElem::evaluate_with. *)
let generated_evaluate gen precision concept_resolver =
  generated_evaluate_with gen precision concept_resolver

(* Convenience wrapper that resolves no references — see
   [element_to_polygon_set_with] for the resolver-aware form used when a
   subtree may contain by-id references. *)
let element_to_polygon_set elem precision =
  let visiting = ref VisitSet.empty in
  element_to_polygon_set_with elem precision null_resolver visiting

(* Convenience wrapper that resolves no references (the operands of a
   compound are owned, not referenced). *)
let evaluate cs precision =
  let visiting = ref VisitSet.empty in
  evaluate_with cs precision null_resolver visiting

(* Resolver-aware reference evaluation, exposed for tests / future render
   wiring. Mirrors Rust ReferenceElem::evaluate_with. *)
let reference_evaluate r precision resolver visiting =
  reference_evaluate_with r precision resolver visiting

(* Resolver-aware recorded-element evaluation, exposed for tests / future
   render wiring. Mirrors Rust RecordedElem::evaluate_with. *)
let recorded_evaluate rec_ precision resolver visiting =
  recorded_evaluate_with rec_ precision resolver visiting

(* Normalize a captured journal op-segment into a recorded recipe
   (RECORDED_ELEMENTS.md section 1 / section 4): rewrite the captured ops into
   the input-addressed copy / translate form [evaluate_with] consumes, tracking
   the working set as recipe refs.

   Two captured shapes are accepted:

   The id-primary family (OP_LOG.md section 5 Fork 4 — the 3c-1 form, NO
   selection dependency). When the segment is already id-primary, this is a
   PASS-THROUGH: every operand id is read DIRECTLY from the op-OWN PARAMS, never
   from a select op-resolved targets, so the recipe is independent of any
   document selection.
   - select_by_ids{ids} establishes the working set from its [ids] PARAM; it is
     NOT emitted (id-addressing replaces selection).
   - copy_by_ids{from, dx, dy} emits copy{from, dx, dy} (source = its [from]
     PARAM) and rebinds the working set to the produced [$n] handles.
   - move_by_ids{ids, dx, dy} emits translate{ids, dx, dy} on the working set
     (which, after a copy, is the produced [$n] handles — so a copy-then-move
     demonstration replays without ever naming the id-less copy).

   The legacy selection-relative family (OP_LOG.md section 7 — kept verbatim). A
   select_rect / select op establishes the working set from its resolved
   targets; copy_selection -> copy, move_selection -> translate. This bridge
   stays for the selection-relative corpus; the id-primary path above does NOT
   route through it.

   Ops outside the replay-safe subset are dropped. The recipe's non-[$] refs
   are the inputs — the elements it rebinds by stable id (the deterministic
   mark-input MVP rule; no AI fitter). Returns [(recipe, input_ids)]; the caller
   wraps them in a recorded element. Mirrors the Rust [capture_recipe]. *)
let capture_recipe (segment : recorded_op list) : recorded_op list * string list =
  let num params k =
    match params with
    | `Assoc fields ->
      (match List.assoc_opt k fields with
       | Some (`Float f) -> f
       | Some (`Int i) -> float_of_int i
       | _ -> 0.0)
    | _ -> 0.0
  in
  (* Read a JSON array-of-strings PARAM (hardened: non-array yields []). *)
  let str_ids params k =
    match params with
    | `Assoc fields ->
      (match List.assoc_opt k fields with
       | Some (`List items) ->
         List.filter_map (function `String s -> Some s | _ -> None) items
       | _ -> [])
    | _ -> []
  in
  let working = ref [] in
  let recipe = ref [] in
  let counter = ref 0 in
  List.iter (fun (op : recorded_op) ->
    match op.rop_op with
    (* ── id-primary family: operands from PARAMS (no selection dep) ── *)
    | "select_by_ids" ->
      working := str_ids op.rop_params "ids"
    | "copy_by_ids" ->
      let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
      let from = str_ids op.rop_params "from" in
      let from_arr = `List (List.map (fun s -> `String s) from) in
      recipe := { rop_op = "copy";
                  rop_params =
                    `Assoc [ ("from", from_arr);
                             ("dx", `Float dx); ("dy", `Float dy) ];
                  rop_targets = [] } :: !recipe;
      let produced = List.map (fun _ ->
        let h = Printf.sprintf "$%d" !counter in incr counter; h) from in
      working := produced
    | "move_by_ids" ->
      let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
      (* The working set is the produced [$n] handles after a copy, or the
         op-OWN [ids] PARAM when it stands alone (a bare id-primary move). *)
      if !working = [] then working := str_ids op.rop_params "ids";
      let ids_arr = `List (List.map (fun s -> `String s) !working) in
      recipe := { rop_op = "translate";
                  rop_params =
                    `Assoc [ ("ids", ids_arr);
                             ("dx", `Float dx); ("dy", `Float dy) ];
                  rop_targets = [] } :: !recipe
    (* ── legacy selection-relative family (kept verbatim) ── *)
    | "select_rect" | "select" ->
      working := op.rop_targets
    | "copy_selection" ->
      let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
      let from_arr = `List (List.map (fun s -> `String s) !working) in
      recipe := { rop_op = "copy";
                  rop_params =
                    `Assoc [ ("from", from_arr);
                             ("dx", `Float dx); ("dy", `Float dy) ];
                  rop_targets = [] } :: !recipe;
      let produced = List.map (fun _ ->
        let h = Printf.sprintf "$%d" !counter in incr counter; h) !working in
      working := produced
    | "move_selection" ->
      let dx = num op.rop_params "dx" and dy = num op.rop_params "dy" in
      let ids_arr = `List (List.map (fun s -> `String s) !working) in
      recipe := { rop_op = "translate";
                  rop_params =
                    `Assoc [ ("ids", ids_arr);
                             ("dx", `Float dx); ("dy", `Float dy) ];
                  rop_targets = [] } :: !recipe
    | _ -> ()
  ) segment;
  let recipe = List.rev !recipe in
  (* Inputs = the distinct non-[$] refs the recipe rebinds, in first-seen
     order. *)
  let inputs = ref [] in
  let consider r =
    if String.length r > 0 && r.[0] <> '$'
       && not (List.mem r !inputs) then inputs := r :: !inputs
  in
  List.iter (fun (op : recorded_op) ->
    List.iter (fun key ->
      match op.rop_params with
      | `Assoc fields ->
        (match List.assoc_opt key fields with
         | Some (`List items) ->
           List.iter (function `String s -> consider s | _ -> ()) items
         | _ -> ())
      | _ -> ()
    ) [ "from"; "ids" ]
  ) recipe;
  (recipe, List.rev !inputs)

(** Replace a compound shape with one Polygon per ring of the
    evaluated geometry. Each output polygon carries the compound
    shape's own fill / stroke / common props; the operand tree is
    discarded. Rings with fewer than 3 points are dropped. See
    BOOLEAN.md § Expand and Release semantics. *)
let expand (cs : compound_shape) precision : element list =
  let ps = evaluate cs precision in
  List.filter_map (fun ring ->
    if Array.length ring < 3 then None
    else
      let points = Array.to_list ring in
      Some (Polygon { name = None; id = None;
        points;
        fill = cs.fill;
        stroke = cs.stroke;
        opacity = cs.opacity;
        transform = cs.transform;
        locked = cs.locked;
        visibility = cs.visibility;
        blend_mode = cs.blend_mode;
        mask = None;
        fill_gradient = None;
        stroke_gradient = None;
      })
  ) ps

(** Inverse of Make. Returns the operands unchanged. Each operand
    keeps its own paint; the compound shape's paint is discarded. *)
let release (cs : compound_shape) : element array = cs.operands

let bounds_of_polygon_set ps =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  List.iter (fun ring ->
    Array.iter (fun (x, y) ->
      if x < !min_x then min_x := x;
      if y < !min_y then min_y := y;
      if x > !max_x then max_x := x;
      if y > !max_y then max_y := y
    ) ring
  ) ps;
  if not (Float.is_finite !min_x) then (0.0, 0.0, 0.0, 0.0)
  else (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)

(** Set the hook at module init time so Element.bounds can compute
    Live bounds without a cycle. *)
let () =
  Element.live_bounds_hook := (fun lv ->
    match lv with
    | Compound_shape cs ->
      bounds_of_polygon_set (evaluate cs default_precision)
    (* Resolver-free bounds are degenerate for a reference (its geometry
       lives elsewhere); the resolver-aware bounds lands with the render
       wiring (Phase 1b). *)
    | Reference _ -> (0.0, 0.0, 0.0, 0.0)
    (* Resolver-free bounds are degenerate for a recorded element too — its
       geometry is replayed from inputs; resolver-aware bounds land with the
       render wiring, like Reference. *)
    | Recorded _ -> (0.0, 0.0, 0.0, 0.0)
    (* Resolver-free bounds are degenerate for a generated element — its
       geometry comes from the concept generator (CONCEPTS.md); resolver-aware
       bounds land with the render wiring, like Reference / Recorded. *)
    | Generated _ -> (0.0, 0.0, 0.0, 0.0))
