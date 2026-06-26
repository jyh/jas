(** Anchor-EDIT gesture-seam tests — OCaml port of the Rust anchor-edit
    seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
    anchor_point_parity_*, add_anchor_parity_*, and
    delete_anchor_parity_* families). ONE combined file covering all
    THREE anchor-editing tools: anchor_point, add_anchor_point,
    delete_anchor_point. Structurally modeled on
    yaml_tool_geometry_test.ml / yaml_tool_line_test.ml: same seam, same
    loader pattern, same first-layer children accessor — but the model
    here is seeded with an existing Path child (these are EDIT tools, not
    draw tools).

    Each case loads the PRODUCTION tool from the workspace bundle
    (workspace/workspace.json) and drives on_press / on_release. The
    identity canvas view means doc coordinates equal screen coordinates,
    so the press / release points double as both.

    These anchor tools read NO app-level state (their handlers call
    doc.path.* effects that scan the document directly for the nearest
    path handle / anchor / segment), so there is NO bridge / seed call
    here — only an existing Path placed in the document.

    Seam mapping from Rust to OCaml:
      on_press   -> on_press ctx x y ~shift ~alt   (dispatches on_mousedown)
      on_release -> on_release ctx x y ~shift ~alt (dispatches on_mouseup)
      model.can_undo() -> m#can_undo
      is_smooth_point(&pe.d, i) -> Element.is_smooth_point d i

    Path / PathCommand mapping (read 1:1 from the Rust fixtures):
      PathCommand::MoveTo  { x, y }            -> Element.MoveTo (x, y)
      PathCommand::LineTo  { x, y }            -> Element.LineTo (x, y)
      PathCommand::CurveTo { x1,y1,x2,y2,x,y } -> Element.CurveTo
                                                  (x1,y1,x2,y2,x,y)
    The fill=None / stroke=None of the Rust PathElem fixtures is the
    default of Element.make_path. *)

open Jas

let () = ignore (GMain.init ())

(* Load a PRODUCTION tool by id from the workspace bundle. *)
let anchor_tool (tool_id : string) : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt tool_id tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

(* A document with a single layer holding ONE path with the given
   commands. Mirrors the Rust fixtures: one Path, no selection,
   selected_layer 0. *)
let model_with_path (d : Element.path_command list) : Model.model =
  let path = Element.make_path d in
  let layer = Element.Layer {
    name = Some "L";
    id = None;
    children = [| path |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

(* Rust model_with_smooth_three_anchor_path(): MoveTo(0,0),
   CurveTo(10,20, 40,20, 50,0), CurveTo(60,-20, 90,-20, 100,0). *)
let model_with_smooth_three_anchor_path () : Model.model =
  model_with_path [
    Element.MoveTo (0.0, 0.0);
    Element.CurveTo (10.0, 20.0, 40.0, 20.0, 50.0, 0.0);
    Element.CurveTo (60.0, -20.0, 90.0, -20.0, 100.0, 0.0);
  ]

(* Rust model_with_four_anchor_path(): MoveTo(0,0) + 3 flat CurveTos,
   anchors at x = 0, 30, 60, 90. *)
let model_with_four_anchor_path () : Model.model =
  model_with_path [
    Element.MoveTo (0.0, 0.0);
    Element.CurveTo (10.0, 0.0, 20.0, 0.0, 30.0, 0.0);
    Element.CurveTo (40.0, 0.0, 50.0, 0.0, 60.0, 0.0);
    Element.CurveTo (70.0, 0.0, 80.0, 0.0, 90.0, 0.0);
  ]

(* Rust model_with_horizontal_line_path(): MoveTo(0,0), LineTo(100,0). *)
let model_with_horizontal_line_path () : Model.model =
  model_with_path [
    Element.MoveTo (0.0, 0.0);
    Element.LineTo (100.0, 0.0);
  ]

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

(* Children of the first layer. *)
let layer0_children (m : Model.model) : Element.element array =
  match m#document.layers.(0) with
  | Element.Layer { children; _ } -> children
  | _ -> [||]

(* The path commands of the first path child of the first layer. *)
let layer0_path0_d (m : Model.model) : Element.path_command list =
  match (layer0_children m).(0) with
  | Element.Path { d; _ } -> d
  | _ -> assert false

(* Press then release at the SAME point (no drag): a click. *)
let click (tool : Yaml_tool.yaml_tool) (ctx : Canvas_tool.tool_context)
    (px : float) (py : float) : unit =
  tool#on_press ctx px py ~shift:false ~alt:false;
  tool#on_release ctx px py ~shift:false ~alt:false

(* Press at (px,py), release at (rx,ry): a drag. *)
let press_release (tool : Yaml_tool.yaml_tool)
    (ctx : Canvas_tool.tool_context)
    (px : float) (py : float) (rx : float) (ry : float) : unit =
  tool#on_press ctx px py ~shift:false ~alt:false;
  tool#on_release ctx rx ry ~shift:false ~alt:false

let approx a b = Float.abs (a -. b) < 0.01

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "anchor_tools_load_from_workspace" `Quick (fun () ->
    let check id =
      match anchor_tool id with
      | Some tool -> assert (tool#spec.id = id)
      | None -> Alcotest.skip ()
    in
    check "anchor_point";
    check "add_anchor_point";
    check "delete_anchor_point");
]

(* ── Anchor Point (convert) ─────────────────────────── *)

let anchor_point_tests = [
  (* Rust anchor_point_parity_click_smooth_makes_corner: click the
     smooth anchor at (50,0) -> anchor 1 becomes a corner
     (is_smooth_point false); undo available. *)
  Alcotest.test_case "anchor_point_click_smooth_makes_corner" `Quick
    (fun () ->
      match anchor_tool "anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_smooth_three_anchor_path () in
        let (ctx, _) = make_ctx m in
        click tool ctx 50.0 0.0;
        let d = layer0_path0_d m in
        assert (not (Element.is_smooth_point d 1));
        assert m#can_undo);

  (* Rust anchor_point_parity_drag_handle_moves_it: press the OUT-handle
     of anchor 1 at (60,-20), release at (70,-15) -> that CurveTo handle
     (x1 of cmd[2]) moves to (70,-15); the OTHER handle (x2 of cmd[1])
     stays at (40,20) — independent. *)
  Alcotest.test_case "anchor_point_drag_handle_moves_it" `Quick (fun () ->
    match anchor_tool "anchor_point" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_smooth_three_anchor_path () in
      let (ctx, _) = make_ctx m in
      press_release tool ctx 60.0 (-20.0) 70.0 (-15.0);
      let d = layer0_path0_d m in
      (match List.nth d 2 with
       | Element.CurveTo (x1, y1, _, _, _, _) ->
         assert (approx x1 70.0);
         assert (approx y1 (-15.0))
       | _ -> assert false);
      (match List.nth d 1 with
       | Element.CurveTo (_, _, x2, y2, _, _) ->
         assert (approx x2 40.0);
         assert (approx y2 20.0)
       | _ -> assert false));

  (* Rust anchor_point_parity_drag_corner_pulls_out_smooth_handles: a
     corner-only path (all LineTos); drag anchor 1 from (50,0) to
     (50,30) -> anchor 1 becomes smooth (handles pulled out). *)
  Alcotest.test_case "anchor_point_drag_corner_pulls_out_smooth_handles"
    `Quick (fun () ->
      match anchor_tool "anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_path [
          Element.MoveTo (0.0, 0.0);
          Element.LineTo (50.0, 0.0);
          Element.LineTo (100.0, 0.0);
        ] in
        let (ctx, _) = make_ctx m in
        press_release tool ctx 50.0 0.0 50.0 30.0;
        let d = layer0_path0_d m in
        assert (Element.is_smooth_point d 1));

  (* Rust anchor_point_parity_click_without_hit_is_noop: click empty
     space -> nothing changes (no undo snapshot). *)
  Alcotest.test_case "anchor_point_click_without_hit_is_noop" `Quick
    (fun () ->
      match anchor_tool "anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_smooth_three_anchor_path () in
        let (ctx, _) = make_ctx m in
        click tool ctx 500.0 500.0;
        assert (not m#can_undo));
]

(* ── Add Anchor Point ───────────────────────────────── *)

let add_anchor_tests = [
  (* Rust add_anchor_parity_click_on_line_inserts_midpoint: click at
     (50,0), exactly on the line at t=0.5 -> 3 commands; cmd[1] is a
     LineTo at the midpoint (50,0); undo available. *)
  Alcotest.test_case "add_anchor_click_on_line_inserts_midpoint" `Quick
    (fun () ->
      match anchor_tool "add_anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_horizontal_line_path () in
        let (ctx, _) = make_ctx m in
        click tool ctx 50.0 0.0;
        let d = layer0_path0_d m in
        assert (List.length d = 3);
        (match List.nth d 1 with
         | Element.LineTo (x, y) ->
           assert (approx x 50.0);
           assert (approx y 0.0)
         | _ -> assert false);
        assert m#can_undo);

  (* Rust add_anchor_parity_click_far_from_path_is_noop: click far off
     the path -> unchanged (still 2 commands), no undo. *)
  Alcotest.test_case "add_anchor_click_far_from_path_is_noop" `Quick
    (fun () ->
      match anchor_tool "add_anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_horizontal_line_path () in
        let (ctx, _) = make_ctx m in
        click tool ctx 500.0 500.0;
        let d = layer0_path0_d m in
        assert (List.length d = 2);
        assert (not m#can_undo));

  (* Rust add_anchor_parity_click_on_curve_splits_it: a single cubic
     CurveTo(25,50, 75,50, 100,0) from (0,0); click at the t=0.5
     midpoint (50, 37.5) -> MoveTo + 2 CurveTos (split into halves);
     cmd[1] and cmd[2] are CurveTos, and cmd[1] endpoint is the
     midpoint. *)
  Alcotest.test_case "add_anchor_click_on_curve_splits_it" `Quick
    (fun () ->
      match anchor_tool "add_anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_path [
          Element.MoveTo (0.0, 0.0);
          Element.CurveTo (25.0, 50.0, 75.0, 50.0, 100.0, 0.0);
        ] in
        let (ctx, _) = make_ctx m in
        (* Cubic Bezier at t=0.5: x=50, y=37.5 (symmetric handles). *)
        let mid_x = 50.0 and mid_y = 37.5 in
        click tool ctx mid_x mid_y;
        let d = layer0_path0_d m in
        assert (List.length d = 3);
        (match List.nth d 1 with
         | Element.CurveTo (_, _, _, _, x, y) ->
           assert (Float.abs (x -. mid_x) < 0.1);
           assert (Float.abs (y -. mid_y) < 0.1)
         | _ -> assert false);
        (match List.nth d 2 with
         | Element.CurveTo _ -> ()
         | _ -> assert false));
]

(* ── Delete Anchor Point ────────────────────────────── *)

let delete_anchor_tests = [
  (* Rust delete_anchor_parity_click_on_interior_removes_anchor: a
     four-anchor path; click the anchor at (60,0) (command index 2) ->
     path still exists, goes from 4 anchors (commands) to 3; undo
     available. *)
  Alcotest.test_case "delete_anchor_click_on_interior_removes_anchor"
    `Quick (fun () ->
      match anchor_tool "delete_anchor_point" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = model_with_four_anchor_path () in
        let (ctx, _) = make_ctx m in
        click tool ctx 60.0 0.0;
        let children = layer0_children m in
        assert (Array.length children = 1);
        let d = layer0_path0_d m in
        assert (List.length d = 3);
        assert m#can_undo);

  (* Rust delete_anchor_parity_click_empty_is_noop: click empty space ->
     path unchanged (still 4 commands), no undo. *)
  Alcotest.test_case "delete_anchor_click_empty_is_noop" `Quick (fun () ->
    match anchor_tool "delete_anchor_point" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_four_anchor_path () in
      let (ctx, _) = make_ctx m in
      click tool ctx 500.0 500.0;
      let d = layer0_path0_d m in
      assert (List.length d = 4);
      assert (not m#can_undo));
]

let () =
  Alcotest.run "Yaml anchor-edit tools" [
    "Tool load", load_tests;
    "Anchor Point", anchor_point_tests;
    "Add Anchor Point", add_anchor_tests;
    "Delete Anchor Point", delete_anchor_tests;
  ]
