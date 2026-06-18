(** Tests for the LiveElement framework — mirror of jas_dioxus
    live.rs tests. *)

open Jas.Element
module Live = Jas.Live

let rect_at x y =
  Rect { name = None; id = None; x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
           fill_gradient = None;
           stroke_gradient = None;
         }

let bbox_of_ring ring =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  Array.iter (fun (x, y) ->
    if x < !min_x then min_x := x;
    if y < !min_y then min_y := y;
    if x > !max_x then max_x := x;
    if y > !max_y then max_y := y
  ) ring;
  (!min_x, !min_y, !max_x, !max_y)

let approx_equal a b = abs_float (a -. b) < 1e-6

let test_element_to_polygon_set_rect () =
  let ps = Live.element_to_polygon_set (rect_at 0.0 0.0)
             Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps)

let test_union_of_two_rects () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 15" true (approx_equal max_x 15.0)

let test_intersection_of_two_rects () =
  let cs = {
    operation = Op_intersection;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 5" true (approx_equal min_x 5.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0)

let test_exclude_is_symmetric_difference () =
  let cs = {
    operation = Op_exclude;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "two rings" 2 (List.length ps)

let test_subtract_front () =
  let cs = {
    operation = Op_subtract_front;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let ps = Live.evaluate cs Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let ring = List.hd ps in
  let (min_x, _, max_x, _) = bbox_of_ring ring in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 5" true (approx_equal max_x 5.0)

let test_bounds_reflect_evaluation () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0; rect_at 5.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let (bx, by, bw, bh) = Jas.Element.bounds (Live (Compound_shape cs)) in
  Alcotest.(check bool) "bx = 0" true (approx_equal bx 0.0);
  Alcotest.(check bool) "by = 0" true (approx_equal by 0.0);
  Alcotest.(check bool) "bw = 15" true (approx_equal bw 15.0);
  Alcotest.(check bool) "bh = 10" true (approx_equal bh 10.0)

let test_empty_compound_has_empty_bounds () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [||];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  let (bx, by, bw, bh) = Jas.Element.bounds (Live (Compound_shape cs)) in
  Alcotest.(check bool) "bx = 0" true (approx_equal bx 0.0);
  Alcotest.(check bool) "by = 0" true (approx_equal by 0.0);
  Alcotest.(check bool) "bw = 0" true (approx_equal bw 0.0);
  Alcotest.(check bool) "bh = 0" true (approx_equal bh 0.0)

let test_path_flattens_into_polygon_set () =
  let path = Path { name = None; id = None;
    d = [
      MoveTo (0.0, 0.0);
      LineTo (10.0, 0.0);
      LineTo (10.0, 10.0);
      LineTo (0.0, 10.0);
      ClosePath;
    ];
    fill = None; stroke = None; width_points = [];
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
    blend_mode = Normal;
    mask = None;
    fill_gradient = None;
    stroke_gradient = None;
    stroke_brush = None;
    stroke_brush_overrides = None;
    tool_origin = None;
  } in
  let ps = Live.element_to_polygon_set path Live.default_precision in
  Alcotest.(check int) "one ring" 1 (List.length ps)

(* --- Reference (REFERENCE_GRAPH.md Phase 1a) ---------------------- *)

(* A test resolver backed by an id->element association list. *)
let map_resolver pairs : Live.element_resolver =
  fun id -> List.assoc_opt id pairs

let reference_elem target = {
  ref_target = target;
  ref_id = None;
  ref_instance_transform = None;
  ref_fill = None;
  ref_stroke = None;
  ref_opacity = 1.0;
  ref_transform = None;
  ref_locked = false;
  ref_visibility = Preview;
  ref_blend_mode = Normal;
  ref_mask = None;
}

let test_reference_evaluates_to_target () =
  let resolver = map_resolver [ ("r1", rect_at 0.0 0.0) ] in
  let r = reference_elem "r1" in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.reference_evaluate r Live.default_precision resolver visiting in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0);
  (* The cycle-guard set is left clean after a successful resolve. *)
  Alcotest.(check bool) "visiting empty" true (Live.VisitSet.is_empty !visiting)

let test_dangling_reference_is_empty () =
  let r = reference_elem "missing" in
  let visiting = ref Live.VisitSet.empty in
  let ps =
    Live.reference_evaluate r Live.default_precision Live.null_resolver visiting in
  Alcotest.(check bool) "empty" true (ps = [])

let test_reference_cycle_breaks_to_empty () =
  (* Resolver where id "a" resolves to a reference back to "a" — a
     self-cycle. The threaded visited-set must break it. *)
  let cycle_resolver : Live.element_resolver = fun id ->
    if id = "a" then Some (Live (Reference (reference_elem "a")))
    else None
  in
  let r = reference_elem "a" in
  let visiting = ref Live.VisitSet.empty in
  let ps =
    Live.reference_evaluate r Live.default_precision cycle_resolver visiting in
  Alcotest.(check bool) "empty" true (ps = []);
  Alcotest.(check bool) "visiting restored" true
    (Live.VisitSet.is_empty !visiting)

let test_reference_reports_dependency () =
  let r = reference_elem "t" in
  Alcotest.(check (list string)) "dependency is target" ["t"]
    (Live.dependencies (Reference r))

(* A rect carrying a stable id (the [rect_at] helper leaves id = None). *)
let rect_with_id id x y =
  Rect { name = None; id = Some id; x; y; width = 10.0; height = 10.0;
         rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
         fill_gradient = None; stroke_gradient = None;
       }

(* Mirror of Rust render_ref_index_resolves_reference_to_target:
   resolver_of_document builds the per-paint id->element index from the
   document layers; the resolver reads it, so a reference resolves and
   evaluates to its target's geometry (Phase 1b render wiring). A
   missing id resolves to None (dangling). *)
let test_resolver_of_document_resolves_reference () =
  let layer = make_layer [| rect_with_id "r1" 0.0 0.0 |] in
  let resolver = Live.resolver_of_document [| layer |] in
  Alcotest.(check bool) "resolves r1" true (resolver "r1" <> None);
  Alcotest.(check bool) "missing id is None" true (resolver "missing" = None);
  let r = reference_elem "r1" in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.reference_evaluate r Live.default_precision resolver visiting in
  Alcotest.(check int) "reference resolves to the rect single ring"
    1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "min_x = 0" true (approx_equal min_x 0.0);
  Alcotest.(check bool) "max_x = 10" true (approx_equal max_x 10.0)

(* --- Symbols P4: the instance transform field (SYMBOLS.md section 4 /
   Fork F2) --------------------------------------------------------- *)

let test_reference_instance_transform_scales_target () =
  (* A reference whose instance transform is scale(2,2), targeting a
     10x10 rect at the origin, evaluates to the rect geometry scaled 2x
     (a 20x20 ring). The instance transform is applied to every point of
     the resolved polygon set (composition: instance.transform of
     geometry). *)
  let resolver = map_resolver [ ("r1", rect_at 0.0 0.0) ] in
  let r = { (reference_elem "r1") with
            ref_instance_transform = Some (make_scale 2.0 2.0) } in
  let visiting = ref Live.VisitSet.empty in
  let scaled = Live.reference_evaluate r Live.default_precision resolver visiting in
  (* Unscaled reference for comparison. *)
  let plain = reference_elem "r1" in
  let visiting2 = ref Live.VisitSet.empty in
  let unscaled =
    Live.reference_evaluate plain Live.default_precision resolver visiting2 in
  Alcotest.(check int) "same ring count, just scaled"
    (List.length unscaled) (List.length scaled);
  let (sminx, sminy, smaxx, smaxy) = bbox_of_ring (List.hd scaled) in
  let (uminx, uminy, umaxx, umaxy) = bbox_of_ring (List.hd unscaled) in
  Alcotest.(check bool) "min_x scaled 2x" true (approx_equal sminx (uminx *. 2.0));
  Alcotest.(check bool) "min_y scaled 2x" true (approx_equal sminy (uminy *. 2.0));
  Alcotest.(check bool) "max_x scaled 2x" true (approx_equal smaxx (umaxx *. 2.0));
  Alcotest.(check bool) "max_y scaled 2x" true (approx_equal smaxy (umaxy *. 2.0));
  (* Concretely: the 10x10 rect at origin scales to a 20x20 box. *)
  Alcotest.(check bool) "min at origin" true
    (approx_equal sminx 0.0 && approx_equal sminy 0.0);
  Alcotest.(check bool) "max at 20,20" true
    (approx_equal smaxx 20.0 && approx_equal smaxy 20.0);
  Alcotest.(check bool) "visiting empty" true (Live.VisitSet.is_empty !visiting)

let test_reference_none_instance_transform_unchanged () =
  (* The default instance transform is None; eval is identical to the
     resolved target geometry (no transform applied, no double-apply). *)
  let resolver = map_resolver [ ("r1", rect_at 0.0 0.0) ] in
  let r = reference_elem "r1" in
  Alcotest.(check bool) "instance transform defaults to None" true
    (r.ref_instance_transform = None);
  let visiting = ref Live.VisitSet.empty in
  let via_ref = Live.reference_evaluate r Live.default_precision resolver visiting in
  (* Equal to evaluating the target rect directly. *)
  let direct = Live.element_to_polygon_set (rect_at 0.0 0.0) Live.default_precision in
  Alcotest.(check bool) "None instance transform leaves geometry unchanged"
    true (via_ref = direct)

(* --- Phase 4b: persistent id->element index (REFERENCE_GRAPH.md
   section 2.4) ------------------------------------------------------ *)

(* A master rect carrying its own id (a master's OWN id is a valid target,
   unlike a top-level layer's). *)
let master_rect id = rect_with_id id 1.0 2.0

(* Mirror of Rust rebuild_id_index_indexes_descendants_and_sorted_masters:
   the pure builder indexes id-bearing layer descendants and doc.symbols
   masters; a top-level layer's OWN id is NOT a resolution target. The map
   it returns equals itself rebuilt (the gate's equality), and a resolver
   over it resolves identically to resolver_of_layers_and_symbols. *)
let test_rebuild_id_index_indexes_descendants_and_sorted_masters () =
  let layer =
    make_layer ~name:"layer0" [| rect_with_id "r1" 0.0 0.0 |] in
  (* Give the top-level layer its own id; it must NOT become a target. *)
  let layer = match layer with
    | Layer l -> Layer { l with id = Some "layer0" }
    | other -> other in
  let layers = [| layer |] in
  let symbols = [| master_rect "m1" |] in
  let index = Live.rebuild_id_index layers symbols in
  let resolver = Live.resolver_of_index index in
  Alcotest.(check bool) "descendant rect indexed" true (resolver "r1" <> None);
  Alcotest.(check bool) "master indexed from symbols" true (resolver "m1" <> None);
  Alcotest.(check bool) "top-level layer id is not a target" true
    (resolver "layer0" = None);
  (* The persistent map equals itself rebuilt — the gate's value equality. *)
  Alcotest.(check bool) "rebuild is deterministic" true
    (Live.Id_map.equal ( = ) index (Live.rebuild_id_index layers symbols));
  (* resolver_of_index resolves identically to the rebuild-each-call form. *)
  let direct = Live.resolver_of_layers_and_symbols layers symbols in
  Alcotest.(check bool) "resolver_of_index agrees with rebuild form" true
    (resolver "r1" = direct "r1" && resolver "m1" = direct "m1"
     && resolver "missing" = direct "missing")

(* The new pure builder produces the SAME index regardless of master
   input order when ids are distinct (masters are sorted by id before
   indexing), and that index agrees value-for-value with the pre-existing
   resolver_of_layers_and_symbols — so resolve() results are unchanged
   (the equivalence pin). *)
let test_rebuild_id_index_matches_legacy_resolver_and_is_order_stable () =
  let m_a = master_rect "a" in
  let m_b = master_rect "b" in
  (* Distinct ids: the sort makes the index independent of input order. *)
  let index1 = Live.rebuild_id_index [||] [| m_b; m_a |] in
  let index2 = Live.rebuild_id_index [||] [| m_a; m_b |] in
  Alcotest.(check bool) "distinct-id masters: order-independent index" true
    (Live.Id_map.equal ( = ) index1 index2);
  (* The index resolves exactly what the legacy build-each-call resolver
     did, pinning resolve() results unchanged across the refactor. *)
  let legacy = Live.resolver_of_layers_and_symbols [||] [| m_a; m_b |] in
  let via_index = Live.resolver_of_index index2 in
  Alcotest.(check bool) "rebuild_id_index agrees with legacy resolver" true
    (via_index "a" = legacy "a" && via_index "b" = legacy "b"
     && via_index "z" = legacy "z")

let test_compound_has_no_dependencies () =
  let cs = {
    operation = Op_union;
    id = None;
    operands = [| rect_at 0.0 0.0 |];
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
  } in
  Alcotest.(check (list string)) "no dependencies" []
    (Live.dependencies (Compound_shape cs))

(* --- Phase 4c: reference-geometry recompute cache (mirror of the Rust
   live.rs Phase-4c tests) -------------------------------------------- *)
(*
   PER-APP perf cache (REFERENCE_GRAPH.md section 2.3). No behavior change:
   every assertion pins eval RESULTS against a fresh eval, while additionally
   checking the cache STATE (Pure / Has_refs / absent). The [assert (cached =
   fresh)] gate inside the lookup also fires on every Pure hit here. *)

(* A rect with explicit width/height (the [rect_at] helper is fixed 10x10). *)
let rect_wh x y w h =
  Rect { name = None; id = None; x; y; width = w; height = h; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
         fill_gradient = None; stroke_gradient = None }

let circle_at cx cy r =
  Circle { name = None; id = None; cx; cy; r;
           fill = None; stroke = None; opacity = 1.0; transform = None;
           locked = false; visibility = Preview; blend_mode = Normal; mask = None;
           fill_gradient = None; stroke_gradient = None }

(* A resolver whose backing store can be mutated between evaluations so a test
   can simulate an edit to the target. Mirrors the Rust CellResolver. *)
let cell_resolver () =
  let store = ref [] in
  let resolver : Live.element_resolver = fun id -> List.assoc_opt id !store in
  let set id elem = store := (id, elem) :: List.remove_assoc id !store in
  (resolver, set)

(* Evaluate the target the cache would obtain, with a fresh visit set so the
   comparison oracle is independent of cache state. *)
let fresh_target_geom target precision resolver =
  let v = ref Live.VisitSet.empty in
  Live.element_to_polygon_set_with target precision resolver v

let test_subtree_has_reference_detects_nested_reference () =
  (* A bare rect has no reference. *)
  Alcotest.(check bool) "bare rect" false
    (Live.subtree_has_reference (rect_at 0.0 0.0));
  (* A group of rects has no reference. *)
  let group = make_group [| rect_at 0.0 0.0; rect_at 5.0 0.0 |] in
  Alcotest.(check bool) "group of rects" false (Live.subtree_has_reference group);
  (* A group containing a reference DOES have one (the stale hazard). *)
  let group_with_ref =
    make_group [| rect_at 0.0 0.0; Live (Reference (reference_elem "x")) |] in
  Alcotest.(check bool) "group with reference" true
    (Live.subtree_has_reference group_with_ref);
  (* A compound shape whose operand is a reference also has one. *)
  let compound_with_ref = Live (Compound_shape {
    operation = Op_union; id = None;
    operands = [| rect_at 0.0 0.0; Live (Reference (reference_elem "x")) |];
    fill = None; stroke = None; opacity = 1.0; transform = None;
    locked = false; visibility = Preview; blend_mode = Normal; mask = None;
  }) in
  Alcotest.(check bool) "compound with reference" true
    (Live.subtree_has_reference compound_with_ref)

let test_pure_target_reference_is_cached_and_second_eval_hits () =
  (* A pure-geometry target referenced by an instance: first eval populates a
     Pure entry; a second eval at the same generation reuses it (the gate
     confirms cached = fresh) and the RESULT equals a fresh eval. *)
  Live.clear_recompute_cache_for_test ();
  Live.set_recompute_cache_generation 7;
  let (resolver, set) = cell_resolver () in
  set "r1" (rect_at 0.0 0.0);
  let r = reference_elem "r1" in
  Alcotest.(check bool) "no entry before eval" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision = None);
  let v1 = ref Live.VisitSet.empty in
  let first = Live.reference_evaluate r Live.default_precision resolver v1 in
  Alcotest.(check bool) "Pure entry after eval" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision
     = Some Live.Pure_state);
  let target = match resolver "r1" with
    | Some t -> t | None -> Alcotest.fail "r1 missing" in
  Alcotest.(check bool) "result equals fresh eval" true
    (first = fresh_target_geom target Live.default_precision resolver);
  let v2 = ref Live.VisitSet.empty in
  let second = Live.reference_evaluate r Live.default_precision resolver v2 in
  Alcotest.(check bool) "second eval same result" true (first = second);
  Alcotest.(check bool) "still Pure" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision
     = Some Live.Pure_state)

let test_editing_target_new_generation_re_evaluates_no_stale () =
  (* Editing the target bumps the generation; the epoch clears the cache so the
     next eval recomputes against the NEW target. No stale geometry survives. *)
  Live.clear_recompute_cache_for_test ();
  Live.set_recompute_cache_generation 1;
  let (resolver, set) = cell_resolver () in
  set "r1" (rect_at 0.0 0.0);                  (* 10x10 *)
  let r = reference_elem "r1" in
  let v1 = ref Live.VisitSet.empty in
  let before = Live.reference_evaluate r Live.default_precision resolver v1 in
  let (_, _, bmaxx, _) = bbox_of_ring (List.hd before) in
  Alcotest.(check bool) "before max_x = 10" true (approx_equal bmaxx 10.0);
  Alcotest.(check bool) "Pure" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision
     = Some Live.Pure_state);
  (* Edit: a larger rect, AND advance the generation, as a real edit would. *)
  set "r1" (rect_wh 0.0 0.0 40.0 40.0);
  Live.set_recompute_cache_generation 2;
  Alcotest.(check bool) "cache cleared by epoch" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision = None);
  let v2 = ref Live.VisitSet.empty in
  let after = Live.reference_evaluate r Live.default_precision resolver v2 in
  let (_, _, amaxx, _) = bbox_of_ring (List.hd after) in
  Alcotest.(check bool) "after max_x = 40 (edited target)" true
    (approx_equal amaxx 40.0);
  let target = match resolver "r1" with
    | Some t -> t | None -> Alcotest.fail "r1 missing" in
  Alcotest.(check bool) "equals fresh eval of new target" true
    (after = fresh_target_geom target Live.default_precision resolver)

let test_ref_containing_target_is_not_cached_and_tracks_nested_edits () =
  (* A target that CONTAINS a nested reference must NOT be cached as Pure: its
     resolved geometry depends on the nested target AND on the ambient
     cycle-guard (visiting) state, so it is never safe to share. It is recorded
     [Has_refs] and re-resolved fresh on every lookup.

     OPTION-B DIVERGENCE FROM RUST (REFERENCE_GRAPH.md section 2.3): the Rust
     test mutates the nested target WITHOUT bumping the generation, relying on
     Rust's per-entry [Rc::as_ptr] check to invalidate. This app rebuilds the
     index at the mutation chokepoint, so every edit bumps the generation and a
     pure target never goes stale within a generation — there is no
     mutate-without-bump scenario and no pointer check. The meaningful pin here
     is the real edit path: the ref-containing target is [Has_refs] (so it
     re-resolves), and a nested edit, which bumps the generation, is reflected. *)
  Live.clear_recompute_cache_for_test ();
  Live.set_recompute_cache_generation 5;
  let (resolver, set) = cell_resolver () in
  set "x" (rect_at 0.0 0.0);                    (* nested leaf, 10x10 *)
  let g = make_group [| Live (Reference (reference_elem "x")) |] in
  set "g" g;                                    (* outer = group referencing x *)
  let outer = reference_elem "g" in
  let v1 = ref Live.VisitSet.empty in
  let first = Live.reference_evaluate outer Live.default_precision resolver v1 in
  Alcotest.(check bool) "g recorded Has_refs (never Pure-cached)" true
    (Live.recompute_cache_state_for_test "g" Live.default_precision
     = Some Live.Has_refs_state);
  let (_, _, fmaxx, _) = bbox_of_ring (List.hd first) in
  Alcotest.(check bool) "first max_x = 10" true (approx_equal fmaxx 10.0);
  (* A no-edit repaint (same generation) re-resolves "g" fresh because it is
     Has_refs — the cache never serves a ref-containing target's geometry. *)
  let v1b = ref Live.VisitSet.empty in
  let again = Live.reference_evaluate outer Live.default_precision resolver v1b in
  Alcotest.(check bool) "same-generation repaint is consistent" true
    (again = first);
  (* Edit the NESTED target — a real edit, which bumps the generation. The
     epoch clears the cache; the next eval reflects the new nested geometry. *)
  set "x" (rect_wh 0.0 0.0 30.0 30.0);
  Live.set_recompute_cache_generation 6;
  let v2 = ref Live.VisitSet.empty in
  let second = Live.reference_evaluate outer Live.default_precision resolver v2 in
  let (_, _, smaxx, _) = bbox_of_ring (List.hd second) in
  Alcotest.(check bool) "nested edit reflected after gen bump (max_x = 30)" true
    (approx_equal smaxx 30.0);
  Alcotest.(check bool) "still Has_refs, never Pure" true
    (Live.recompute_cache_state_for_test "g" Live.default_precision
     = Some Live.Has_refs_state)

let test_instance_transform_composes_on_cached_pure_geometry () =
  (* The per-reference instance transform is applied AFTER the (shared, cached)
     target geometry. A plain instance caches the untransformed target; a
     scaled instance of the SAME target reuses that cache and applies its own
     transform on top. *)
  Live.clear_recompute_cache_for_test ();
  Live.set_recompute_cache_generation 9;
  let (resolver, set) = cell_resolver () in
  set "r1" (rect_at 0.0 0.0);
  let plain = reference_elem "r1" in
  let v1 = ref Live.VisitSet.empty in
  let plain_ps = Live.reference_evaluate plain Live.default_precision resolver v1 in
  Alcotest.(check bool) "Pure after plain" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision
     = Some Live.Pure_state);
  let (_, _, pmaxx, pmaxy) = bbox_of_ring (List.hd plain_ps) in
  Alcotest.(check bool) "plain max 10,10" true
    (approx_equal pmaxx 10.0 && approx_equal pmaxy 10.0);
  let scaled = { (reference_elem "r1") with
                 ref_instance_transform = Some (make_scale 2.0 2.0) } in
  let v2 = ref Live.VisitSet.empty in
  let scaled_ps = Live.reference_evaluate scaled Live.default_precision resolver v2 in
  let (sminx, sminy, smaxx, smaxy) = bbox_of_ring (List.hd scaled_ps) in
  Alcotest.(check bool) "scaled min at origin" true
    (approx_equal sminx 0.0 && approx_equal sminy 0.0);
  Alcotest.(check bool) "scaled max 20,20" true
    (approx_equal smaxx 20.0 && approx_equal smaxy 20.0);
  Alcotest.(check bool) "cache still holds untransformed Pure geometry" true
    (Live.recompute_cache_state_for_test "r1" Live.default_precision
     = Some Live.Pure_state)

let test_cache_keys_on_precision () =
  (* The two render passes use different precision. The cache key includes
     precision, so a circle tessellated at one precision never serves a request
     at another (which would be a wrong-detail result). *)
  Live.clear_recompute_cache_for_test ();
  Live.set_recompute_cache_generation 3;
  let (resolver, set) = cell_resolver () in
  set "c1" (circle_at 0.0 0.0 100.0);
  let r = reference_elem "c1" in
  let coarse = 1.0 and fine = 0.01 in
  let v1 = ref Live.VisitSet.empty in
  let ps_coarse = Live.reference_evaluate r coarse resolver v1 in
  let v2 = ref Live.VisitSet.empty in
  let ps_fine = Live.reference_evaluate r fine resolver v2 in
  Alcotest.(check bool) "different precision different tessellation" true
    (Array.length (List.hd ps_coarse) <> Array.length (List.hd ps_fine));
  Alcotest.(check bool) "coarse key Pure" true
    (Live.recompute_cache_state_for_test "c1" coarse = Some Live.Pure_state);
  Alcotest.(check bool) "fine key Pure" true
    (Live.recompute_cache_state_for_test "c1" fine = Some Live.Pure_state)

(* --- RecordedElem (RECORDED_ELEMENTS.md — history-based provenance) ----- *)

let recorded_op op params : recorded_op =
  { rop_op = op; rop_params = params; rop_targets = [] }

(* A recorded element whose recipe copies its input "eye", then translates
   the derived copy +50x. *)
let recorded_eye () : recorded_elem =
  let ops = [
    recorded_op "copy" (`Assoc [ ("from", `List [ `String "eye" ]);
                                 ("dx", `Float 0.0); ("dy", `Float 0.0) ]);
    recorded_op "translate" (`Assoc [ ("ids", `List [ `String "$0" ]);
                                      ("dx", `Float 50.0); ("dy", `Float 0.0) ]);
  ] in
  { rec_ops = ops;
    rec_inputs = [ "eye" ];
    rec_id = Some "rec";
    rec_fill = None; rec_stroke = None; rec_opacity = 1.0;
    rec_transform = None; rec_locked = false;
    rec_visibility = Preview; rec_blend_mode = Normal; rec_mask = None }

let test_recorded_replays_copy_translate_and_re_derives () =
  let rec_ = recorded_eye () in
  (* Source eye at (0,0,10,10) -> derived copy translated +50 -> bbox [50,60]. *)
  let resolver = map_resolver [ ("eye", rect_at 0.0 0.0) ] in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.recorded_evaluate rec_ Live.default_precision resolver visiting in
  Alcotest.(check int) "one derived output element" 1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "min_x = 50" true (approx_equal min_x 50.0);
  Alcotest.(check bool) "max_x = 60" true (approx_equal max_x 60.0);
  (* Edit the source eye (move to x=100) -> the derived copy follows. *)
  let resolver2 = map_resolver [ ("eye", rect_at 100.0 0.0) ] in
  let visiting2 = ref Live.VisitSet.empty in
  let ps2 = Live.recorded_evaluate rec_ Live.default_precision resolver2 visiting2 in
  let (min_x2, _, max_x2, _) = bbox_of_ring (List.hd ps2) in
  Alcotest.(check bool) "derived copy re-derived min_x = 150" true
    (approx_equal min_x2 150.0);
  Alcotest.(check bool) "derived copy re-derived max_x = 160" true
    (approx_equal max_x2 160.0)

let test_recorded_dangling_input_evaluates_empty () =
  let ops = [ recorded_op "copy"
                (`Assoc [ ("from", `List [ `String "x" ]);
                          ("dx", `Float 0.0); ("dy", `Float 0.0) ]) ] in
  let rec_ : recorded_elem =
    { rec_ops = ops; rec_inputs = [ "x" ]; rec_id = None;
      rec_fill = None; rec_stroke = None; rec_opacity = 1.0;
      rec_transform = None; rec_locked = false;
      rec_visibility = Preview; rec_blend_mode = Normal; rec_mask = None } in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.recorded_evaluate rec_ Live.default_precision
             Live.null_resolver visiting in
  Alcotest.(check bool) "dangling input evaluates empty, never fails" true
    (ps = [])

let test_recorded_reports_inputs_as_dependencies () =
  let rec_ = recorded_eye () in
  Alcotest.(check (list string)) "dependencies are the inputs" ["eye"]
    (Live.dependencies (Recorded rec_))

let test_recorded_round_trips_and_serializes () =
  (* RecordedElem as a real live variant in a document: it survives the
     binary codec round-trip and serializes the recorded kind + recipe via
     test_json. *)
  let rec_ = recorded_eye () in
  let layer = Layer { name = None; id = None;
    children = [| Live (Recorded rec_) |];
    opacity = 1.0; transform = None; locked = false; visibility = Preview;
    blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false } in
  let doc = Jas.Document.make_document ~artboards:[] [| layer |] in
  let json = Jas.Test_json.document_to_test_json doc in
  let contains needle =
    let nl = String.length needle and hl = String.length json in
    let rec go i = i + nl <= hl
      && (String.sub json i nl = needle || go (i + 1)) in
    go 0 in
  Alcotest.(check bool) "serializes kind=recorded" true
    (contains "\"kind\":\"recorded\"");
  Alcotest.(check bool) "serializes the input ids" true
    (contains "\"inputs\":[\"eye\"]");
  Alcotest.(check bool) "serializes the recipe ops" true
    (contains "\"op\":\"copy\"");
  (* Binary round-trip preserves the recorded element (compare canonical JSON,
     since Document has no structural equality across the codec). *)
  let bytes = Jas.Binary.document_to_binary ~compress:false doc in
  let back = Jas.Binary.binary_to_document bytes in
  Alcotest.(check string) "recorded element survives the binary round-trip"
    json (Jas.Test_json.document_to_test_json back)

let test_capture_recipe_normalizes_select_copy_move () =
  (* A captured journal segment ("watch what I did"): select the eye, copy
     it, move the copy. select_rect carries its resolved targets. *)
  let segment = [
    { rop_op = "select_rect"; rop_params = `Assoc []; rop_targets = ["eye"] };
    recorded_op "copy_selection" (`Assoc [ ("dx", `Float 0.0); ("dy", `Float 0.0) ]);
    recorded_op "move_selection" (`Assoc [ ("dx", `Float 50.0); ("dy", `Float 0.0) ]);
  ] in
  let (recipe, inputs) = Live.capture_recipe segment in
  Alcotest.(check (list string)) "the read element is the input" ["eye"] inputs;
  Alcotest.(check int) "recipe has two ops" 2 (List.length recipe);
  let op0 = List.nth recipe 0 and op1 = List.nth recipe 1 in
  Alcotest.(check string) "first op is copy" "copy" op0.rop_op;
  Alcotest.(check string) "second op is translate" "translate" op1.rop_op;
  let from_of op = match op.rop_params with
    | `Assoc fields -> (match List.assoc_opt "from" fields with
        | Some (`List items) ->
          List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> [])
    | _ -> [] in
  let ids_of op = match op.rop_params with
    | `Assoc fields -> (match List.assoc_opt "ids" fields with
        | Some (`List items) ->
          List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> [])
    | _ -> [] in
  Alcotest.(check (list string)) "copy from = [eye]" ["eye"] (from_of op0);
  Alcotest.(check (list string)) "translate targets the produced copy"
    ["$0"] (ids_of op1);
  (* The captured recipe replays + re-derives like the hand-built one. *)
  let rec_ : recorded_elem =
    { rec_ops = recipe; rec_inputs = inputs; rec_id = Some "rec";
      rec_fill = None; rec_stroke = None; rec_opacity = 1.0;
      rec_transform = None; rec_locked = false;
      rec_visibility = Preview; rec_blend_mode = Normal; rec_mask = None } in
  let resolver = map_resolver [ ("eye", rect_at 0.0 0.0) ] in
  let visiting = ref Live.VisitSet.empty in
  let ps = Live.recorded_evaluate rec_ Live.default_precision resolver visiting in
  Alcotest.(check int) "one ring" 1 (List.length ps);
  let (min_x, _, max_x, _) = bbox_of_ring (List.hd ps) in
  Alcotest.(check bool) "captured recipe replays to demonstrated output min_x = 50"
    true (approx_equal min_x 50.0);
  Alcotest.(check bool) "captured recipe replays to demonstrated output max_x = 60"
    true (approx_equal max_x 60.0)

let () =
  Alcotest.run "Live"
    [ "compound shape", [
        Alcotest.test_case "rect to polygon set" `Quick
          test_element_to_polygon_set_rect;
        Alcotest.test_case "union of two rects" `Quick
          test_union_of_two_rects;
        Alcotest.test_case "intersection of two rects" `Quick
          test_intersection_of_two_rects;
        Alcotest.test_case "exclude is symmetric difference" `Quick
          test_exclude_is_symmetric_difference;
        Alcotest.test_case "subtract front" `Quick
          test_subtract_front;
        Alcotest.test_case "bounds reflect evaluation" `Quick
          test_bounds_reflect_evaluation;
        Alcotest.test_case "empty compound has empty bounds" `Quick
          test_empty_compound_has_empty_bounds;
        Alcotest.test_case "path flattens to polygon set" `Quick
          test_path_flattens_into_polygon_set;
      ];
      "reference", [
        Alcotest.test_case "reference evaluates to target geometry" `Quick
          test_reference_evaluates_to_target;
        Alcotest.test_case "dangling reference evaluates empty" `Quick
          test_dangling_reference_is_empty;
        Alcotest.test_case "reference cycle breaks to empty" `Quick
          test_reference_cycle_breaks_to_empty;
        Alcotest.test_case "reference reports its target as dependency" `Quick
          test_reference_reports_dependency;
        Alcotest.test_case "resolver_of_document resolves reference" `Quick
          test_resolver_of_document_resolves_reference;
        Alcotest.test_case "compound shape has no dependencies" `Quick
          test_compound_has_no_dependencies;
        Alcotest.test_case "instance transform scales target geometry" `Quick
          test_reference_instance_transform_scales_target;
        Alcotest.test_case "None instance transform leaves eval unchanged" `Quick
          test_reference_none_instance_transform_unchanged;
      ];
      "id index (Phase 4b)", [
        Alcotest.test_case "rebuild_id_index indexes descendants + sorted masters"
          `Quick test_rebuild_id_index_indexes_descendants_and_sorted_masters;
        Alcotest.test_case "rebuild_id_index matches legacy resolver, order-stable"
          `Quick test_rebuild_id_index_matches_legacy_resolver_and_is_order_stable;
      ];
      "recompute cache (Phase 4c)", [
        Alcotest.test_case "subtree_has_reference detects nested reference"
          `Quick test_subtree_has_reference_detects_nested_reference;
        Alcotest.test_case "pure target is cached and second eval hits"
          `Quick test_pure_target_reference_is_cached_and_second_eval_hits;
        Alcotest.test_case "editing target (new generation) re-evaluates, no stale"
          `Quick test_editing_target_new_generation_re_evaluates_no_stale;
        Alcotest.test_case "ref-containing target not cached, tracks nested edits"
          `Quick test_ref_containing_target_is_not_cached_and_tracks_nested_edits;
        Alcotest.test_case "instance transform composes on cached pure geometry"
          `Quick test_instance_transform_composes_on_cached_pure_geometry;
        Alcotest.test_case "cache keys on precision"
          `Quick test_cache_keys_on_precision;
      ];
      "recorded (RECORDED_ELEMENTS.md)", [
        Alcotest.test_case "replays copy+translate and re-derives on input edit"
          `Quick test_recorded_replays_copy_translate_and_re_derives;
        Alcotest.test_case "dangling input evaluates empty"
          `Quick test_recorded_dangling_input_evaluates_empty;
        Alcotest.test_case "reports its inputs as dependencies"
          `Quick test_recorded_reports_inputs_as_dependencies;
        Alcotest.test_case "round-trips through binary codec and serializes"
          `Quick test_recorded_round_trips_and_serializes;
        Alcotest.test_case "capture_recipe normalizes select->copy->move"
          `Quick test_capture_recipe_normalizes_select_copy_move;
      ]
    ]
