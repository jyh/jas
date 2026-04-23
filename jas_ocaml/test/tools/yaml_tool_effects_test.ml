(** Phase 2 of the OCaml YAML tool-runtime migration.
    Tests for [Yaml_tool_effects.build] — the doc.* selection-family
    effects wired to a [Controller]. *)

open Jas

let make_rect x y w h =
  Element.Rect {
    x; y; width = w; height = h;
    rx = 0.0; ry = 0.0;
    fill = None; stroke = None;
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

(** Layer with two 10x10 rects at (0,0) and (50,50). *)
let two_rect_model () =
  let layer = Element.Layer {
    name = "L";
    children = [| make_rect 0.0 0.0 10.0 10.0;
                  make_rect 50.0 50.0 10.0 10.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document doc;
  m

let make_ctrl_with (model : Model.model) =
  new Controller.controller ~model ()

let run_with_effects store effects ctrl =
  let pe = Yaml_tool_effects.build ctrl in
  Effects.run_effects ~platform_effects:pe effects [] store

(* ── doc.snapshot ────────────────────────────────────── *)

let snapshot_tests = [
  Alcotest.test_case "doc_snapshot_pushes_undo" `Quick (fun () ->
    let m = Model.create () in
    let ctrl = make_ctrl_with m in
    assert (not m#can_undo);
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.snapshot", `Null)]] ctrl;
    assert m#can_undo);
]

(* ── doc.clear_selection ─────────────────────────────── *)

let clear_selection_tests = [
  Alcotest.test_case "doc_clear_selection_empties" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    ctrl#select_element [0; 0];
    assert (not (Document.PathMap.is_empty m#document.selection));
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.clear_selection", `Null)]] ctrl;
    assert (Document.PathMap.is_empty m#document.selection));
]

(* ── doc.set_selection ───────────────────────────────── *)

let set_selection_tests = [
  Alcotest.test_case "doc_set_selection_from_paths" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    let spec = `Assoc [("paths", `List [
      `List [`Int 0; `Int 0];
      `List [`Int 0; `Int 1];
    ])] in
    run_with_effects store [`Assoc [("doc.set_selection", spec)]] ctrl;
    assert (Document.PathMap.cardinal m#document.selection = 2);
    assert (Document.PathMap.mem [0; 0] m#document.selection);
    assert (Document.PathMap.mem [0; 1] m#document.selection));

  Alcotest.test_case "doc_set_selection_drops_invalid" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    let spec = `Assoc [("paths", `List [
      `List [`Int 0; `Int 0];
      `List [`Int 99; `Int 99];  (* invalid *)
    ])] in
    run_with_effects store [`Assoc [("doc.set_selection", spec)]] ctrl;
    assert (Document.PathMap.cardinal m#document.selection = 1);
    assert (Document.PathMap.mem [0; 0] m#document.selection));
]

(* ── doc.add_to_selection ────────────────────────────── *)

let add_to_selection_tests = [
  Alcotest.test_case "doc_add_to_selection_adds" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.add_to_selection", `List [`Int 0; `Int 0])]]
      ctrl;
    assert (Document.PathMap.mem [0; 0] m#document.selection));

  Alcotest.test_case "doc_add_to_selection_idempotent" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    ctrl#select_element [0; 0];
    let before = Document.PathMap.cardinal m#document.selection in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.add_to_selection", `List [`Int 0; `Int 0])]]
      ctrl;
    assert (Document.PathMap.cardinal m#document.selection = before));
]

(* ── doc.toggle_selection ────────────────────────────── *)

let toggle_selection_tests = [
  Alcotest.test_case "doc_toggle_selection_adds_when_absent" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.toggle_selection", `List [`Int 0; `Int 0])]]
      ctrl;
    assert (Document.PathMap.mem [0; 0] m#document.selection));

  Alcotest.test_case "doc_toggle_selection_removes_when_present" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    ctrl#select_element [0; 0];
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.toggle_selection", `List [`Int 0; `Int 0])]]
      ctrl;
    assert (not (Document.PathMap.mem [0; 0] m#document.selection)));
]

(* ── doc.translate_selection ─────────────────────────── *)

let translate_selection_tests = [
  Alcotest.test_case "doc_translate_moves_selected" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    ctrl#select_element [0; 0];
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.translate_selection",
                `Assoc [("dx", `Int 5); ("dy", `Int 3)])]]
      ctrl;
    let child = (match m#document.layers.(0) with
                 | Element.Layer {children; _} -> children.(0)
                 | _ -> assert false) in
    match child with
    | Element.Rect r -> assert (r.x = 5.0); assert (r.y = 3.0)
    | _ -> assert false);
]

(* ── doc.select_in_rect + doc.partial_select_in_rect ─── *)

let select_in_rect_tests = [
  Alcotest.test_case "doc_select_in_rect_hits_first_rect" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.select_in_rect",
                `Assoc [("x1", `Int (-1));
                        ("y1", `Int (-1));
                        ("x2", `Int 11);
                        ("y2", `Int 11);
                        ("additive", `Bool false)])]]
      ctrl;
    assert (Document.PathMap.mem [0; 0] m#document.selection));

  Alcotest.test_case "doc_partial_select_in_rect_hits_cps" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.partial_select_in_rect",
                `Assoc [("x1", `Int (-1));
                        ("y1", `Int (-1));
                        ("x2", `Int 11);
                        ("y2", `Int 11);
                        ("additive", `Bool false)])]]
      ctrl;
    assert (Document.PathMap.mem [0; 0] m#document.selection));
]

(* ── Path extraction paths ───────────────────────────── *)

let path_extract_tests = [
  Alcotest.test_case "add_to_selection_accepts_path_value_from_ctx" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* An expression-returning-path: the [__path__] marker. *)
    let ctx = [("hit", `Assoc [("__path__", `List [`Int 0; `Int 0])])] in
    let pe = Yaml_tool_effects.build ctrl in
    Effects.run_effects ~platform_effects:pe
      [`Assoc [("doc.add_to_selection", `String "hit")]] ctx store;
    assert (Document.PathMap.mem [0; 0] m#document.selection));
]

let () =
  Alcotest.run "Yaml_tool_effects" [
    "doc.snapshot", snapshot_tests;
    "doc.clear_selection", clear_selection_tests;
    "doc.set_selection", set_selection_tests;
    "doc.add_to_selection", add_to_selection_tests;
    "doc.toggle_selection", toggle_selection_tests;
    "doc.translate_selection", translate_selection_tests;
    "doc.select_in_rect", select_in_rect_tests;
    "Path extraction", path_extract_tests;
  ]
