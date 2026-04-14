open Jas.State_store
open Jas.Workspace_loader

(* ── Global state tests ─────────────────────────────────── *)

let global_tests = [
  Alcotest.test_case "get_set" `Quick (fun () ->
    let s = create () in
    set s "x" (`Int 5);
    assert (get s "x" = `Int 5));

  Alcotest.test_case "get_missing_returns_null" `Quick (fun () ->
    let s = create () in
    assert (get s "missing" = `Null));

  Alcotest.test_case "init_from_defaults" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 10); ("y", `String "hello")] () in
    assert (get s "x" = `Int 10);
    assert (get s "y" = `String "hello"));

  Alcotest.test_case "get_all" `Quick (fun () ->
    let s = create ~defaults:[("a", `Int 1); ("b", `Int 2)] () in
    let all = get_all s in
    assert (List.assoc "a" all = `Int 1);
    assert (List.assoc "b" all = `Int 2));
]

(* ── Panel state tests ──────────────────────────────────── *)

let panel_tests = [
  Alcotest.test_case "init_panel" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb"); ("h", `Int 0)];
    assert (get_panel s "color" "mode" = `String "hsb");
    assert (get_panel s "color" "h" = `Int 0));

  Alcotest.test_case "set_panel" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb")];
    set_panel s "color" "mode" (`String "rgb");
    assert (get_panel s "color" "mode" = `String "rgb"));

  Alcotest.test_case "panel_scoping" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb")];
    init_panel s "swatches" [("mode", `String "grid")];
    assert (get_panel s "color" "mode" = `String "hsb");
    assert (get_panel s "swatches" "mode" = `String "grid"));

  Alcotest.test_case "active_panel_state" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb")];
    set_active_panel s (Some "color");
    let state = get_active_panel_state s in
    assert (List.assoc "mode" state = `String "hsb"));

  Alcotest.test_case "destroy_panel" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb")];
    destroy_panel s "color";
    assert (get_panel s "color" "mode" = `Null));
]

(* ── Dialog state tests ─────────────────────────────────── *)

let dialog_tests = [
  Alcotest.test_case "init_dialog" `Quick (fun () ->
    let s = create () in
    init_dialog s "color_picker"
      [("h", `Int 0); ("color", `String "#ffffff")]
      ~params:[("target", `String "fill")] ();
    assert (get_dialog_id s = Some "color_picker");
    assert (get_dialog s "h" = Some (`Int 0));
    assert (get_dialog s "color" = Some (`String "#ffffff"));
    (match get_dialog_params s with
     | Some p -> assert (List.assoc "target" p = `String "fill")
     | None -> assert false));

  Alcotest.test_case "get_set_dialog" `Quick (fun () ->
    let s = create () in
    init_dialog s "test" [("name", `String "")] ();
    set_dialog s "name" (`String "hello");
    assert (get_dialog s "name" = Some (`String "hello")));

  Alcotest.test_case "get_dialog_no_dialog_returns_none" `Quick (fun () ->
    let s = create () in
    assert (get_dialog s "anything" = None);
    assert (get_dialog_id s = None);
    assert (get_dialog_params s = None));

  Alcotest.test_case "close_dialog" `Quick (fun () ->
    let s = create () in
    init_dialog s "test" [("x", `Int 1)]
      ~params:[("p", `String "v")] ();
    close_dialog s;
    assert (get_dialog_id s = None);
    assert (get_dialog s "x" = None);
    assert (get_dialog_params s = None);
    assert (get_dialog_state s = []));

  Alcotest.test_case "init_dialog_replaces_previous" `Quick (fun () ->
    let s = create () in
    init_dialog s "first" [("x", `Int 1)] ();
    init_dialog s "second" [("y", `Int 2)] ();
    assert (get_dialog_id s = Some "second");
    assert (get_dialog s "x" = None);
    assert (get_dialog s "y" = Some (`Int 2)));
]

(* ── Eval context tests ─────────────────────────────────── *)

let ctx_tests = [
  Alcotest.test_case "eval_context_basic" `Quick (fun () ->
    let s = create ~defaults:[("fill_color", `String "#ff0000")] () in
    init_panel s "color" [("mode", `String "hsb")];
    set_active_panel s (Some "color");
    let ctx = eval_context s in
    let state = json_member "state" ctx in
    let panel = json_member "panel" ctx in
    (match state with
     | Some (`Assoc pairs) -> assert (List.assoc "fill_color" pairs = `String "#ff0000")
     | _ -> assert false);
    (match panel with
     | Some (`Assoc pairs) -> assert (List.assoc "mode" pairs = `String "hsb")
     | _ -> assert false));

  Alcotest.test_case "eval_context_includes_dialog" `Quick (fun () ->
    let s = create () in
    init_dialog s "test" [("h", `Int 180); ("s", `Int 50)] ();
    let ctx = eval_context s in
    let dialog = json_member "dialog" ctx in
    (match dialog with
     | Some (`Assoc pairs) ->
       assert (List.assoc "h" pairs = `Int 180);
       assert (List.assoc "s" pairs = `Int 50)
     | _ -> assert false));

  Alcotest.test_case "eval_context_includes_dialog_params" `Quick (fun () ->
    let s = create () in
    init_dialog s "test" [("x", `Int 1)]
      ~params:[("target", `String "fill")] ();
    let ctx = eval_context s in
    let param = json_member "param" ctx in
    (match param with
     | Some (`Assoc pairs) -> assert (List.assoc "target" pairs = `String "fill")
     | _ -> assert false));

  Alcotest.test_case "eval_context_no_dialog_omits_key" `Quick (fun () ->
    let s = create ~defaults:[("x", `Int 1)] () in
    let ctx = eval_context s in
    assert (json_member "dialog" ctx = None));

  Alcotest.test_case "dialog_and_panel_coexist" `Quick (fun () ->
    let s = create () in
    init_panel s "color" [("mode", `String "hsb")];
    set_active_panel s (Some "color");
    init_dialog s "picker" [("h", `Int 270)] ();
    let ctx = eval_context s in
    let panel = json_member "panel" ctx in
    let dialog = json_member "dialog" ctx in
    (match panel with
     | Some (`Assoc pairs) -> assert (List.assoc "mode" pairs = `String "hsb")
     | _ -> assert false);
    (match dialog with
     | Some (`Assoc pairs) -> assert (List.assoc "h" pairs = `Int 270)
     | _ -> assert false));
]

let () =
  Alcotest.run "State store" [
    "Global", global_tests;
    "Panel", panel_tests;
    "Dialog", dialog_tests;
    "Context", ctx_tests;
  ]
