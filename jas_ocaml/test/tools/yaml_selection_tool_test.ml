(** Phase 6 of the OCaml YAML tool-runtime migration. End-to-end
    tests that drive [Yaml_tool] with the Selection spec loaded from
    workspace/workspace.json and verify behavior matches the native
    [Selection_tool]. "Prove the pattern works" gate before Phase 7
    per-tool migration. *)

open Jas

let () = ignore (GMain.init ())

let selection_tool () : Yaml_tool.yaml_tool option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.json_member "tools" ws.data with
    | Some (`Assoc tools) ->
      (match List.assoc_opt "selection" tools with
       | Some spec -> Yaml_tool.from_workspace_tool spec
       | None -> None)
    | _ -> None

let make_rect x y w h =
  Element.Rect {
    x; y; width = w; height = h; rx = 0.0; ry = 0.0;
    fill = None; stroke = None; opacity = 1.0;
    transform = None; locked = false; visibility = Preview;
    blend_mode = Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

(** Layer with two 10x10 rects at (0,0) and (50,50). *)
let two_rect_model () : Model.model =
  let layer = Element.Layer {
    name = "L";
    children = [| make_rect 0.0 0.0 10.0 10.0;
                  make_rect 50.0 50.0 10.0 10.0 |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Preview; blend_mode = Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document (Document.make_document [| layer |]);
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

(* ── Tool load ─────────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "selection_tool_loads_from_workspace" `Quick (fun () ->
    match selection_tool () with
    | Some tool ->
      assert (tool#spec.id = "selection");
      assert (tool#spec.cursor = Some "arrow");
      assert (tool#spec.shortcut = Some "V")
    | None -> Alcotest.skip ());
]

(* ── Click behaviors ───────────────────────────────── *)

let click_tests = [
  Alcotest.test_case "click_on_element_selects" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      assert (Document.PathMap.cardinal m#document.selection = 1);
      assert (Document.PathMap.mem [0; 0] m#document.selection));

  Alcotest.test_case "click_empty_space_clears" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, ctrl) = make_ctx m in
      ctrl#select_element [0; 0];
      tool#on_press ctx 200.0 200.0 ~shift:false ~alt:false;
      tool#on_release ctx 200.0 200.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));

  Alcotest.test_case "shift_click_toggles_selection" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      (* First shift-click adds. *)
      tool#on_press ctx 5.0 5.0 ~shift:true ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:true ~alt:false;
      assert (Document.PathMap.cardinal m#document.selection = 1);
      (* Second shift-click removes. *)
      tool#on_press ctx 5.0 5.0 ~shift:true ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:true ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));
]

(* ── Drag (translate) ──────────────────────────────── *)

let drag_tests = [
  Alcotest.test_case "drag_moves_selected_element" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_move ctx 15.0 15.0 ~shift:false ~dragging:true;
      tool#on_release ctx 15.0 15.0 ~shift:false ~alt:false;
      let child = match m#document.layers.(0) with
        | Element.Layer { children; _ } -> children.(0)
        | _ -> assert false in
      match child with
      | Element.Rect { x; y; _ } ->
        assert (x = 10.0);
        assert (y = 10.0)
      | _ -> assert false);
]

(* ── Marquee ───────────────────────────────────────── *)

let marquee_tests = [
  Alcotest.test_case "marquee_release_selects_elements" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      (* Start in empty space, drag over the first rect, release. *)
      tool#on_press ctx (-. 5.0) (-. 5.0) ~shift:false ~alt:false;
      tool#on_move ctx 12.0 12.0 ~shift:false ~dragging:true;
      tool#on_release ctx 12.0 12.0 ~shift:false ~alt:false;
      assert (Document.PathMap.mem [0; 0] m#document.selection));
]

(* ── Alt+drag (copy) ──────────────────────────────── *)

let alt_drag_tests = [
  Alcotest.test_case "alt_drag_copies_selection" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:true;
      tool#on_move ctx 100.0 100.0 ~shift:false ~dragging:true;
      tool#on_release ctx 100.0 100.0 ~shift:false ~alt:true;
      let children = match m#document.layers.(0) with
        | Element.Layer { children; _ } -> children
        | _ -> [||] in
      assert (Array.length children = 3));
]

(* ── Escape ───────────────────────────────────────── *)

let escape_tests = [
  Alcotest.test_case "escape_idles_state" `Quick (fun () ->
    match selection_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = two_rect_model () in
      let (ctx, _) = make_ctx m in
      tool#on_press ctx (-. 5.0) (-. 5.0) ~shift:false ~alt:false;
      assert (tool#tool_state "mode" = `String "marquee");
      let _ = tool#on_key_event ctx "Escape"
        { shift = false; ctrl = false; alt = false; meta = false } in
      assert (tool#tool_state "mode" = `String "idle"));
]

let () =
  Alcotest.run "Yaml selection tool" [
    "Tool load", load_tests;
    "Click", click_tests;
    "Drag", drag_tests;
    "Marquee", marquee_tests;
    "Alt+drag", alt_drag_tests;
    "Escape", escape_tests;
  ]
