(** Combined Rotate + Shear gesture-seam tests. Drives [Yaml_tool] with
    the rotate / shear specs loaded from workspace/workspace.json and
    verifies behavior matches the Rust reference in
    jas_dioxus/src/tools/yaml_tool.rs (the rotate_parity and shear_parity
    families).

    These transform tools BAKE their matrix into the element's
    common.transform field (via compose_matrix_over_paths), leaving the
    rect's LOCAL x/y/w/h untouched. So the load-bearing geometry check is
    [selection_transformed_bbox]: it takes the element LOCAL geometric
    bounds, maps the four corners through common.transform, and re-derives
    the axis-aligned box — exactly mirroring the Rust helper of the same
    name. Element.geometric_bounds alone (no transform) would be blind to
    the baked matrix.

    The reference point is a handler-written GLOBAL state key
    (state.transform_reference_point), set by a plain click; it is read
    back from the tool store via the test-only [read_global_state] accessor
    (mirrors the Rust read_ref_point reaching tool.store.eval_context).

    "Document unchanged" cases compare Test_json.document_to_test_json
    before vs after (mirrors the Rust doc_json). These tools read no
    app-level state.* beyond what their own handlers write, so no bridge
    seeding is needed. *)

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

let rotate_tool () = load_tool "rotate"
let shear_tool () = load_tool "shear"

(* ── Fixture ───────────────────────────────────────── *)

(** One-layer document with a single stroked NON-SQUARE 100x40 rect at
    doc (0,0), selected via element path [0;0]. The aspect ratio is the
    whole point: a 90deg rotation about the centre SWAPS the bbox dims
    (100x40 -> 40x100), a swap a square could never show. Mirrors the
    Rust [transform_nonsquare_model]. *)
let transform_nonsquare_model () : Model.model =
  let black = Element.make_color 0.0 0.0 0.0 in
  let rect = Element.Rect {
    name = None; id = None;
    x = 0.0; y = 0.0; width = 100.0; height = 40.0; rx = 0.0; ry = 0.0;
    fill = Some (Element.make_fill black);
    stroke = Some (Element.make_stroke ~width:1.0 black);
    opacity = 1.0;
    transform = None; locked = false; visibility = Preview;
    blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  } in
  let layer = Element.Layer {
    name = Some "L"; id = None;
    children = [| rect |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let selection =
    Document.PathMap.add [0; 0]
      (Document.element_selection_all [0; 0])
      Document.PathMap.empty
  in
  let doc = Document.make_document ~selection [| layer |] in
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

(* ── Helpers (ports of the Rust reference helpers) ─── *)

(** Axis-aligned bounding box of the element at [path], in DOCUMENT
    space, WITH its common.transform applied. Returns
    (min_x, min_y, width, height).

    Port of the Rust [selection_transformed_bbox]: the transform tools
    bake their matrix into common.transform, leaving the rect LOCAL
    x/y/w/h untouched — so the element local bounds alone are blind to a
    rotate/shear. We take the element LOCAL geometric bounds (NO stroke
    inflation), map its four corners through the transform, and re-derive
    the axis-aligned box. With an identity transform this is a no-op, so
    it also validates the click-only / sub-threshold / escape cases
    honestly (their bbox stays 100x40). *)
let selection_transformed_bbox (model : Model.model) (path : int list)
    : float * float * float * float =
  let elem = Document.get_element model#document path in
  let (lx, ly, lw, lh) = Element.geometric_bounds elem in
  let t = match Element.transform_of elem with
    | Some t -> t
    | None -> Element.identity_transform
  in
  let corners = [
    (lx, ly); (lx +. lw, ly); (lx +. lw, ly +. lh); (lx, ly +. lh);
  ] in
  let min_x = ref infinity and min_y = ref infinity in
  let max_x = ref neg_infinity and max_y = ref neg_infinity in
  List.iter (fun (cx, cy) ->
    let (tx, ty) = Element.apply_point t cx cy in
    if tx < !min_x then min_x := tx;
    if ty < !min_y then min_y := ty;
    if tx > !max_x then max_x := tx;
    if ty > !max_y then max_y := ty)
    corners;
  (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)

(** Canonical document JSON for the "unchanged?" comparison — the same
    canonicalization the cross-language byte-gate uses. Port of the Rust
    [doc_json]. *)
let doc_json (model : Model.model) : string =
  Test_json.document_to_test_json model#document

(** Read state.transform_reference_point back out of the tool own store
    as (rx, ry), or None if unset / malformed. Port of the Rust
    [read_ref_point]: the stored list elements may be int- or
    float-typed JSON, so coerce each via a number-or-fail match. *)
let read_ref_point (tool : Yaml_tool.yaml_tool) : (float * float) option =
  let num = function
    | `Float f -> Some f
    | `Int i -> Some (float_of_int i)
    | _ -> None
  in
  match tool#read_global_state "transform_reference_point" with
  | `List (a :: b :: _) ->
    (match num a, num b with
     | Some rx, Some ry -> Some (rx, ry)
     | _ -> None)
  | _ -> None

let approx a b tol = Float.abs (a -. b) < tol

(* ── Rotate ────────────────────────────────────────── *)

let rotate_tests = [
  Alcotest.test_case "click_only_sets_ref_and_does_not_transform" `Quick
    (fun () ->
    match rotate_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      (* Plain click at doc (10, 20): press+release at the SAME point, no
         move => moved stays false => the apply branch never runs, the
         else branch writes transform_reference_point. *)
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
      (* Pivot stored in the tool global state (handler-written, not
         bridged), readable as state.transform_reference_point. *)
      (match read_ref_point tool with
       | Some (rx, ry) ->
         assert (approx rx 10.0 1e-9 && approx ry 20.0 1e-9)
       | None -> assert false);
      (* Document byte-identical and nothing undoable. *)
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));

  Alcotest.test_case "drag_applies_90deg_and_swaps_bbox" `Quick (fun () ->
    match rotate_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      (* Seed the pivot at the selection CENTRE (50, 20) via a click-only
         gesture (the production path that writes it). *)
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      assert (not m#can_undo);
      (* Rotate drag for theta = +90deg about (50, 20):
           press  doc (150, 20)  -> atan2(0, 100)  = 0deg
           cursor doc (50, 120)  -> atan2(100, 0)  = 90deg
           theta = 90 - 0 = 90deg. Move is >2px => moved = true. *)
      tool#on_press ctx 150.0 20.0 ~shift:false ~alt:false;
      tool#on_move ctx 50.0 120.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 50.0 120.0 ~shift:false ~alt:false;
      (* A 90deg rotation about the centre SWAPS the bbox dims. *)
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 40.0 0.5 && approx h 100.0 0.5);
      assert m#can_undo);

  Alcotest.test_case "subthreshold_drag_does_not_transform" `Quick
    (fun () ->
    match rotate_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      (* Pre-seed a pivot so the only variable is the drag distance. *)
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      let before = doc_json m in
      (* Press, then a 1px move (<2px on both axes => moved stays false),
         then release. The apply branch must not run. *)
      tool#on_press ctx 150.0 20.0 ~shift:false ~alt:false;
      tool#on_move ctx 151.0 21.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 151.0 21.0 ~shift:false ~alt:false;
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));

  Alcotest.test_case "escape_mid_drag_suppresses_apply" `Quick (fun () ->
    match rotate_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      let before = doc_json m in
      let mods : Canvas_tool.key_mods =
        { shift = false; ctrl = false; alt = false; meta = false } in
      (* Begin the SAME 90deg drag proven to mutate in the apply case,
         but press Escape BEFORE releasing. Escape sets mode back to
         idle, so the subsequent mouseup mode == 'rotating' guard fails
         and the apply is suppressed. *)
      tool#on_press ctx 150.0 20.0 ~shift:false ~alt:false;
      tool#on_move ctx 50.0 120.0 ~shift:false ~alt:false ~dragging:true;
      ignore (tool#on_key_event ctx "Escape" mods);
      tool#on_release ctx 50.0 120.0 ~shift:false ~alt:false;
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));
]

(* ── Shear ─────────────────────────────────────────── *)

let shear_tests = [
  Alcotest.test_case "click_only_sets_ref_and_does_not_transform" `Quick
    (fun () ->
    match shear_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      let before = doc_json m in
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
      (match read_ref_point tool with
       | Some (rx, ry) ->
         assert (approx rx 10.0 1e-9 && approx ry 20.0 1e-9)
       | None -> assert false);
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));

  Alcotest.test_case "drag_applies_horizontal_shear_and_widens_bbox"
    `Quick (fun () ->
    match shear_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      (* Seed the pivot at the selection CENTRE (50, 20). *)
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      assert (not m#can_undo);
      (* Shift-constrained HORIZONTAL shear, k = 1 (angle = 45deg):
           press  doc (50, 60)  -> |press_y - ref_y| = 40
           cursor doc (90, 60)  -> dx = 40 (dominant-x), dy = 0
           k = dx / 40 = 1.0  =>  angle = atan(1) = 45deg.
         Shift is the FIRST labeled bool arg to the seam methods. *)
      tool#on_press ctx 50.0 60.0 ~shift:true ~alt:false;
      tool#on_move ctx 90.0 60.0 ~shift:true ~alt:false ~dragging:true;
      tool#on_release ctx 90.0 60.0 ~shift:true ~alt:false;
      (* Horizontal shear widens the bbox (100 + k*height = 140), keeps
         the height (40), and shifts the box LEFT (min_x = -20: the top
         edge slides left, the bottom edge slides right). *)
      let (min_x, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 140.0 0.5);
      assert (approx h 40.0 0.5);
      assert (approx min_x (-20.0) 0.5);
      assert m#can_undo);

  Alcotest.test_case "subthreshold_drag_does_not_transform" `Quick
    (fun () ->
    match shear_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      let before = doc_json m in
      (* 1px move on both axes (<2px => moved stays false). *)
      tool#on_press ctx 50.0 60.0 ~shift:true ~alt:false;
      tool#on_move ctx 51.0 61.0 ~shift:true ~alt:false ~dragging:true;
      tool#on_release ctx 51.0 61.0 ~shift:true ~alt:false;
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));

  Alcotest.test_case "escape_mid_drag_suppresses_apply" `Quick (fun () ->
    match shear_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = transform_nonsquare_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 50.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 50.0 20.0 ~shift:false ~alt:false;
      let before = doc_json m in
      let mods : Canvas_tool.key_mods =
        { shift = false; ctrl = false; alt = false; meta = false } in
      (* The SAME k=1 shear drag that case 2 proves mutates, but Escape
         before release suppresses the apply. *)
      tool#on_press ctx 50.0 60.0 ~shift:true ~alt:false;
      tool#on_move ctx 90.0 60.0 ~shift:true ~alt:false ~dragging:true;
      ignore (tool#on_key_event ctx "Escape" mods);
      tool#on_release ctx 90.0 60.0 ~shift:true ~alt:false;
      assert (doc_json m = before);
      assert (not m#can_undo);
      let (_, _, w, h) = selection_transformed_bbox m [0; 0] in
      assert (approx w 100.0 0.5 && approx h 40.0 0.5));
]

let () =
  Alcotest.run "Yaml transform tools" [
    "Rotate", rotate_tests;
    "Shear", shear_tests;
  ]
