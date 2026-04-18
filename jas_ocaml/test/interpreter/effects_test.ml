open Jas.State_store
open Jas.Effects

let set_tests = [
  Alcotest.test_case "set_single" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 0)] () in
    run_effects [`Assoc [("set", `Assoc [("x", `String "5")])]] [] s;
    assert (get s "x" = `Int 5));

  Alcotest.test_case "set_from_expression" `Quick (fun () ->
    let s = create ~defaults:[("a", `Int 10); ("b", `Int 0)] () in
    run_effects [`Assoc [("set", `Assoc [("b", `String "state.a")])]] [] s;
    assert (get s "b" = `Int 10));
]

let toggle_tests = [
  Alcotest.test_case "toggle_true_to_false" `Quick (fun () ->
    let s = create ~defaults:[("flag", `Bool true)] () in
    run_effects [`Assoc [("toggle", `String "flag")]] [] s;
    assert (get s "flag" = `Bool false));

  Alcotest.test_case "toggle_false_to_true" `Quick (fun () ->
    let s = create ~defaults:[("flag", `Bool false)] () in
    run_effects [`Assoc [("toggle", `String "flag")]] [] s;
    assert (get s "flag" = `Bool true));
]

let swap_tests = [
  Alcotest.test_case "swap" `Quick (fun () ->
    let s = create ~defaults:[("a", `String "#ff0000"); ("b", `String "#00ff00")] () in
    run_effects [`Assoc [("swap", `List [`String "a"; `String "b"])]] [] s;
    assert (get s "a" = `String "#00ff00");
    assert (get s "b" = `String "#ff0000"));
]

let inc_dec_tests = [
  Alcotest.test_case "increment" `Quick (fun () ->
    let s = create ~defaults:[("count", `Int 5)] () in
    run_effects [`Assoc [("increment", `Assoc [("key", `String "count"); ("by", `Int 3)])]] [] s;
    assert (get s "count" = `Float 8.0));

  Alcotest.test_case "decrement" `Quick (fun () ->
    let s = create ~defaults:[("count", `Int 5)] () in
    run_effects [`Assoc [("decrement", `Assoc [("key", `String "count"); ("by", `Int 2)])]] [] s;
    assert (get s "count" = `Float 3.0));
]

let if_tests = [
  Alcotest.test_case "if_true_branch" `Quick (fun () ->
    let s = create ~defaults:[("flag", `Bool true); ("result", `String "")] () in
    run_effects [`Assoc [("if", `Assoc [
      ("condition", `String "state.flag");
      ("then", `List [`Assoc [("set", `Assoc [("result", `String "\"yes\"")])]]);
      ("else", `List [`Assoc [("set", `Assoc [("result", `String "\"no\"")])]])])]] [] s;
    assert (get s "result" = `String "yes"));

  Alcotest.test_case "if_false_branch" `Quick (fun () ->
    let s = create ~defaults:[("flag", `Bool false); ("result", `String "")] () in
    run_effects [`Assoc [("if", `Assoc [
      ("condition", `String "state.flag");
      ("then", `List [`Assoc [("set", `Assoc [("result", `String "\"yes\"")])]]);
      ("else", `List [`Assoc [("set", `Assoc [("result", `String "\"no\"")])]])])]] [] s;
    assert (get s "result" = `String "no"));
]

let dispatch_tests = [
  Alcotest.test_case "dispatch_runs_action" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 0)] () in
    let actions = `Assoc [
      ("set_x_to_42", `Assoc [("effects", `List [`Assoc [("set", `Assoc [("x", `String "42")])]])])
    ] in
    run_effects [`Assoc [("dispatch", `String "set_x_to_42")]] [] s ~actions;
    assert (get s "x" = `Int 42));
]

let dialog_tests = [
  Alcotest.test_case "open_dialog_sets_defaults" `Quick (fun () ->
    let s = create () in
    let dialogs = `Assoc [
      ("simple", `Assoc [
        ("summary", `String "Simple");
        ("state", `Assoc [("name", `Assoc [("type", `String "string"); ("default", `String "")])]);
        ("content", `Assoc [("type", `String "container")])])
    ] in
    run_effects [`Assoc [("open_dialog", `Assoc [("id", `String "simple")])]] [] s ~dialogs;
    assert (get_dialog_id s = Some "simple");
    assert (get_dialog s "name" = Some (`String "")));

  Alcotest.test_case "open_dialog_with_params_and_init" `Quick (fun () ->
    let s = create ~defaults:[("fill_color", `String "#00ff00"); ("stroke_color", `String "#0000ff")] () in
    let dialogs = `Assoc [
      ("picker", `Assoc [
        ("summary", `String "Pick");
        ("state", `Assoc [
          ("h", `Assoc [("type", `String "number"); ("default", `Int 0)]);
          ("color", `Assoc [("type", `String "color"); ("default", `String "#ffffff")])]);
        ("init", `Assoc [
          ("color", `String "if param.target == \"fill\" then state.fill_color else state.stroke_color");
          ("h", `String "hsb_h(dialog.color)")]);
        ("content", `Assoc [("type", `String "container")])])
    ] in
    run_effects [`Assoc [("open_dialog", `Assoc [
      ("id", `String "picker");
      ("params", `Assoc [("target", `String "\"fill\"")])])]] [] s ~dialogs;
    assert (get_dialog_id s = Some "picker");
    assert (get_dialog s "color" = Some (`String "#00ff00"));
    (* hsb_h("#00ff00") = 120 *)
    assert (get_dialog s "h" = Some (`Int 120)));

  Alcotest.test_case "close_dialog" `Quick (fun () ->
    let s = create () in
    init_dialog s "test" [("x", `Int 1)] ();
    run_effects [`Assoc [("close_dialog", `Null)]] [] s;
    assert (get_dialog_id s = None));

  Alcotest.test_case "set_from_dialog_state" `Quick (fun () ->
    let s = create ~defaults:[("fill_color", `Null)] () in
    let dialogs = `Assoc [
      ("picker", `Assoc [
        ("summary", `String "Pick");
        ("state", `Assoc [("color", `Assoc [("type", `String "color"); ("default", `String "#aabbcc")])]);
        ("content", `Assoc [("type", `String "container")])])
    ] in
    run_effects [`Assoc [("open_dialog", `Assoc [("id", `String "picker")])]] [] s ~dialogs;
    assert (get_dialog s "color" = Some (`String "#aabbcc"));
    run_effects [`Assoc [("set", `Assoc [("fill_color", `String "dialog.color")])]] [] s;
    assert (get s "fill_color" = `String "#aabbcc"));
]

let pop_tests = [
  Alcotest.test_case "pop_panel_removes_last" `Quick (fun () ->
    let s = create () in
    let items = `List [`Assoc [("id", `String "a")]; `Assoc [("id", `String "b")]] in
    init_panel s "layers" [("isolation_stack", items)];
    set_active_panel s (Some "layers");
    run_effects [`Assoc [("pop", `String "panel.isolation_stack")]] [] s;
    assert (get_panel s "layers" "isolation_stack" = `List [`Assoc [("id", `String "a")]]));

  Alcotest.test_case "pop_panel_empty_is_noop" `Quick (fun () ->
    let s = create () in
    init_panel s "layers" [("isolation_stack", `List [])];
    set_active_panel s (Some "layers");
    run_effects [`Assoc [("pop", `String "panel.isolation_stack")]] [] s;
    assert (get_panel s "layers" "isolation_stack" = `List []));

  Alcotest.test_case "pop_global_list" `Quick (fun () ->
    let s = create ~defaults:[("my_stack", `List [`Int 1; `Int 2; `Int 3])] () in
    run_effects [`Assoc [("pop", `String "my_stack")]] [] s;
    assert (get s "my_stack" = `List [`Int 1; `Int 2]));
]

let let_tests = [
  Alcotest.test_case "let_binds_for_subsequent_effect" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 0)] () in
    run_effects [
      `Assoc [("let", `Assoc [("n", `String "5")])];
      `Assoc [("set", `Assoc [("x", `String "n")])]
    ] [] s;
    assert (get s "x" = `Int 5));

  Alcotest.test_case "let_shadows_outer_scope" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 0)] () in
    run_effects [
      `Assoc [("let", `Assoc [("v", `String "1")])];
      `Assoc [("let", `Assoc [("v", `String "2")])];
      `Assoc [("set", `Assoc [("x", `String "v")])]
    ] [] s;
    assert (get s "x" = `Int 2));
]

let platform_effects_tests = [
  Alcotest.test_case "bare_string_snapshot_dispatches_to_handler" `Quick (fun () ->
    let called = ref 0 in
    let handler _ _ _ = incr called; `Null in
    let s = create () in
    run_effects ~platform_effects:[("snapshot", handler)]
      [`String "snapshot"] [] s;
    assert (!called = 1));

  Alcotest.test_case "map_snapshot_dispatches_to_handler" `Quick (fun () ->
    let called = ref 0 in
    let handler _ _ _ = incr called; `Null in
    let s = create () in
    run_effects ~platform_effects:[("snapshot", handler)]
      [`Assoc [("snapshot", `Null)]] [] s;
    assert (!called = 1));

  Alcotest.test_case "platform_handler_return_value_bound_via_as" `Quick (fun () ->
    (* Handler returns a JSON value; subsequent set: reads it from ctx. *)
    let handler _ _ _ = `String "clone_result" in
    let s = create ~defaults:[("out", `String "")] () in
    run_effects ~platform_effects:[("doc.clone_at", handler)]
      [
        `Assoc [("doc.clone_at", `String "path(0)"); ("as", `String "c")];
        `Assoc [("set", `Assoc [("out", `String "c")])];
      ] [] s;
    assert (get s "out" = `String "clone_result"));

  Alcotest.test_case "doc_set_dispatches_with_spec" `Quick (fun () ->
    let captured = ref `Null in
    let handler value _ _ = captured := value; `Null in
    let s = create () in
    let spec = `Assoc [
      ("path", `String "p");
      ("fields", `Assoc [("common.visibility", `String "'invisible'")]);
    ] in
    run_effects ~platform_effects:[("doc.set", handler)]
      [`Assoc [("doc.set", spec)]] [] s;
    assert (!captured = spec));
]

let foreach_tests = [
  Alcotest.test_case "foreach_iterates" `Quick (fun () ->
    let s = create ~defaults:[("sum", `Int 0)] () in
    run_effects [
      `Assoc [("foreach", `Assoc [("source", `String "[1, 2, 3]"); ("as", `String "n")]);
              ("do", `List [`Assoc [("set", `Assoc [("x", `String "state.sum + n")])]])]
    ] [] s;
    ignore s);

  Alcotest.test_case "foreach_empty_list_noop" `Quick (fun () ->
    let s = create ~defaults:[("touched", `Bool false)] () in
    run_effects [
      `Assoc [("foreach", `Assoc [("source", `String "[]"); ("as", `String "x")]);
              ("do", `List [`Assoc [("set", `Assoc [("touched", `String "true")])]])]
    ] [] s;
    assert (get s "touched" = `Bool false));
]

(* ── Character panel attrs-from-panel (Layer B) ─────────────── *)

let character_attrs_tests = [
  Alcotest.test_case "text_decoration_neither" `Quick (fun () ->
    let a = attrs_from_character_panel [] in
    assert (a.text_decoration = ""));

  Alcotest.test_case "text_decoration_underline" `Quick (fun () ->
    let a = attrs_from_character_panel [("underline", `Bool true)] in
    assert (a.text_decoration = "underline"));

  Alcotest.test_case "text_decoration_strikethrough" `Quick (fun () ->
    let a = attrs_from_character_panel [("strikethrough", `Bool true)] in
    assert (a.text_decoration = "line-through"));

  Alcotest.test_case "text_decoration_both_alphabetical" `Quick (fun () ->
    let a = attrs_from_character_panel [("underline", `Bool true);
                                         ("strikethrough", `Bool true)] in
    assert (a.text_decoration = "line-through underline"));

  Alcotest.test_case "all_caps_wins_over_small_caps" `Quick (fun () ->
    let a = attrs_from_character_panel [("all_caps", `Bool true);
                                         ("small_caps", `Bool true)] in
    assert (a.text_transform = "uppercase");
    assert (a.font_variant = ""));

  Alcotest.test_case "small_caps_when_all_caps_off" `Quick (fun () ->
    let a = attrs_from_character_panel [("small_caps", `Bool true)] in
    assert (a.text_transform = "");
    assert (a.font_variant = "small-caps"));

  Alcotest.test_case "super_wins_over_numeric" `Quick (fun () ->
    let a = attrs_from_character_panel [("superscript", `Bool true);
                                         ("baseline_shift", `Int 5)] in
    assert (a.baseline_shift = "super"));

  Alcotest.test_case "sub_when_super_off" `Quick (fun () ->
    let a = attrs_from_character_panel [("subscript", `Bool true)] in
    assert (a.baseline_shift = "sub"));

  Alcotest.test_case "numeric_baseline_shift" `Quick (fun () ->
    let a = attrs_from_character_panel [("baseline_shift", `Int 3)] in
    assert (a.baseline_shift = "3pt"));

  Alcotest.test_case "style_name_regular" `Quick (fun () ->
    let a = attrs_from_character_panel [("style_name", `String "Regular")] in
    assert (a.font_weight = Some "normal");
    assert (a.font_style = Some "normal"));

  Alcotest.test_case "style_name_bold_italic" `Quick (fun () ->
    let a = attrs_from_character_panel [("style_name", `String "Bold Italic")] in
    assert (a.font_weight = Some "bold");
    assert (a.font_style = Some "italic"));

  Alcotest.test_case "style_name_unknown_leaves_untouched" `Quick (fun () ->
    let a = attrs_from_character_panel [("style_name", `String "Something Weird")] in
    assert (a.font_weight = None);
    assert (a.font_style = None));

  Alcotest.test_case "leading_at_auto_empties" `Quick (fun () ->
    let a = attrs_from_character_panel [("font_size", `Int 12);
                                         ("leading", `Float 14.4)] in
    assert (a.line_height = ""));

  Alcotest.test_case "leading_off_auto" `Quick (fun () ->
    let a = attrs_from_character_panel [("font_size", `Int 12);
                                         ("leading", `Int 20)] in
    assert (a.line_height = "20pt"));

  Alcotest.test_case "tracking_positive" `Quick (fun () ->
    let a = attrs_from_character_panel [("tracking", `Int 25)] in
    assert (a.letter_spacing = "0.025em"));

  Alcotest.test_case "kerning_positive" `Quick (fun () ->
    let a = attrs_from_character_panel [("kerning", `Int 50)] in
    assert (a.kerning = "0.05em"));

  Alcotest.test_case "rotation_nonzero" `Quick (fun () ->
    let a = attrs_from_character_panel [("character_rotation", `Int 15)] in
    assert (a.rotate = "15"));

  Alcotest.test_case "scale_identity_empties" `Quick (fun () ->
    let a = attrs_from_character_panel [("horizontal_scale", `Int 100);
                                         ("vertical_scale", `Int 100)] in
    assert (a.horizontal_scale = "");
    assert (a.vertical_scale = ""));

  Alcotest.test_case "sharp_aa_empties" `Quick (fun () ->
    let a = attrs_from_character_panel [("anti_aliasing", `String "Sharp")] in
    assert (a.aa_mode = ""));

  Alcotest.test_case "non_default_aa" `Quick (fun () ->
    let a = attrs_from_character_panel [("anti_aliasing", `String "Crisp")] in
    assert (a.aa_mode = "Crisp"));
]

(* ── apply_character_attrs_to_elem ──────────────────────────── *)

let apply_to_elem_tests = [
  Alcotest.test_case "writes_font_family_onto_text" `Quick (fun () ->
    let t = Jas.Element.make_text ~font_family:"serif" ~font_size:12.0 0.0 0.0 "hi" in
    let attrs = attrs_from_character_panel [("font_family", `String "Arial")] in
    match apply_character_attrs_to_elem t attrs with
    | Jas.Element.Text { font_family; _ } -> assert (font_family = "Arial")
    | _ -> assert false);

  Alcotest.test_case "underline_flows_to_text_decoration" `Quick (fun () ->
    let t = Jas.Element.make_text ~font_family:"serif" ~font_size:12.0 0.0 0.0 "hi" in
    let attrs = attrs_from_character_panel [("underline", `Bool true)] in
    match apply_character_attrs_to_elem t attrs with
    | Jas.Element.Text { text_decoration; _ } -> assert (text_decoration = "underline")
    | _ -> assert false);

  Alcotest.test_case "non_text_passes_through" `Quick (fun () ->
    let r = Jas.Element.make_rect 0.0 0.0 10.0 10.0 in
    let attrs = attrs_from_character_panel [("font_family", `String "Arial")] in
    let r' = apply_character_attrs_to_elem r attrs in
    assert (r = r'));
]

let () =
  Alcotest.run "Effects" [
    "Set", set_tests;
    "Toggle", toggle_tests;
    "Swap", swap_tests;
    "Increment/Decrement", inc_dec_tests;
    "If", if_tests;
    "Dispatch", dispatch_tests;
    "Dialog", dialog_tests;
    "Pop", pop_tests;
    "Phase3 Let", let_tests;
    "Phase3 Foreach", foreach_tests;
    "Phase3 PlatformEffects", platform_effects_tests;
    "Character attrs", character_attrs_tests;
    "Character apply-to-elem", apply_to_elem_tests;
  ]
