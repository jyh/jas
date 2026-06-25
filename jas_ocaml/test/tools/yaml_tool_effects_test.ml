(** Phase 2 of the OCaml YAML tool-runtime migration.
    Tests for [Yaml_tool_effects.build] — the doc.* selection-family
    effects wired to a [Controller]. *)

open Jas

let make_rect x y w h =
  Element.Rect { name = None; id = None;
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
    name = Some "L";
    id = None;
    children = [| make_rect 0.0 0.0 10.0 10.0;
                  make_rect 50.0 50.0 10.0 10.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
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

(* Blob Brush commit effects *)

let seed_blob_brush_sweep () =
  Point_buffers.clear "blob_brush";
  (* 6 points spanning 50pt horizontally at y=0. *)
  for i = 0 to 5 do
    Point_buffers.push "blob_brush" (float_of_int i *. 10.0) 0.0
  done

let blob_brush_state_defaults (store : State_store.t) =
  State_store.set store "fill_color" (`String "#ff0000");
  State_store.set store "blob_brush_size" (`Float 10.0);
  State_store.set store "blob_brush_angle" (`Float 0.0);
  State_store.set store "blob_brush_roundness" (`Float 100.0)

let empty_layer_model () =
  let layer = Element.Layer {
    name = Some "L";
    id = None;
    children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
  m

let blob_brush_commit_tests = [
  Alcotest.test_case "commit_painting_creates_tagged_path" `Quick (fun () ->
    let m = empty_layer_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    blob_brush_state_defaults store;
    seed_blob_brush_sweep ();
    run_with_effects store
      [`Assoc [("doc.blob_brush.commit_painting",
                `Assoc [("buffer", `String "blob_brush");
                        ("fidelity_epsilon", `String "5.0");
                        ("merge_only_with_selection", `String "false");
                        ("keep_selected", `String "false")])]]
      ctrl;
    let children = Document.children_of m#document.layers.(0) in
    assert (Array.length children = 1);
    match children.(0) with
    | Element.Path pe ->
      assert (pe.tool_origin = Some "blob_brush");
      assert (pe.fill <> None);
      assert (pe.stroke = None);
      (* At least MoveTo + some LineTos + ClosePath. *)
      assert (List.length pe.d >= 3)
    | _ -> Alcotest.fail "expected Path");

  Alcotest.test_case "commit_erasing_deletes_fully_covered_element" `Quick (fun () ->
    (* Small 4x2 blob-brush square fully inside the sweep's coverage
       area (sweep = 50pt horizontal, tip 10pt -> covers y in [-5, 5]). *)
    let target = Element.Path { name = None; id = None;
      d = [ Element.MoveTo (23.0, -1.0);
            Element.LineTo (27.0, -1.0);
            Element.LineTo (27.0, 1.0);
            Element.LineTo (23.0, 1.0);
            Element.ClosePath ];
      fill = Some (Element.make_fill (
        Element.color_rgb 1.0 0.0 0.0));
      stroke = None; width_points = [];
      opacity = 1.0; transform = None; locked = false;
      visibility = Preview; blend_mode = Normal; mask = None;
      fill_gradient = None; stroke_gradient = None;
      stroke_brush = None; stroke_brush_overrides = None;
      tool_origin = Some "blob_brush";
    } in
    let layer = Element.Layer {
      name = Some "L"; id = None; children = [| target |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document_unbracketed doc;
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    blob_brush_state_defaults store;
    seed_blob_brush_sweep ();
    run_with_effects store
      [`Assoc [("doc.blob_brush.commit_erasing",
                `Assoc [("buffer", `String "blob_brush");
                        ("fidelity_epsilon", `String "5.0")])]]
      ctrl;
    let children = Document.children_of m#document.layers.(0) in
    Alcotest.(check int) "erase deletes fully-covered element" 0
      (Array.length children));

  Alcotest.test_case "commit_erasing_ignores_non_blob_brush" `Quick (fun () ->
    (* Same square but tool_origin = None. Erase must skip it. *)
    let target = Element.Path { name = None; id = None;
      d = [ Element.MoveTo (20.0, -2.0);
            Element.LineTo (30.0, -2.0);
            Element.LineTo (30.0, 2.0);
            Element.LineTo (20.0, 2.0);
            Element.ClosePath ];
      fill = Some (Element.make_fill (
        Element.color_rgb 1.0 0.0 0.0));
      stroke = None; width_points = [];
      opacity = 1.0; transform = None; locked = false;
      visibility = Preview; blend_mode = Normal; mask = None;
      fill_gradient = None; stroke_gradient = None;
      stroke_brush = None; stroke_brush_overrides = None;
      tool_origin = None;
    } in
    let layer = Element.Layer {
      name = Some "L"; id = None; children = [| target |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document_unbracketed doc;
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    blob_brush_state_defaults store;
    seed_blob_brush_sweep ();
    run_with_effects store
      [`Assoc [("doc.blob_brush.commit_erasing",
                `Assoc [("buffer", `String "blob_brush");
                        ("fidelity_epsilon", `String "5.0")])]]
      ctrl;
    let children = Document.children_of m#document.layers.(0) in
    Alcotest.(check int) "non-blob-brush untouched" 1
      (Array.length children));
]

(* Magic Wand effect *)

let red_filled_rect x y =
  Element.Rect { name = None; id = None;
    x; y; width = 10.0; height = 10.0;
    rx = 0.0; ry = 0.0;
    fill = Some (Element.make_fill (Element.color_rgb 1.0 0.0 0.0));
    stroke = None;
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let blue_filled_rect x y =
  Element.Rect { name = None; id = None;
    x; y; width = 10.0; height = 10.0;
    rx = 0.0; ry = 0.0;
    fill = Some (Element.make_fill (Element.color_rgb 0.0 0.0 1.0));
    stroke = None;
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let magic_wand_state_defaults (store : State_store.t) =
  State_store.set store "magic_wand_fill_color" (`Bool true);
  State_store.set store "magic_wand_fill_tolerance" (`Float 32.0);
  State_store.set store "magic_wand_stroke_color" (`Bool true);
  State_store.set store "magic_wand_stroke_tolerance" (`Float 32.0);
  State_store.set store "magic_wand_stroke_weight" (`Bool true);
  State_store.set store "magic_wand_stroke_weight_tolerance" (`Float 5.0);
  State_store.set store "magic_wand_opacity" (`Bool true);
  State_store.set store "magic_wand_opacity_tolerance" (`Float 5.0);
  State_store.set store "magic_wand_blending_mode" (`Bool false)

let three_rect_model () =
  let layer = Element.Layer {
    name = Some "L";
    id = None;
    children = [| red_filled_rect 0.0 0.0;
                  red_filled_rect 50.0 0.0;
                  blue_filled_rect 100.0 0.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
  m

let path_arg path =
  `Assoc [("__path__", `List (List.map (fun i -> `Int i) path))]

let magic_wand_apply_tests = [
  Alcotest.test_case "replace_selects_all_red_rects" `Quick (fun () ->
    let m = three_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    magic_wand_state_defaults store;
    run_with_effects store
      [`Assoc [("doc.magic_wand.apply",
                `Assoc [("seed", path_arg [0; 0]);
                        ("mode", `String "'replace'")])]]
      ctrl;
    let sel = m#document.selection in
    Alcotest.(check int) "two reds selected" 2 (Document.PathMap.cardinal sel);
    assert (Document.PathMap.mem [0; 0] sel);
    assert (Document.PathMap.mem [0; 1] sel);
    assert (not (Document.PathMap.mem [0; 2] sel)));

  Alcotest.test_case "add_extends_existing_selection" `Quick (fun () ->
    let m = three_rect_model () in
    let ctrl = make_ctrl_with m in
    ctrl#set_selection (Document.PathMap.singleton [0; 2]
      (Document.element_selection_all [0; 2]));
    let store = State_store.create () in
    magic_wand_state_defaults store;
    run_with_effects store
      [`Assoc [("doc.magic_wand.apply",
                `Assoc [("seed", path_arg [0; 0]);
                        ("mode", `String "'add'")])]]
      ctrl;
    let sel = m#document.selection in
    Alcotest.(check int) "all three selected" 3
      (Document.PathMap.cardinal sel));

  Alcotest.test_case "subtract_removes_matches_only" `Quick (fun () ->
    let m = three_rect_model () in
    let ctrl = make_ctrl_with m in
    let all_three = List.fold_left (fun acc p ->
      Document.PathMap.add p (Document.element_selection_all p) acc
    ) Document.PathMap.empty [[0; 0]; [0; 1]; [0; 2]] in
    ctrl#set_selection all_three;
    let store = State_store.create () in
    magic_wand_state_defaults store;
    run_with_effects store
      [`Assoc [("doc.magic_wand.apply",
                `Assoc [("seed", path_arg [0; 0]);
                        ("mode", `String "'subtract'")])]]
      ctrl;
    let sel = m#document.selection in
    Alcotest.(check int) "only blue remains" 1 (Document.PathMap.cardinal sel);
    assert (Document.PathMap.mem [0; 2] sel));

  Alcotest.test_case "skips_locked_and_hidden_elements" `Quick (fun () ->
    let r0 = red_filled_rect 0.0 0.0 in
    let r1_locked = match red_filled_rect 50.0 0.0 with
      | Element.Rect r -> Element.Rect { r with locked = true }
      | e -> e in
    let r2_hidden = match red_filled_rect 100.0 0.0 with
      | Element.Rect r -> Element.Rect { r with visibility = Element.Invisible }
      | e -> e in
    let layer = Element.Layer {
      name = Some "L"; id = None; children = [| r0; r1_locked; r2_hidden |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document_unbracketed doc;
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    magic_wand_state_defaults store;
    run_with_effects store
      [`Assoc [("doc.magic_wand.apply",
                `Assoc [("seed", path_arg [0; 0]);
                        ("mode", `String "'replace'")])]]
      ctrl;
    let sel = m#document.selection in
    Alcotest.(check int) "only seed selected" 1 (Document.PathMap.cardinal sel);
    assert (Document.PathMap.mem [0; 0] sel));
]

(* ── doc.artboard.* effects (ARTBOARD_TOOL.md) ──────── *)

let artboard_model abs_list =
  let layer = Element.Layer {
    name = Some "L"; id = None; children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document
    ~artboards:abs_list [| layer |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
  m

let artboard_create_tests = [
  Alcotest.test_case "create_commit_appends_with_rounded_bounds" `Quick (fun () ->
    let seed = { (Artboard.default_with_id "seed00001") with name = "Artboard 1" } in
    let m = artboard_model [seed] in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.artboard.create_commit",
      `Assoc [("x1", `String "10"); ("y1", `String "20");
              ("x2", `String "110"); ("y2", `String "120")])]] ctrl;
    Alcotest.(check int) "two artboards" 2
      (List.length m#document.artboards);
    let new_ab = List.nth m#document.artboards 1 in
    Alcotest.(check (float 0.001)) "x" 10.0 new_ab.x;
    Alcotest.(check (float 0.001)) "y" 20.0 new_ab.y;
    Alcotest.(check (float 0.001)) "w" 100.0 new_ab.width;
    Alcotest.(check (float 0.001)) "h" 100.0 new_ab.height;
    Alcotest.(check string) "name" "Artboard 2" new_ab.name);

  Alcotest.test_case "create_commit_clamps_at_min" `Quick (fun () ->
    let seed = { (Artboard.default_with_id "seed00001") with name = "Artboard 1" } in
    let m = artboard_model [seed] in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.artboard.create_commit",
      `Assoc [("x1", `String "50"); ("y1", `String "50");
              ("x2", `String "50.4"); ("y2", `String "50.4")])]] ctrl;
    let new_ab = List.nth m#document.artboards 1 in
    Alcotest.(check (float 0.001)) "w clamped" 1.0 new_ab.width;
    Alcotest.(check (float 0.001)) "h clamped" 1.0 new_ab.height);
]

let artboard_probe_hit_tests = [
  Alcotest.test_case "probe_hit_interior_sets_tool_state" `Quick (fun () ->
    (* Verifies tool state — panel-selection write requires
       active_document scope plumbing covered by the manual test
       suite. *)
    let ab = { (Artboard.default_with_id "aaa00001") with
               name = "Artboard 1";
               x = 0.0; y = 0.0; width = 100.0; height = 100.0 } in
    let m = artboard_model [ab] in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.artboard.probe_hit",
      `Assoc [("x", `String "50"); ("y", `String "50");
              ("shift", `String "false");
              ("cmd", `String "false");
              ("alt", `String "false")])]] ctrl;
    let ctx = State_store.eval_context store in
    let tool = Yojson.Safe.Util.member "tool" ctx in
    let ab_state = Yojson.Safe.Util.member "artboard" tool in
    let mode = Yojson.Safe.Util.member "mode" ab_state in
    let hit = Yojson.Safe.Util.member "hit_artboard_id" ab_state in
    Alcotest.(check string) "mode" "moving_pending"
      (match mode with `String s -> s | _ -> "");
    Alcotest.(check string) "hit id" "aaa00001"
      (match hit with `String s -> s | _ -> ""));

  Alcotest.test_case "probe_hit_empty_canvas_sets_creating" `Quick (fun () ->
    let ab = { (Artboard.default_with_id "aaa00001") with
               name = "Artboard 1";
               x = 0.0; y = 0.0; width = 100.0; height = 100.0 } in
    let m = artboard_model [ab] in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store [`Assoc [("doc.artboard.probe_hit",
      `Assoc [("x", `String "999"); ("y", `String "999");
              ("shift", `String "false");
              ("cmd", `String "false");
              ("alt", `String "false")])]] ctrl;
    let mode = Yojson.Safe.Util.(
      member "mode" (member "artboard"
        (member "tool" (State_store.eval_context store)))) in
    Alcotest.(check string) "mode" "creating"
      (match mode with `String s -> s | _ -> ""));
]

let artboard_probe_hover_tests = [
  Alcotest.test_case "probe_hover_classifies_position" `Quick (fun () ->
    let ab = { (Artboard.default_with_id "aaa00001") with
               name = "Artboard 1";
               x = 0.0; y = 0.0; width = 100.0; height = 100.0 } in
    let m = artboard_model [ab] in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    let read_hover () = Yojson.Safe.Util.(
      member "hover_kind" (member "artboard"
        (member "tool" (State_store.eval_context store)))) in
    run_with_effects store [`Assoc [("doc.artboard.probe_hover",
      `Assoc [("x", `String "50"); ("y", `String "50")])]] ctrl;
    Alcotest.(check string) "interior" "interior"
      (match read_hover () with `String s -> s | _ -> "");
    run_with_effects store [`Assoc [("doc.artboard.probe_hover",
      `Assoc [("x", `String "999"); ("y", `String "999")])]] ctrl;
    Alcotest.(check string) "empty" "empty"
      (match read_hover () with `String s -> s | _ -> ""));
]

let artboard_move_tests = [
  Alcotest.test_case "move_apply_translates_via_hit_fallback" `Quick (fun () ->
    let ab = { (Artboard.default_with_id "aaa00001") with
               name = "Artboard 1";
               x = 100.0; y = 100.0; width = 200.0; height = 200.0 } in
    let m = artboard_model [ab] in
    m#capture_preview_snapshot;
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    State_store.set_tool store "artboard" "hit_artboard_id"
      (`String "aaa00001");
    run_with_effects store [`Assoc [("doc.artboard.move_apply",
      `Assoc [("press_x", `String "100"); ("press_y", `String "100");
              ("cursor_x", `String "150"); ("cursor_y", `String "70");
              ("shift_held", `String "false")])]] ctrl;
    let result = List.hd m#document.artboards in
    Alcotest.(check (float 0.001)) "x" 150.0 result.x;
    Alcotest.(check (float 0.001)) "y" 70.0 result.y);
]

(* ── Partial Selection control-point selection (SEL-100/103/105/106) ──

   CP-LEVEL selection through the Partial Selection effects. two_rect_model's
   first rect (0,0,10,10) exposes four control points at its corners:
   cp0=(0,0), cp1=(10,0), cp2=(10,10), cp3=(0,10)
   (Element.control_points). [doc.path.probe_partial_hit] selects the CP under
   the cursor (or shift-toggles it into the per-element partial set);
   [doc.path.commit_partial_marquee] selects every CP inside the rubber-band
   rect. These assert the CP-level selection_kind (SelKindPartial carrying the
   enclosed indices), not just which element is touched. The second rect lives
   at path [0; 1] and must stay untouched.

   These use the PRODUCTION effects (doc.path.probe_partial_hit /
   doc.path.commit_partial_marquee, matching workspace/tools/partial_selection.yaml),
   NOT the legacy doc.partial_select_in_rect. *)

(* Helper — fetch the per-element selection entry at [path], if present. *)
let sel_entry (m : Model.model) path =
  Document.PathMap.find_opt path m#document.Document.selection

(* Helper — kind of the entry at [path], or fail. *)
let sel_kind m path =
  match sel_entry m path with
  | Some es -> es.Document.es_kind
  | None -> Alcotest.failf "expected selection entry at path"

let partial_selection_cp_tests = [
  (* SEL-100: clicking a single CP selects exactly that CP (a partial
     selection of one), not the whole element. *)
  Alcotest.test_case "cp_click_selects_single_control_point" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 0); ("y", `Int 0);
                        ("hit_radius", `Int 8)])]]
      ctrl;
    assert (sel_entry m [0; 0] <> None);
    let kind = sel_kind m [0; 0] in
    assert (Document.selection_kind_contains kind 0);          (* cp0=(0,0) *)
    Alcotest.(check int) "exactly one CP" 1
      (Document.selection_kind_count kind ~total:4);
    assert (not (Document.selection_kind_is_all kind ~total:4));(* not whole *)
    let mode = State_store.get_tool store "partial_selection" "mode" in
    Alcotest.(check string) "mode moving_pending" "moving_pending"
      (match mode with `String s -> s | _ -> "");
    assert (not (Document.PathMap.mem [0; 1] m#document.selection)));

  (* SEL-103/104: shift-click ADDS CPs to the per-element partial set, and
     shift-clicking a selected CP toggles it OFF. *)
  Alcotest.test_case "shift_click_adds_and_toggles_control_points" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Plain click cp0. *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 0); ("y", `Int 0);
                        ("hit_radius", `Int 8)])]]
      ctrl;
    Alcotest.(check int) "one CP after plain click" 1
      (Document.selection_kind_count (sel_kind m [0; 0]) ~total:4);
    (* Shift-click cp1=(10,0): ADDS it -> two CPs on the same element. *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 10); ("y", `Int 0);
                        ("hit_radius", `Int 8);
                        ("shift", `Bool true)])]]
      ctrl;
    let two = sel_kind m [0; 0] in
    Alcotest.(check int) "two CPs after shift-add" 2
      (Document.selection_kind_count two ~total:4);
    assert (Document.selection_kind_contains two 0);
    assert (Document.selection_kind_contains two 1);
    (* Shift-click cp1 AGAIN: toggles it OFF -> back to just cp0. *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 10); ("y", `Int 0);
                        ("hit_radius", `Int 8);
                        ("shift", `Bool true)])]]
      ctrl;
    let one = sel_kind m [0; 0] in
    Alcotest.(check int) "one CP after shift-toggle-off" 1
      (Document.selection_kind_count one ~total:4);
    assert (Document.selection_kind_contains one 0);
    assert (not (Document.selection_kind_contains one 1)));

  (* SEL-105: a marquee enclosing only one corner selects exactly that one CP
     (proving CP-level, not whole-element, marquee granularity). *)
  Alcotest.test_case "marquee_selects_only_enclosed_control_point" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Rect (-5,-5)..(5,5) encloses cp0=(0,0) only; the others are at x or y=10. *)
    run_with_effects store
      [`Assoc [("doc.path.commit_partial_marquee",
                `Assoc [("x1", `Int (-5)); ("y1", `Int (-5));
                        ("x2", `Int 5); ("y2", `Int 5)])]]
      ctrl;
    assert (sel_entry m [0; 0] <> None);
    let kind = sel_kind m [0; 0] in
    assert (Document.selection_kind_contains kind 0);
    Alcotest.(check int) "exactly one CP" 1
      (Document.selection_kind_count kind ~total:4);
    assert (not (Document.selection_kind_is_all kind ~total:4));
    assert (not (Document.PathMap.mem [0; 1] m#document.selection)));

  (* SEL-105: a marquee enclosing all four corners selects every CP of the
     element, and leaves the out-of-rect element untouched. *)
  Alcotest.test_case "marquee_selects_all_enclosed_control_points" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Rect (-5,-5)..(15,15) encloses all four corners of rect[0,0]; rect[0,1]
       lives at (50,50) and is fully outside. *)
    run_with_effects store
      [`Assoc [("doc.path.commit_partial_marquee",
                `Assoc [("x1", `Int (-5)); ("y1", `Int (-5));
                        ("x2", `Int 15); ("y2", `Int 15)])]]
      ctrl;
    assert (sel_entry m [0; 0] <> None);
    let kind = sel_kind m [0; 0] in
    Alcotest.(check int) "all four CPs" 4
      (Document.selection_kind_count kind ~total:4);
    assert (Document.selection_kind_is_all kind ~total:4);
    assert (not (Document.PathMap.mem [0; 1] m#document.selection)));

  (* SEL-106: an empty (zero-size) marquee with no shift clears the CP
     selection. *)
  Alcotest.test_case "empty_marquee_clears_selection" `Quick (fun () ->
    let m = two_rect_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Select a CP first. *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 0); ("y", `Int 0);
                        ("hit_radius", `Int 8)])]]
      ctrl;
    assert (not (Document.PathMap.is_empty m#document.selection));
    (* A zero-size marquee (rw,rh <= 1), non-additive, clears the selection. *)
    run_with_effects store
      [`Assoc [("doc.path.commit_partial_marquee",
                `Assoc [("x1", `Int 100); ("y1", `Int 100);
                        ("x2", `Int 100); ("y2", `Int 100)])]]
      ctrl;
    assert (Document.PathMap.is_empty m#document.selection));
]

(* ── Partial Selection control-point DRAG (SEL-130 CP translate) ──

   Dragging a selected control point is [doc.translate_selection] over a PARTIAL
   selection: the move calls Element.move_control_points on the kind, so ONLY
   the selected CPs move. A rect's corners are not independently movable, so
   these use a triangle Path whose anchors are cp0=(0,0), cp1=(100,0),
   cp2=(50,100) (Element.control_points == path_anchor_points d). *)

let make_path_element d =
  Element.Path { name = None; id = None;
    d;
    fill = None; stroke = None; width_points = [];
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
    stroke_brush = None; stroke_brush_overrides = None;
    tool_origin = None;
  }

let path_children_model d =
  let layer = Element.Layer {
    name = Some "L"; id = None; children = [| make_path_element d |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
  m

let triangle_path_model () =
  path_children_model
    [ Element.MoveTo (0.0, 0.0);
      Element.LineTo (100.0, 0.0);
      Element.LineTo (50.0, 100.0);
      Element.ClosePath ]

(* Read the control-point positions of the single path child. *)
let cps_of (m : Model.model) =
  match m#document.Document.layers.(0) with
  | Element.Layer { children; _ } -> Element.control_points children.(0)
  | _ -> Alcotest.fail "expected layer"

let cp_eq (ax, ay) x y = Float.abs (ax -. x) < 1e-9 && Float.abs (ay -. y) < 1e-9

let partial_selection_cp_drag_tests = [
  (* SEL-130: dragging a single selected CP translates ONLY that anchor; the
     other anchors of the same path stay put. *)
  Alcotest.test_case "cp_drag_translates_only_selected_control_point" `Quick (fun () ->
    let m = triangle_path_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Select anchor 0 = (0,0). *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 0); ("y", `Int 0);
                        ("hit_radius", `Int 8)])]]
      ctrl;
    assert (Document.selection_kind_contains (sel_kind m [0; 0]) 0);
    (* Drag that CP by (+20, +30). *)
    run_with_effects store
      [`Assoc [("doc.translate_selection",
                `Assoc [("dx", `Int 20); ("dy", `Int 30)])]]
      ctrl;
    let cps = cps_of m in
    Alcotest.(check int) "three CPs" 3 (List.length cps);
    assert (cp_eq (List.nth cps 0) 20.0 30.0);    (* anchor 0 moved *)
    assert (cp_eq (List.nth cps 1) 100.0 0.0);    (* anchor 1 unchanged *)
    assert (cp_eq (List.nth cps 2) 50.0 100.0);   (* anchor 2 unchanged *)
    (* Selection preserved (still the same single CP). *)
    Alcotest.(check int) "still one CP selected" 1
      (Document.selection_kind_count (sel_kind m [0; 0]) ~total:3));

  (* SEL-130: dragging a multi-CP selection translates EVERY selected anchor by
     the same delta and leaves the unselected anchor put. *)
  Alcotest.test_case "cp_drag_translates_all_selected_control_points" `Quick (fun () ->
    let m = triangle_path_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* Select anchor 0 = (0,0), then shift-add anchor 2 = (50,100). *)
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 0); ("y", `Int 0);
                        ("hit_radius", `Int 8)])]]
      ctrl;
    run_with_effects store
      [`Assoc [("doc.path.probe_partial_hit",
                `Assoc [("x", `Int 50); ("y", `Int 100);
                        ("hit_radius", `Int 8);
                        ("shift", `Bool true)])]]
      ctrl;
    Alcotest.(check int) "two CPs selected" 2
      (Document.selection_kind_count (sel_kind m [0; 0]) ~total:3);
    (* Drag the pair by (+10, -10). *)
    run_with_effects store
      [`Assoc [("doc.translate_selection",
                `Assoc [("dx", `Int 10); ("dy", `Int (-10))])]]
      ctrl;
    let cps = cps_of m in
    assert (cp_eq (List.nth cps 0) 10.0 (-10.0));  (* anchor 0 moved *)
    assert (cp_eq (List.nth cps 1) 100.0 0.0);     (* anchor 1 not selected *)
    assert (cp_eq (List.nth cps 2) 60.0 90.0));    (* anchor 2 moved *)
]

(* ── Partial Selection Bezier HANDLE drag (SEL-131 / SEL-306) ──

   Dragging a Bezier HANDLE (not the anchor) of a SMOOTH path anchor is
   [doc.move_path_handle]. The effect reads the latched handle target from
   partial_selection tool state — handle_path (encoded element path as
   {"__path__": [..]}), handle_anchor_idx, handle_type ("in"|"out") — and
   applies (dx,dy) to the named handle. The opposite handle is then rotated to
   stay COLLINEAR through the anchor while keeping its OWN distance
   (smooth-point semantics), and the anchor stays put.

   Handle drags need a CURVED Path: a smooth middle anchor whose in- and
   out-handles are collinear-through-the-anchor and equidistant, so the
   reflection is an exact point-reflection (clean integer assertions).

   Fixture — a two-segment cubic path:
     MoveTo(0,100)                                     anchor 0 = (0,100)
     CurveTo(20,100, 80,100, 100,100)   anchor 1 = (100,100), in-handle (80,100)
     CurveTo(120,100, 180,100, 200,100) anchor 2 = (200,100), out-handle of
                                        anchor 1 = (120,100)
   Anchor 1 is the SMOOTH anchor under test: in-handle (80,100) and out-handle
   (120,100) sit on opposite sides of the anchor, both 20 units away — a true
   smooth point. (path_handle_positions returns (in, out) for an anchor index.) *)

let smooth_curve_path_model () =
  path_children_model
    [ Element.MoveTo (0.0, 100.0);
      Element.CurveTo (20.0, 100.0, 80.0, 100.0, 100.0, 100.0);
      Element.CurveTo (120.0, 100.0, 180.0, 100.0, 200.0, 100.0) ]

(* Anchor (end-point) position of a path command, for asserting the anchor
   stays put. *)
let anchor_pos d anchor_idx =
  let cmd_indices = ref [] in
  List.iteri (fun ci cmd ->
    match cmd with
    | Element.ClosePath -> ()
    | _ -> cmd_indices := ci :: !cmd_indices) d;
  let cmd_indices = List.rev !cmd_indices in
  match List.nth d (List.nth cmd_indices anchor_idx) with
  | Element.MoveTo (x, y) | Element.LineTo (x, y) -> (x, y)
  | Element.CurveTo (_, _, _, _, x, y) -> (x, y)
  | _ -> Alcotest.fail "anchor command has no end point"

let path_d_of (m : Model.model) =
  match m#document.Document.layers.(0) with
  | Element.Layer { children; _ } ->
    (match children.(0) with
     | Element.Path { d; _ } -> d
     | _ -> Alcotest.fail "expected path element")
  | _ -> Alcotest.fail "expected layer"

let opt_eq o x y = match o with Some p -> cp_eq p x y | None -> false

let partial_selection_handle_tests = [
  (* SEL-131/306: dragging the OUT handle of a smooth anchor moves that handle
     by (dx,dy); the opposite IN handle is reflected through the anchor (mirror
     / smooth-point behavior), and the anchor itself does not move.

       anchor 1 = (100,100) before and after — stays put.
       out-handle (120,100) --[drag (-20,+20)]--> (100,120)   moved by (dx,dy)
       in-handle  (80,100)  --[MIRRORED]--------> (100, 80)   reflected through
           the anchor: 2*anchor - new_out = (200,200)-(100,120) = (100,80). *)
  Alcotest.test_case "handle_drag_out_mirrors_opposite_in_handle" `Quick (fun () ->
    let m = smooth_curve_path_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    (* BEFORE: confirm the smooth-point fixture. *)
    let d0 = path_d_of m in
    let (in0, out0) = Element.path_handle_positions d0 1 in
    assert (opt_eq in0 80.0 100.0);    (* in-handle  (80,100) *)
    assert (opt_eq out0 120.0 100.0);  (* out-handle (120,100) *)
    assert (cp_eq (anchor_pos d0 1) 100.0 100.0);  (* anchor (100,100) *)
    (* Latch the handle target the way probe_partial_hit would: anchor 1's OUT
       handle on element [0;0]. *)
    State_store.set_tool store "partial_selection" "handle_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 0])]);
    State_store.set_tool store "partial_selection" "handle_anchor_idx" (`Int 1);
    State_store.set_tool store "partial_selection" "handle_type" (`String "out");
    (* Drag the OUT handle by (dx=-20, dy=+20): (120,100) -> (100,120). *)
    run_with_effects store
      [`Assoc [("doc.move_path_handle",
                `Assoc [("dx", `Int (-20)); ("dy", `Int 20)])]]
      ctrl;
    (* AFTER. *)
    let d1 = path_d_of m in
    let (in1, out1) = Element.path_handle_positions d1 1 in
    assert (opt_eq out1 100.0 120.0);  (* dragged handle moved by (dx,dy) *)
    assert (opt_eq in1 100.0 80.0);    (* opposite handle MIRRORED *)
    assert (cp_eq (anchor_pos d1 1) 100.0 100.0);  (* anchor unmoved *)
    assert (cp_eq (anchor_pos d1 0) 0.0 100.0);    (* other anchors untouched *)
    assert (cp_eq (anchor_pos d1 2) 200.0 100.0));

  (* SEL-131/306 (symmetric case): dragging the IN handle mirrors the OUT
     handle. Drag the in-handle (80,100) by (dx=+20, dy=+20) -> (100,120); the
     out-handle reflects through the anchor to (100,80) = 2*(100,100)-(100,120). *)
  Alcotest.test_case "handle_drag_in_mirrors_opposite_out_handle" `Quick (fun () ->
    let m = smooth_curve_path_model () in
    let ctrl = make_ctrl_with m in
    let store = State_store.create () in
    State_store.set_tool store "partial_selection" "handle_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 0])]);
    State_store.set_tool store "partial_selection" "handle_anchor_idx" (`Int 1);
    State_store.set_tool store "partial_selection" "handle_type" (`String "in");
    (* Drag the IN handle by (dx=+20, dy=+20): (80,100) -> (100,120). *)
    run_with_effects store
      [`Assoc [("doc.move_path_handle",
                `Assoc [("dx", `Int 20); ("dy", `Int 20)])]]
      ctrl;
    let d1 = path_d_of m in
    let (in1, out1) = Element.path_handle_positions d1 1 in
    assert (opt_eq in1 100.0 120.0);   (* dragged in-handle *)
    assert (opt_eq out1 100.0 80.0);   (* MIRRORED out-handle *)
    assert (cp_eq (anchor_pos d1 1) 100.0 100.0));  (* anchor put *)
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
    "Blob Brush commit", blob_brush_commit_tests;
    "doc.magic_wand.apply", magic_wand_apply_tests;
    "doc.artboard.create_commit", artboard_create_tests;
    "doc.artboard.probe_hit", artboard_probe_hit_tests;
    "doc.artboard.probe_hover", artboard_probe_hover_tests;
    "doc.artboard.move_apply", artboard_move_tests;
    "Partial Selection CP", partial_selection_cp_tests;
    "Partial Selection CP drag", partial_selection_cp_drag_tests;
    "Partial Selection handle", partial_selection_handle_tests;
  ]
