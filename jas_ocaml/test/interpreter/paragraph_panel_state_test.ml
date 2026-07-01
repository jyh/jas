(** Cross-language SEAM tests for the Paragraph panel selection-driven
    state. Mirrors Python's jas/panels/paragraph_panel_state_test.py:
    the text-kind gating (point / area / text-path / empty / non-text),
    the wrapper-attr read-back, and the mutual-exclusion helper are
    pinned to the SAME input -> output values so the two apps stay
    equivalent. *)

open Jas

(* ── helpers ─────────────────────────────────────────────── *)

let bool_of = function `Bool b -> b | _ -> failwith "not bool"
let float_of = function `Float f -> f | `Int i -> float_of_int i
                      | _ -> failwith "not number"
let string_of = function `String s -> s | _ -> failwith "not string"

let model_with_elems elems_with_paths =
  let elems = List.map snd elems_with_paths in
  let layer = Element.make_layer (Array.of_list elems) in
  let selection = List.fold_left (fun acc (path, _) ->
    Document.PathMap.add path (Document.make_element_selection path) acc)
    Document.PathMap.empty elems_with_paths in
  let doc = Document.make_document ~selection [| layer |] in
  Model.create ~document:doc ()

(* Full Phase-3b/4 default panel scope so set_panel has somewhere to
   write (OCaml set_panel is a no-op on an uninitialised scope). *)
let store_with_panel () =
  let s = State_store.create () in
  State_store.init_panel s "paragraph_panel_content" [
    ("text_selected", `Bool true); ("area_text_selected", `Bool true);
    ("align_left", `Bool true); ("align_center", `Bool false);
    ("align_right", `Bool false); ("justify_left", `Bool false);
    ("justify_center", `Bool false); ("justify_right", `Bool false);
    ("justify_all", `Bool false);
    ("left_indent", `Int 0); ("right_indent", `Int 0);
    ("hyphenate", `Bool false); ("hanging_punctuation", `Bool false);
    ("bullets", `String ""); ("numbered_list", `String "");
  ];
  s

let getp s k = State_store.get_panel s "paragraph_panel_content" k

(* Build an area Text carrying explicit tspans (a paragraph wrapper +
   body). make_text derives tspans from content, so we splice ours in. *)
let area_text_with_tspans tspans =
  match Element.make_text ~text_width:200.0 ~text_height:100.0
          0.0 0.0 "hello" with
  | Element.Text r -> Element.Text { r with tspans = Array.of_list tspans }
  | e -> e

let wrapper ?(left = None) ?(right = None) ?(hyph = None)
    ?(hang = None) ?(list_style = None) id =
  { (Tspan.default_tspan ()) with
    id; content = ""; jas_role = Some "paragraph";
    jas_left_indent = left; jas_right_indent = right;
    jas_hyphenate = hyph; jas_hanging_punctuation = hang;
    jas_list_style = list_style }

let body id content = { (Tspan.default_tspan ()) with id; content }

(* ── text-kind gating (sync_paragraph_panel_from_selection) ── *)

let kind_tests = [
  Alcotest.test_case "empty_selection_disables" `Quick (fun () ->
    let model = model_with_elems [] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" false (bool_of (getp s "text_selected"));
    Alcotest.(check bool) "area" false (bool_of (getp s "area_text_selected")));

  Alcotest.test_case "non_text_selection_disables" `Quick (fun () ->
    let r = Element.make_rect 0.0 0.0 10.0 10.0 in
    let model = model_with_elems [([0; 0], r)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" false (bool_of (getp s "text_selected"));
    Alcotest.(check bool) "area" false (bool_of (getp s "area_text_selected")));

  Alcotest.test_case "point_text_universal_only" `Quick (fun () ->
    (* width=0, height=0 -> point text -> text true, area false. *)
    let t = Element.make_text ~text_width:0.0 ~text_height:0.0
              0.0 0.0 "hi" in
    let model = model_with_elems [([0; 0], t)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" true (bool_of (getp s "text_selected"));
    Alcotest.(check bool) "area" false (bool_of (getp s "area_text_selected")));

  Alcotest.test_case "area_text_enables_all" `Quick (fun () ->
    let t = Element.make_text ~text_width:200.0 ~text_height:100.0
              0.0 0.0 "hello" in
    let model = model_with_elems [([0; 0], t)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" true (bool_of (getp s "text_selected"));
    Alcotest.(check bool) "area" true (bool_of (getp s "area_text_selected")));

  Alcotest.test_case "text_path_universal_only" `Quick (fun () ->
    let tp = Element.make_text_path [] "path" in
    let model = model_with_elems [([0; 0], tp)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" true (bool_of (getp s "text_selected"));
    Alcotest.(check bool) "area" false (bool_of (getp s "area_text_selected")));

  Alcotest.test_case "mixed_area_and_point" `Quick (fun () ->
    let area = Element.make_text ~text_width:200.0 ~text_height:100.0
                 0.0 0.0 "area" in
    let point = Element.make_text ~text_width:0.0 ~text_height:0.0
                  0.0 0.0 "pt" in
    let model = model_with_elems [([0; 0], area); ([0; 1], point)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check bool) "text" true (bool_of (getp s "text_selected"));
    (* Control enabled iff every element supports it -> area false. *)
    Alcotest.(check bool) "area" false (bool_of (getp s "area_text_selected")));
]

(* ── wrapper-attr read-back ──────────────────────────────── *)

let readback_tests = [
  Alcotest.test_case "reads_wrapper_indents_and_flags" `Quick (fun () ->
    let w = wrapper ~left:(Some 18.0) ~right:(Some 9.0)
              ~hyph:(Some true) ~hang:(Some true)
              ~list_style:(Some "bullet-disc") 0 in
    let area = area_text_with_tspans [w; body 1 "hello"] in
    let model = model_with_elems [([0; 0], area)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check (float 1e-9)) "left" 18.0 (float_of (getp s "left_indent"));
    Alcotest.(check (float 1e-9)) "right" 9.0 (float_of (getp s "right_indent"));
    Alcotest.(check bool) "hyph" true (bool_of (getp s "hyphenate"));
    Alcotest.(check bool) "hang" true (bool_of (getp s "hanging_punctuation"));
    Alcotest.(check string) "bullets" "bullet-disc" (string_of (getp s "bullets"));
    Alcotest.(check string) "numbered" "" (string_of (getp s "numbered_list")));

  Alcotest.test_case "num_list_routes_to_numbered_dropdown" `Quick (fun () ->
    let w = wrapper ~list_style:(Some "num-decimal") 0 in
    let area = area_text_with_tspans [w; body 1 "1. item"] in
    let model = model_with_elems [([0; 0], area)] in
    let s = store_with_panel () in
    let ctrl = new Controller.controller ~model () in
    Effects.sync_paragraph_panel_from_selection s ctrl;
    Alcotest.(check string) "numbered" "num-decimal"
      (string_of (getp s "numbered_list"));
    Alcotest.(check string) "bullets" "" (string_of (getp s "bullets")));
]

(* ── mutual exclusion (pure store helper) ────────────────── *)

let mutex_tests = [
  Alcotest.test_case "radio_clears_other_six" `Quick (fun () ->
    let s = store_with_panel () in
    Effects.apply_paragraph_panel_mutual_exclusion s "justify_center" (`Bool true);
    List.iter (fun k ->
      Alcotest.(check bool) k false (bool_of (getp s k)))
      ["align_left"; "align_center"; "align_right";
       "justify_left"; "justify_right"; "justify_all"]);

  Alcotest.test_case "bullets_clears_numbered" `Quick (fun () ->
    let s = store_with_panel () in
    State_store.set_panel s "paragraph_panel_content" "numbered_list"
      (`String "num-decimal");
    Effects.apply_paragraph_panel_mutual_exclusion s "bullets"
      (`String "bullet-disc");
    Alcotest.(check string) "numbered" "" (string_of (getp s "numbered_list")));

  Alcotest.test_case "numbered_clears_bullets" `Quick (fun () ->
    let s = store_with_panel () in
    State_store.set_panel s "paragraph_panel_content" "bullets"
      (`String "bullet-disc");
    Effects.apply_paragraph_panel_mutual_exclusion s "numbered_list"
      (`String "num-decimal");
    Alcotest.(check string) "bullets" "" (string_of (getp s "bullets")));

  Alcotest.test_case "empty_string_does_not_clear_other" `Quick (fun () ->
    let s = store_with_panel () in
    State_store.set_panel s "paragraph_panel_content" "numbered_list"
      (`String "num-decimal");
    Effects.apply_paragraph_panel_mutual_exclusion s "bullets" (`String "");
    Alcotest.(check string) "numbered" "num-decimal"
      (string_of (getp s "numbered_list")));
]

let () =
  Alcotest.run "paragraph_panel_state" [
    "text_kind", kind_tests;
    "readback", readback_tests;
    "mutual_exclusion", mutex_tests;
  ]
