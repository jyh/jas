(** Combined selection-VARIANT gesture-seam tests. Drives [Yaml_tool]
    with the partial_selection / lasso / interior_selection specs loaded
    from workspace/workspace.json and verifies behavior matches the
    Rust reference (jas_dioxus/src/tools/yaml_tool.rs). These are the
    harder selection variants: they hit-test the live document and (for
    partial_selection) run an alt-drag-copy preview state machine.

    Reuses the exact loader + model/ToolContext/hit-test setup from
    yaml_selection_tool_test.ml; only the cases are new. The probe
    builtins (doc.path.probe_partial_hit, hit_test_deep) read the
    registered document directly, so the always-miss hit-test stubs in
    [make_ctx] are inert for these tools. *)

open Jas

let () = ignore (GMain.init ())

(* ── Loaders ───────────────────────────────────────── *)

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

let partial_selection_tool () = load_tool "partial_selection"
let lasso_tool () = load_tool "lasso"
let interior_selection_tool () = load_tool "interior_selection"

(* ── Fixtures ──────────────────────────────────────── *)

let make_rect x y w h =
  Element.Rect { name = None; id = None;
    x; y; width = w; height = h; rx = 0.0; ry = 0.0;
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview;
    blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

(** Single layer with one rect at (x,y,w,h). Mirrors Rust
    [model_with_rect_at]. *)
let model_with_rect_at x y w h : Model.model =
  let layer = Element.Layer {
    name = Some "L";
    id = None;
    children = [| make_rect x y w h |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

(** Rect at (0,0,10,10). Control points:
    0 = (0,0)  1 = (10,0)  2 = (10,10)  3 = (0,10). Mirrors Rust
    [model_with_rect_element]. *)
let model_with_rect_element () : Model.model =
  model_with_rect_at 0.0 0.0 10.0 10.0

(** Single rect at (50,50,20,20). Mirrors Rust
    [selection_parity_model_for_lasso]. *)
let model_for_lasso () : Model.model =
  model_with_rect_at 50.0 50.0 20.0 20.0

(** Layer -> Group -> Rect at (50,50,20,20); the rect lives at path
    [0;0;0]. Mirrors Rust [model_with_rect_inside_group]. *)
let model_with_rect_inside_group () : Model.model =
  let rect = make_rect 50.0 50.0 20.0 20.0 in
  let group = Element.Group {
    name = None; id = None;
    children = [| rect |];
    opacity = 1.0; transform = None; locked = false;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let layer = Element.Layer {
    name = Some "L"; id = None;
    children = [| group |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

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

(** First-layer children of the model document. *)
let layer0_children (m : Model.model) : Element.element array =
  match m#document.layers.(0) with
  | Element.Layer { children; _ } -> children
  | _ -> assert false

let rect_xy = function
  | Element.Rect { x; y; _ } -> (x, y)
  | _ -> assert false

(* ── Partial Selection ─────────────────────────────── *)

let partial_tests = [
  Alcotest.test_case "click_on_cp_selects_it" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, _) = make_ctx m in
      (* Click on CP 0 at (0,0). *)
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_release ctx 0.0 0.0 ~shift:false ~alt:false;
      let sel = m#document.selection in
      assert (Document.PathMap.cardinal sel = 1);
      (match Document.PathMap.find_opt [0; 0] sel with
       | Some es -> assert (Document.selection_kind_contains es.es_kind 0)
       | None -> assert false));

  Alcotest.test_case "click_empty_starts_marquee" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, _) = make_ctx m in
      (* Click far from any CP -> marquee. *)
      tool#on_press ctx 500.0 500.0 ~shift:false ~alt:false;
      assert (tool#tool_state "mode" = `String "marquee");
      (* Release far away -> no hits -> empty selection. *)
      tool#on_release ctx 600.0 600.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));

  Alcotest.test_case "marquee_picks_control_points" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, _) = make_ctx m in
      (* Marquee covering all 4 CPs (at 0 or 10 in x and y). *)
      tool#on_press ctx (-. 5.0) (-. 5.0) ~shift:false ~alt:false;
      tool#on_move ctx 15.0 15.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 15.0 15.0 ~shift:false ~alt:false;
      let sel = m#document.selection in
      assert (Document.PathMap.cardinal sel = 1);
      assert (Document.PathMap.mem [0; 0] sel));

  Alcotest.test_case "at_press_alt_drag_copies_path" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, ctrl) = make_ctx m in
      (* Whole-element selection, then press on CP 0 with Alt, drag
         past threshold, release. Exactly one copy inserted. *)
      ctrl#select_element [0; 0];
      let n_before = Array.length (layer0_children m) in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:true;
      tool#on_move ctx 5.0 0.0 ~shift:false ~alt:true ~dragging:true;
      tool#on_move ctx 80.0 0.0 ~shift:false ~alt:true ~dragging:true;
      tool#on_release ctx 80.0 0.0 ~shift:false ~alt:true;
      let n_after = Array.length (layer0_children m) in
      assert (n_after = n_before + 1));

  Alcotest.test_case "mid_drag_alt_copies_path" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      let n_before = Array.length (layer0_children m) in
      (* Press WITHOUT alt, drag past threshold (mode -> moving,
         translate by 5), press alt mid-drag (preview: original snaps
         back, real copy created), release WITH alt held. *)
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 5.0 0.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 10.0 0.0 ~shift:false ~alt:true ~dragging:true;
      tool#on_move ctx 80.0 0.0 ~shift:false ~alt:true ~dragging:true;
      tool#on_release ctx 80.0 0.0 ~shift:false ~alt:true;
      let children = layer0_children m in
      assert (Array.length children = n_before + 1);
      (* Original at (0,0) — preview snapped it back. *)
      let (ox, oy) = rect_xy children.(0) in
      assert (ox = 0.0);
      assert (oy = 0.0);
      (* Copy at (80,0) — translated by (cursor - press). *)
      let (cx, cy) = rect_xy children.(1) in
      assert (cx = 80.0);
      assert (cy = 0.0));

  Alcotest.test_case "mid_drag_alt_preview_shows_real_copy" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      let n_before = Array.length (layer0_children m) in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 5.0 0.0 ~shift:false ~alt:false ~dragging:true;
      (* Alt pressed mid-drag — enter preview; doc holds original +
         real copy. *)
      tool#on_move ctx 30.0 0.0 ~shift:false ~alt:true ~dragging:true;
      let children = layer0_children m in
      assert (Array.length children = n_before + 1);
      let (ox, _) = rect_xy children.(0) in
      assert (ox = 0.0);
      let (cx, _) = rect_xy children.(1) in
      assert (cx = 30.0));

  Alcotest.test_case "mid_drag_alt_released_before_mouseup_no_copy" `Quick (fun () ->
    match partial_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_element () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      let n_before = Array.length (layer0_children m) in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 5.0 0.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 30.0 0.0 ~shift:false ~alt:true ~dragging:true;
      (* Alt released before mouseup — exit preview; original lands at
         cursor; NO copy. *)
      tool#on_move ctx 50.0 0.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 50.0 0.0 ~shift:false ~alt:false;
      let children = layer0_children m in
      assert (Array.length children = n_before);
      let (ox, oy) = rect_xy children.(0) in
      assert (ox = 50.0);
      assert (oy = 0.0));
]

(* ── Lasso ─────────────────────────────────────────── *)

let lasso_tests = [
  Alcotest.test_case "lasso_select" `Quick (fun () ->
    match lasso_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_for_lasso () in
      let (ctx, _) = make_ctx m in
      (* Polygon enclosing the rect at (50,50,20,20). *)
      tool#on_press ctx 40.0 40.0 ~shift:false ~alt:false;
      tool#on_move ctx 80.0 40.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 80.0 80.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 40.0 80.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 40.0 80.0 ~shift:false ~alt:false;
      assert (not (Document.PathMap.is_empty m#document.selection)));

  Alcotest.test_case "lasso_miss" `Quick (fun () ->
    match lasso_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_for_lasso () in
      let (ctx, _) = make_ctx m in
      (* Polygon nowhere near the rect. *)
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 10.0 0.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 10.0 10.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_move ctx 0.0 10.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 0.0 10.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));

  Alcotest.test_case "click_without_drag_clears" `Quick (fun () ->
    match lasso_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_for_lasso () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      assert (not (Document.PathMap.is_empty m#document.selection));
      (* Press + release at same point, no shift — buffer has 1 point,
         fewer than 3 -> clear-selection branch. *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));

  Alcotest.test_case "click_without_drag_shift_preserves" `Quick (fun () ->
    match lasso_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_for_lasso () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      (* Shift+click without drag — shift_held captured at press; the
         clear-selection branch is guarded by not shift_held. *)
      tool#on_press ctx 5.0 5.0 ~shift:true ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:true ~alt:false;
      assert (not (Document.PathMap.is_empty m#document.selection)));

  Alcotest.test_case "state_transitions" `Quick (fun () ->
    match lasso_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_for_lasso () in
      let (ctx, _) = make_ctx m in
      assert (tool#tool_state "mode" = `String "idle");
      tool#on_press ctx 10.0 10.0 ~shift:false ~alt:false;
      assert (tool#tool_state "mode" = `String "drawing");
      tool#on_release ctx 10.0 10.0 ~shift:false ~alt:false;
      assert (tool#tool_state "mode" = `String "idle"));
]

(* ── Interior Selection ────────────────────────────── *)

let interior_tests = [
  Alcotest.test_case "click_enters_group" `Quick (fun () ->
    match interior_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_inside_group () in
      let (ctx, _) = make_ctx m in
      (* Click inside the rect (layer[0]/group[0]/rect[0]). *)
      tool#on_press ctx 55.0 55.0 ~shift:false ~alt:false;
      tool#on_release ctx 55.0 55.0 ~shift:false ~alt:false;
      let sel = m#document.selection in
      assert (Document.PathMap.cardinal sel = 1);
      (* Interior selection picks the leaf inside the group, not the
         group itself. *)
      assert (Document.PathMap.mem [0; 0; 0] sel));

  Alcotest.test_case "marquee_selects_partial" `Quick (fun () ->
    match interior_selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_rect_inside_group () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 40.0 40.0 ~shift:false ~alt:false;
      tool#on_move ctx 80.0 80.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 80.0 80.0 ~shift:false ~alt:false;
      assert (not (Document.PathMap.is_empty m#document.selection)));
]

let () =
  Alcotest.run "Yaml selection variants" [
    "Partial Selection", partial_tests;
    "Lasso", lasso_tests;
    "Interior Selection", interior_tests;
  ]
