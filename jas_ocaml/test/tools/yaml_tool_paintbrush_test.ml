(** Paintbrush-tool gesture-seam tests — OCaml port of the Rust
    paintbrush seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
    paintbrush_parity_* family). Structurally modeled on
    yaml_tool_blob_brush_test.ml: same seam, same loader pattern, same
    empty-layer model, same production app-state bridge.

    These drive the PRODUCTION paintbrush tool loaded from the workspace
    bundle through on_press / on_move / on_release / on_key_event and
    assert the committed Path. They complement the effect-level unit
    tests (which call doc.add_path_from_buffer / edit_commit directly
    with a PRE-SEEDED point buffer): the seam tests exercise the FULL
    gesture pipeline AND the app-state bridge. Both the smoothing
    (paintbrush_fidelity -> fit_error) and the fill (fill_new_strokes ->
    state.fill_color) arrive ONLY through the bridge — before the
    paintbrush_* keys were bridged the live tool committed with
    fit_error=0 (no smoothing) and dropped the fill.

    Seam mapping from Rust to OCaml:
      on_press        -> on_press ctx x y ~shift ~alt
      on_move(drag)   -> on_move ctx x y ~shift ~alt ~dragging
      on_release      -> on_release ctx x y ~shift ~alt
      on_key_event    -> on_key_event ctx key mods

    App-level state seeding. The commit handlers read app-level
    state.paintbrush_fidelity / state.paintbrush_fill_new_strokes /
    state.fill_color. In Rust the test seeds these through the
    production sync_global_state bridge. The OCaml bridge
    ([Yaml_tool.bridge_app_state]) reads fill_color from the Model
    active default fill and takes the rest as allowlisted [~overrides] —
    the same allowlist the live per-dispatch state map flows through.
    fidelity=3 maps to fit_error 5.0, a SMOOTHED fit.

    Escape entry point. The GTK canvas shell, for a non-capturing tool,
    routes Escape and Enter through active_tool#on_key_event (see
    Canvas_subwindow.forward_key_event), and the YamlTool maps the
    string-based on_key_event onto the spec on_keydown handler with
    event.key bound to the key string. Driving Escape through
    on_key_event ctx "Escape" no_mods is exactly the shell dispatch a
    non-capturing paintbrush tool receives. *)

open Jas

let () = ignore (GMain.init ())

let paintbrush_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "paintbrush" tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

(** Seed the app-level state the paintbrush commit reads, through the
    PRODUCTION bridge ([bridge_app_state]) rather than poking the tool
    store directly — so these seam tests exercise the same path the
    canvas uses per-dispatch.

    fill_color is delivered by setting its PRODUCTION source (the Model
    active default fill) to red; [bridge_app_state] reads it and writes
    state.fill_color=#ff0000 into the tool global namespace. The
    paintbrush_* options are passed as allowlisted [~overrides] — the
    same allowlist the live per-dispatch state map flows through:
    paintbrush_fidelity=3 (-> fit_error 5.0, a SMOOTHED fit), the
    edit/keep options, and paintbrush_fill_new_strokes set per
    [fill_new] so a single helper covers both the fills/no-fill cases.
    Mirrors the Rust seed_paintbrush_app_state helper, which routes the
    same app-level state through sync_global_state. *)
let seed_paintbrush_app_state (tool : Yaml_tool.yaml_tool)
    (model : Model.model) (fill_new : bool) : unit =
  model#set_default_fill
    (Some (Element.make_fill (Element.color_rgb 1.0 0.0 0.0)));
  let overrides : (string * Yojson.Safe.t) list = [
    ("paintbrush_fidelity", `Int 3);
    ("paintbrush_fill_new_strokes", `Bool fill_new);
    ("paintbrush_edit_within", `Int 12);
    ("paintbrush_edit_selected_paths", `Bool true);
    ("paintbrush_keep_selected", `Bool true);
  ] in
  tool#bridge_app_state ~overrides model

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

(** Drive a multi-point paintbrush zigzag: press -> three drag moves ->
    release. Mirrors the Rust paintbrush_stroke helper (same points). *)
let paintbrush_stroke (tool : Yaml_tool.yaml_tool)
    (ctx : Canvas_tool.tool_context) : unit =
  tool#on_press ctx 40.0 60.0 ~shift:false ~alt:false;
  tool#on_move ctx 60.0 40.0 ~shift:false ~alt:false ~dragging:true;
  tool#on_move ctx 80.0 60.0 ~shift:false ~alt:false ~dragging:true;
  tool#on_move ctx 100.0 40.0 ~shift:false ~alt:false ~dragging:true;
  tool#on_release ctx 120.0 60.0 ~shift:false ~alt:false

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "paintbrush_tool_loads_from_workspace" `Quick (fun () ->
    match paintbrush_tool () with
    | Some tool -> assert (tool#spec.id = "paintbrush")
    | None -> Alcotest.skip ());
]

(* ── Paint commits a SMOOTHED stroke (fidelity via the bridge) ─── *)

let smoothed_tests = [
  Alcotest.test_case "paint_commits_smoothed_stroke" `Quick (fun () ->
    match paintbrush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      seed_paintbrush_app_state tool m false;
      let (ctx, _) = make_ctx m in
      paintbrush_stroke tool ctx;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Path pe ->
         (* Paintbrush path carries a stroke. *)
         assert (pe.stroke <> None);
         (* fidelity=3 -> fit_error 5.0 (via the bridge): a SMOOTHED fit
            (MoveTo followed by CurveTos), NOT the degenerate fit_error=0
            over-fit that a null fidelity would produce. *)
         (match pe.d with
          | Element.MoveTo _ :: rest ->
            assert (rest <> []);
            assert (List.for_all
                      (function Element.CurveTo _ -> true | _ -> false)
                      rest)
          | _ -> assert false)
       | _ -> assert false));
]

(* ── fill_new_strokes=true fills via the bridge ─────── *)

let fill_on_tests = [
  Alcotest.test_case "fill_new_strokes_fills_via_bridge" `Quick (fun () ->
    (* The fill (red) reaches the commit ONLY through the app-state bridge
       (fill_color from the Model default fill), gated by
       fill_new_strokes=true. Before the bridge the live tool dropped it
       (fill_new_strokes -> null -> false). Paintbrush analogue of the
       blob fill bug. *)
    match paintbrush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      seed_paintbrush_app_state tool m true;
      let (ctx, _) = make_ctx m in
      paintbrush_stroke tool ctx;
      (match (layer0_children m).(0) with
       | Element.Path pe -> assert (pe.fill <> None)
       | _ -> assert false));
]

(* ── fill_new_strokes=false (default) -> no fill ────── *)

let fill_off_tests = [
  Alcotest.test_case "no_fill_when_option_off" `Quick (fun () ->
    (* fill_new_strokes=false -> open freehand stroke, no fill. *)
    match paintbrush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      seed_paintbrush_app_state tool m false;
      let (ctx, _) = make_ctx m in
      paintbrush_stroke tool ctx;
      (match (layer0_children m).(0) with
       | Element.Path pe -> assert (pe.fill = None)
       | _ -> assert false));
]

(* ── undo / redo round-trips a paint ────────────────── *)

let undo_redo_tests = [
  Alcotest.test_case "undo_redo_round_trips" `Quick (fun () ->
    match paintbrush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      seed_paintbrush_app_state tool m false;
      let (ctx, _) = make_ctx m in
      paintbrush_stroke tool ctx;
      assert (Array.length (layer0_children m) = 1);
      (* undo removes the stroke. *)
      m#undo;
      assert (Array.length (layer0_children m) = 0);
      (* redo restores it. *)
      m#redo;
      assert (Array.length (layer0_children m) = 1));
]

(* ── Escape mid-drag cancels ────────────────────────── *)

let escape_cancel_tests = [
  Alcotest.test_case "escape_during_drag_cancels" `Quick (fun () ->
    match paintbrush_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      seed_paintbrush_app_state tool m false;
      let (ctx, _) = make_ctx m in
      (* Begin a paint drag. *)
      tool#on_press ctx 40.0 60.0 ~shift:false ~alt:false;
      tool#on_move ctx 60.0 40.0 ~shift:false ~alt:false ~dragging:true;
      (* Escape via the SAME key entry the canvas shell dispatches for a
         non-capturing tool. The spec on_keydown Escape branch sets
         mode=idle, so the on_mouseup drawing-commit branch (guarded by
         mode == drawing) is skipped. *)
      let _ = tool#on_key_event ctx "Escape" no_mods in
      tool#on_release ctx 80.0 60.0 ~shift:false ~alt:false;
      (* ZERO children committed: Escape cancelled the stroke. *)
      assert (Array.length (layer0_children m) = 0));
]

let () =
  Alcotest.run "Yaml paintbrush tool" [
    "Tool load", load_tests;
    "Smoothed commit", smoothed_tests;
    "Fill on", fill_on_tests;
    "Fill off", fill_off_tests;
    "Undo redo", undo_redo_tests;
    "Escape cancel", escape_cancel_tests;
  ]
