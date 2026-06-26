(** Geometry-tool gesture-seam tests — OCaml port of the Rust geometry
    seam tests in jas_dioxus/src/tools/yaml_tool.rs (the rect_parity_*,
    ellipse_parity_*, rounded_rect_parity_*, polygon_parity_*, and
    star_parity_* families). ONE combined file covering all five
    shape-drawing tools. Structurally modeled on yaml_tool_line_test.ml:
    same seam, same loader pattern, same empty-layer model, same
    first-layer children accessor.

    Each case loads the PRODUCTION tool from the workspace bundle
    (workspace/workspace.json) and drives on_press / on_move (dragging) /
    on_release. The identity canvas view means doc coordinates equal
    screen coordinates, so the press/move/release points double as both.

    These geometry tools read NO app-level state (no state.* lookups in
    their commit handlers), so unlike the blob-brush / paintbrush seam
    tests there is NO bridge_app_state / seed call here — with one
    deliberate exception: rect_parity_uses_model_defaults sets the Model
    active default fill and stroke directly, because the rect tool omits
    fill / stroke from its add_element spec and doc.add_element falls
    through to model.default_fill / model.default_stroke. That fall-through
    is exercised here without any bridge call.

    Seam mapping from Rust to OCaml:
      on_press     -> on_press ctx x y ~shift ~alt
      on_move(drag)-> on_move ctx x y ~shift ~alt ~dragging
      on_release   -> on_release ctx x y ~shift ~alt

    Element-type mapping (read from the Rust case bodies, mirrored 1:1):
      rect / rounded_rect -> Element.Rect (rounded_rect with rx/ry > 0)
      ellipse             -> Element.Ellipse (cx/cy center, rx/ry radii)
      polygon             -> Element.Polygon (5 points for the default
                             5-sided polygon)
      star                -> Element.Polygon (10 vertices: 5 outer
                             alternating with 5 inner) *)

open Jas

let () = ignore (GMain.init ())

(* Load a PRODUCTION tool by id from the workspace bundle. *)
let geometry_tool (tool_id : string) : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt tool_id tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

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

(* Drive a press-drag-release gesture: press at (px,py), drag to and
   release at (rx,ry). Mirrors the Rust press / move / release triple. *)
let drag (tool : Yaml_tool.yaml_tool) (ctx : Canvas_tool.tool_context)
    (px : float) (py : float) (rx : float) (ry : float) : unit =
  tool#on_press ctx px py ~shift:false ~alt:false;
  tool#on_move ctx rx ry ~shift:false ~alt:false ~dragging:true;
  tool#on_release ctx rx ry ~shift:false ~alt:false

(* Press then release at the SAME point (no drag): the zero-size /
   sub-threshold suppression path. *)
let click (tool : Yaml_tool.yaml_tool) (ctx : Canvas_tool.tool_context)
    (px : float) (py : float) : unit =
  tool#on_press ctx px py ~shift:false ~alt:false;
  tool#on_release ctx px py ~shift:false ~alt:false

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "geometry_tools_load_from_workspace" `Quick (fun () ->
    let check id =
      match geometry_tool id with
      | Some tool -> assert (tool#spec.id = id)
      | None -> Alcotest.skip ()
    in
    check "rect";
    check "ellipse";
    check "rounded_rect";
    check "polygon";
    check "star");
]

(* ── Rect ───────────────────────────────────────────── *)

let rect_tests = [
  (* press 10,20; move/release 110,70 -> ONE Rect x=10,y=20,w=100,h=50. *)
  Alcotest.test_case "rect_draw_rect" `Quick (fun () ->
    match geometry_tool "rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 10.0 20.0 110.0 70.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Rect r ->
         assert (r.x = 10.0);
         assert (r.y = 20.0);
         assert (r.width = 100.0);
         assert (r.height = 50.0)
       | _ -> assert false));

  (* press + release same point -> 0 children. *)
  Alcotest.test_case "rect_zero_size_rect_not_created" `Quick (fun () ->
    match geometry_tool "rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 10.0 20.0;
      assert (Array.length (layer0_children m) = 0));

  (* press 100,80; release 10,20 -> Rect normalized to 10,20,90,60. *)
  Alcotest.test_case "rect_negative_drag_normalizes" `Quick (fun () ->
    match geometry_tool "rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 100.0 80.0 10.0 20.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Rect r ->
         assert (r.x = 10.0);
         assert (r.y = 20.0);
         assert (r.width = 90.0);
         assert (r.height = 60.0)
       | _ -> assert false));

  (* The committed Rect picks up the Model active default fill / stroke,
     because rect.yaml omits fill / stroke from its add_element spec and
     doc.add_element falls through to model.default_fill /
     model.default_stroke. Mirrors the Rust rect_parity_uses_model_defaults
     case: red fill, blue 3pt stroke. *)
  Alcotest.test_case "rect_uses_model_defaults" `Quick (fun () ->
    match geometry_tool "rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let red = Element.color_rgb 1.0 0.0 0.0 in
      let blue = Element.color_rgb 0.0 0.0 1.0 in
      m#set_default_fill (Some (Element.make_fill red));
      m#set_default_stroke (Some (Element.make_stroke ~width:3.0 blue));
      let (ctx, _) = make_ctx m in
      drag tool ctx 10.0 20.0 110.0 70.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Rect r ->
         (match r.fill with
          | Some f -> assert (f.Element.fill_color = red)
          | None -> assert false);
         (match r.stroke with
          | Some s ->
            assert (s.Element.stroke_color = blue);
            assert (s.Element.stroke_width = 3.0)
          | None -> assert false)
       | _ -> assert false));
]

(* ── Ellipse ────────────────────────────────────────── *)

let ellipse_tests = [
  (* press 10,20; move/release 110,70 -> bbox 100x50; Ellipse cx=60,
     cy=45, rx=50, ry=25. *)
  Alcotest.test_case "ellipse_draw_ellipse" `Quick (fun () ->
    match geometry_tool "ellipse" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 10.0 20.0 110.0 70.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Ellipse e ->
         assert (e.cx = 60.0);
         assert (e.cy = 45.0);
         assert (e.rx = 50.0);
         assert (e.ry = 25.0)
       | _ -> assert false));

  Alcotest.test_case "ellipse_zero_size_not_created" `Quick (fun () ->
    match geometry_tool "ellipse" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 10.0 20.0;
      assert (Array.length (layer0_children m) = 0));

  (* press 100,80; release 10,20 -> positive rx/ry; cx=55, cy=50,
     rx=45, ry=30. *)
  Alcotest.test_case "ellipse_negative_drag_yields_positive_radii" `Quick
    (fun () ->
      match geometry_tool "ellipse" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = empty_layer_model () in
        let (ctx, _) = make_ctx m in
        drag tool ctx 100.0 80.0 10.0 20.0;
        let children = layer0_children m in
        assert (Array.length children = 1);
        (match children.(0) with
         | Element.Ellipse e ->
           assert (e.cx = 55.0);
           assert (e.cy = 50.0);
           assert (e.rx = 45.0);
           assert (e.ry = 30.0)
         | _ -> assert false));
]

(* ── Rounded rect ───────────────────────────────────── *)

let rounded_rect_tests = [
  (* press 10,20; move/release 110,70 -> Rect x=10,y=20,w=100,h=50 with
     rx=ry=10 (the rounded corner radius). *)
  Alcotest.test_case "rounded_rect_draw_with_radius" `Quick (fun () ->
    match geometry_tool "rounded_rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 10.0 20.0 110.0 70.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Rect r ->
         assert (r.x = 10.0);
         assert (r.y = 20.0);
         assert (r.width = 100.0);
         assert (r.height = 50.0);
         assert (r.rx = 10.0);
         assert (r.ry = 10.0)
       | _ -> assert false));

  Alcotest.test_case "rounded_rect_zero_size_not_created" `Quick (fun () ->
    match geometry_tool "rounded_rect" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 10.0 20.0;
      assert (Array.length (layer0_children m) = 0));

  (* press 100,80; release 10,20 -> Rect normalized to 10,20,90,60 with
     rx=10. *)
  Alcotest.test_case "rounded_rect_negative_drag_normalizes" `Quick
    (fun () ->
      match geometry_tool "rounded_rect" with
      | None -> Alcotest.skip ()
      | Some tool ->
        let m = empty_layer_model () in
        let (ctx, _) = make_ctx m in
        drag tool ctx 100.0 80.0 10.0 20.0;
        let children = layer0_children m in
        assert (Array.length children = 1);
        (match children.(0) with
         | Element.Rect r ->
           assert (r.x = 10.0);
           assert (r.y = 20.0);
           assert (r.width = 90.0);
           assert (r.height = 60.0);
           assert (r.rx = 10.0)
         | _ -> assert false));
]

(* ── Polygon ────────────────────────────────────────── *)

let polygon_tests = [
  (* press 50,50; move/release 100,50 -> ONE Polygon with 5 points
     (default 5-sided polygon). *)
  Alcotest.test_case "polygon_draw_polygon" `Quick (fun () ->
    match geometry_tool "polygon" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 50.0 50.0 100.0 50.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Polygon p -> assert (List.length p.points = 5)
       | _ -> assert false));

  (* press + release same point (sub-threshold drag) -> 0 children. *)
  Alcotest.test_case "polygon_short_drag_no_polygon" `Quick (fun () ->
    match geometry_tool "polygon" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 50.0 50.0;
      assert (Array.length (layer0_children m) = 0));
]

(* ── Star ───────────────────────────────────────────── *)

let star_tests = [
  (* press 10,20; move/release 110,120 -> ONE Polygon with 10 vertices
     (5 outer alternating with 5 inner). *)
  Alcotest.test_case "star_draw_star" `Quick (fun () ->
    match geometry_tool "star" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 10.0 20.0 110.0 120.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Polygon p -> assert (List.length p.points = 10)
       | _ -> assert false));

  Alcotest.test_case "star_zero_size_not_created" `Quick (fun () ->
    match geometry_tool "star" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 10.0 20.0;
      assert (Array.length (layer0_children m) = 0));

  (* press 100,100; move/release 0,0 -> Polygon normalized: 10 vertices,
     first outer vertex at top-center of the normalized bbox
     (center.x = 50, top.y = 0). *)
  Alcotest.test_case "star_negative_drag_normalizes" `Quick (fun () ->
    match geometry_tool "star" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      drag tool ctx 100.0 100.0 0.0 0.0;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Polygon p ->
         assert (List.length p.points = 10);
         let (x0, y0) = List.nth p.points 0 in
         assert (Float.abs (x0 -. 50.0) < 1e-9);
         assert (Float.abs (y0 -. 0.0) < 1e-9)
       | _ -> assert false));
]

let () =
  Alcotest.run "Yaml geometry tools" [
    "Tool load", load_tests;
    "Rect", rect_tests;
    "Ellipse", ellipse_tests;
    "Rounded rect", rounded_rect_tests;
    "Polygon", polygon_tests;
    "Star", star_tests;
  ]
