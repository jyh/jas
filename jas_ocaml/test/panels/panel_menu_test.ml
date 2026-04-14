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
    panel_dispatch Color "close_panel" addr l ~fill_on_top:true ~get_model:(fun () -> Jas.Model.create ());
    assert (not (is_panel_visible l Color)));

  Alcotest.test_case "is_checked_defaults_false" `Quick (fun () ->
    let l = default_layout () in
    Array.iter (fun kind ->
      assert (not (panel_is_checked kind "anything" l))
    ) all_panel_kinds);
]

(* ================================================================== *)
(* Runner                                                             *)
(* ================================================================== *)

let () =
  Alcotest.run "Panel menu" [
    "Labels", label_tests;
    "Menus", menu_tests;
  ]
