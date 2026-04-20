(** End-to-end tests for the OCaml Align platform-effect
    pipeline — parallels applyAlignLeftTranslatesNonExtremalRects
    in Swift and apply_align_left_translates_non_extremal_rects
    in Rust. *)

open Jas

let make_rect_elem x y w h = Element.make_rect x y w h

let model_with_rects rects selected =
  let layer = Element.make_layer (Array.of_list rects) in
  let selection = List.fold_left (fun acc path ->
    let es = Document.make_element_selection path in
    Document.PathMap.add path es acc
  ) Document.PathMap.empty selected in
  let doc = Document.make_document ~selection [| layer |] in
  Model.create ~document:doc ()

let transform_at model path =
  match Element.get_transform (Document.get_element model#document path) with
  | Some t -> t
  | None -> Element.identity_transform

let eps = 1e-6
let close a b = abs_float (a -. b) < eps

let tests = [
  Alcotest.test_case "apply_align_left_translates_non_extremal_rects" `Quick (fun () ->
    let rects = [
      make_rect_elem 10.0 0.0 10.0 10.0;
      make_rect_elem 30.0 0.0 10.0 10.0;
      make_rect_elem 60.0 0.0 10.0 10.0;
    ] in
    let model = model_with_rects rects [[0; 0]; [0; 1]; [0; 2]] in
    let store = State_store.create () in
    let ctrl = new Controller.controller ~model () in
    Effects.apply_align_operation store ctrl "align_left";
    (* First rect at x=10 — no translation. *)
    let t0 = transform_at model [0; 0] in
    assert (t0 = Element.identity_transform);
    (* Second rect translated by -20. *)
    let t1 = transform_at model [0; 1] in
    assert (close t1.e (-20.0) && close t1.f 0.0);
    (* Third rect translated by -50. *)
    let t2 = transform_at model [0; 2] in
    assert (close t2.e (-50.0) && close t2.f 0.0));

  Alcotest.test_case "apply_align_operation_noop_when_fewer_than_two" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 10.0 10.0;
                 make_rect_elem 100.0 0.0 10.0 10.0] in
    let model = model_with_rects rects [[0; 0]] in
    let store = State_store.create () in
    let ctrl = new Controller.controller ~model () in
    Effects.apply_align_operation store ctrl "align_left";
    assert (transform_at model [0; 0] = Element.identity_transform);
    assert (transform_at model [0; 1] = Element.identity_transform));

  Alcotest.test_case "reset_align_panel_resets_all_fields" `Quick (fun () ->
    let store = State_store.create () in
    State_store.set store "align_to" (`String "key_object");
    State_store.set store "align_key_object_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 1])]);
    State_store.set store "align_distribute_spacing" (`Float 12.0);
    State_store.set store "align_use_preview_bounds" (`Bool true);
    State_store.init_panel store "align_panel_content" [];
    Effects.reset_align_panel store;
    assert (State_store.get store "align_to" = `String "selection");
    assert (State_store.get store "align_key_object_path" = `Null);
    assert (State_store.get store "align_distribute_spacing" = `Float 0.0);
    assert (State_store.get store "align_use_preview_bounds" = `Bool false);
    assert (State_store.get_panel store "align_panel_content" "align_to"
            = `String "selection");
    assert (State_store.get_panel store "align_panel_content" "key_object_path"
            = `Null));

  Alcotest.test_case "align_key_object_holds_while_others_move" `Quick (fun () ->
    let rects = [
      make_rect_elem 10.0 0.0 10.0 10.0;
      make_rect_elem 30.0 0.0 10.0 10.0;
      make_rect_elem 60.0 0.0 10.0 10.0;
    ] in
    let model = model_with_rects rects [[0; 0]; [0; 1]; [0; 2]] in
    let store = State_store.create () in
    State_store.set store "align_to" (`String "key_object");
    State_store.set store "align_key_object_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 1])]);
    let ctrl = new Controller.controller ~model () in
    Effects.apply_align_operation store ctrl "align_left";
    (* Key never moves. *)
    let t1 = transform_at model [0; 1] in
    assert (t1 = Element.identity_transform);
    (* Others align to key left edge (x=30). *)
    let t0 = transform_at model [0; 0] in
    assert (close t0.e 20.0);
    let t2 = transform_at model [0; 2] in
    assert (close t2.e (-30.0)));

  (* Canvas click intercept *)

  Alcotest.test_case "try_designate_returns_false_when_not_key_mode" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]; [0; 1]] in
    let store = State_store.create () in
    let ctrl = new Controller.controller ~model () in
    assert (not (Effects.try_designate_align_key_object store ctrl 25.0 25.0)));

  Alcotest.test_case "try_designate_sets_key_on_hit_in_key_mode" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]; [0; 1]] in
    let store = State_store.create () in
    State_store.set store "align_to" (`String "key_object");
    let ctrl = new Controller.controller ~model () in
    let consumed = Effects.try_designate_align_key_object store ctrl 25.0 25.0 in
    assert consumed;
    assert (State_store.get store "align_key_object_path"
            = `Assoc [("__path__", `List [`Int 0; `Int 0])]));

  Alcotest.test_case "try_designate_second_click_on_same_clears_key" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]; [0; 1]] in
    let store = State_store.create () in
    State_store.set store "align_to" (`String "key_object");
    let ctrl = new Controller.controller ~model () in
    let _ = Effects.try_designate_align_key_object store ctrl 25.0 25.0 in
    let _ = Effects.try_designate_align_key_object store ctrl 25.0 25.0 in
    assert (State_store.get store "align_key_object_path" = `Null));

  Alcotest.test_case "try_designate_outside_selection_clears_key" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]; [0; 1]] in
    let store = State_store.create () in
    State_store.set store "align_to" (`String "key_object");
    State_store.set store "align_key_object_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 0])]);
    let ctrl = new Controller.controller ~model () in
    let _ = Effects.try_designate_align_key_object store ctrl 500.0 500.0 in
    assert (State_store.get store "align_key_object_path" = `Null));

  Alcotest.test_case "sync_align_key_object_preserves_still_selected" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]; [0; 1]] in
    let store = State_store.create () in
    State_store.set store "align_key_object_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 1])]);
    let ctrl = new Controller.controller ~model () in
    Effects.sync_align_key_object_from_selection store ctrl;
    assert (State_store.get store "align_key_object_path"
            = `Assoc [("__path__", `List [`Int 0; `Int 1])]));

  Alcotest.test_case "sync_align_key_object_clears_dangling" `Quick (fun () ->
    let rects = [make_rect_elem 0.0 0.0 50.0 50.0;
                 make_rect_elem 100.0 0.0 50.0 50.0] in
    let model = model_with_rects rects [[0; 0]] in
    let store = State_store.create () in
    State_store.set store "align_key_object_path"
      (`Assoc [("__path__", `List [`Int 0; `Int 1])]);
    let ctrl = new Controller.controller ~model () in
    Effects.sync_align_key_object_from_selection store ctrl;
    assert (State_store.get store "align_key_object_path" = `Null));
]

let () =
  Alcotest.run "align_apply" [ "apply", tests ]
