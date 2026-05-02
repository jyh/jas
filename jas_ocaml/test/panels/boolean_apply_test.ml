(** Tests for Boolean_apply — compound-shape menu dispatch.
    Mirrors jas_dioxus controller_test.rs boolean cases. *)

open Jas.Element
module Model = Jas.Model
module Document = Jas.Document
module Boolean_apply = Jas.Boolean_apply

let rect_at x y =
  Rect { name = None; x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = None; stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
           fill_gradient = None;
           stroke_gradient = None;
         }

let make_model rects selected_paths =
  let layer = Layer {
    name = "L0";
    children = Array.of_list rects;
    opacity = 1.0; transform = None; locked = false; visibility = Preview; blend_mode = Normal;
    mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let sel = List.fold_left (fun acc path ->
    Document.PathMap.add path (Document.make_element_selection path) acc
  ) Document.PathMap.empty selected_paths in
  let doc = { (Document.make_document [| layer |]) with Document.selection = sel } in
  new Model.model ~document:doc ()

let top_children_count (model : Model.model) =
  match model#document.Document.layers.(0) with
  | Layer { children; _ } -> Array.length children
  | _ -> -1

let test_make_wraps_selection_in_one_compound () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Alcotest.(check int) "one child" 1 (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Live _ -> ()
     | _ -> Alcotest.fail "expected Live element")
  | _ -> Alcotest.fail "expected Layer"

let test_less_than_two_is_noop () =
  let model = make_model [rect_at 0.0 0.0] [[0; 0]] in
  Boolean_apply.apply_make_compound_shape model;
  Alcotest.(check int) "one child" 1 (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Rect _ -> ()
     | _ -> Alcotest.fail "expected Rect")
  | _ -> Alcotest.fail "expected Layer"

let test_release_restores_operands () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Boolean_apply.apply_release_compound_shape model;
  Alcotest.(check int) "two children" 2 (top_children_count model)

let test_expand_replaces_with_polygons () =
  let model = make_model [rect_at 0.0 0.0; rect_at 5.0 0.0]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_make_compound_shape model;
  Boolean_apply.apply_expand_compound_shape model;
  Alcotest.(check int) "one child (union to 1 polygon)" 1
    (top_children_count model);
  match model#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Polygon _ -> ()
     | _ -> Alcotest.fail "expected Polygon")
  | _ -> Alcotest.fail "expected Layer"

(* ── Destructive boolean tests ──────────────────────────────── *)

let two_overlapping () =
  make_model [rect_at 0.0 0.0; rect_at 5.0 0.0] [[0; 0]; [0; 1]]

let test_union_produces_one_polygon () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "union";
  Alcotest.(check int) "one polygon" 1 (top_children_count m);
  match m#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Polygon _ -> ()
     | _ -> Alcotest.fail "expected Polygon")
  | _ -> Alcotest.fail "expected Layer"

let test_intersection_produces_one_polygon () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "intersection";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_exclude_produces_two_polygons () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "exclude";
  Alcotest.(check int) "two polygons" 2 (top_children_count m)

let test_subtract_front_consumes_front () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "subtract_front";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_subtract_back_consumes_back () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "subtract_back";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_crop_uses_frontmost_as_mask () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "crop";
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_unknown_op_is_noop () =
  let m = two_overlapping () in
  let before = top_children_count m in
  Boolean_apply.apply_destructive_boolean m "nonexistent";
  Alcotest.(check int) "unchanged" before (top_children_count m)

(* ── DIVIDE / TRIM / MERGE tests ────────────────────────────── *)

let rect_with_fill x y color =
  Rect { name = None; x; y; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
         fill = Some { fill_color = color; fill_opacity = 1.0 };
         stroke = None; opacity = 1.0; transform = None;
         locked = false; visibility = Preview; blend_mode = Normal; mask = None;
           fill_gradient = None;
           stroke_gradient = None;
         }

let disjoint_rects () =
  make_model [rect_at 0.0 0.0; rect_at 20.0 0.0] [[0; 0]; [0; 1]]

let test_divide_two_overlapping_produces_three_fragments () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "divide";
  Alcotest.(check int) "three fragments" 3 (top_children_count m)

let test_divide_disjoint_keeps_two () =
  let m = disjoint_rects () in
  Boolean_apply.apply_destructive_boolean m "divide";
  Alcotest.(check int) "two fragments" 2 (top_children_count m)

let test_trim_two_overlapping_keeps_two () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "trim";
  Alcotest.(check int) "two outputs" 2 (top_children_count m)

let test_trim_fully_covered_operand_vanishes () =
  let back = rect_at 0.0 0.0 in
  let front = Rect { name = None; x = 0.0; y = 0.0; width = 20.0; height = 20.0;
                     rx = 0.0; ry = 0.0; fill = None; stroke = None;
                     opacity = 1.0; transform = None; locked = false;
                     visibility = Preview; blend_mode = Normal; mask = None;
                       fill_gradient = None;
                       stroke_gradient = None;
                     } in
  let m = make_model [back; front] [[0; 0]; [0; 1]] in
  Boolean_apply.apply_destructive_boolean m "trim";
  Alcotest.(check int) "front only" 1 (top_children_count m)

let test_merge_matching_fills_combine () =
  let red = color_rgb 1.0 0.0 0.0 in
  let m = make_model
    [rect_with_fill 0.0 0.0 red; rect_with_fill 5.0 0.0 red]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_destructive_boolean m "merge";
  Alcotest.(check int) "one merged" 1 (top_children_count m)

let test_merge_mismatched_fills_stay_separate () =
  let red = color_rgb 1.0 0.0 0.0 in
  let blue = color_rgb 0.0 0.0 1.0 in
  let m = make_model
    [rect_with_fill 0.0 0.0 red; rect_with_fill 5.0 0.0 blue]
    [[0; 0]; [0; 1]] in
  Boolean_apply.apply_destructive_boolean m "merge";
  Alcotest.(check int) "two separate" 2 (top_children_count m)

let test_merge_none_fill_never_matches () =
  let m = two_overlapping () in
  Boolean_apply.apply_destructive_boolean m "merge";
  Alcotest.(check int) "two separate" 2 (top_children_count m)

(* ── Compound creation (Alt+click) tests ────────────────────── *)

let cs_operation (m : Model.model) =
  match m#document.Document.layers.(0) with
  | Layer { children; _ } ->
    (match children.(0) with
     | Live (Compound_shape cs) -> Some cs.operation
     | _ -> None)
  | _ -> None

let test_union_compound_uses_union () =
  let m = two_overlapping () in
  Boolean_apply.apply_compound_creation m "union";
  (match cs_operation m with
   | Some Op_union -> ()
   | _ -> Alcotest.fail "expected Op_union compound")

let test_subtract_front_compound_uses_subtract_front () =
  let m = two_overlapping () in
  Boolean_apply.apply_compound_creation m "subtract_front";
  (match cs_operation m with
   | Some Op_subtract_front -> ()
   | _ -> Alcotest.fail "expected Op_subtract_front compound")

let test_intersection_compound_uses_intersection () =
  let m = two_overlapping () in
  Boolean_apply.apply_compound_creation m "intersection";
  (match cs_operation m with
   | Some Op_intersection -> ()
   | _ -> Alcotest.fail "expected Op_intersection compound")

let test_exclude_compound_uses_exclude () =
  let m = two_overlapping () in
  Boolean_apply.apply_compound_creation m "exclude";
  (match cs_operation m with
   | Some Op_exclude -> ()
   | _ -> Alcotest.fail "expected Op_exclude compound")

let test_compound_creation_unknown_op_is_noop () =
  let m = two_overlapping () in
  Boolean_apply.apply_compound_creation m "nonexistent";
  Alcotest.(check int) "rects unchanged" 2 (top_children_count m)

(* ── Boolean options / Repeat / Reset tests ─────────────────── *)

let test_collapse_collinear_drops_midpoint () =
  let ring = [| (0.0, 0.0); (5.0, 0.0); (10.0, 0.0);
                (10.0, 10.0); (0.0, 10.0) |] in
  let collapsed = Boolean_apply.collapse_collinear_points ring 0.01 in
  (* (5, 0) is collinear and should drop. *)
  Alcotest.(check int) "one point dropped" 4 (Array.length collapsed)

let test_collapse_preserves_triangle_corners () =
  let ring = [| (0.0, 0.0); (10.0, 0.0); (5.0, 10.0) |] in
  let collapsed = Boolean_apply.collapse_collinear_points ring 0.01 in
  Alcotest.(check int) "triangle preserved" 3 (Array.length collapsed)

let test_divide_remove_unpainted_drops_unfilled () =
  let m = two_overlapping () in
  let opts = { Boolean_apply.default_boolean_options with
               divide_remove_unpainted = true } in
  Boolean_apply.apply_destructive_boolean ~options:opts m "divide";
  Alcotest.(check int) "all fragments dropped" 0 (top_children_count m)

let test_repeat_destructive_replays_op () =
  let m = two_overlapping () in
  Boolean_apply.apply_repeat_boolean_operation m (Some "union");
  Alcotest.(check int) "one polygon" 1 (top_children_count m)

let test_repeat_compound_replays_compound_creation () =
  let m = two_overlapping () in
  Boolean_apply.apply_repeat_boolean_operation m (Some "intersection_compound");
  match cs_operation m with
  | Some Op_intersection -> ()
  | _ -> Alcotest.fail "expected intersection compound"

let test_repeat_none_is_noop () =
  let m = two_overlapping () in
  Boolean_apply.apply_repeat_boolean_operation m None;
  Alcotest.(check int) "unchanged" 2 (top_children_count m)

let test_repeat_empty_string_is_noop () =
  let m = two_overlapping () in
  Boolean_apply.apply_repeat_boolean_operation m (Some "");
  Alcotest.(check int) "unchanged" 2 (top_children_count m)

let () =
  Alcotest.run "Boolean_apply"
    [ "compound shape", [
        Alcotest.test_case "make wraps selection" `Quick
          test_make_wraps_selection_in_one_compound;
        Alcotest.test_case "less than two is noop" `Quick
          test_less_than_two_is_noop;
        Alcotest.test_case "release restores operands" `Quick
          test_release_restores_operands;
        Alcotest.test_case "expand replaces with polygons" `Quick
          test_expand_replaces_with_polygons;
      ];
      "destructive boolean", [
        Alcotest.test_case "union produces one polygon" `Quick
          test_union_produces_one_polygon;
        Alcotest.test_case "intersection produces one polygon" `Quick
          test_intersection_produces_one_polygon;
        Alcotest.test_case "exclude produces two polygons" `Quick
          test_exclude_produces_two_polygons;
        Alcotest.test_case "subtract_front consumes front" `Quick
          test_subtract_front_consumes_front;
        Alcotest.test_case "subtract_back consumes back" `Quick
          test_subtract_back_consumes_back;
        Alcotest.test_case "crop uses frontmost as mask" `Quick
          test_crop_uses_frontmost_as_mask;
        Alcotest.test_case "unknown op is noop" `Quick
          test_unknown_op_is_noop;
      ];
      "divide trim merge", [
        Alcotest.test_case "divide overlapping produces three" `Quick
          test_divide_two_overlapping_produces_three_fragments;
        Alcotest.test_case "divide disjoint keeps two" `Quick
          test_divide_disjoint_keeps_two;
        Alcotest.test_case "trim overlapping keeps two" `Quick
          test_trim_two_overlapping_keeps_two;
        Alcotest.test_case "trim fully covered operand vanishes" `Quick
          test_trim_fully_covered_operand_vanishes;
        Alcotest.test_case "merge matching fills combine" `Quick
          test_merge_matching_fills_combine;
        Alcotest.test_case "merge mismatched fills stay separate" `Quick
          test_merge_mismatched_fills_stay_separate;
        Alcotest.test_case "merge none fill never matches" `Quick
          test_merge_none_fill_never_matches;
      ];
      "compound creation", [
        Alcotest.test_case "union compound uses union" `Quick
          test_union_compound_uses_union;
        Alcotest.test_case "subtract_front compound uses subtract_front" `Quick
          test_subtract_front_compound_uses_subtract_front;
        Alcotest.test_case "intersection compound uses intersection" `Quick
          test_intersection_compound_uses_intersection;
        Alcotest.test_case "exclude compound uses exclude" `Quick
          test_exclude_compound_uses_exclude;
        Alcotest.test_case "unknown op is noop" `Quick
          test_compound_creation_unknown_op_is_noop;
      ];
      "boolean options and repeat", [
        Alcotest.test_case "collapse collinear drops midpoint" `Quick
          test_collapse_collinear_drops_midpoint;
        Alcotest.test_case "collapse preserves triangle corners" `Quick
          test_collapse_preserves_triangle_corners;
        Alcotest.test_case "divide remove unpainted drops unfilled" `Quick
          test_divide_remove_unpainted_drops_unfilled;
        Alcotest.test_case "repeat destructive replays op" `Quick
          test_repeat_destructive_replays_op;
        Alcotest.test_case "repeat compound replays compound creation" `Quick
          test_repeat_compound_replays_compound_creation;
        Alcotest.test_case "repeat none is noop" `Quick
          test_repeat_none_is_noop;
        Alcotest.test_case "repeat empty string is noop" `Quick
          test_repeat_empty_string_is_noop;
      ]
    ]
