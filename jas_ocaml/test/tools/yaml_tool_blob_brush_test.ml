(** Blob-brush-tool gesture-seam tests — OCaml port of the Rust blob
    brush seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
    blob_brush_parity_* family). Structurally modeled on
    yaml_tool_pencil_test.ml: same seam, same loader pattern, same
    empty-layer model.

    These drive the PRODUCTION blob_brush tool loaded from the
    workspace bundle through on_press / on_move / on_release /
    on_key_event and assert the committed Path. They complement the
    effect-level unit tests in yaml_tool_effects_test.ml (which call
    doc.blob_brush.commit_painting / commit_erasing directly with a
    PRE-SEEDED point buffer): the seam tests exercise the FULL gesture
    pipeline — mode latching on press (Alt to erasing), arc-length dab
    accumulation via doc.blob_brush.sweep_sample on each move, and the
    commit on release.

    Seam mapping from Rust to OCaml:
      on_press        -> on_press ctx x y ~shift ~alt
      on_move(drag)   -> on_move ctx x y ~shift ~alt ~dragging
      on_release      -> on_release ctx x y ~shift ~alt
      on_key_event    -> on_key_event ctx key mods

    App-level state seeding. The commit handlers read app-level
    state.blob_brush_* and state.fill_color (tip shape, fill, fidelity,
    merge filter). In Rust the test reaches the YamlTool private store
    directly (tool.store.set, same-module test). The OCaml test lives
    in a separate file, so the yaml_tool class exposes a test-only
    seed_state method that writes the same global keys into its own
    store. Keys and values mirror the blob_brush_state_defaults helper
    in yaml_tool_effects_test.ml plus the extra fidelity / merge /
    keep-selected keys the commit reads.

    Escape entry point. The GTK canvas shell, for a non-capturing tool,
    routes Escape and Enter through active_tool#on_key_event (see
    Canvas_subwindow.forward_key_event), and the YamlTool maps the
    string-based on_key_event onto the spec on_keydown handler with
    event.key bound to the key string. Driving Escape through
    on_key_event ctx "Escape" no_mods is exactly the shell dispatch a
    non-capturing blob brush tool receives, matching the pencil tests
    Escape case. *)

open Jas

let () = ignore (GMain.init ())

let blob_brush_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "blob_brush" tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

(** Seed the app-level state.blob_brush_* and state.fill_color that the
    commit reads (tip shape, fill, fidelity, merge filter, keep-
    selected). Mirrors the Rust seed_blob_brush_app_state helper. *)
let seed_blob_brush_app_state (tool : Yaml_tool.yaml_tool) : unit =
  tool#seed_state "fill_color" (`String "#ff0000");
  tool#seed_state "blob_brush_size" (`Float 10.0);
  tool#seed_state "blob_brush_angle" (`Float 0.0);
  tool#seed_state "blob_brush_roundness" (`Float 100.0);
  tool#seed_state "blob_brush_fidelity" (`Float 1.0);
  tool#seed_state "blob_brush_merge_only_with_selection" (`Bool false);
  tool#seed_state "blob_brush_keep_selected" (`Bool false)

(** Document with a single empty layer (no children). *)
let empty_layer_model () : Model.model =
  let layer = Element.Layer {
    name = Some "L";
    id = None;
    children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

(** Single-layer model holding one filled red square spanning
    (x0,y0)-(x1,y1). When [blob_origin] is true the square carries
    jas:tool-origin=blob_brush (an erase target); otherwise it has no
    tool-origin (an erase bystander). Mirrors the Rust
    model_with_square helper. *)
let model_with_square (x0 : float) (y0 : float) (x1 : float) (y1 : float)
    (blob_origin : bool) : Model.model =
  let square = Element.Path { name = None; id = None;
    d = [ Element.MoveTo (x0, y0);
          Element.LineTo (x1, y0);
          Element.LineTo (x1, y1);
          Element.LineTo (x0, y1);
          Element.ClosePath ];
    fill = Some (Element.make_fill (Element.color_rgb 1.0 0.0 0.0));
    stroke = None; width_points = [];
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
    stroke_brush = None; stroke_brush_overrides = None;
    tool_origin = (if blob_origin then Some "blob_brush" else None);
  } in
  let layer = Element.Layer {
    name = Some "L"; id = None; children = [| square |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

let no_mods : Canvas_tool.key_mods =
  { shift = false; ctrl = false; alt = false; meta = false }

let make_ctx model =
  let ctrl = new Controller.controller ~model () in
  let ctx : Canvas_tool.tool_context = {
    model;
    controller = ctrl;
    hit_test_selection = (fun _ _ -> false);
    hit_test_handle = (fun _ _ -> None);
    hit_test_text = (fun _ _ -> None);
    hit_test_path_curve = (fun _ _ -> None);
    request_update = (fun () -> ());
    draw_element_overlay = (fun _cr _elem ~is_partial:_ _cps -> ());
  } in
  (ctx, ctrl)

(** Children of the first layer. *)
let layer0_children (m : Model.model) : Element.element array =
  match m#document.layers.(0) with
  | Element.Layer { children; _ } -> children
  | _ -> [||]

(** Drive a left-to-right paint (or erase, when [alt] is true) sweep
    along y=0 from x0 to x1 with a dab every 10pt — enough arc-length
    for sweep_sample to push a dab on each move (tip size 10, so half
    min-dimension is the 5pt threshold). press latches the mode (Alt to
    erasing), release commits. Mirrors the Rust blob_brush_sweep. *)
let blob_brush_sweep (tool : Yaml_tool.yaml_tool)
    (ctx : Canvas_tool.tool_context) (x0 : float) (x1 : float) (alt : bool)
  : unit =
  tool#on_press ctx x0 0.0 ~shift:false ~alt;
  let x = ref (x0 +. 10.0) in
  while !x < x1 do
    tool#on_move ctx !x 0.0 ~shift:false ~alt ~dragging:true;
    x := !x +. 10.0
  done;
  tool#on_release ctx x1 0.0 ~shift:false ~alt

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "blob_brush_tool_loads_from_workspace" `Quick (fun () ->
    match blob_brush_tool () with
    | Some tool ->
      assert (tool#spec.id = "blob_brush")
    | None -> Alcotest.skip ());
]

(* ── Paint commits a tagged Path (BB-010/011) ───────── *)

let paint_tests = [
  Alcotest.test_case "paint_commits_tagged_path" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      blob_brush_sweep tool ctx 0.0 50.0 false;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Path pe ->
         (* Committed path carries jas:tool-origin=blob_brush. *)
         assert (pe.tool_origin = Some "blob_brush");
         (* Blob path is filled, with no stroke. *)
         assert (pe.fill <> None);
         assert (pe.stroke = None);
         (* Closed swept region: MoveTo + LineTos + ClosePath. *)
         assert (List.length pe.d >= 3)
       | _ -> assert false));
]

(* ── undo / redo round-trips a paint (BB-016) ───────── *)

let undo_redo_tests = [
  Alcotest.test_case "undo_redo_round_trips" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      blob_brush_sweep tool ctx 0.0 50.0 false;
      assert (Array.length (layer0_children m) = 1);
      (* undo removes the blob. *)
      m#undo;
      assert (Array.length (layer0_children m) = 0);
      (* redo restores the blob. *)
      m#redo;
      assert (Array.length (layer0_children m) = 1));
]

(* ── Escape mid-drag cancels (BB-004) ───────────────── *)

let escape_cancel_tests = [
  Alcotest.test_case "escape_during_drag_cancels" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* Begin a paint drag. *)
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 20.0 0.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 40.0 0.0 ~shift:false ~alt:false ~dragging:true;
      (* Escape via the SAME key entry the canvas shell dispatches for a
         non-capturing tool. The spec on_keydown Escape branch sets
         mode=idle and clears the buffer. *)
      let _ = tool#on_key_event ctx "Escape" no_mods in
      (* on_mouseup now takes the non-painting branch (mode != painting),
         so it must NOT commit. *)
      tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
      (* ZERO children committed: the document is unchanged. *)
      assert (Array.length (layer0_children m) = 0));
]

(* ── Alt-erase removes a fully-covered blob (BB-100/101) ── *)

let alt_erase_removes_tests = [
  Alcotest.test_case "alt_erase_removes_covered_blob" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      (* Square (23,-1)-(27,1): fully inside a 0..50 sweep, 10pt tip. *)
      let m = model_with_square 23.0 (-1.0) 27.0 1.0 true in
      let (ctx, _) = make_ctx m in
      assert (Array.length (layer0_children m) = 1);
      (* alt = erase. *)
      blob_brush_sweep tool ctx 0.0 50.0 true;
      (* Alt-erase deletes a fully-covered blob-brush element. *)
      assert (Array.length (layer0_children m) = 0));
]

(* ── Alt-erase leaves a non-blob bystander (BB-104) ─── *)

let alt_erase_leaves_tests = [
  Alcotest.test_case "alt_erase_leaves_non_blob" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      (* Same square but with no tool-origin. *)
      let m = model_with_square 23.0 (-1.0) 27.0 1.0 false in
      let (ctx, _) = make_ctx m in
      (* alt = erase. *)
      blob_brush_sweep tool ctx 0.0 50.0 true;
      let children = layer0_children m in
      (* Erase must not touch non-blob-brush elements. *)
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Path pe -> assert (pe.tool_origin = None)
       | _ -> assert false));
]

(* ── Overlapping same-fill paint merges (BB-070) ─────── *)

let merge_tests = [
  Alcotest.test_case "overlapping_same_fill_merges" `Quick (fun () ->
    match blob_brush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      seed_blob_brush_app_state tool;
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      blob_brush_sweep tool ctx 0.0 50.0 false;
      assert (Array.length (layer0_children m) = 1);
      (* Second stroke (25..75) overlaps the first (0..50). *)
      blob_brush_sweep tool ctx 25.0 75.0 false;
      (* Overlapping same-fill paint merges into one Path. *)
      assert (Array.length (layer0_children m) = 1));
]

let () =
  Alcotest.run "Yaml blob brush tool" [
    "Tool load", load_tests;
    "Paint commit", paint_tests;
    "Undo redo", undo_redo_tests;
    "Escape cancel", escape_cancel_tests;
    "Alt erase removes", alt_erase_removes_tests;
    "Alt erase leaves non-blob", alt_erase_leaves_tests;
    "Overlapping merge", merge_tests;
  ]
