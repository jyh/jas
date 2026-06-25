(** Pencil-tool behavioral tests — OCaml port of the Rust pencil seam
    tests in jas_dioxus/src/tools/yaml_tool.rs (the pencil_parity_*
    family). Structurally modeled on yaml_tool_pen_test.ml: same seam,
    same loader pattern, same empty-layer model.

    These cover the externally-observable outcomes of the YAML-driven
    pencil tool loaded from the workspace bundle: a freehand drag commits
    one Path whose d is a MoveTo followed by CurveTos (fit_curve output),
    a click without drag still lands a degenerate Path, the committed
    Path carries a stroke and no fill, a release with no prior press is a
    no-op, and the path starts at the press point.

    Seam mapping from Rust to OCaml:
      on_press        -> on_press ctx x y ~shift ~alt
      on_move(drag)   -> on_move ctx x y ~shift ~alt ~dragging
      on_release      -> on_release ctx x y ~shift ~alt *)

open Jas

let () = ignore (GMain.init ())

let pencil_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "pencil" tools with
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

(** The committed path element at layers[0].children[0]. *)
let committed_path (m : Model.model) : Element.element =
  (layer0_children m).(0)

(** The d command list of the committed path. *)
let committed_d (m : Model.model) : Element.path_command list =
  match committed_path m with
  | Element.Path { d; _ } -> d
  | _ -> assert false

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "pencil_tool_loads_from_workspace" `Quick (fun () ->
    match pencil_tool () with
    | Some tool ->
      assert (tool#spec.id = "pencil")
    | None -> Alcotest.skip ());
]

(* ── Freehand drag -> MoveTo + CurveTos ─────────────── *)

let freehand_tests = [
  Alcotest.test_case "freehand_draw_creates_path" `Quick (fun () ->
    match pencil_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      for i = 1 to 20 do
        let x = float_of_int i *. 5.0 in
        let y = sin (float_of_int i *. 0.1) *. 20.0 in
        tool#on_move ctx x y ~shift:false ~alt:false ~dragging:true
      done;
      tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;

      let children = layer0_children m in
      assert (Array.length children = 1);
      let d = committed_d m in
      (* MoveTo + at least one CurveTo. *)
      assert (List.length d >= 2);
      (match List.nth d 0 with
       | Element.MoveTo _ -> ()
       | _ -> assert false);
      (* Every command after the leading MoveTo is a CurveTo. *)
      List.iteri (fun i cmd ->
        if i >= 1 then
          match cmd with
          | Element.CurveTo _ -> ()
          | _ -> assert false) d);
]

(* ── Click without drag -> degenerate path ──────────── *)

let degenerate_tests = [
  Alcotest.test_case "click_without_drag_creates_degenerate_path" `Quick
    (fun () ->
    match pencil_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* Press + release at the same point. on_release pushes the final
         point, giving the buffer 2 identical points. fit_curve returns
         1 degenerate segment, which still lands a Path. *)
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
      assert (Array.length (layer0_children m) = 1));
]

(* ── Committed path uses model defaults (stroke, no fill) ── *)

let defaults_tests = [
  Alcotest.test_case "path_uses_model_defaults" `Quick (fun () ->
    match pencil_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      tool#on_move ctx 50.0 50.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;

      assert (Array.length (layer0_children m) = 1);
      (match committed_path m with
       | Element.Path { stroke; fill; _ } ->
         (* Pencil path has a stroke and no fill. *)
         assert (stroke <> None);
         assert (fill = None)
       | _ -> assert false));
]

(* ── Release without press is a no-op ───────────────── *)

let noop_tests = [
  Alcotest.test_case "release_without_press_is_noop" `Quick (fun () ->
    match pencil_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
      assert (Array.length (layer0_children m) = 0));
]

(* ── Path starts at the press point ─────────────────── *)

let start_point_tests = [
  Alcotest.test_case "path_starts_at_press_point" `Quick (fun () ->
    match pencil_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 15.0 25.0 ~shift:false ~alt:false;
      tool#on_move ctx 50.0 50.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 100.0 0.0 ~shift:false ~alt:false;

      assert (Array.length (layer0_children m) = 1);
      let d = committed_d m in
      (match List.nth d 0 with
       | Element.MoveTo (x, y) ->
         assert (x = 15.0);
         assert (y = 25.0)
       | _ -> assert false));
]

let () =
  Alcotest.run "Yaml pencil tool" [
    "Tool load", load_tests;
    "Freehand draw", freehand_tests;
    "Degenerate click", degenerate_tests;
    "Defaults", defaults_tests;
    "Release no-op", noop_tests;
    "Start point", start_point_tests;
  ]
