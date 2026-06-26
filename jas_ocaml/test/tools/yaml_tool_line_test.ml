(** Line-tool gesture-seam tests — OCaml port of the Rust line seam
    tests in jas_dioxus/src/tools/yaml_tool.rs (the line_parity_*
    family). Structurally modeled on yaml_tool_blob_brush_test.ml:
    same seam, same loader pattern, same empty-layer model, same
    tool-state accessor for mode.

    These drive the PRODUCTION line tool loaded from the workspace
    bundle through on_press / on_move / on_release and assert the
    committed Element.Line.

    The line tool is simple: a press-drag-release commits a single
    Line whose endpoints are the press point (x1,y1) and the release
    point (x2,y2) in doc space; a drag shorter than 2pt (hypot) is
    rejected. It reads NO app-level state, so unlike the blob-brush
    seam tests there is NO bridge / seed call here.

    Seam mapping from Rust to OCaml:
      on_press     -> on_press ctx x y ~shift ~alt
      on_move(drag)-> on_move ctx x y ~shift ~alt ~dragging
      on_release   -> on_release ctx x y ~shift ~alt
      tool_state("mode") -> tool#tool_state "mode" (a Yojson string) *)

open Jas

let () = ignore (GMain.init ())

let line_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "line" tools with
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

(* The mode tool-state, as a plain string. *)
let mode (tool : Yaml_tool.yaml_tool) : string =
  match tool#tool_state "mode" with
  | `String s -> s
  | other -> Yojson.Safe.to_string other

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "line_tool_loads_from_workspace" `Quick (fun () ->
    match line_tool () with
    | Some tool ->
      assert (tool#spec.id = "line")
    | None -> Alcotest.skip ());
]

(* ── draw_line commits one Line with the press/release endpoints ── *)

let draw_line_tests = [
  Alcotest.test_case "draw_line" `Quick (fun () ->
    match line_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      tool#on_move ctx 30.0 40.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
      let children = layer0_children m in
      assert (Array.length children = 1);
      (match children.(0) with
       | Element.Line l ->
         assert (l.x1 = 10.0);
         assert (l.y1 = 20.0);
         assert (l.x2 = 50.0);
         assert (l.y2 = 60.0)
       | _ -> assert false));
]

(* ── short_line_not_created: zero-length drag commits nothing ── *)

let short_line_tests = [
  Alcotest.test_case "short_line_not_created" `Quick (fun () ->
    match line_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* Press and release at the same point — hypot distance = 0. *)
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      tool#on_release ctx 10.0 20.0 ~shift:false ~alt:false;
      assert (Array.length (layer0_children m) = 0));
]

(* ── idle_after_release: mode latches idle -> drawing -> idle ── *)

let idle_after_release_tests = [
  Alcotest.test_case "idle_after_release" `Quick (fun () ->
    match line_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      assert (mode tool = "idle");
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      assert (mode tool = "drawing");
      tool#on_release ctx 50.0 60.0 ~shift:false ~alt:false;
      assert (mode tool = "idle"));
]

(* ── move_without_press_is_noop: guarded by mode == drawing ── *)

let move_noop_tests = [
  Alcotest.test_case "move_without_press_is_noop" `Quick (fun () ->
    match line_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* on_mousemove's handler is guarded by mode == drawing; without a
         prior on_mousedown, mode stays idle and nothing happens. *)
      tool#on_move ctx 50.0 60.0 ~shift:false ~alt:false ~dragging:true;
      assert (mode tool = "idle");
      assert (Array.length (layer0_children m) = 0));
]

let () =
  Alcotest.run "Yaml line tool" [
    "Tool load", load_tests;
    "Draw line", draw_line_tests;
    "Short line not created", short_line_tests;
    "Idle after release", idle_after_release_tests;
    "Move without press noop", move_noop_tests;
  ]
