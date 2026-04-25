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
    name = "L";
    children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document doc;
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
    let target = Element.Path {
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
      name = "L"; children = [| target |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document doc;
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
    let target = Element.Path {
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
      name = "L"; children = [| target |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document doc;
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
  Element.Rect {
    x; y; width = 10.0; height = 10.0;
    rx = 0.0; ry = 0.0;
    fill = Some (Element.make_fill (Element.color_rgb 1.0 0.0 0.0));
    stroke = None;
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let blue_filled_rect x y =
  Element.Rect {
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
    name = "L";
    children = [| red_filled_rect 0.0 0.0;
                  red_filled_rect 50.0 0.0;
                  blue_filled_rect 100.0 0.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  let m = Model.create () in
  m#set_document doc;
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
      name = "L"; children = [| r0; r1_locked; r2_hidden |];
      transform = None; locked = false; opacity = 1.0;
      visibility = Preview; blend_mode = Normal; mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = Document.make_document [| layer |] in
    let m = Model.create () in
    m#set_document doc;
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
    name = "L"; children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document
    ~artboards:abs_list [| layer |] in
  let m = Model.create () in
  m#set_document doc;
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
  ]
