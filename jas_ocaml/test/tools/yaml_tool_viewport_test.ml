(** Combined Zoom + Hand viewport gesture-seam tests. Drives [Yaml_tool]
    with the zoom / hand specs loaded from workspace/workspace.json and
    verifies behavior matches the Rust reference in
    jas_dioxus/src/tools/yaml_tool.rs (the zoom_parity and hand_parity
    families, committed 69fd8f1d).

    These are VIEWPORT tools: they change the per-tab VIEW STATE on the
    model (zoom_level, view_offset_x, view_offset_y), never the document.
    So the load-bearing assertions read those three model fields directly,
    with the EXACT numbers from the Rust reference:

      Hand drag : view_offset = initial_offset + (cursor - press), same
                  sign. From a NON-zero baseline (30, -10) a (+60, +35)
                  screen delta lands the offset at (90, 25). Idempotent —
                  re-issuing the same cursor does not accumulate.
      Hand esc  : Escape mid-pan restores the pre-drag offset; mode goes
                  idle -> panning -> idle.
      Zoom click: a plain click zooms IN to initial * zoom_step (1.2) and
                  recenters so the clicked SCREEN point stays glued to its
                  doc point (off = anchor - doc_anchor * z_new; at the
                  identity view off = sx*(1 - z_new)).
      Zoom alt  : an Alt-click zooms OUT to initial * (1 / zoom_step) =
                  0.83333...
      Zoom esc  : a >4px scrubby drag changes the view; Escape restores the
                  pre-drag snapshot.
      Zoom sub  : a <=4px drag is treated as a click (zooms in by step on
                  release, anchored at the release point).

    [zoom_step] is read from the bundle (preferences.viewport.zoom_step =
    1.2) the same way the Rust [bundle_zoom_step] helper does, so the tests
    assert against the REAL production factor.

    View changes are NOT journaled: the no-op / escape cases also assert
    [Test_json.document_to_test_json] byte-identity and [can_undo] = false.
    These tools read no app-level state.* beyond the view fields the
    dispatch ctx injects, so no bridge seeding is needed. *)

open Jas

let () = ignore (GMain.init ())

(* -- Loaders ----------------------------------------------------- *)

let load_tool (key : string) : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt key tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

let zoom_tool () = load_tool "zoom"
let hand_tool () = load_tool "hand"

(** Read [preferences.viewport.zoom_step] out of the embedded bundle so
    the tests assert against the REAL production factor rather than a
    hardcoded guess. Port of the Rust [bundle_zoom_step]; falls back to the
    documented 1.2 if the bundle is somehow missing the key (a sanity
    assert in the first zoom case catches a true mismatch). *)
let bundle_zoom_step () : float =
  match Workspace_loader.load () with
  | None -> 1.2
  | Some ws ->
    (match Workspace_loader.json_member "preferences" ws.data with
     | Some (`Assoc prefs) ->
       (match List.assoc_opt "viewport" prefs with
        | Some (`Assoc viewport) ->
          (match List.assoc_opt "zoom_step" viewport with
           | Some (`Float f) -> f
           | Some (`Int i) -> float_of_int i
           | _ -> 1.2)
        | _ -> 1.2)
     | _ -> 1.2)

(* -- Fixture ----------------------------------------------------- *)

(** Minimal one-layer document for the VIEWPORT tools. They ignore
    document content entirely (they touch only view state), so an empty
    layer is enough; the fresh model starts at the identity view (zoom 1.0,
    offset 0,0). Port of the Rust [viewport_model]. *)
let viewport_model () : Model.model =
  let layer = Element.Layer {
    name = Some "L"; id = None;
    children = [||];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let doc = Document.make_document [| layer |] in
  new Model.model ~document:doc ()

let make_ctx (model : Model.model) =
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

(* -- Helpers ----------------------------------------------------- *)

(** Canonical document JSON for the "unchanged?" comparison — the same
    canonicalization the cross-language byte-gate uses. Port of the Rust
    [doc_json]. *)
let doc_json (model : Model.model) : string =
  Test_json.document_to_test_json model#document

(** Read [tool.hand.mode] back out of the tool own store. Port of the Rust
    [read_mode] closure reaching [tool.store.eval_context]. *)
let read_hand_mode (tool : Yaml_tool.yaml_tool) : string =
  match tool#tool_state "mode" with
  | `String s -> s
  | _ -> ""

let approx a b tol = Float.abs (a -. b) < tol

(* -- Hand -------------------------------------------------------- *)

let hand_tests = [
  Alcotest.test_case "drag_pans_view_offset_by_screen_delta" `Quick
    (fun () ->
    match hand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      (* Start from a NON-zero baseline offset so the test proves the pan
         is [initial + delta], not just [delta]. *)
      m#set_view_offset_x 30.0;
      m#set_view_offset_y (-10.0);
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      let z_before = m#zoom_level in
      (* Press at screen (100,100); drag to (160,135):
           delta = (160-100, 135-100) = (+60, +35)
         doc.pan.apply: off = initial + delta (same sign), so
           off_x = 30 + 60 = 90 ; off_y = -10 + 35 = 25 *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_move ctx 160.0 135.0 ~shift:false ~alt:false ~dragging:true;
      assert (approx m#view_offset_x 90.0 1e-9);
      assert (approx m#view_offset_y 25.0 1e-9);
      (* The pan touches ONLY the offset — zoom and document stay put. *)
      assert (approx m#zoom_level z_before 1e-9);
      assert (doc_json m = before);
      assert (not m#can_undo);
      (* Idempotency: a SECOND move to the same cursor recomputes from
         press+initial, so the offset is identical (not doubled). *)
      tool#on_move ctx 160.0 135.0 ~shift:false ~alt:false ~dragging:true;
      assert (approx m#view_offset_x 90.0 1e-9);
      assert (approx m#view_offset_y 25.0 1e-9));

  Alcotest.test_case "escape_mid_pan_restores_initial_offset" `Quick
    (fun () ->
    match hand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      m#set_view_offset_x 30.0;
      m#set_view_offset_y (-10.0);
      let off_x0 = m#view_offset_x in
      let off_y0 = m#view_offset_y in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      let mods : Canvas_tool.key_mods =
        { shift = false; ctrl = false; alt = false; meta = false } in
      (* Begin the SAME pan proven to move the view, but press Escape
         BEFORE releasing. Escape's on_keydown restores the pre-drag
         offset via doc.zoom.set_full and idles. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_move ctx 160.0 135.0 ~shift:false ~alt:false ~dragging:true;
      (* Precondition: mid-pan the view IS shifted to (90, 25). *)
      assert (approx m#view_offset_x 90.0 1e-9);
      assert (approx m#view_offset_y 25.0 1e-9);
      ignore (tool#on_key_event ctx "Escape" mods);
      (* Escape restores the initial offset. *)
      assert (approx m#view_offset_x off_x0 1e-9);
      assert (approx m#view_offset_y off_y0 1e-9);
      (* A subsequent mousemove must NOT re-pan: Escape set mode=idle so
         the on_mousemove [mode == panning] guard now fails. *)
      tool#on_move ctx 300.0 300.0 ~shift:false ~alt:false ~dragging:true;
      assert (approx m#view_offset_x off_x0 1e-9);
      assert (approx m#view_offset_y off_y0 1e-9);
      assert (doc_json m = before);
      assert (not m#can_undo));

  Alcotest.test_case "mode_idle_panning_idle_lifecycle" `Quick (fun () ->
    match hand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      let (ctx, _) = make_ctx m in
      (* on_enter resets to idle. *)
      tool#activate ctx;
      assert (read_hand_mode tool = "idle");
      (* mousedown => panning. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      assert (read_hand_mode tool = "panning");
      (* mouseup => idle. *)
      tool#on_release ctx 160.0 135.0 ~shift:false ~alt:false;
      assert (read_hand_mode tool = "idle"));
]

(* -- Zoom -------------------------------------------------------- *)

let zoom_tests = [
  Alcotest.test_case "plain_click_zooms_in_by_zoom_step" `Quick (fun () ->
    match zoom_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      let step = bundle_zoom_step () in
      (* Sanity: the bundle ships the documented 1.2 step. *)
      assert (approx step 1.2 1e-9);
      (* Plain CLICK: press + release at the SAME screen point, no
         intervening move => moved stays false => the not-moved branch
         dispatches zoom_in anchored at the click.
           z_new   = 1.0 * 1.2 = 1.2
           anchor  = (200, 150) (screen); doc_a = (200, 150) at identity
           off_new = anchor - doc_a*z_new = 200 - 200*1.2 = -40
                                            150 - 150*1.2 = -30 *)
      tool#on_press ctx 200.0 150.0 ~shift:false ~alt:false;
      tool#on_release ctx 200.0 150.0 ~shift:false ~alt:false;
      let expected_zoom = 1.0 *. step in
      assert (approx m#zoom_level expected_zoom 1e-9);
      assert (approx m#view_offset_x (-40.0) 1e-9);
      assert (approx m#view_offset_y (-30.0) 1e-9);
      (* The clicked SCREEN point maps to the SAME doc point before and
         after the zoom — the invariant the recenter exists to keep. *)
      let doc_before = (200.0 -. 0.0) /. 1.0 in
      let doc_after = (200.0 -. m#view_offset_x) /. m#zoom_level in
      assert (approx doc_after doc_before 1e-9);
      assert (doc_json m = before);
      assert (not m#can_undo));

  Alcotest.test_case "alt_click_zooms_out" `Quick (fun () ->
    match zoom_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      let step = bundle_zoom_step () in
      (* ALT-click (alt = the LAST labeled bool arg). alt_at_press latches
         true on mousedown, so the not-moved branch dispatches zoom_OUT
         with factor 1/step.
           z_new   = 1.0 * (1/1.2) = 0.833333...
           off_new = 200 - 200*z_new ; 150 - 150*z_new *)
      tool#on_press ctx 200.0 150.0 ~shift:false ~alt:true;
      tool#on_release ctx 200.0 150.0 ~shift:false ~alt:true;
      let expected_zoom = 1.0 /. step in
      assert (approx m#zoom_level expected_zoom 1e-9);
      assert (m#zoom_level < 1.0);
      let expected_off_x = 200.0 -. 200.0 *. expected_zoom in
      let expected_off_y = 150.0 -. 150.0 *. expected_zoom in
      assert (approx m#view_offset_x expected_off_x 1e-9);
      assert (approx m#view_offset_y expected_off_y 1e-9);
      (* Same screen->doc invariant under zoom-out. *)
      let doc_after = (200.0 -. m#view_offset_x) /. m#zoom_level in
      assert (approx doc_after 200.0 1e-9);
      assert (doc_json m = before);
      assert (not m#can_undo));

  Alcotest.test_case "escape_mid_scrubby_drag_restores_initial_view"
    `Quick (fun () ->
    match zoom_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      (* Non-identity starting view so the restore target is distinctive. *)
      m#set_zoom_level 2.0;
      m#set_view_offset_x 15.0;
      m#set_view_offset_y 25.0;
      let z0 = m#zoom_level in
      let off_x0 = m#view_offset_x in
      let off_y0 = m#view_offset_y in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      let mods : Canvas_tool.key_mods =
        { shift = false; ctrl = false; alt = false; meta = false } in
      (* Scrubby is on by default in the bundle, so a horizontal drag past
         the 4px threshold applies a continuous scrubby zoom on each move.
         Press captures the initial snapshot; the move (>4px in x) flips
         moved=true and writes a NEW zoom/offset. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_move ctx 180.0 100.0 ~shift:false ~alt:false ~dragging:true;
      (* Precondition: the scrubby move actually CHANGED the view. *)
      assert (Float.abs (m#zoom_level -. z0) > 1e-6);
      (* Escape mid-drag: zoom.yaml restores the pre-drag snapshot via
         doc.zoom.set_full and idles. *)
      ignore (tool#on_key_event ctx "Escape" mods);
      assert (approx m#zoom_level z0 1e-9);
      assert (approx m#view_offset_x off_x0 1e-9);
      assert (approx m#view_offset_y off_y0 1e-9);
      (* After Escape (mode idle) a further move must NOT re-zoom. *)
      tool#on_move ctx 300.0 100.0 ~shift:false ~alt:false ~dragging:true;
      assert (approx m#zoom_level z0 1e-9);
      assert (doc_json m = before);
      assert (not m#can_undo));

  Alcotest.test_case "subthreshold_drag_is_a_click" `Quick (fun () ->
    (* A press + tiny move (<=4px) + release is NOT a drag: moved stays
       false, so mouseup takes the click branch and zooms IN by zoom_step.
       Proves the 4px click-vs-drag threshold and that scrubby did NOT fire
       on the sub-threshold move. *)
    match zoom_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = viewport_model () in
      let (ctx, _) = make_ctx m in
      let step = bundle_zoom_step () in
      tool#on_press ctx 200.0 150.0 ~shift:false ~alt:false;
      (* 3px in x, 0 in y — both within the >4px gate, so moved stays false
         and no scrubby zoom is written on the move. *)
      tool#on_move ctx 203.0 150.0 ~shift:false ~alt:false ~dragging:true;
      assert (approx m#zoom_level 1.0 1e-9);
      tool#on_release ctx 203.0 150.0 ~shift:false ~alt:false;
      (* Release takes the click branch => zoom IN by step. Anchor is the
         RELEASE point (203,150): off_x = 203 - 203*1.2. *)
      assert (approx m#zoom_level step 1e-9);
      let expected_off_x = 203.0 -. 203.0 *. step in
      assert (approx m#view_offset_x expected_off_x 1e-9);
      assert (not m#can_undo));
]

let () =
  Alcotest.run "Yaml viewport tools" [
    "Hand", hand_tests;
    "Zoom", zoom_tests;
  ]
