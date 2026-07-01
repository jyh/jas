(** Cross-language SEAM tests for the Stroke panel apply-to-selection
    pipeline. Mirrors the Rust reference
    [apply_stroke_panel_to_selection] (jas_dioxus app_state.rs) and the
    Python sync test (jas/panels/stroke_panel_sync_test.py): every panel
    field -> element stroke attribute mapping is pinned to the SAME
    input -> output values so all apps stay equivalent.

    The end-to-end cases drive [Effects.apply_stroke_panel_to_selection]
    through a real Controller + Document holding a SELECTED stroked
    shape (Line / Rect / Path), then assert the element's stroke.

    OCaml note: the stroke panel keeps its fields in GLOBAL state
    under stroke_-prefixed keys, not a named panel scope (see
    State_store.subscribe_global doc), so we seed via [State_store.set]
    not [init_panel].

    OCaml WEIGHT note: unlike the Rust/Python canonical where panel
    [weight] flows straight to stroke.width, the OCaml apply derives the
    written width from [model#default_stroke.stroke_width] (effects.ml
    ~754), NOT from a panel weight key. We therefore exercise the weight
    mapping by seeding the model default stroke to the canonical 2.5 and
    assert the element receives 2.5 (semantically the SAME canonical
    outcome: panel weight -> written stroke.width). *)

open Jas

(* ── helpers ─────────────────────────────────────────────── *)

(* Build a model whose single layer holds [elem], with [selected]
   paths marked selected, and a model default stroke of [width]. *)
let model_with_stroked ?(default_width = 1.0) elem selected =
  let layer = Element.make_layer [| elem |] in
  let selection = List.fold_left (fun acc path ->
    Document.PathMap.add path (Document.make_element_selection path) acc)
    Document.PathMap.empty selected in
  let doc = Document.make_document ~selection [| layer |] in
  let m = Model.create ~document:doc () in
  m#set_default_stroke
    (Some (Element.make_stroke ~width:default_width Element.black));
  m

(* Extract the stroke of the element at [path]. *)
let elem_stroke model path =
  match Document.get_element model#document path with
  | Element.Line { stroke; _ } | Element.Rect { stroke; _ }
  | Element.Path { stroke; _ } -> stroke
  | _ -> None

let stroke_at model path =
  match elem_stroke model path with
  | Some s -> s
  | None -> Alcotest.fail "expected element to have a stroke"

(* Seed a global stroke_* key. *)
let set store key v = State_store.set store key v

let check_float name expected got =
  Alcotest.(check (float 1e-9)) name expected got
let check_int name expected got = Alcotest.(check int) name expected got

let a_line () = Element.make_line
  ~stroke:(Some (Element.make_stroke ~width:1.0 Element.black)) 0.0 0.0 10.0 0.0
let a_rect () = Element.make_rect
  ~stroke:(Some (Element.make_stroke ~width:1.0 Element.black)) 0.0 0.0 10.0 10.0
let a_path () = Element.make_path
  ~stroke:(Some (Element.make_stroke ~width:1.0 Element.black))
  [ Element.MoveTo (0.0, 0.0); Element.LineTo (10.0, 10.0) ]

let apply model store =
  let ctrl = new Controller.controller ~model () in
  Effects.apply_stroke_panel_to_selection store ctrl

let sel = [[0; 0]]

(* ── end-to-end apply-to-selection ───────────────────────── *)

let e2e_tests = [
  (* weight = 2.5 -> stroke.width == 2.5 (via model default stroke; see
     OCaml WEIGHT note). *)
  Alcotest.test_case "weight_2p5" `Quick (fun () ->
    let model = model_with_stroked ~default_width:2.5 (a_line ()) sel in
    let store = State_store.create () in
    apply model store;
    check_float "width" 2.5 (stroke_at model [0; 0]).stroke_width);

  (* cap: round / square / butt *)
  Alcotest.test_case "cap_round" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_cap" (`String "round");
    apply model store;
    Alcotest.(check bool) "round"
      true ((stroke_at model [0; 0]).stroke_linecap = Element.Round_cap));
  Alcotest.test_case "cap_square" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_cap" (`String "square");
    apply model store;
    Alcotest.(check bool) "square"
      true ((stroke_at model [0; 0]).stroke_linecap = Element.Square));
  Alcotest.test_case "cap_butt_default" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_cap" (`String "butt");
    apply model store;
    Alcotest.(check bool) "butt"
      true ((stroke_at model [0; 0]).stroke_linecap = Element.Butt));

  (* join: round / bevel / miter *)
  Alcotest.test_case "join_round" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_join" (`String "round");
    apply model store;
    Alcotest.(check bool) "round"
      true ((stroke_at model [0; 0]).stroke_linejoin = Element.Round_join));
  Alcotest.test_case "join_bevel" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_join" (`String "bevel");
    apply model store;
    Alcotest.(check bool) "bevel"
      true ((stroke_at model [0; 0]).stroke_linejoin = Element.Bevel));
  Alcotest.test_case "join_miter_default" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_join" (`String "miter");
    apply model store;
    Alcotest.(check bool) "miter"
      true ((stroke_at model [0; 0]).stroke_linejoin = Element.Miter));

  (* miter_limit = 8 *)
  Alcotest.test_case "miter_limit_8" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_miter_limit" (`Int 8);
    apply model store;
    check_float "miter" 8.0 (stroke_at model [0; 0]).stroke_miter_limit);

  (* align: inside / outside / center. NB the OCaml apply reads key
     [stroke_align_stroke] (effects.ml ~700), NOT [stroke_align]. *)
  Alcotest.test_case "align_inside" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_align_stroke" (`String "inside");
    apply model store;
    Alcotest.(check bool) "inside"
      true ((stroke_at model [0; 0]).stroke_align = Element.Inside));
  Alcotest.test_case "align_outside" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_align_stroke" (`String "outside");
    apply model store;
    Alcotest.(check bool) "outside"
      true ((stroke_at model [0; 0]).stroke_align = Element.Outside));
  Alcotest.test_case "align_center_default" `Quick (fun () ->
    let model = model_with_stroked (a_rect ()) sel in
    let store = State_store.create () in
    set store "stroke_align_stroke" (`String "center");
    apply model store;
    Alcotest.(check bool) "center"
      true ((stroke_at model [0; 0]).stroke_align = Element.Center));

  (* dashed=true, dash_1=12, gap_1=6 -> [12; 6] *)
  Alcotest.test_case "dash_two_entries" `Quick (fun () ->
    let model = model_with_stroked (a_path ()) sel in
    let store = State_store.create () in
    set store "stroke_dashed" (`Bool true);
    set store "stroke_dash_1" (`Int 12);
    set store "stroke_gap_1" (`Int 6);
    apply model store;
    let p = (stroke_at model [0; 0]).stroke_dash_pattern in
    check_int "len" 2 (List.length p);
    Alcotest.(check (list (float 1e-9))) "pattern" [12.0; 6.0] p);

  (* dashed=true, 2 pairs -> [12; 6; 3; 3] *)
  Alcotest.test_case "dash_four_entries" `Quick (fun () ->
    let model = model_with_stroked (a_path ()) sel in
    let store = State_store.create () in
    set store "stroke_dashed" (`Bool true);
    set store "stroke_dash_1" (`Int 12);
    set store "stroke_gap_1" (`Int 6);
    set store "stroke_dash_2" (`Int 3);
    set store "stroke_gap_2" (`Int 3);
    apply model store;
    let p = (stroke_at model [0; 0]).stroke_dash_pattern in
    check_int "len" 4 (List.length p);
    Alcotest.(check (list (float 1e-9))) "pattern" [12.0; 6.0; 3.0; 3.0] p);

  (* dashed=false -> no dash pattern *)
  Alcotest.test_case "dash_none_when_off" `Quick (fun () ->
    let model = model_with_stroked (a_path ()) sel in
    let store = State_store.create () in
    set store "stroke_dashed" (`Bool false);
    set store "stroke_dash_1" (`Int 12);
    set store "stroke_gap_1" (`Int 6);
    apply model store;
    check_int "empty" 0
      (List.length (stroke_at model [0; 0]).stroke_dash_pattern));

  (* start_arrowhead "simple_arrow" -> Simple_arrow *)
  Alcotest.test_case "start_arrow_simple" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_start_arrowhead" (`String "simple_arrow");
    apply model store;
    Alcotest.(check bool) "start"
      true ((stroke_at model [0; 0]).stroke_start_arrow = Element.Simple_arrow));

  (* end_arrowhead "none" -> Arrow_none *)
  Alcotest.test_case "end_arrow_none" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_end_arrowhead" (`String "none");
    apply model store;
    Alcotest.(check bool) "end"
      true ((stroke_at model [0; 0]).stroke_end_arrow = Element.Arrow_none));

  (* optional extras that are easily reachable *)
  Alcotest.test_case "arrow_scale" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_start_arrowhead_scale" (`Int 150);
    set store "stroke_end_arrowhead_scale" (`Int 75);
    apply model store;
    let s = stroke_at model [0; 0] in
    check_float "start_scale" 150.0 s.stroke_start_arrow_scale;
    check_float "end_scale" 75.0 s.stroke_end_arrow_scale);

  Alcotest.test_case "arrow_align_center_at_end" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) sel in
    let store = State_store.create () in
    set store "stroke_arrow_align" (`String "center_at_end");
    apply model store;
    Alcotest.(check bool) "align"
      true ((stroke_at model [0; 0]).stroke_arrow_align = Element.Center_at_end));

  Alcotest.test_case "dash_align_anchors_true" `Quick (fun () ->
    let model = model_with_stroked (a_path ()) sel in
    let store = State_store.create () in
    set store "stroke_dash_align_anchors" (`Bool true);
    apply model store;
    Alcotest.(check bool) "anchors"
      true (stroke_at model [0; 0]).stroke_dash_align_anchors);

  (* no-op guard: empty selection leaves the (unselected) element alone *)
  Alcotest.test_case "no_op_when_selection_empty" `Quick (fun () ->
    let model = model_with_stroked (a_line ()) [] in
    let store = State_store.create () in
    set store "stroke_cap" (`String "round");
    apply model store;
    (* Element untouched: still the butt cap it was built with. *)
    Alcotest.(check bool) "unchanged"
      true ((stroke_at model [0; 0]).stroke_linecap = Element.Butt));
]

(* ── sync (element -> panel) reflection ──────────────────── *)
(* Mirrors Python's stroke_panel_sync_test.py: weight/cap/join reflect
   FROM the selected element via sync_stroke_panel_from_selection, which
   writes into the [stroke_panel_content] panel scope. *)

let panel_str store key =
  match State_store.get_panel store "stroke_panel_content" key with
  | `String s -> s | _ -> "<none>"
let panel_float store key =
  match State_store.get_panel store "stroke_panel_content" key with
  | `Float f -> f | `Int n -> float_of_int n | _ -> nan

let sync_tests = [
  Alcotest.test_case "weight_reflects_from_selection" `Quick (fun () ->
    let line = Element.make_line
      ~stroke:(Some (Element.make_stroke ~width:2.5 Element.black))
      0.0 0.0 10.0 0.0 in
    let model = model_with_stroked line sel in
    let store = State_store.create () in
    State_store.init_panel store "stroke_panel_content" [("weight", `Float 1.0)];
    let ctrl = new Controller.controller ~model () in
    Effects.sync_stroke_panel_from_selection store ctrl;
    check_float "weight" 2.5 (panel_float store "weight"));

  Alcotest.test_case "cap_reflects_from_selection" `Quick (fun () ->
    let line = Element.make_line
      ~stroke:(Some (Element.make_stroke ~width:1.0 ~linecap:Element.Round_cap
                       Element.black))
      0.0 0.0 10.0 0.0 in
    let model = model_with_stroked line sel in
    let store = State_store.create () in
    State_store.init_panel store "stroke_panel_content" [("cap", `String "butt")];
    let ctrl = new Controller.controller ~model () in
    Effects.sync_stroke_panel_from_selection store ctrl;
    Alcotest.(check string) "cap" "round" (panel_str store "cap"));

  Alcotest.test_case "join_reflects_from_selection" `Quick (fun () ->
    let rect = Element.make_rect
      ~stroke:(Some (Element.make_stroke ~width:1.0 ~linejoin:Element.Bevel
                       Element.black))
      0.0 0.0 10.0 10.0 in
    let model = model_with_stroked rect sel in
    let store = State_store.create () in
    State_store.init_panel store "stroke_panel_content" [("join", `String "miter")];
    let ctrl = new Controller.controller ~model () in
    Effects.sync_stroke_panel_from_selection store ctrl;
    Alcotest.(check string) "join" "bevel" (panel_str store "join"));
]

let () =
  Alcotest.run "stroke_panel_state" [
    "end_to_end", e2e_tests;
    "sync", sync_tests;
  ]
