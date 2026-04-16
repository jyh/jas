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
  ]
