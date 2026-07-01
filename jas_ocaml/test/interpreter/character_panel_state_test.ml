(** Cross-language SEAM tests for the Character panel apply-to-selection
    pipeline. Mirrors Python's jas/panels/character_panel_state_test.py:
    every panel field -> element attribute mapping is pinned to the SAME
    input -> output values so the two apps stay equivalent.

    The pure mapping cases hit [Effects.attrs_from_character_panel]
    directly (mirrors Python's _attrs_from_panel); the end-to-end cases
    drive [Effects.apply_character_panel_to_selection] through a real
    Controller + Document (mirrors Python's TestApplyEndToEnd). *)

open Jas

(* ── helpers ─────────────────────────────────────────────── *)

let attrs (panel : (string * Yojson.Safe.t) list) =
  Effects.attrs_from_character_panel panel

let check_str name expected got = Alcotest.(check string) name expected got
let check_str_opt name expected got =
  Alcotest.(check (option string)) name expected got

(* Build a single-Text model with the given paths selected. *)
let model_with_elem elem selected =
  let layer = Element.make_layer [| elem |] in
  let selection = List.fold_left (fun acc path ->
    Document.PathMap.add path (Document.make_element_selection path) acc)
    Document.PathMap.empty selected in
  let doc = Document.make_document ~selection [| layer |] in
  Model.create ~document:doc ()

let text_font_family model path =
  match Document.get_element model#document path with
  | Element.Text t -> t.font_family
  | _ -> "<not-text>"

let text_decoration model path =
  match Document.get_element model#document path with
  | Element.Text t -> t.text_decoration
  | _ -> "<not-text>"

(* ── pure mapping: _attrs_from_panel equivalents ─────────── *)

let pure_tests = [
  (* font_size *)
  Alcotest.test_case "font_size_24" `Quick (fun () ->
    let a = attrs [("font_size", `Int 24)] in
    Alcotest.(check (option (float 1e-9))) "font_size" (Some 24.0) a.font_size);

  (* style_name -> font_weight + font_style *)
  Alcotest.test_case "style_regular" `Quick (fun () ->
    let a = attrs [("style_name", `String "Regular")] in
    check_str_opt "weight" (Some "normal") a.font_weight;
    check_str_opt "style" (Some "normal") a.font_style);
  Alcotest.test_case "style_italic" `Quick (fun () ->
    let a = attrs [("style_name", `String "Italic")] in
    check_str_opt "weight" (Some "normal") a.font_weight;
    check_str_opt "style" (Some "italic") a.font_style);
  Alcotest.test_case "style_bold" `Quick (fun () ->
    let a = attrs [("style_name", `String "Bold")] in
    check_str_opt "weight" (Some "bold") a.font_weight;
    check_str_opt "style" (Some "normal") a.font_style);
  Alcotest.test_case "style_bold_italic" `Quick (fun () ->
    let a = attrs [("style_name", `String "Bold Italic")] in
    check_str_opt "weight" (Some "bold") a.font_weight;
    check_str_opt "style" (Some "italic") a.font_style);
  Alcotest.test_case "style_unknown_leaves_none" `Quick (fun () ->
    let a = attrs [("style_name", `String "Something Weird")] in
    check_str_opt "weight" None a.font_weight;
    check_str_opt "style" None a.font_style);

  (* caps *)
  Alcotest.test_case "all_caps" `Quick (fun () ->
    let a = attrs [("all_caps", `Bool true)] in
    check_str "transform" "uppercase" a.text_transform;
    check_str "variant" "" a.font_variant);
  Alcotest.test_case "small_caps_when_all_caps_off" `Quick (fun () ->
    let a = attrs [("small_caps", `Bool true)] in
    check_str "transform" "" a.text_transform;
    check_str "variant" "small-caps" a.font_variant);
  Alcotest.test_case "all_caps_wins_over_small_caps" `Quick (fun () ->
    let a = attrs [("all_caps", `Bool true); ("small_caps", `Bool true)] in
    check_str "transform" "uppercase" a.text_transform;
    check_str "variant" "" a.font_variant);

  (* text_decoration *)
  Alcotest.test_case "decoration_none" `Quick (fun () ->
    let a = attrs [("underline", `Bool false); ("strikethrough", `Bool false)] in
    check_str "decoration" "" a.text_decoration);
  Alcotest.test_case "decoration_underline" `Quick (fun () ->
    let a = attrs [("underline", `Bool true)] in
    check_str "decoration" "underline" a.text_decoration);
  Alcotest.test_case "decoration_strikethrough" `Quick (fun () ->
    let a = attrs [("strikethrough", `Bool true)] in
    check_str "decoration" "line-through" a.text_decoration);
  Alcotest.test_case "decoration_both_alphabetical" `Quick (fun () ->
    let a = attrs [("underline", `Bool true); ("strikethrough", `Bool true)] in
    check_str "decoration" "line-through underline" a.text_decoration);

  (* leading -> line_height *)
  Alcotest.test_case "leading_auto_empty" `Quick (fun () ->
    let a = attrs [("font_size", `Int 12); ("leading", `Float 14.4)] in
    check_str "line_height" "" a.line_height);
  Alcotest.test_case "leading_explicit" `Quick (fun () ->
    let a = attrs [("font_size", `Int 12); ("leading", `Int 20)] in
    check_str "line_height" "20pt" a.line_height);

  (* tracking -> letter_spacing *)
  Alcotest.test_case "tracking_zero_empty" `Quick (fun () ->
    let a = attrs [("tracking", `Int 0)] in
    check_str "letter_spacing" "" a.letter_spacing);
  Alcotest.test_case "tracking_positive" `Quick (fun () ->
    let a = attrs [("tracking", `Int 25)] in
    check_str "letter_spacing" "0.025em" a.letter_spacing);

  (* kerning *)
  Alcotest.test_case "kerning_zero_empty" `Quick (fun () ->
    let a = attrs [("kerning", `Int 0)] in
    check_str "kerning" "" a.kerning);
  Alcotest.test_case "kerning_positive" `Quick (fun () ->
    let a = attrs [("kerning", `Int 50)] in
    check_str "kerning" "0.05em" a.kerning);
  Alcotest.test_case "kerning_numeric_string" `Quick (fun () ->
    let a = attrs [("kerning", `String "25")] in
    check_str "kerning" "0.025em" a.kerning);
  Alcotest.test_case "kerning_optical_passthrough" `Quick (fun () ->
    check_str "optical" "Optical" (attrs [("kerning", `String "Optical")]).kerning;
    check_str "metrics" "Metrics" (attrs [("kerning", `String "Metrics")]).kerning);
  Alcotest.test_case "kerning_auto_empty" `Quick (fun () ->
    check_str "auto" "" (attrs [("kerning", `String "Auto")]).kerning;
    check_str "zero" "" (attrs [("kerning", `String "0")]).kerning;
    check_str "empty" "" (attrs [("kerning", `String "")]).kerning);

  (* baseline_shift *)
  Alcotest.test_case "baseline_zero_empty" `Quick (fun () ->
    let a = attrs [("baseline_shift", `Int 0)] in
    check_str "bs" "" a.baseline_shift);
  Alcotest.test_case "baseline_numeric" `Quick (fun () ->
    let a = attrs [("baseline_shift", `Int 3)] in
    check_str "bs" "3pt" a.baseline_shift);
  Alcotest.test_case "baseline_super_wins" `Quick (fun () ->
    let a = attrs [("superscript", `Bool true); ("baseline_shift", `Int 5)] in
    check_str "bs" "super" a.baseline_shift);
  Alcotest.test_case "baseline_sub" `Quick (fun () ->
    let a = attrs [("subscript", `Bool true)] in
    check_str "bs" "sub" a.baseline_shift);

  (* rotation *)
  Alcotest.test_case "rotation_zero_empty" `Quick (fun () ->
    check_str "rot" "" (attrs [("character_rotation", `Int 0)]).rotate);
  Alcotest.test_case "rotation_numeric" `Quick (fun () ->
    check_str "rot" "15" (attrs [("character_rotation", `Int 15)]).rotate);

  (* scale *)
  Alcotest.test_case "scale_identity_empty" `Quick (fun () ->
    let a = attrs [("horizontal_scale", `Int 100); ("vertical_scale", `Int 100)] in
    check_str "h" "" a.horizontal_scale;
    check_str "v" "" a.vertical_scale);
  Alcotest.test_case "scale_non_identity" `Quick (fun () ->
    let a = attrs [("horizontal_scale", `Int 120); ("vertical_scale", `Int 90)] in
    check_str "h" "120" a.horizontal_scale;
    check_str "v" "90" a.vertical_scale);

  (* language / anti-aliasing *)
  Alcotest.test_case "language_passthrough" `Quick (fun () ->
    check_str_opt "lang" (Some "fr") (attrs [("language", `String "fr")]).xml_lang);
  Alcotest.test_case "aa_sharp_empty" `Quick (fun () ->
    check_str "aa" "" (attrs [("anti_aliasing", `String "Sharp")]).aa_mode);
  Alcotest.test_case "aa_non_default" `Quick (fun () ->
    check_str "aa" "Crisp" (attrs [("anti_aliasing", `String "Crisp")]).aa_mode);
]

(* ── end-to-end apply-to-selection ───────────────────────── *)

let e2e_tests = [
  Alcotest.test_case "font_family_written_to_selected_text" `Quick (fun () ->
    let t = Element.make_text ~font_family:"sans-serif" ~font_size:12.0
              0.0 0.0 "hello" in
    let model = model_with_elem t [[0; 0]] in
    let store = State_store.create () in
    State_store.init_panel store "character_panel_content"
      [("font_family", `String "Arial"); ("font_size", `Int 12)];
    let ctrl = new Controller.controller ~model () in
    Effects.apply_character_panel_to_selection store ctrl;
    check_str "font_family" "Arial" (text_font_family model [0; 0]));

  Alcotest.test_case "underline_flows_to_text_decoration" `Quick (fun () ->
    let t = Element.make_text ~font_family:"serif" ~font_size:12.0
              0.0 0.0 "hi" in
    let model = model_with_elem t [[0; 0]] in
    let store = State_store.create () in
    State_store.init_panel store "character_panel_content"
      [("font_family", `String "serif"); ("underline", `Bool true);
       ("font_size", `Int 12)];
    let ctrl = new Controller.controller ~model () in
    Effects.apply_character_panel_to_selection store ctrl;
    check_str "decoration" "underline" (text_decoration model [0; 0]));

  Alcotest.test_case "no_op_when_selection_empty" `Quick (fun () ->
    let t = Element.make_text ~font_family:"serif" ~font_size:12.0
              0.0 0.0 "hi" in
    let model = model_with_elem t [] in
    let store = State_store.create () in
    State_store.init_panel store "character_panel_content"
      [("font_family", `String "Arial"); ("font_size", `Int 12)];
    let ctrl = new Controller.controller ~model () in
    Effects.apply_character_panel_to_selection store ctrl;
    (* Element untouched: no selected text to write to. *)
    check_str "font_family" "serif" (text_font_family model [0; 0]));
]

let () =
  Alcotest.run "character_panel_state" [
    "pure_mapping", pure_tests;
    "end_to_end", e2e_tests;
  ]
