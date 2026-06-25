(** Pen-tool behavioral tests — OCaml port of the Rust pen seam tests
    in jas_dioxus/src/tools/yaml_tool.rs (the pen_parity_* family) and
    the Swift port in JasSwift/Tests/Tools/YamlToolPenTests.swift.

    These cover the externally-observable outcomes of the YAML-driven
    pen tool loaded from the workspace bundle: click-click-click creates
    a polyline, click-drag sets the out-handle, click-near-first closes,
    double-click commits open, and Escape either commits (anchors >= 2)
    or discards (anchors < 2).

    Seam mapping from Rust to OCaml:
      on_press        -> on_press ctx x y ~shift ~alt
      on_move(drag)   -> on_move ctx x y ~shift ~alt ~dragging
      on_release      -> on_release ctx x y ~shift ~alt
      on_double_click -> on_double_click ctx x y
      on_key_event    -> on_key_event ctx key mods

    Escape entry point. Rust distinguishes tool.on_key (the app shell
    Escape/Enter call path) from tool.on_key_event, and keeps a regression
    guard exercising on_key. In OCaml the canvas_tool method [on_key]
    takes an [int] keycode and the YamlTool does not handle Escape there;
    the string-based handler is [on_key_event]. The GTK canvas shell, in
    Canvas_subwindow.forward_key_event, builds a string key name and for a
    non-capturing tool routes Escape and Enter through
    [active_tool#on_key_event ctx k mods] (see the branch guarded by
    [captures_keyboard () || k = "Escape" || k = "Enter"]). So the OCaml
    shell Escape path for a non-capturing tool like the pen collapses onto
    [on_key_event], exactly as in Swift. pen_parity_escape_via_shell_key_path
    therefore drives the exact entry the canvas dispatches, which is the
    equivalent regression guard. *)

open Jas

let () = ignore (GMain.init ())

let pen_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "pen" tools with
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

let no_mods : Canvas_tool.key_mods =
  { shift = false; ctrl = false; alt = false; meta = false }

(** A single pen click: press + release at the same point, no modifiers. *)
let click (tool : Yaml_tool.yaml_tool) ctx x y =
  tool#on_press ctx x y ~shift:false ~alt:false;
  tool#on_release ctx x y ~shift:false ~alt:false

(** Children of the first layer. *)
let layer0_children (m : Model.model) : Element.element array =
  match m#document.layers.(0) with
  | Element.Layer { children; _ } -> children
  | _ -> [||]

(** The d command list of the committed path at layers[0].children[0]. *)
let committed_d (m : Model.model) : Element.path_command list =
  match (layer0_children m).(0) with
  | Element.Path { d; _ } -> d
  | _ -> assert false

let last lst = List.nth lst (List.length lst - 1)

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "pen_tool_loads_from_workspace" `Quick (fun () ->
    match pen_tool () with
    | Some tool ->
      assert (tool#spec.id = "pen")
    | None -> Alcotest.skip ());
]

(* ── Three clicks + double-click -> open polyline ───── *)

let polyline_tests = [
  Alcotest.test_case
    "three_clicks_then_double_click_creates_polyline" `Quick (fun () ->
    match pen_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* Click, click, click — each mouseup lands mode=placing and
         leaves the anchor in the buffer. Handles stay at anchor
         position (corner anchors). *)
      click tool ctx 10.0 10.0;
      click tool ctx 50.0 10.0;
      click tool ctx 50.0 50.0;
      (* Double-click (the second press pushed a fourth anchor; the
         dblclick handler pops it, leaving 3 anchors). *)
      click tool ctx 50.0 50.0;
      tool#on_double_click ctx 50.0 50.0;

      let children = layer0_children m in
      assert (Array.length children = 1);
      let d = committed_d m in
      (* MoveTo + 2 CurveTos (3 anchors -> 2 segments). No ClosePath
         because dblclick commits open. *)
      assert (List.length d = 3);
      (match List.nth d 0 with
       | Element.MoveTo (x, y) -> assert (x = 10.0 && y = 10.0)
       | _ -> assert false);
      (match List.nth d 1 with
       | Element.CurveTo _ -> ()
       | _ -> assert false);
      (match List.nth d 2 with
       | Element.CurveTo _ -> ()
       | _ -> assert false);
      (match last d with
       | Element.ClosePath -> assert false
       | _ -> ()));
]

(* ── Click-drag sets out-handle ─────────────────────── *)

let drag_handle_tests = [
  Alcotest.test_case "click_drag_sets_out_handle" `Quick (fun () ->
    match pen_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* First anchor: click + drag out to (60, 10). on_move sets the
         handle; the first anchor out = (60, 10), in mirrors to
         (-40, 10). *)
      tool#on_press ctx 10.0 10.0 ~shift:false ~alt:false;
      tool#on_move ctx 60.0 10.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 60.0 10.0 ~shift:false ~alt:false;
      (* Second anchor: plain click at (50, 50). *)
      click tool ctx 50.0 50.0;
      (* Escape commits open — exercising the on_keydown path too. *)
      let _ = tool#on_key_event ctx "Escape" no_mods in

      let children = layer0_children m in
      assert (Array.length children = 1);
      let d = committed_d m in
      (* d[0] = MoveTo(10,10); d[1] = CurveTo(prev_out=(60,10),
         curr_in=(50,50), curr=(50,50)) because the second anchor is a
         corner. *)
      assert (List.length d = 2);
      (match List.nth d 1 with
       | Element.CurveTo (x1, y1, _, _, x, y) ->
         assert (x1 = 60.0);
         assert (y1 = 10.0);
         assert (x = 50.0);
         assert (y = 50.0)
       | _ -> assert false));
]

(* ── Click near first anchor closes ─────────────────── *)

let close_tests = [
  Alcotest.test_case "click_near_first_closes" `Quick (fun () ->
    match pen_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* Three corner anchors. *)
      click tool ctx 10.0 10.0;
      click tool ctx 50.0 10.0;
      click tool ctx 50.0 50.0;
      (* Fourth click within 8 px of the first anchor (10, 10). *)
      click tool ctx 11.0 11.0;

      let children = layer0_children m in
      assert (Array.length children = 1);
      let d = committed_d m in
      (* Should end with ClosePath. *)
      (match last d with
       | Element.ClosePath -> ()
       | _ -> assert false));
]

(* ── Escape via the app shell key path ──────────────── *)

let escape_commit_tests = [
  Alcotest.test_case "escape_via_shell_key_path_commits" `Quick (fun () ->
    (* Regression guard for the canvas keyboard path. The Rust shell
       calls tool.on_key (NOT on_key_event); a YamlTool overriding only
       on_key_event would miss Escape (the dx-serve bug that surfaced
       this). The OCaml shell equivalent for a non-capturing tool is
       Canvas_subwindow.forward_key_event ->
       active_tool#on_key_event ctx "Escape" mods, which is exactly what
       we drive here. *)
    match pen_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      click tool ctx 10.0 10.0;
      click tool ctx 50.0 50.0;
      (* The shell actual Escape dispatch for a non-capturing tool. *)
      let _ = tool#on_key_event ctx "Escape" no_mods in

      let children = layer0_children m in
      assert (Array.length children = 1);
      let d = committed_d m in
      (match List.nth d 0 with
       | Element.MoveTo _ -> ()
       | _ -> assert false);
      (match last d with
       | Element.ClosePath -> assert false
       | _ -> ()));
]

(* ── Escape with a single anchor discards ───────────── *)

let escape_discard_tests = [
  Alcotest.test_case
    "escape_without_enough_anchors_discards" `Quick (fun () ->
    match pen_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = empty_layer_model () in
      let (ctx, _) = make_ctx m in
      (* One anchor — not enough to make a path. *)
      click tool ctx 10.0 10.0;
      let _ = tool#on_key_event ctx "Escape" no_mods in
      assert (Array.length (layer0_children m) = 0));
]

let () =
  Alcotest.run "Yaml pen tool" [
    "Tool load", load_tests;
    "Polyline", polyline_tests;
    "Click-drag handle", drag_handle_tests;
    "Close", close_tests;
    "Escape commit", escape_commit_tests;
    "Escape discard", escape_discard_tests;
  ]
