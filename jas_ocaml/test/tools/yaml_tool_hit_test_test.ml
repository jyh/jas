(** Magic Wand + Eyedropper gesture-seam tests — OCaml port of the Rust
    seam tests in jas_dioxus/src/tools/yaml_tool.rs (the
    magic_wand_parity_* and eyedropper_parity_* families). Drives the
    PRODUCTION magic_wand / eyedropper tools loaded from the workspace
    bundle through on_press / on_release and asserts the live selection
    paths and the sampled fill colour, matching the Rust reference numbers
    and tolerances exactly.

    Both tools fire on on_mousedown: each does hit_test(event.x, event.y)
    on the live registered document (the same headless path the selection
    tools use — the always-miss hit-test stubs in make_ctx are inert here),
    then dispatches doc.magic_wand.apply or doc.eyedropper.sample /
    apply_loaded. The seam runs the full pipeline (snapshot, hit-test,
    branch, effect) rather than calling the effect directly.

    Magic Wand config seeding. The wand commit reads the nine app-level
    state.magic_wand_* options. Those keys are bridged into the tool global
    namespace by the PRODUCTION bridge (bridge_app_state, the OCaml analog
    of the Rust sync_global_state) — and ONLY because the nine keys were
    added to bridged_state_keys (yaml_tool.ml) alongside this test. Before
    that fix the live wand always fell back to Magic_wand.default_config and
    SILENTLY IGNORED every Magic Wand Panel adjustment. The
    respects_bridged_nondefault_config case is the regression gate: it
    routes magic_wand_fill_color=false through bridge_app_state and proves
    it changes the wand result. Remove the keys from the allowlist and that
    case fails.

    Eyedropper needs no bridge seeding: the state.eyedropper_* toggles all
    default true and Eyedropper.default_config agrees, so the fill-copy
    path falls back to all-on and the cache write goes straight to the tool
    store. *)

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

let magic_wand_tool () = load_tool "magic_wand"
let eyedropper_tool () = load_tool "eyedropper"

(* ── Shared helpers ────────────────────────────────── *)

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

(** A 1pt black stroke, identical across every fixture rect. Mirrors the
    Rust Stroke::new(Color::BLACK, 1.0). *)
let black_stroke : Element.stroke = {
  stroke_color = Element.black;
  stroke_width = 1.0;
  stroke_linecap = Element.Butt;
  stroke_linejoin = Element.Miter;
  stroke_miter_limit = 4.0;
  stroke_align = Element.Center;
  stroke_dash_pattern = [];
  stroke_dash_align_anchors = false;
  stroke_start_arrow = Element.Arrow_none;
  stroke_end_arrow = Element.Arrow_none;
  stroke_start_arrow_scale = 1.0;
  stroke_end_arrow_scale = 1.0;
  stroke_arrow_align = Element.Tip_at_end;
  stroke_opacity = 1.0;
}

let make_rect ?fill (x : float) : Element.element =
  Element.Rect { name = None; id = None;
    x; y = 0.0; width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
    fill; stroke = Some black_stroke; opacity = 1.0;
    transform = None; locked = false; visibility = Element.Preview;
    blend_mode = Element.Normal; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let rect_fill = function
  | Element.Rect { fill; _ } -> fill
  | _ -> assert false

(** Selected element paths as a set, for order-independent assertions.
    Mirrors the Rust selection_paths. *)
let selection_paths (m : Model.model) : (int list) list =
  Document.PathMap.bindings m#document.selection
  |> List.map (fun (_, (es : Document.element_selection)) -> es.es_path)
  |> List.sort compare

(** Replace the selection with exactly [paths] (each whole-element),
    mirroring the Rust Controller::set_selection with ElementSelection::all. *)
let set_selection (ctrl : Controller.controller) (paths : int list list) : unit =
  let sel = List.fold_left (fun acc p ->
    Document.PathMap.add p (Document.element_selection_all p) acc
  ) Document.PathMap.empty paths in
  ctrl#set_selection sel

(* ── Magic Wand fixture ────────────────────────────── *)

(** Three rects in one layer — red @[0,0] (x=0), red @[0,1] (x=20),
    blue @[0,2] (x=40) — each 10x10 with an identical 1pt black stroke
    and opacity 1.0. Mirrors the Rust magic_wand_seam_model. *)
let magic_wand_seam_model () : Model.model =
  let red = Element.make_fill (Element.color_rgb 1.0 0.0 0.0) in
  let blue = Element.make_fill (Element.color_rgb 0.0 0.0 1.0) in
  let layer = Element.Layer {
    name = Some "L"; id = None;
    children = [|
      make_rect ~fill:red 0.0;
      make_rect ~fill:red 20.0;
      make_rect ~fill:blue 40.0;
    |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Element.Preview; blend_mode = Element.Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

(** The full default Magic Wand config as the workspace ships it, routed
    through the PRODUCTION bridge (bridge_app_state ~overrides, the OCaml
    analog of the Rust sync_global_state) so the tool store carries it
    exactly as the live canvas would. Mirrors the Rust
    seed_magic_wand_defaults. *)
let seed_magic_wand_defaults (tool : Yaml_tool.yaml_tool)
    (model : Model.model) : unit =
  tool#bridge_app_state ~overrides:[
    ("magic_wand_fill_color", `Bool true);
    ("magic_wand_fill_tolerance", `Int 32);
    ("magic_wand_stroke_color", `Bool true);
    ("magic_wand_stroke_tolerance", `Int 32);
    ("magic_wand_stroke_weight", `Bool true);
    ("magic_wand_stroke_weight_tolerance", `Float 5.0);
    ("magic_wand_opacity", `Bool true);
    ("magic_wand_opacity_tolerance", `Int 5);
    ("magic_wand_blending_mode", `Bool false);
  ] model

(* ── Magic Wand tests ──────────────────────────────── *)

let magic_wand_tests = [
  Alcotest.test_case "click_red_selects_both_reds_not_blue" `Quick (fun () ->
    match magic_wand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = magic_wand_seam_model () in
      let (ctx, _) = make_ctx m in
      seed_magic_wand_defaults tool m;
      (* Plain click on the first red rect at screen (5,5) -> replace. *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      let paths = selection_paths m in
      assert (List.mem [0; 0] paths);
      assert (List.mem [0; 1] paths);
      assert (not (List.mem [0; 2] paths));
      assert (List.length paths = 2));

  Alcotest.test_case "click_blue_selects_only_blue" `Quick (fun () ->
    match magic_wand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = magic_wand_seam_model () in
      let (ctx, _) = make_ctx m in
      seed_magic_wand_defaults tool m;
      (* Plain click on the blue rect at screen (45,5) -> replace. *)
      tool#on_press ctx 45.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 45.0 5.0 ~shift:false ~alt:false;
      assert (selection_paths m = [[0; 2]]));

  Alcotest.test_case "shift_click_unions_alt_click_subtracts" `Quick (fun () ->
    match magic_wand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = magic_wand_seam_model () in
      let (ctx, ctrl) = make_ctx m in
      seed_magic_wand_defaults tool m;
      (* Pre-select the blue rect [0,2]. *)
      set_selection ctrl [[0; 2]];
      (* Shift+click red [0,0] -> ADD: {2} union {0,1} = {0,1,2}. *)
      tool#on_press ctx 5.0 5.0 ~shift:true ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:true ~alt:false;
      assert (selection_paths m = [[0; 0]; [0; 1]; [0; 2]]);
      (* Alt+click red [0,0] -> SUBTRACT the wand result {0,1}: leaves {2}. *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:true;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:true;
      assert (selection_paths m = [[0; 2]]));

  Alcotest.test_case "click_empty_clears_selection" `Quick (fun () ->
    match magic_wand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = magic_wand_seam_model () in
      let (ctx, ctrl) = make_ctx m in
      seed_magic_wand_defaults tool m;
      (* Start with a non-empty selection. *)
      set_selection ctrl [[0; 1]];
      assert (not (Document.PathMap.is_empty m#document.selection));
      (* Plain click on empty canvas (100,100) -> selection cleared. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_release ctx 100.0 100.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty m#document.selection));

  Alcotest.test_case "respects_bridged_nondefault_config" `Quick (fun () ->
    (* REGRESSION GATE for the live state-bridge fix. With Fill Color
       turned OFF and only stroke / weight / opacity matching the seed, the
       blue rect — which has the SAME 1pt black stroke and opacity as the
       reds — now also matches, so a click on a red selects ALL THREE rects.
       This non-default config reaches the tool only via bridge_app_state,
       and only because magic_wand_* is now in bridged_state_keys. Remove
       the keys from the allowlist and the config falls back to
       Magic_wand.default_config (Fill ON) -> the blue stops matching ->
       this assertion fails. That is the bridge proof. *)
    match magic_wand_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = magic_wand_seam_model () in
      let (ctx, _) = make_ctx m in
      tool#bridge_app_state ~overrides:[
        ("magic_wand_fill_color", `Bool false);
        ("magic_wand_fill_tolerance", `Int 32);
        ("magic_wand_stroke_color", `Bool true);
        ("magic_wand_stroke_tolerance", `Int 32);
        ("magic_wand_stroke_weight", `Bool true);
        ("magic_wand_stroke_weight_tolerance", `Float 5.0);
        ("magic_wand_opacity", `Bool true);
        ("magic_wand_opacity_tolerance", `Int 5);
        ("magic_wand_blending_mode", `Bool false);
      ] m;
      (* Click red [0,0]. Fill is ignored, stroke + weight + opacity are
         identical across all three rects -> all three match. *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      assert (selection_paths m = [[0; 0]; [0; 1]; [0; 2]]));
]

(* ── Eyedropper fixture ────────────────────────────── *)

(** The exact green the eyedropper fixture source carries — a distinctive
    non-primary colour so the apply assertion cannot accidentally pass
    against a stray black / red default. Mirrors the Rust
    eyedropper_source_color rgb(0.0, 0.6, 0.2). *)
let eyedropper_source_color : Element.color =
  Element.color_rgb 0.0 0.6 0.2

(** Two rects in one layer: source [0,0] green-filled (x=0), target [0,1]
    fill-less (x=20). Both 10x10 at the identity view, so screen (5,5) hits
    the source and screen (25,5) hits the target. Mirrors the Rust
    eyedropper_seam_model. *)
let eyedropper_seam_model () : Model.model =
  let green = Element.make_fill eyedropper_source_color in
  let layer = Element.Layer {
    name = Some "L"; id = None;
    children = [|
      make_rect ~fill:green 0.0;
      make_rect 20.0;
    |];
    transform = None; locked = false; opacity = 1.0;
    visibility = Element.Preview; blend_mode = Element.Normal; mask = None;
    isolated_blending = false; knockout_group = false;
  } in
  let m = Model.create () in
  m#set_document_unbracketed (Document.make_document [| layer |]);
  m

(** Assert two colours are equal channel-for-channel in RGBA, mirroring
    the exact-equality Rust assert on fill.color. *)
let assert_color_eq (expected : Element.color) (actual : Element.color)
    (msg : string) : unit =
  let (er, eg, eb, ea) = Element.color_to_rgba expected in
  let (ar, ag, ab, aa) = Element.color_to_rgba actual in
  if not (er = ar && eg = ag && eb = ab && ea = aa) then begin
    Printf.eprintf "%s: expected (%f,%f,%f,%f) got (%f,%f,%f,%f)\n%!"
      msg er eg eb ea ar ag ab aa;
    assert false
  end

(* ── Eyedropper tests ──────────────────────────────── *)

let eyedropper_tests = [
  Alcotest.test_case "click_source_with_selection_copies_fill_to_target"
    `Quick (fun () ->
    match eyedropper_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = eyedropper_seam_model () in
      let (ctx, ctrl) = make_ctx m in
      (* Pre-select the empty target [0,1]; the source [0,0] is clicked. *)
      set_selection ctrl [[0; 1]];
      assert (rect_fill (Document.get_element m#document [0; 1]) = None);
      (* Plain click on the green source at screen (5,5) -> sample, which
         (selection non-empty) also writes the appearance to [0,1]. *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      (match rect_fill (Document.get_element m#document [0; 1]) with
       | None -> assert false
       | Some f ->
         assert_color_eq eyedropper_source_color f.fill_color
           "eyedropper sample must copy the exact source green into target"));

  Alcotest.test_case "alt_click_applies_cached_color_to_target"
    `Quick (fun () ->
    match eyedropper_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = eyedropper_seam_model () in
      let (ctx, _) = make_ctx m in
      (* First, plain-click the source with NO selection -> loads the cache
         (and mutates nothing, since the selection is empty). *)
      tool#on_press ctx 5.0 5.0 ~shift:false ~alt:false;
      tool#on_release ctx 5.0 5.0 ~shift:false ~alt:false;
      assert (rect_fill (Document.get_element m#document [0; 1]) = None);
      (* Now Alt+click the empty target [0,1] at screen (25,5) ->
         apply_loaded writes the cached green into the target. *)
      tool#on_press ctx 25.0 5.0 ~shift:false ~alt:true;
      tool#on_release ctx 25.0 5.0 ~shift:false ~alt:true;
      (match rect_fill (Document.get_element m#document [0; 1]) with
       | None -> assert false
       | Some f ->
         assert_color_eq eyedropper_source_color f.fill_color
           "Alt+click must apply the cached green to the target"));

  Alcotest.test_case "click_empty_is_a_noop" `Quick (fun () ->
    match eyedropper_tool () with
    | None -> Alcotest.skip ()
    | Some tool ->
      let m = eyedropper_seam_model () in
      let (ctx, _) = make_ctx m in
      (* Snapshot the document layers before the gesture for an exact
         no-op proof. *)
      let before = m#document.layers in
      (* Plain click on empty canvas (100,100) -> no hit -> no-op. *)
      tool#on_press ctx 100.0 100.0 ~shift:false ~alt:false;
      tool#on_release ctx 100.0 100.0 ~shift:false ~alt:false;
      assert (m#document.layers = before);
      (* The source fill is untouched; the target is still fill-less. *)
      (match rect_fill (Document.get_element m#document [0; 0]) with
       | Some f -> assert_color_eq eyedropper_source_color f.fill_color
                     "source fill untouched after empty-space click"
       | None -> assert false);
      assert (rect_fill (Document.get_element m#document [0; 1]) = None));
]

let () =
  Alcotest.run "Yaml hit-test tools" [
    "Magic Wand", magic_wand_tests;
    "Eyedropper", eyedropper_tests;
  ]
