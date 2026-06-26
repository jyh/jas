(** Artboard gesture-seam tests. Drives [Yaml_tool] with the artboard
    spec loaded from workspace/workspace.json and verifies behavior
    matches the Rust reference (jas_dioxus/src/tools/yaml_tool.rs,
    artboard_parity_* at d1b8c911).

    The Artboard tool is a state machine (artboard.yaml: idle /
    creating / moving_pending / moving / resizing /
    duplicating_pending / duplicating). It reads NO app-level state.*
    — every gesture decision comes from the cursor coords, modifiers,
    and the document artboard list — so no bridge seeding is required.

    It operates in SCREEN coords. With the default identity view (zoom
    1, offset 0) screen equals doc, so a press at screen (100,100)
    lands at doc (100,100). doc.artboard.probe_hit hit-tests against
    the document artboard list, which the controller exposes via
    [ctrl#document]; the YamlTool seam registers the document
    headlessly, so the probe resolves without any GUI.

    These tests DRIVE the tool through the CanvasTool press/move/
    release seam (NOT the effects directly) and assert against the
    document ARTBOARD LIST: model#document.artboards (each artboard
    has id / name / x / y / width / height — the fields asserted here
    are x / y / width / height and the list length).

    RESIZE COVERAGE NOTE: the resize gesture is NOT covered through the
    press-on-handle seam. The resize-handle branch of probe_hit only
    fires when artboards_panel_selection_ids holds exactly one id,
    which the headless seam cannot reach (the dispatch path carries no
    panel-selection namespace). So a real press on a corner cannot
    transition the machine to resizing here. The resize MATH is pinned
    directly by a separate effect test. Reported, not faked — mirrors
    the Rust reference, which skips resize the same way. *)

open Jas

let () = ignore (GMain.init ())

(* ── Loader ────────────────────────────────────────── *)

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

let artboard_tool () = load_tool "artboard"

(* ── Fixture ───────────────────────────────────────── *)

(** A document with exactly ONE artboard "A" at (0,0) 200x200 and no
    document elements (an empty layer). Mirrors the Rust
    [model_with_one_artboard]. [make_document] defaults to an empty
    artboard list, so passing exactly [A] keeps the count assertions
    unambiguous. Identity view, so screen coords equal doc coords. *)
let model_with_one_artboard () : Model.model =
  let a : Artboard.artboard = {
    (Artboard.default_with_id "A") with
    name = "Artboard A";
    x = 0.0; y = 0.0; width = 200.0; height = 200.0;
  } in
  let doc = Document.make_document
      ~artboards:[a] [| Element.make_layer [||] |] in
  let m = Model.create () in
  m#set_document_unbracketed doc;
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

(** The document artboard list. *)
let artboards (m : Model.model) : Artboard.artboard list =
  m#document.artboards

(** The single artboard with id "A" — its (x, y, w, h). Asserts it is
    present so a vanished artboard fails loudly rather than silently
    skipping. Mirrors the Rust [artboard_a_rect]. *)
let artboard_a_rect (m : Model.model) : float * float * float * float =
  match List.find_opt (fun (a : Artboard.artboard) -> a.id = "A")
          (artboards m) with
  | Some a -> (a.x, a.y, a.width, a.height)
  | None -> assert false

(** The first non-A artboard — the one created or duplicated by the
    gesture. Asserts present. *)
let artboard_non_a (m : Model.model) : Artboard.artboard =
  match List.find_opt (fun (a : Artboard.artboard) -> a.id <> "A")
          (artboards m) with
  | Some a -> a
  | None -> assert false

(* ── Cases ─────────────────────────────────────────── *)

let artboard_tests = [
  (* CREATE: press in EMPTY space clear of A, drag, release. *)
  Alcotest.test_case "drag_empty_space_creates_artboard" `Quick (fun () ->
    match artboard_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_one_artboard () in
      let (ctx, _) = make_ctx m in
      tool#activate ctx;
      assert (List.length (artboards m) = 1);
      (* Press at (300,300) — well clear of the 0..200 artboard — then
         drag to (450,420) past the 4 px threshold and release.
         create_commit builds the rect from press to release:
         x = min(300,450) = 300, y = min(300,420) = 300,
         w = |300-450| = 150, h = |300-420| = 120. *)
      tool#on_press ctx 300.0 300.0 ~shift:false ~alt:false;
      tool#on_move ctx 450.0 420.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 450.0 420.0 ~shift:false ~alt:false;
      (* Drag-to-create adds exactly one artboard. *)
      assert (List.length (artboards m) = 2);
      let created = artboard_non_a m in
      assert (created.x = 300.0);
      assert (created.y = 300.0);
      assert (created.width = 150.0);
      assert (created.height = 120.0);
      (* The pre-existing A is untouched. *)
      assert (artboard_a_rect m = (0.0, 0.0, 200.0, 200.0)));

  (* MOVE: press INSIDE A, drag by (+50,+30), release. *)
  Alcotest.test_case "drag_interior_moves_artboard" `Quick (fun () ->
    match artboard_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_one_artboard () in
      let (ctx, _) = make_ctx m in
      tool#activate ctx;
      (* Press inside A at (100,100) -> moving_pending. Drag by
         (+50,+30) to (150,130) past threshold -> moving + move_apply.
         Release -> move_commit. move_apply / move_commit fall back to
         hit_artboard_id when panel-selection is empty, so the
         single-artboard move works end-to-end through the seam. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_move ctx 150.0 130.0 ~shift:false ~alt:false ~dragging:true;
      tool#on_release ctx 150.0 130.0 ~shift:false ~alt:false;
      (* A move must not change the artboard count. *)
      assert (List.length (artboards m) = 1);
      (* A shifts by exactly the drag delta (+50,+30); size unchanged. *)
      assert (artboard_a_rect m = (50.0, 30.0, 200.0, 200.0)));

  (* DUPLICATE: ALT-press inside A, drag by (+60,+40), release. *)
  Alcotest.test_case "alt_drag_interior_duplicates_artboard" `Quick (fun () ->
    match artboard_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_one_artboard () in
      let (ctx, _) = make_ctx m in
      tool#activate ctx;
      assert (List.length (artboards m) = 1);
      (* ALT-press inside A at (100,100) -> duplicating_pending. Drag by
         (+60,+40) past threshold -> duplicate_init mints the copy at
         As position and retargets translate ops at it, then
         duplicate_apply / duplicate_commit translate the COPY. The
         source A stays put; the copy lands at A + delta. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:true;
      tool#on_move ctx 160.0 140.0 ~shift:false ~alt:true ~dragging:true;
      tool#on_release ctx 160.0 140.0 ~shift:false ~alt:true;
      (* Alt-drag duplicates: count grows by exactly one. *)
      assert (List.length (artboards m) = 2);
      (* Source A is unmoved. *)
      assert (artboard_a_rect m = (0.0, 0.0, 200.0, 200.0));
      (* The copy carries As size, shifted by the drag delta (+60,+40). *)
      let copy = artboard_non_a m in
      assert (copy.x = 60.0);
      assert (copy.y = 40.0);
      assert (copy.width = 200.0);
      assert (copy.height = 200.0));

  (* NO-OP: sub-threshold press+release (no drag). *)
  Alcotest.test_case "press_release_no_drag_is_a_noop" `Quick (fun () ->
    match artboard_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = model_with_one_artboard () in
      let (ctx, _) = make_ctx m in
      tool#activate ctx;
      (* Snapshot the artboard list before for an exact no-op proof. *)
      let before = artboards m in
      (* Press inside A then release with NO intervening move — a
         sub-threshold click. moved stays false, so on_mouseup
         mode-guarded commit arms never fire: no move, no create, no
         duplicate, no new artboard. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_release ctx 100.0 100.0 ~shift:false ~alt:false;
      assert (List.length (artboards m) = 1);
      (* List byte-identical. *)
      assert (artboards m = before);
      assert (artboard_a_rect m = (0.0, 0.0, 200.0, 200.0));
      (* Same for a press on EMPTY canvas with no drag — creating mode
         is latched but the sub-threshold mouseup commits nothing. *)
      let before_empty = artboards m in
      tool#on_press ctx 400.0 400.0 ~shift:false ~alt:false;
      tool#on_release ctx 400.0 400.0 ~shift:false ~alt:false;
      assert (artboards m = before_empty));
]

let () =
  Alcotest.run "Yaml artboard" [
    "Artboard", artboard_tests;
  ]
