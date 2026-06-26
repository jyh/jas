(** Path-EDIT gesture-seam tests — OCaml port of the Rust path-edit
    seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
    path_eraser_parity_* and smooth_parity_* families). ONE combined
    file covering TWO path-editing tools: path_eraser and smooth.
    Structurally modeled on yaml_tool_anchor_test.ml: same seam, same
    loader pattern, same first-layer children accessor — but the model
    here is seeded with an existing Path child (these are EDIT tools,
    not draw tools).

    Each case loads the PRODUCTION tool from the workspace bundle
    (workspace/workspace.json) and drives on_press / on_release. The
    identity canvas view means doc coordinates equal screen coordinates,
    so the press / release points double as both.

    The path_eraser tool reads NO app-level state (its handler scans the
    document directly for the nearest path under the cursor). The smooth
    tool reads the document SELECTION (it only simplifies paths that are
    selected), so the zigzag fixture is seeded WITH a selection on the
    path at tree path [0; 0]. There is NO bridge / seed call here — only
    an existing Path (plus, for smooth, a selection) in the document.

    Seam mapping from Rust to OCaml:
      on_press   -> on_press ctx x y ~shift ~alt   (dispatches on_mousedown)
      on_release -> on_release ctx x y ~shift ~alt (dispatches on_mouseup)
      model.can_undo() -> m#can_undo
      children.len() -> Array.length (layer0_children m)
      pe.d.len() -> List.length (layer0_path0_d m)

    Path / PathCommand mapping (read 1:1 from the Rust fixtures):
      PathCommand::MoveTo { x, y } -> Element.MoveTo (x, y)
      PathCommand::LineTo { x, y } -> Element.LineTo (x, y)
    The fill=None of the Rust PathElem fixtures is the default of
    Element.make_path. *)

open Jas

let () = ignore (GMain.init ())

(* Load a PRODUCTION tool by id from the workspace bundle. *)
let path_edit_tool (tool_id : string) : Yaml_tool.yaml_tool option =
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
   commands, optionally with a selection on that path (tree path
   [0; 0]). Mirrors the Rust fixtures: one Path, selected_layer 0. *)
let model_with_path ?(selected = false) (d : Element.path_command list)
    : Model.model =
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
  let document =
    if selected then
      let selection =
        Document.PathMap.singleton [0; 0]
          (Document.element_selection_all [0; 0])
      in
      Document.make_document ~selection [| layer |]
    else
      Document.make_document [| layer |]
  in
  m#set_document_unbracketed document;
  m

(* Rust model_with_long_line_path(): MoveTo(0,0), LineTo(100,0). No
   selection. *)
let model_with_long_line_path () : Model.model =
  model_with_path [
    Element.MoveTo (0.0, 0.0);
    Element.LineTo (100.0, 0.0);
  ]

(* Rust model_with_selected_zigzag_path(): MoveTo(0,0) followed by 20
   LineTos, x = i*5, y = +5 for even i / -5 for odd i (i = 1..=20).
   The path is SELECTED (selection on tree path [0; 0]). *)
let model_with_selected_zigzag_path () : Model.model =
  let cmds = ref [ Element.MoveTo (0.0, 0.0) ] in
  for i = 1 to 20 do
    let x = float_of_int i *. 5.0 in
    let y = if i mod 2 = 0 then 5.0 else -5.0 in
    cmds := Element.LineTo (x, y) :: !cmds
  done;
  model_with_path ~selected:true (List.rev !cmds)

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

(* Press then release at the SAME point (no drag): a click / dab. *)
let click (tool : Yaml_tool.yaml_tool) (ctx : Canvas_tool.tool_context)
    (px : float) (py : float) : unit =
  tool#on_press ctx px py ~shift:false ~alt:false;
  tool#on_release ctx px py ~shift:false ~alt:false

(* ── Loader sanity ─────────────────────────────────── *)

let load_tests = [
  Alcotest.test_case "path_edit_tools_load_from_workspace" `Quick (fun () ->
    let check id =
      match path_edit_tool id with
      | Some tool -> assert (tool#spec.id = id)
      | None -> Alcotest.skip ()
    in
    check "path_eraser";
    check "smooth");
]

(* ── Path Eraser ────────────────────────────────────── *)

let path_eraser_tests = [
  (* Rust path_eraser_parity_splits_open_path: press in the middle of
     the open line at (50,0) and release there -> the single line is
     split into TWO sub-paths (the layer goes from 1 child to 2 path
     children); undo available. *)
  Alcotest.test_case "path_eraser_splits_open_path" `Quick (fun () ->
    match path_edit_tool "path_eraser" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_long_line_path () in
      let (ctx, _) = make_ctx m in
      click tool ctx 50.0 0.0;
      let children = layer0_children m in
      assert (Array.length children = 2);
      assert m#can_undo);

  (* Rust path_eraser_parity_miss_does_nothing: press far from the line
     at (500,500) -> the path count is unchanged (still 1 child). *)
  Alcotest.test_case "path_eraser_miss_does_nothing" `Quick (fun () ->
    match path_edit_tool "path_eraser" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_long_line_path () in
      let (ctx, _) = make_ctx m in
      click tool ctx 500.0 500.0;
      let children = layer0_children m in
      assert (Array.length children = 1));
]

(* ── Smooth ─────────────────────────────────────────── *)

let smooth_tests = [
  (* Rust smooth_parity_reduces_commands_on_zigzag: with the zigzag path
     SELECTED, a smooth gesture at the midpoint (50,0) reduces the
     path's command count (fit-curve simplification); undo available. *)
  Alcotest.test_case "smooth_reduces_commands_on_zigzag" `Quick (fun () ->
    match path_edit_tool "smooth" with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_selected_zigzag_path () in
      let (ctx, _) = make_ctx m in
      let original_len = List.length (layer0_path0_d m) in
      click tool ctx 50.0 0.0;
      let new_len = List.length (layer0_path0_d m) in
      assert (new_len < original_len);
      assert m#can_undo);

  (* Rust smooth_parity_only_affects_selected_paths: with the SAME
     zigzag path but NO selection, the smooth gesture leaves the path
     untouched (command count unchanged). *)
  Alcotest.test_case "smooth_only_affects_selected_paths" `Quick (fun () ->
    match path_edit_tool "smooth" with
    | None -> Alcotest.skip ()
    | Some tool ->
      (* Same zigzag commands, but unselected. *)
      let m =
        let cmds = ref [ Element.MoveTo (0.0, 0.0) ] in
        for i = 1 to 20 do
          let x = float_of_int i *. 5.0 in
          let y = if i mod 2 = 0 then 5.0 else -5.0 in
          cmds := Element.LineTo (x, y) :: !cmds
        done;
        model_with_path (List.rev !cmds)
      in
      let (ctx, _) = make_ctx m in
      let original_len = List.length (layer0_path0_d m) in
      click tool ctx 50.0 0.0;
      let new_len = List.length (layer0_path0_d m) in
      assert (new_len = original_len));
]

let () =
  Alcotest.run "Yaml path-edit tools" [
    "Tool load", load_tests;
    "Path Eraser", path_eraser_tests;
    "Smooth", smooth_tests;
  ]
