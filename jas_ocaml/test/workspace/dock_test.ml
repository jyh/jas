open Jas.Dock

let pass = ref 0
let fail = ref 0

let run name f =
  try f (); incr pass; Printf.printf "  PASS: %s\n" name
  with e -> incr fail; Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let ga did gi = { dock_id = did; group_idx = gi }
let pa did gi pi = { group = ga did gi; panel_idx = pi }

let right_dock_id l =
  match anchored_dock l Right with
  | Some d -> d.id
  | None -> failwith "no right dock"

(* ================================================================== *)
(* Layout & lookup                                                    *)
(* ================================================================== *)

let () = Printf.printf "Dock tests:\n"

let () =
  run "default_layout_one_anchored_right" (fun () ->
    let l = default_layout () in
    assert (List.length l.anchored = 1);
    assert (fst (List.hd l.anchored) = Right);
    assert (l.floating = []));

  run "default_layout_two_groups" (fun () ->
    let l = default_layout () in
    let d = Option.get (anchored_dock l Right) in
    assert (Array.length d.groups = 2);
    assert (d.groups.(0).panels = [|Layers|]);
    assert (d.groups.(1).panels = [|Color; Stroke; Properties|]));

  run "default_not_collapsed" (fun () ->
    let l = default_layout () in
    let (d : dock) = Option.get (anchored_dock l Right) in
    assert (not d.collapsed);
    Array.iter (fun (g : panel_group) -> assert (not g.collapsed)) d.groups);

  run "default_dock_width" (fun () ->
    let l = default_layout () in
    let d = Option.get (anchored_dock l Right) in
    assert (d.width = default_dock_width));

  run "dock_lookup_anchored" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    assert (find_dock l id <> None));

  run "dock_lookup_floating" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:100.0 ~y:100.0) in
    assert (find_dock l fid <> None);
    assert (floating_dock l fid <> None));

  run "dock_lookup_invalid" (fun () ->
    let l = default_layout () in
    assert (find_dock l 99 = None));

  run "anchored_dock_by_edge" (fun () ->
    let l = default_layout () in
    assert (anchored_dock l Right <> None);
    assert (anchored_dock l Left = None);
    assert (anchored_dock l Bottom = None))

(* ================================================================== *)
(* Toggle / active                                                    *)
(* ================================================================== *)

let () =
  run "toggle_dock_collapsed" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    assert (not (Option.get (find_dock l id)).collapsed);
    toggle_dock_collapsed l id;
    assert (Option.get (find_dock l id)).collapsed;
    toggle_dock_collapsed l id;
    assert (not (Option.get (find_dock l id)).collapsed));

  run "toggle_group_collapsed" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    toggle_group_collapsed l (ga id 0);
    assert (Option.get (find_dock l id)).groups.(0).collapsed;
    assert (not (Option.get (find_dock l id)).groups.(1).collapsed);
    toggle_group_collapsed l (ga id 0);
    assert (not (Option.get (find_dock l id)).groups.(0).collapsed));

  run "toggle_group_out_of_bounds" (fun () ->
    let l = default_layout () in
    toggle_group_collapsed l (ga 0 99);
    toggle_group_collapsed l (ga 99 0));

  run "set_active_panel" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_active_panel l (pa id 1 2);
    assert ((Option.get (find_dock l id)).groups.(1).active = 2));

  run "set_active_panel_out_of_bounds" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_active_panel l (pa id 1 99);
    assert ((Option.get (find_dock l id)).groups.(1).active = 0);
    set_active_panel l (pa id 99 0);
    set_active_panel l (pa 99 0 0))

(* ================================================================== *)
(* Move group within dock                                             *)
(* ================================================================== *)

let () =
  run "move_group_forward" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_within_dock l id ~from:0 ~to_:1;
    let d = Option.get (find_dock l id) in
    assert (d.groups.(0).panels = [|Color; Stroke; Properties|]);
    assert (d.groups.(1).panels = [|Layers|]));

  run "move_group_backward" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_within_dock l id ~from:1 ~to_:0;
    let d = Option.get (find_dock l id) in
    assert (d.groups.(0).panels = [|Color; Stroke; Properties|]));

  run "move_group_same_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_within_dock l id ~from:0 ~to_:0;
    assert ((Option.get (find_dock l id)).groups.(0).panels = [|Layers|]));

  run "move_group_clamped" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_within_dock l id ~from:0 ~to_:99;
    assert ((Option.get (find_dock l id)).groups.(1).panels = [|Layers|]));

  run "move_group_out_of_bounds" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_within_dock l id ~from:99 ~to_:0;
    assert (Array.length (Option.get (find_dock l id)).groups = 2));

  run "move_group_preserves_state" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    (Option.get (find_dock l id)).groups.(1).active <- 2;
    (Option.get (find_dock l id)).groups.(1).collapsed <- true;
    move_group_within_dock l id ~from:1 ~to_:0;
    let d = Option.get (find_dock l id) in
    assert (d.groups.(0).active = 2);
    assert (d.groups.(0).collapsed))

(* ================================================================== *)
(* Move group between docks                                           *)
(* ================================================================== *)

let () =
  run "move_group_between_docks" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    move_group_to_dock l ~from:(ga id 0) ~to_dock:fid ~to_idx:1;
    assert (Array.length (Option.get (find_dock l id)).groups = 0);
    assert (Array.length (Option.get (find_dock l fid)).groups = 2));

  run "move_group_inserts_at_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    let f2 = Option.get (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0) in
    move_group_to_dock l ~from:(ga f1 0) ~to_dock:f2 ~to_idx:0;
    assert ((Option.get (find_dock l f2)).groups.(0).panels = [|Layers|]);
    assert (find_dock l f1 = None));

  run "move_group_same_dock_is_reorder" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_to_dock l ~from:(ga id 0) ~to_dock:id ~to_idx:1;
    let d = Option.get (find_dock l id) in
    assert (d.groups.(0).panels = [|Color; Stroke; Properties|]);
    assert (d.groups.(1).panels = [|Layers|]));

  run "move_group_invalid_source" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_to_dock l ~from:(ga id 99) ~to_dock:id ~to_idx:0;
    assert (Array.length (Option.get (find_dock l id)).groups = 2));

  run "move_group_invalid_target" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_group_to_dock l ~from:(ga id 0) ~to_dock:99 ~to_idx:0;
    assert (Array.length (Option.get (find_dock l id)).groups = 2))

(* ================================================================== *)
(* Detach group                                                       *)
(* ================================================================== *)

let () =
  run "detach_group_creates_floating" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:100.0 ~y:200.0) in
    assert ((Option.get (find_dock l fid)).groups.(0).panels = [|Layers|]);
    assert (Array.length (Option.get (find_dock l id)).groups = 1));

  run "detach_group_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:100.0 ~y:200.0) in
    let fd = Option.get (floating_dock l fid) in
    assert (fd.x = 100.0);
    assert (fd.y = 200.0));

  run "detach_group_unique_ids" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    let f2 = Option.get (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0) in
    assert (f1 <> f2));

  run "detach_last_group_floating_removes_dock" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    ignore (detach_group l ~from:(ga f1 0) ~x:20.0 ~y:20.0);
    assert (find_dock l f1 = None));

  run "detach_last_group_anchored_keeps_dock" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    ignore (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0);
    ignore (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0);
    assert (find_dock l id <> None);
    assert (Array.length (Option.get (find_dock l id)).groups = 0))

(* ================================================================== *)
(* Move panel                                                         *)
(* ================================================================== *)

let () =
  run "move_panel_same_dock" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_panel_to_group l ~from:(pa id 1 1) ~to_:(ga id 0);
    let d = Option.get (find_dock l id) in
    assert (d.groups.(0).panels = [|Layers; Stroke|]);
    assert (d.groups.(1).panels = [|Color; Properties|]));

  run "move_panel_becomes_active" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_panel_to_group l ~from:(pa id 1 1) ~to_:(ga id 0);
    assert ((Option.get (find_dock l id)).groups.(0).active = 1));

  run "move_panel_cross_dock" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    move_panel_to_group l ~from:(pa id 0 0) ~to_:(ga fid 0);
    assert ((Option.get (find_dock l fid)).groups.(0).panels = [|Layers; Color|]);
    assert ((Option.get (find_dock l id)).groups.(0).panels = [|Stroke; Properties|]));

  run "move_last_panel_removes_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_panel_to_group l ~from:(pa id 0 0) ~to_:(ga id 1);
    let d = Option.get (find_dock l id) in
    assert (Array.length d.groups = 1);
    assert (Array.mem Layers d.groups.(0).panels));

  run "move_last_panel_removes_floating" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    move_panel_to_group l ~from:(pa fid 0 0) ~to_:(ga id 0);
    assert (find_dock l fid = None));

  run "move_panel_clamps_active" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    (Option.get (find_dock l id)).groups.(1).active <- 2;
    move_panel_to_group l ~from:(pa id 1 2) ~to_:(ga id 0);
    let g = (Option.get (find_dock l id)).groups.(1) in
    assert (g.active < Array.length g.panels));

  run "move_panel_invalid_source" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_panel_to_group l ~from:(pa id 1 99) ~to_:(ga id 0);
    move_panel_to_group l ~from:(pa 99 0 0) ~to_:(ga id 0));

  run "move_panel_invalid_target" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    move_panel_to_group l ~from:(pa id 1 0) ~to_:(ga 99 0);
    assert (Array.length (Option.get (find_dock l id)).groups.(1).panels = 3))

(* ================================================================== *)
(* Insert panel as new group                                          *)
(* ================================================================== *)

let () =
  run "insert_panel_creates_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    insert_panel_as_new_group l ~from:(pa id 1 1) ~to_dock:id ~at_idx:0;
    let d = Option.get (find_dock l id) in
    assert (Array.length d.groups = 3);
    assert (d.groups.(0).panels = [|Stroke|]));

  run "insert_panel_cleans_source" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    insert_panel_as_new_group l ~from:(pa id 0 0) ~to_dock:id ~at_idx:99;
    let d = Option.get (find_dock l id) in
    assert (Array.length d.groups = 2);
    assert (d.groups.(1).panels = [|Layers|]));

  run "insert_panel_invalid" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    insert_panel_as_new_group l ~from:(pa id 1 99) ~to_dock:id ~at_idx:0;
    insert_panel_as_new_group l ~from:(pa 99 0 0) ~to_dock:id ~at_idx:0;
    assert (Array.length (Option.get (find_dock l id)).groups = 2))

(* ================================================================== *)
(* Detach panel                                                       *)
(* ================================================================== *)

let () =
  run "detach_panel_creates_floating" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_panel l ~from:(pa id 1 1) ~x:300.0 ~y:150.0) in
    assert ((Option.get (find_dock l fid)).groups.(0).panels = [|Stroke|]);
    assert ((Option.get (find_dock l id)).groups.(1).panels = [|Color; Properties|]));

  run "detach_panel_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_panel l ~from:(pa id 1 0) ~x:300.0 ~y:150.0) in
    let fd = Option.get (floating_dock l fid) in
    assert (fd.x = 300.0);
    assert (fd.y = 150.0));

  run "detach_panel_last_removes_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    ignore (detach_panel l ~from:(pa id 0 0) ~x:50.0 ~y:50.0);
    assert (Array.length (Option.get (find_dock l id)).groups = 1));

  run "detach_panel_last_removes_floating" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    ignore (detach_panel l ~from:(pa f1 0 0) ~x:100.0 ~y:100.0);
    assert (find_dock l f1 = None))

(* ================================================================== *)
(* Floating position                                                  *)
(* ================================================================== *)

let () =
  run "set_floating_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    set_floating_position l fid ~x:200.0 ~y:300.0;
    let fd = Option.get (floating_dock l fid) in
    assert (fd.x = 200.0);
    assert (fd.y = 300.0));

  run "set_position_anchored_ignored" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_floating_position l id ~x:999.0 ~y:999.0);

  run "set_position_invalid_id" (fun () ->
    let l = default_layout () in
    set_floating_position l 99 ~x:0.0 ~y:0.0)

(* ================================================================== *)
(* Resize                                                             *)
(* ================================================================== *)

let () =
  run "resize_group_sets_height" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    resize_group l (ga id 0) ~height:150.0;
    assert ((Option.get (find_dock l id)).groups.(0).height = Some 150.0));

  run "resize_group_clamps_min" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    resize_group l (ga id 0) ~height:5.0;
    assert ((Option.get (find_dock l id)).groups.(0).height = Some min_group_height));

  run "resize_group_invalid_addr" (fun () ->
    let l = default_layout () in
    resize_group l (ga 99 0) ~height:100.0;
    resize_group l (ga 0 99) ~height:100.0);

  run "default_group_height_is_none" (fun () ->
    let l = default_layout () in
    let d = Option.get (anchored_dock l Right) in
    Array.iter (fun g -> assert (g.height = None)) d.groups);

  run "set_dock_width_clamped" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_dock_width l id ~width:50.0;
    assert ((Option.get (find_dock l id)).width = min_dock_width);
    set_dock_width l id ~width:9999.0;
    assert ((Option.get (find_dock l id)).width = max_dock_width);
    set_dock_width l id ~width:300.0;
    assert ((Option.get (find_dock l id)).width = 300.0))

(* ================================================================== *)
(* Cleanup                                                            *)
(* ================================================================== *)

let () =
  run "cleanup_clamps_active" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    (Option.get (find_dock l id)).groups.(1).active <- 2;
    move_panel_to_group l ~from:(pa id 1 2) ~to_:(ga id 0);
    let g = (Option.get (find_dock l id)).groups.(1) in
    assert (g.active < Array.length g.panels));

  run "cleanup_multiple_empty_groups" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let d = Option.get (find_dock l id) in
    d.groups.(0).panels <- [||];
    d.groups.(1).panels <- [||];
    cleanup l id;
    assert (Array.length (Option.get (find_dock l id)).groups = 0))

(* ================================================================== *)
(* Labels                                                             *)
(* ================================================================== *)

let () =
  run "panel_label_values" (fun () ->
    assert (panel_label Layers = "Layers");
    assert (panel_label Color = "Color");
    assert (panel_label Stroke = "Stroke");
    assert (panel_label Properties = "Properties"));

  run "panel_group_active_panel" (fun () ->
    let g = make_panel_group [Color; Stroke] in
    assert (active_panel g = Some Color));

  run "panel_group_active_panel_empty" (fun () ->
    let g = { panels = [||]; active = 0; collapsed = false; height = None } in
    assert (active_panel g = None))

(* ================================================================== *)
(* Close / show panels                                                *)
(* ================================================================== *)

let () =
  run "close_panel_hides_it" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 1 1);
    assert (List.mem Stroke l.hidden_panels);
    assert (not (is_panel_visible l Stroke)));

  run "close_panel_removes_from_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 1 1);
    assert ((Option.get (find_dock l id)).groups.(1).panels = [|Color; Properties|]));

  run "close_last_panel_removes_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 0 0);
    assert (Array.length (Option.get (find_dock l id)).groups = 1);
    assert (List.mem Layers l.hidden_panels));

  run "show_panel_adds_to_default_group" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 1 1);
    show_panel l Stroke;
    assert (not (List.mem Stroke l.hidden_panels));
    assert (Array.mem Stroke (Option.get (find_dock l id)).groups.(0).panels));

  run "show_panel_removes_from_hidden" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 1 0);
    assert (List.length l.hidden_panels = 1);
    show_panel l Color;
    assert (l.hidden_panels = []));

  run "hidden_panels_default_empty" (fun () ->
    let l = default_layout () in
    assert (l.hidden_panels = []));

  run "panel_menu_items_all_visible" (fun () ->
    let l = default_layout () in
    let items = panel_menu_items l in
    assert (List.length items = 4);
    List.iter (fun (_, v) -> assert v) items);

  run "panel_menu_items_with_hidden" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    close_panel l (pa id 1 1);
    let items = panel_menu_items l in
    assert (not (snd (List.find (fun (k, _) -> k = Stroke) items)));
    assert (snd (List.find (fun (k, _) -> k = Layers) items)))

(* ================================================================== *)
(* Z-index                                                            *)
(* ================================================================== *)

let () =
  run "bring_to_front_moves_to_end" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    let _f2 = Option.get (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0) in
    bring_to_front l f1;
    assert (List.nth l.z_order (List.length l.z_order - 1) = f1));

  run "bring_to_front_already_front" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let _f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    let f2 = Option.get (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0) in
    bring_to_front l f2;
    assert (List.nth l.z_order (List.length l.z_order - 1) = f2);
    assert (List.length l.z_order = 2));

  run "z_index_for_ordering" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let f1 = Option.get (detach_group l ~from:(ga id 0) ~x:10.0 ~y:10.0) in
    let f2 = Option.get (detach_group l ~from:(ga id 0) ~x:20.0 ~y:20.0) in
    assert (z_index_for l f1 = 0);
    assert (z_index_for l f2 = 1);
    bring_to_front l f1;
    assert (z_index_for l f1 = 1);
    assert (z_index_for l f2 = 0))

(* ================================================================== *)
(* Snap & re-dock                                                     *)
(* ================================================================== *)

let () =
  run "snap_to_right_edge" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    let before = Array.length (Option.get (anchored_dock l Right)).groups in
    snap_to_edge l fid Right;
    assert (floating_dock l fid = None);
    assert (Array.length (Option.get (anchored_dock l Right)).groups > before));

  run "snap_to_left_edge" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    snap_to_edge l fid Left;
    assert (anchored_dock l Left <> None);
    assert (floating_dock l fid = None));

  run "snap_creates_anchored_dock" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    assert (anchored_dock l Bottom = None);
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    snap_to_edge l fid Bottom;
    assert (anchored_dock l Bottom <> None);
    assert ((Option.get (anchored_dock l Bottom)).groups.(0).panels = [|Layers|]));

  run "redock_merges_into_right" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0) in
    redock l fid;
    assert (l.floating = []);
    let d = Option.get (anchored_dock l Right) in
    assert (Array.exists (fun g -> Array.mem Layers g.panels) d.groups));

  run "redock_invalid_id" (fun () ->
    let l = default_layout () in
    redock l 99;
    assert (List.length l.anchored = 1));

  run "is_near_edge_detection" (fun () ->
    assert (is_near_edge ~x:5.0 ~y:500.0 ~viewport_w:1000.0 ~viewport_h:800.0 = Some Left);
    assert (is_near_edge ~x:990.0 ~y:500.0 ~viewport_w:1000.0 ~viewport_h:800.0 = Some Right);
    assert (is_near_edge ~x:500.0 ~y:790.0 ~viewport_w:1000.0 ~viewport_h:800.0 = Some Bottom));

  run "is_near_edge_not_near" (fun () ->
    assert (is_near_edge ~x:500.0 ~y:400.0 ~viewport_w:1000.0 ~viewport_h:800.0 = None))

(* ================================================================== *)
(* Multi-edge                                                         *)
(* ================================================================== *)

let () =
  run "add_anchored_left" (fun () ->
    let l = default_layout () in
    let id = add_anchored_dock l Left in
    assert (anchored_dock l Left <> None);
    assert ((Option.get (anchored_dock l Left)).id = id));

  run "add_anchored_existing_returns_id" (fun () ->
    let l = default_layout () in
    let id1 = add_anchored_dock l Left in
    let id2 = add_anchored_dock l Left in
    assert (id1 = id2);
    assert (List.length l.anchored = 2));

  run "add_anchored_bottom" (fun () ->
    let l = default_layout () in
    ignore (add_anchored_dock l Bottom);
    assert (anchored_dock l Bottom <> None);
    assert (List.length l.anchored = 2));

  run "remove_anchored_moves_to_floating" (fun () ->
    let l = default_layout () in
    let lid = add_anchored_dock l Left in
    (Option.get (find_dock l lid)).groups <- [|make_panel_group [Layers]|];
    let fid = remove_anchored_dock l Left in
    assert (fid <> None);
    assert (anchored_dock l Left = None);
    assert (floating_dock l (Option.get fid) <> None));

  run "remove_anchored_empty_returns_none" (fun () ->
    let l = default_layout () in
    ignore (add_anchored_dock l Left);
    let fid = remove_anchored_dock l Left in
    assert (fid = None))

(* ================================================================== *)
(* Persistence                                                        *)
(* ================================================================== *)

let () =
  run "reset_to_default" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    ignore (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0);
    close_panel l (pa id 0 0);
    assert (l.floating <> []);
    assert (l.hidden_panels <> []);
    reset_to_default l;
    assert (l.floating = []);
    assert (l.hidden_panels = []);
    assert (Array.length (Option.get (anchored_dock l Right)).groups = 2))

(* ================================================================== *)
(* Focus                                                              *)
(* ================================================================== *)

let () =
  run "set_focused_panel" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let addr = pa id 1 2 in
    set_focused_panel l (Some addr);
    assert (l.focused_panel = Some addr);
    set_focused_panel l None;
    assert (l.focused_panel = None));

  run "focus_next_wraps" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_focused_panel l None;
    focus_next_panel l;
    assert (l.focused_panel = Some (pa id 0 0));
    focus_next_panel l;
    focus_next_panel l;
    focus_next_panel l;
    assert (l.focused_panel = Some (pa id 1 2));
    focus_next_panel l;
    assert (l.focused_panel = Some (pa id 0 0)));

  run "focus_prev_wraps" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    set_focused_panel l None;
    focus_prev_panel l;
    assert (l.focused_panel = Some (pa id 1 2));
    focus_prev_panel l;
    focus_prev_panel l;
    focus_prev_panel l;
    assert (l.focused_panel = Some (pa id 0 0));
    focus_prev_panel l;
    assert (l.focused_panel = Some (pa id 1 2)))

(* ================================================================== *)
(* Safety                                                             *)
(* ================================================================== *)

let () =
  run "clamp_floating_within_viewport" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:2000.0 ~y:1500.0) in
    clamp_floating_docks l ~viewport_w:1000.0 ~viewport_h:800.0;
    let fd = Option.get (floating_dock l fid) in
    assert (fd.x <= 950.0);
    assert (fd.y <= 750.0));

  run "clamp_floating_partially_offscreen" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    let fid = Option.get (detach_group l ~from:(ga id 0) ~x:(-500.0) ~y:(-100.0)) in
    clamp_floating_docks l ~viewport_w:1000.0 ~viewport_h:800.0;
    let fd = Option.get (floating_dock l fid) in
    assert (fd.x >= -.fd.dock.width +. 50.0);
    assert (fd.y >= 0.0));

  run "set_auto_hide" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    assert (not (Option.get (find_dock l id)).auto_hide);
    set_auto_hide l id ~auto_hide:true;
    assert (Option.get (find_dock l id)).auto_hide;
    set_auto_hide l id ~auto_hide:false;
    assert (not (Option.get (find_dock l id)).auto_hide))

(* ================================================================== *)
(* Reorder panels                                                     *)
(* ================================================================== *)

let () =
  run "reorder_panel_forward" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    reorder_panel l ~group:(ga id 1) ~from:0 ~to_:2;
    let g = (Option.get (find_dock l id)).groups.(1) in
    assert (g.panels = [|Stroke; Properties; Color|]);
    assert (g.active = 2));

  run "reorder_panel_backward" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    reorder_panel l ~group:(ga id 1) ~from:2 ~to_:0;
    let g = (Option.get (find_dock l id)).groups.(1) in
    assert (g.panels = [|Properties; Color; Stroke|]);
    assert (g.active = 0));

  run "reorder_panel_same_position" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    reorder_panel l ~group:(ga id 1) ~from:1 ~to_:1;
    assert ((Option.get (find_dock l id)).groups.(1).panels = [|Color; Stroke; Properties|]));

  run "reorder_panel_clamped" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    reorder_panel l ~group:(ga id 1) ~from:0 ~to_:99;
    assert ((Option.get (find_dock l id)).groups.(1).panels.(2) = Color));

  run "reorder_panel_out_of_bounds" (fun () ->
    let l = default_layout () in
    let id = right_dock_id l in
    reorder_panel l ~group:(ga id 1) ~from:99 ~to_:0;
    reorder_panel l ~group:(ga 99 0) ~from:0 ~to_:1)

(* ================================================================== *)
(* Named layouts & AppConfig                                          *)
(* ================================================================== *)

let () =
  run "default_layout_name" (fun () ->
    let l = default_layout () in
    assert (l.name = "Default"));

  run "named_layout" (fun () ->
    let l = named "My Workspace" in
    assert (l.name = "My Workspace");
    assert (List.length l.anchored = 1));

  run "storage_key_includes_name" (fun () ->
    let l = named "Editing" in
    assert (storage_key l = "jas_layout:Editing"));

  run "storage_key_for_static" (fun () ->
    assert (storage_key_for "Drawing" = "jas_layout:Drawing"));

  run "reset_preserves_name" (fun () ->
    let l = named "Custom" in
    let id = right_dock_id l in
    ignore (detach_group l ~from:(ga id 0) ~x:50.0 ~y:50.0);
    assert (l.floating <> []);
    reset_to_default l;
    assert (l.name = "Custom");
    assert (l.floating = []));

  run "app_config_default" (fun () ->
    let c = default_app_config () in
    assert (c.active_layout = "Default");
    assert (c.saved_layouts = ["Default"]));

  run "register_layout" (fun () ->
    let c = default_app_config () in
    register_layout c "New";
    assert (c.saved_layouts = ["Default"; "New"]);
    register_layout c "New";
    assert (c.saved_layouts = ["Default"; "New"]))

(* ================================================================== *)
(* Pane layout integration                                            *)
(* ================================================================== *)

let () =
  run "dock_layout_default_has_no_pane_layout" (fun () ->
    let l = default_layout () in
    assert (panes l = None));

  run "ensure_pane_layout_creates_if_none" (fun () ->
    let l = default_layout () in
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (panes l <> None);
    assert (Array.length (Option.get (panes l)).Jas.Pane.panes = 3));

  run "ensure_pane_layout_noop_if_present" (fun () ->
    let l = default_layout () in
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    mark_saved l;
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (not (needs_save l)));

  run "reset_to_default_clears_pane_layout" (fun () ->
    let l = default_layout () in
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (panes l <> None);
    reset_to_default l;
    assert (panes l = None));

  run "panes_accessors" (fun () ->
    let l = default_layout () in
    assert (panes l = None);
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (panes l <> None);
    panes_mut l (fun pl -> Jas.Pane.hide_pane pl Jas.Pane.Toolbar);
    assert (not (Jas.Pane.is_pane_visible (Option.get (panes l)) Jas.Pane.Toolbar)));

  run "serde_backward_compat_no_pane_layout" (fun () ->
    let l = default_layout () in
    let json = layout_to_json l in
    let l2 = layout_of_json json in
    assert (panes l2 = None);
    assert (List.length l2.anchored = 1));

  run "serde_round_trip_with_pane_layout" (fun () ->
    let l = default_layout () in
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    let json = layout_to_json l in
    let l2 = layout_of_json json in
    assert (panes l2 <> None);
    let pl2 = Option.get (panes l2) in
    assert (Array.length pl2.Jas.Pane.panes = 3);
    assert (List.length pl2.snaps = 10));

  run "clamp_floating_docks_also_clamps_panes" (fun () ->
    let l = default_layout () in
    ensure_pane_layout l ~viewport_w:1000.0 ~viewport_h:700.0;
    panes_mut l (fun pl ->
      let canvas_id = (Option.get (Jas.Pane.pane_by_kind pl Jas.Pane.Canvas)).id in
      Jas.Pane.set_pane_position pl canvas_id ~x:5000.0 ~y:5000.0);
    clamp_floating_docks l ~viewport_w:1000.0 ~viewport_h:700.0;
    let canvas = Option.get (Jas.Pane.pane_by_kind (Option.get (panes l)) Jas.Pane.Canvas) in
    assert (canvas.x <= 1000.0 -. Jas.Pane.min_pane_visible);
    assert (canvas.y <= 700.0 -. Jas.Pane.min_pane_visible))

(* ================================================================== *)

let () =
  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
