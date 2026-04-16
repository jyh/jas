open Jas.Workspace_layout
open Jas.Panel_menu

let ga did gi = { dock_id = did; group_idx = gi }
let pa did gi pi = { group = ga did gi; panel_idx = pi }

let right_dock_id l =
  match anchored_dock l Right with
  | Some d -> d.id
  | None -> failwith "no right dock"

(* ================================================================== *)
(* Panel labels                                                       *)
(* ================================================================== *)

let label_tests = [
  Alcotest.test_case "panel_label_layers" `Quick (fun () ->
    assert (panel_label Layers = "Layers"));

  Alcotest.test_case "panel_label_color" `Quick (fun () ->
    assert (panel_label Color = "Color"));

  Alcotest.test_case "panel_label_stroke" `Quick (fun () ->
    assert (panel_label Stroke = "Stroke"));

  Alcotest.test_case "panel_label_swatches" `Quick (fun () ->
    assert (panel_label Swatches = "Swatches"));

  Alcotest.test_case "panel_label_properties" `Quick (fun () ->
    assert (panel_label Properties = "Properties"));

  Alcotest.test_case "all_panel_kinds_count" `Quick (fun () ->
    assert (Array.length all_panel_kinds = 5));

  Alcotest.test_case "all_panel_kinds_contains_all" `Quick (fun () ->
    let has k = Array.exists (( = ) k) all_panel_kinds in
    assert (has Layers);
    assert (has Color);
    assert (has Swatches);
    assert (has Stroke);
    assert (has Properties));
]

(* ================================================================== *)
(* Panel menus                                                        *)
(* ================================================================== *)

let menu_tests = [
  Alcotest.test_case "menu_non_empty_all_kinds" `Quick (fun () ->
    Array.iter (fun kind ->
      assert (panel_menu kind <> [])
    ) all_panel_kinds);

  Alcotest.test_case "every_panel_has_close_action" `Quick (fun () ->
    Array.iter (fun kind ->
      let items = panel_menu kind in
      let has_close = List.exists (function
        | Action { command = "close_panel"; _ } -> true
        | _ -> false) items in
      assert has_close
    ) all_panel_kinds);

  Alcotest.test_case "close_label_matches_panel_name" `Quick (fun () ->
    Array.iter (fun kind ->
      let items = panel_menu kind in
      let close_item = List.find_opt (function
        | Action { command = "close_panel"; _ } -> true
        | _ -> false) items in
      match close_item with
      | Some (Action { label; _ }) ->
        let expected = "Close " ^ panel_label kind in
        assert (label = expected)
      | _ -> assert false
    ) all_panel_kinds);

  Alcotest.test_case "dispatch_close_removes_panel" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    (* Color is at group 0, panel index 0 *)
    let addr = pa did 0 0 in
    assert (is_panel_visible l Color);
    panel_dispatch Color "close_panel" addr l ~fill_on_top:true ~get_model:(fun () -> Jas.Model.create ()) ();
    assert (not (is_panel_visible l Color)));

  Alcotest.test_case "is_checked_defaults_false" `Quick (fun () ->
    let l = default_layout () in
    Array.iter (fun kind ->
      assert (not (panel_is_checked kind "anything" l))
    ) all_panel_kinds);

  Alcotest.test_case "layers_menu_has_new_layer" `Quick (fun () ->
    let items = panel_menu Layers in
    let has = List.exists (function
      | Action { command = "new_layer"; _ } -> true | _ -> false) items in
    assert has);

  Alcotest.test_case "layers_menu_has_new_group" `Quick (fun () ->
    let items = panel_menu Layers in
    let has = List.exists (function
      | Action { command = "new_group"; _ } -> true | _ -> false) items in
    assert has);

  Alcotest.test_case "layers_menu_has_visibility_toggles" `Quick (fun () ->
    let items = panel_menu Layers in
    let cmds = ["toggle_all_layers_visibility"; "toggle_all_layers_outline";
                "toggle_all_layers_lock"] in
    List.iter (fun cmd ->
      let has = List.exists (function
        | Action { command = c; _ } -> c = cmd | _ -> false) items in
      assert has
    ) cmds);

  Alcotest.test_case "layers_menu_has_isolation_mode" `Quick (fun () ->
    let items = panel_menu Layers in
    let cmds = ["enter_isolation_mode"; "exit_isolation_mode"] in
    List.iter (fun cmd ->
      let has = List.exists (function
        | Action { command = c; _ } -> c = cmd | _ -> false) items in
      assert has
    ) cmds);

  Alcotest.test_case "layers_menu_has_flatten_and_collect" `Quick (fun () ->
    let items = panel_menu Layers in
    let cmds = ["flatten_artwork"; "collect_in_new_layer"] in
    List.iter (fun cmd ->
      let has = List.exists (function
        | Action { command = c; _ } -> c = cmd | _ -> false) items in
      assert has
    ) cmds);

  Alcotest.test_case "new_layer_no_selection_appends_to_end" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 2 0 in
    let m = Jas.Model.create () in
    (* Add two existing layers *)
    let layer0 = Jas.Element.make_layer ~name:"Layer 0" [||] in
    let layer1 = Jas.Element.make_layer ~name:"Layer 1" [||] in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer0; layer1|] };
    panel_dispatch Layers "new_layer" addr l ~fill_on_top:true ~get_model:(fun () -> m)
      ~get_panel_selection:(fun () -> []) ();
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 3);
    (* No selection: new layer appended at end *)
    assert (match layers.(2) with Jas.Element.Layer le -> le.name <> "Layer 0" && le.name <> "Layer 1" | _ -> false));

  Alcotest.test_case "new_layer_with_selection_inserts_above" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 2 0 in
    let m = Jas.Model.create () in
    let layer0 = Jas.Element.make_layer ~name:"Layer 0" [||] in
    let layer1 = Jas.Element.make_layer ~name:"Layer 1" [||] in
    let layer2 = Jas.Element.make_layer ~name:"Layer 2" [||] in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer0; layer1; layer2|] };
    (* Select layer at index 1 (Layer 1) *)
    panel_dispatch Layers "new_layer" addr l ~fill_on_top:true ~get_model:(fun () -> m)
      ~get_panel_selection:(fun () -> [[1]]) ();
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 4);
    (* insert_pos = 1 + 1 = 2, new layer at index 2 *)
    assert (match layers.(2) with Jas.Element.Layer le ->
      le.name <> "Layer 0" && le.name <> "Layer 1" && le.name <> "Layer 2" | _ -> false);
    (* Layer 2 shifted to index 3 *)
    assert (match layers.(3) with Jas.Element.Layer le -> le.name = "Layer 2" | _ -> false));

  Alcotest.test_case "toggle_all_layers_visibility_via_yaml" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 2 0 in
    let m = Jas.Model.create () in
    let layer0 = Jas.Element.Layer {
      name = "A"; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer0|] };
    (* Run toggle_all_layers_visibility via YAML dispatch *)
    panel_dispatch Layers "toggle_all_layers_visibility" addr l
      ~fill_on_top:true ~get_model:(fun () -> m) ();
    (* Layer 0 was Preview → any_visible=true → target=invisible *)
    let after = m#document.Jas.Document.layers.(0) in
    assert (Jas.Element.get_visibility after = Jas.Element.Invisible));

  Alcotest.test_case "toggle_all_layers_lock_via_yaml" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 2 0 in
    let m = Jas.Model.create () in
    let layer0 = Jas.Element.Layer {
      name = "A"; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer0|] };
    panel_dispatch Layers "toggle_all_layers_lock" addr l
      ~fill_on_top:true ~get_model:(fun () -> m) ();
    let after = m#document.Jas.Document.layers.(0) in
    assert (Jas.Element.is_locked after));

  Alcotest.test_case "delete_layer_selection_via_yaml" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer "A"; layer "B"; layer "C"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[0]; [2]]
      "delete_layer_selection" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 1);
    assert (match layers.(0) with Jas.Element.Layer le -> le.name = "B" | _ -> false));

  Alcotest.test_case "duplicate_layer_selection_via_yaml" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer "A"; layer "B"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[1]]
      "duplicate_layer_selection" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 3);
    assert (match layers.(0) with Jas.Element.Layer le -> le.name = "A" | _ -> false);
    assert (match layers.(1) with Jas.Element.Layer le -> le.name = "B" | _ -> false);
    assert (match layers.(2) with Jas.Element.Layer le -> le.name = "B" | _ -> false));

  Alcotest.test_case "layers_dispatch_tier3_no_crash" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 2 0 in
    let cmds = ["new_layer"; "new_group"; "toggle_all_layers_visibility";
                "toggle_all_layers_outline"; "toggle_all_layers_lock";
                "enter_isolation_mode"; "exit_isolation_mode";
                "flatten_artwork"; "collect_in_new_layer"] in
    List.iter (fun cmd ->
      panel_dispatch Layers cmd addr l ~fill_on_top:true ~get_model:(fun () -> Jas.Model.create ()) ()
    ) cmds);
]

(* ================================================================== *)
(* Runner                                                             *)
(* ================================================================== *)

let () =
  Alcotest.run "Panel menu" [
    "Labels", label_tests;
    "Menus", menu_tests;
  ]
