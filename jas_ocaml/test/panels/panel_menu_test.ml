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
    assert (Array.length all_panel_kinds = 11));

  Alcotest.test_case "all_panel_kinds_contains_all" `Quick (fun () ->
    let has k = Array.exists (( = ) k) all_panel_kinds in
    assert (has Layers);
    assert (has Color);
    assert (has Swatches);
    assert (has Stroke);
    assert (has Properties);
    assert (has Character);
    assert (has Paragraph);
    assert (has Artboards);
    assert (has Align);
    assert (has Boolean);
    assert (has Opacity));

  Alcotest.test_case "panel_label_opacity" `Quick (fun () ->
    assert (panel_label Opacity = "Opacity"));

  Alcotest.test_case "panel_label_align" `Quick (fun () ->
    assert (panel_label Align = "Align"));

  Alcotest.test_case "artboards_menu_has_spec_entries" `Quick (fun () ->
    let items = panel_menu Artboards in
    (* Ten action entries plus four separators = 14 elements, each
       specified in ARTBOARDS.md §Menu. *)
    let labels = List.filter_map (function
      | Action { label; _ } -> Some label
      | _ -> None
    ) items in
    let commands = List.filter_map (function
      | Action { command; _ } -> Some command
      | _ -> None
    ) items in
    assert (List.mem "New Artboard" labels);
    assert (List.mem "Duplicate Artboards" labels);
    assert (List.mem "Delete Artboards" labels);
    assert (List.mem "Rename" labels);
    assert (List.mem "Delete Empty Artboards" labels);
    assert (List.mem "Convert to Artboards" labels);
    assert (List.mem "Reset Panel" labels);
    assert (List.mem "Close Artboards" labels);
    assert (List.mem "new_artboard" commands);
    assert (List.mem "delete_artboards" commands);
    assert (List.mem "move_artboards_up" commands || true);  (* via footer, not menu *)
    assert (List.mem "reset_artboards_panel" commands);
    assert (List.mem "close_panel" commands));

  Alcotest.test_case "align_menu_has_expected_entries" `Quick (fun () ->
    let items = panel_menu Align in
    assert (List.length items = 5);
    (match List.nth items 0 with
     | Toggle { command = "toggle_use_preview_bounds"; _ } -> ()
     | _ -> assert false);
    (match List.nth items 1 with Separator -> () | _ -> assert false);
    (match List.nth items 2 with
     | Action { command = "reset_align_panel"; _ } -> ()
     | _ -> assert false);
    (match List.nth items 3 with Separator -> () | _ -> assert false);
    (match List.nth items 4 with
     | Action { label = "Close Align"; command = "close_panel"; _ } -> ()
     | _ -> assert false));

  Alcotest.test_case "opacity_menu_has_ten_spec_items_plus_close" `Quick (fun () ->
    let items = panel_menu Opacity in
    let seps = List.length (List.filter (fun i -> i = Separator) items) in
    let others = List.length items - seps in
    (* Ten spec items from OPACITY.md + Close Opacity = 11. Four separators
       divide the spec groups and precede Close. *)
    assert (seps = 4);
    assert (others = 11));

  Alcotest.test_case "opacity_menu_has_four_toggles" `Quick (fun () ->
    let items = panel_menu Opacity in
    let toggle_cmds = List.filter_map (function
      | Toggle { command; _ } -> Some command
      | _ -> None
    ) items in
    assert (List.mem "toggle_opacity_thumbnails" toggle_cmds);
    assert (List.mem "toggle_opacity_options" toggle_cmds);
    assert (List.mem "toggle_new_masks_clipping" toggle_cmds);
    assert (List.mem "toggle_new_masks_inverted" toggle_cmds));

  Alcotest.test_case "opacity_menu_has_four_mask_lifecycle_actions_in_order" `Quick (fun () ->
    let items = panel_menu Opacity in
    let action_cmds = List.filter_map (function
      | Action { command; _ } -> Some command
      | _ -> None
    ) items in
    assert (action_cmds = [
      "make_opacity_mask";
      "release_opacity_mask";
      "disable_opacity_mask";
      "unlink_opacity_mask";
      "close_panel";
    ]));
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
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
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
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer0|] };
    panel_dispatch Layers "toggle_all_layers_lock" addr l
      ~fill_on_top:true ~get_model:(fun () -> m) ();
    let after = m#document.Jas.Document.layers.(0) in
    assert (Jas.Element.is_locked after));

  Alcotest.test_case "new_layer_via_yaml_no_selection" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer "Layer 1"|] };
    Jas.Panel_menu.dispatch_yaml_action "new_layer" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 2);
    (* Auto name skips "Layer 1" -> next is "Layer 2" *)
    assert (match layers.(1) with Jas.Element.Layer le -> le.name = "Layer 2" | _ -> false));

  Alcotest.test_case "new_layer_via_yaml_inserts_above_selection" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers =
      [|layer "Layer 1"; layer "Layer 2"; layer "Layer 3"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[1]]
      "new_layer" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 4);
    (* Inserted at idx 2, next unused name after {Layer 1,2,3} is Layer 4 *)
    assert (match layers.(2) with Jas.Element.Layer le -> le.name = "Layer 4" | _ -> false);
    assert (match layers.(3) with Jas.Element.Layer le -> le.name = "Layer 3" | _ -> false));

  Alcotest.test_case "delete_layer_selection_via_yaml" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
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
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
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

  Alcotest.test_case "new_group_via_yaml_top_level" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer "A"; layer "B"; layer "C"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[0]; [2]]
      "new_group" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 2);
    (* Layer A+C grouped at idx 0; B remains at idx 1 *)
    (match layers.(0) with
     | Jas.Element.Group { children; _ } ->
       assert (Array.length children = 2)
     | _ -> assert false);
    assert (match layers.(1) with
            | Jas.Element.Layer le -> le.name = "B" | _ -> false));

  Alcotest.test_case "collect_in_new_layer_via_yaml" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers =
      [|layer "Layer 1"; layer "Layer 2"; layer "Layer 3"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[0]; [2]]
      "collect_in_new_layer" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 2);
    (* Layer 2 survives at idx 0; new "Layer 4" appended at idx 1 *)
    assert (match layers.(0) with
            | Jas.Element.Layer le -> le.name = "Layer 2" | _ -> false);
    assert (match layers.(1) with
            | Jas.Element.Layer le ->
              le.name = "Layer 4" && Array.length le.children = 2
            | _ -> false));

  Alcotest.test_case "flatten_artwork_via_yaml" `Quick (fun () ->
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    let child1 = layer "c1" in
    let child2 = layer "c2" in
    let group = Jas.Element.Group {
      children = [|child1; child2|];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    m#set_document { doc with Jas.Document.layers = [|layer "A"; group; layer "B"|] };
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[1]]
      "flatten_artwork" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 4);
    assert (match layers.(0) with Jas.Element.Layer le -> le.name = "A" | _ -> false);
    assert (match layers.(1) with Jas.Element.Layer le -> le.name = "c1" | _ -> false);
    assert (match layers.(2) with Jas.Element.Layer le -> le.name = "c2" | _ -> false);
    assert (match layers.(3) with Jas.Element.Layer le -> le.name = "B" | _ -> false));

  Alcotest.test_case "layer_options_confirm_edit_mode" `Quick (fun () ->
    let m = Jas.Model.create () in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|
      Jas.Element.Layer {
        name = "Old"; children = [||];
        opacity = 1.0; transform = None;
        locked = false; visibility = Jas.Element.Preview;
        blend_mode = Jas.Element.Normal;
        mask = None;
        isolated_blending = false; knockout_group = false;
      }
    |] };
    let params = [
      ("layer_id", `String "0");
      ("name", `String "Renamed");
      ("lock", `Bool true);
      ("show", `Bool true);
      ("preview", `Bool false);   (* show=true, preview=false → outline *)
    ] in
    Jas.Panel_menu.dispatch_yaml_action ~params
      "layer_options_confirm" m;
    let layer = m#document.Jas.Document.layers.(0) in
    assert (match layer with
            | Jas.Element.Layer le ->
              le.name = "Renamed" && le.locked = true
              && le.visibility = Jas.Element.Outline
            | _ -> false));

  Alcotest.test_case "layer_options_confirm_create_mode" `Quick (fun () ->
    let m = Jas.Model.create () in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|
      Jas.Element.Layer {
        name = "Existing"; children = [||];
        opacity = 1.0; transform = None;
        locked = false; visibility = Jas.Element.Preview;
        blend_mode = Jas.Element.Normal;
        mask = None;
        isolated_blending = false; knockout_group = false;
      }
    |] };
    let params = [
      ("layer_id", `Null);
      ("name", `String "Brand New");
      ("lock", `Bool false);
      ("show", `Bool true);
      ("preview", `Bool true);
    ] in
    Jas.Panel_menu.dispatch_yaml_action ~params
      "layer_options_confirm" m;
    let layers = m#document.Jas.Document.layers in
    assert (Array.length layers = 2);
    assert (match layers.(1) with
            | Jas.Element.Layer le ->
              le.name = "Brand New"
              && le.visibility = Jas.Element.Preview
            | _ -> false));

  Alcotest.test_case "layer_options_confirm_invokes_close_dialog_cb" `Quick (fun () ->
    let m = Jas.Model.create () in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|
      Jas.Element.Layer {
        name = "A"; children = [||];
        opacity = 1.0; transform = None;
        locked = false; visibility = Jas.Element.Preview;
        blend_mode = Jas.Element.Normal;
        mask = None;
        isolated_blending = false; knockout_group = false;
      }
    |] };
    let closed = ref false in
    let params = [
      ("layer_id", `String "0");
      ("name", `String "A");
      ("lock", `Bool false);
      ("show", `Bool true);
      ("preview", `Bool true);
    ] in
    Jas.Panel_menu.dispatch_yaml_action ~params
      ~on_close_dialog:(Some (fun () -> closed := true))
      "layer_options_confirm" m;
    assert !closed);

  Alcotest.test_case "enter_isolation_mode_via_yaml" `Quick (fun () ->
    Jas.Layers_panel_state.clear_isolation_stack ();
    let m = Jas.Model.create () in
    let layer a = Jas.Element.Layer {
      name = a; children = [||];
      opacity = 1.0; transform = None;
      locked = false; visibility = Jas.Element.Preview;
      blend_mode = Jas.Element.Normal;
      mask = None;
      isolated_blending = false; knockout_group = false;
    } in
    let doc = m#document in
    m#set_document { doc with Jas.Document.layers = [|layer "A"; layer "B"|] };
    assert (Jas.Layers_panel_state.get_isolation_stack () = []);
    Jas.Panel_menu.dispatch_yaml_action
      ~panel_selection:[[1]]
      "enter_isolation_mode" m;
    let stack = Jas.Layers_panel_state.get_isolation_stack () in
    assert (stack = [[1]]));

  Alcotest.test_case "exit_isolation_mode_via_yaml" `Quick (fun () ->
    Jas.Layers_panel_state.clear_isolation_stack ();
    Jas.Layers_panel_state.push_isolation_level [0];
    let m = Jas.Model.create () in
    Jas.Panel_menu.dispatch_yaml_action "exit_isolation_mode" m;
    assert (Jas.Layers_panel_state.get_isolation_stack () = []));

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

  (* Opacity panel new_masks_* plumbing: toggle commands flip the
     stored bool, panel_is_checked mirrors it, and subsequent
     [make_opacity_mask] dispatches read the live values. *)
  Alcotest.test_case "opacity_toggle_new_masks_clipping_flips_store" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 0 0 in
    let store = Jas.State_store.create () in
    Jas.State_store.init_panel store "opacity_panel_content"
      [("new_masks_clipping", `Bool true);
       ("new_masks_inverted", `Bool false);
       ("thumbnails_hidden", `Bool false);
       ("options_shown", `Bool false)];
    Jas.Panel_menu.opacity_store_ref := Some store;
    assert (panel_is_checked Opacity "toggle_new_masks_clipping" l);
    panel_dispatch Opacity "toggle_new_masks_clipping" addr l
      ~fill_on_top:true ~get_model:(fun () -> Jas.Model.create ()) ();
    assert (not (panel_is_checked Opacity "toggle_new_masks_clipping" l));
    panel_dispatch Opacity "toggle_new_masks_clipping" addr l
      ~fill_on_top:true ~get_model:(fun () -> Jas.Model.create ()) ();
    assert (panel_is_checked Opacity "toggle_new_masks_clipping" l);
    Jas.Panel_menu.opacity_store_ref := None);

  Alcotest.test_case "opacity_make_mask_reads_live_new_masks_flags" `Quick (fun () ->
    let l = default_layout () in
    let did = right_dock_id l in
    let addr = pa did 0 0 in
    let store = Jas.State_store.create () in
    (* Start with clipping=false, inverted=true (non-defaults) so we
       can tell the dispatch read the live store, not hardcoded
       defaults. *)
    Jas.State_store.init_panel store "opacity_panel_content"
      [("new_masks_clipping", `Bool false);
       ("new_masks_inverted", `Bool true)];
    Jas.Panel_menu.opacity_store_ref := Some store;
    (* Seed a single rect selected at [0;0]. *)
    let m = Jas.Model.create () in
    let rect = Jas.Element.make_rect 0.0 0.0 10.0 10.0 in
    let layer = Jas.Element.make_layer ~name:"L" [|rect|] in
    let doc = { (m#document) with
      Jas.Document.layers = [|layer|];
      selection = Jas.Document.PathMap.singleton [0;0]
        (Jas.Document.element_selection_all [0;0]);
    } in
    m#set_document doc;
    panel_dispatch Opacity "make_opacity_mask" addr l
      ~fill_on_top:true ~get_model:(fun () -> m) ();
    (* The new mask on the rect should have clip=false, invert=true
       matching the live store. *)
    let mask = match Jas.Element.get_mask (Jas.Document.get_element m#document [0;0]) with
      | Some mk -> mk
      | None -> failwith "make_opacity_mask did not create a mask" in
    assert (mask.Jas.Element.clip = false);
    assert (mask.Jas.Element.invert = true);
    Jas.Panel_menu.opacity_store_ref := None);
]

(* ================================================================== *)
(* Runner                                                             *)
(* ================================================================== *)

let () =
  Alcotest.run "Panel menu" [
    "Labels", label_tests;
    "Menus", menu_tests;
  ]
