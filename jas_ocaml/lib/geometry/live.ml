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

(* Walk [elem] and its id-bearing descendants, recording the first
   element seen for each id (first-occurrence wins, matching Rust
   [collect_ref_ids]; the unique-id invariant means there are no
   collisions in practice, this just makes the build deterministic). *)
let rec collect_ref_ids (elem : element) (tbl : (element_ref, element) Hashtbl.t) : unit =
  (match resolver_id elem with
   | Some id -> if not (Hashtbl.mem tbl id) then Hashtbl.replace tbl id elem
   | None -> ());
  List.iter (fun child -> collect_ref_ids child tbl) (resolver_children elem)

(* Build an [element_resolver] from a document's [layers]. Indexes the
   id-bearing descendants of each top-level layer; top-level layer ids
   are not resolution targets in Phase 1 (references target shapes), so
   the walk starts at each layer's children. Rebuilt on demand by the
   render each paint (the rebuild strategy; the persistent-incremental
   index is Phase 4). Mirrors Rust [register_ref_index]. *)
let resolver_of_document (layers : element array) : element_resolver =
  let tbl : (element_ref, element) Hashtbl.t = Hashtbl.create 16 in
  Array.iter (fun layer ->
    List.iter (fun child -> collect_ref_ids child tbl)
      (resolver_children layer)
  ) layers;
  fun id -> Hashtbl.find_opt tbl id

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

(* Resolver-aware flattening. Identical to [element_to_polygon_set]
   except that by-id references resolve through [resolver], with
   [visiting] breaking cycles. The 2-arg [element_to_polygon_set]
   wrapper below passes [null_resolver], so existing call sites are
   behavior-identical. *)
let rec element_to_polygon_set_with elem precision resolver visiting =
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
      acc @ element_to_polygon_set_with child precision resolver visiting
    ) [] children
  | Live (Compound_shape cs) -> evaluate_with cs precision resolver visiting
  | Live (Reference r) -> reference_evaluate_with r precision resolver visiting
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
      let ps = element_to_polygon_set_with target precision resolver visiting in
      visiting := VisitSet.remove r.ref_target !visiting;
      ps
    | None -> [] (* dangling: target not found *)

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
    | Reference _ -> (0.0, 0.0, 0.0, 0.0))
