open Jas.Pane

let pass = ref 0
let fail = ref 0

let run name f =
  try f (); incr pass; Printf.printf "  PASS: %s\n" name
  with e -> incr fail; Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let near a b = abs_float (a -. b) < 0.001

(* ================================================================== *)
(* Initialization & lookup                                            *)
(* ================================================================== *)

let () = Printf.printf "Pane tests:\n"

let () =
  run "default_three_pane_fills_viewport" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (Array.length pl.panes = 3);
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let canvas = Option.get (pane_by_kind pl Canvas) in
    let dock = Option.get (pane_by_kind pl Dock) in
    assert (toolbar.x = 0.0);
    assert (toolbar.width = default_toolbar_width);
    assert (near canvas.x (toolbar.x +. toolbar.width));
    assert (near dock.x (canvas.x +. canvas.width));
    let total = toolbar.width +. canvas.width +. dock.width in
    assert (near total 1000.0);
    assert (toolbar.height = 700.0);
    assert (canvas.height = 700.0);
    assert (dock.height = 700.0));

  run "default_three_pane_snap_count" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (List.length pl.snaps = 10));

  run "pane_lookup_by_id" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (find_pane pl 0 <> None);
    assert (find_pane pl 1 <> None);
    assert (find_pane pl 2 <> None));

  run "pane_lookup_by_kind" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert ((Option.get (pane_by_kind pl Toolbar)).kind = Toolbar);
    assert ((Option.get (pane_by_kind pl Canvas)).kind = Canvas);
    assert ((Option.get (pane_by_kind pl Dock)).kind = Dock));

  run "pane_lookup_invalid_id" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (find_pane pl 99 = None));

  run "pane_config_defaults" (fun () ->
    let tc = config_for_kind Toolbar in
    assert (tc.min_width = min_toolbar_width);
    assert tc.fixed_width;
    assert (tc.double_click_action = No_action);
    let cc = config_for_kind Canvas in
    assert (cc.min_width = min_canvas_width);
    assert (not cc.fixed_width);
    assert (cc.double_click_action = Maximize);
    let dc = config_for_kind Dock in
    assert (dc.min_width = min_pane_dock_width);
    assert (not dc.fixed_width);
    assert (dc.double_click_action = Redock);
    (* collapsed_width drives collapsibility *)
    assert (tc.collapsed_width = None);
    assert (cc.collapsed_width = None);
    assert (dc.collapsed_width = Some 36.0))

(* ================================================================== *)
(* Position & sizing                                                  *)
(* ================================================================== *)

let () =
  run "set_pane_position_moves_pane" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Canvas)).id in
    set_pane_position pl id ~x:100.0 ~y:50.0;
    let p = Option.get (find_pane pl id) in
    assert (p.x = 100.0);
    assert (p.y = 50.0));

  run "set_pane_position_clears_snaps" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let snaps_before = List.length pl.snaps in
    assert (snaps_before > 0);
    set_pane_position pl canvas_id ~x:200.0 ~y:200.0;
    let has_canvas_snap = List.exists (fun s ->
      s.snap_pane = canvas_id ||
      (match s.target with Pane_target (pid, _) -> pid = canvas_id | _ -> false)
    ) pl.snaps in
    assert (not has_canvas_snap);
    assert (List.length pl.snaps < snaps_before));

  run "resize_pane_clamps_min_toolbar" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Toolbar)).id in
    resize_pane pl id ~width:10.0 ~height:10.0;
    let p = Option.get (find_pane pl id) in
    assert (p.width = min_toolbar_width);
    assert (p.height = min_toolbar_height));

  run "resize_pane_clamps_min_canvas" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Canvas)).id in
    resize_pane pl id ~width:10.0 ~height:10.0;
    let p = Option.get (find_pane pl id) in
    assert (p.width = min_canvas_width);
    assert (p.height = min_canvas_height));

  run "resize_pane_clamps_min_dock" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Dock)).id in
    resize_pane pl id ~width:10.0 ~height:10.0;
    let p = Option.get (find_pane pl id) in
    assert (p.width = min_pane_dock_width);
    assert (p.height = min_pane_dock_height));

  run "resize_pane_accepts_large_values" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Canvas)).id in
    resize_pane pl id ~width:800.0 ~height:600.0;
    let p = Option.get (find_pane pl id) in
    assert (p.width = 800.0);
    assert (p.height = 600.0))

(* ================================================================== *)
(* Snap detection                                                     *)
(* ================================================================== *)

let () =
  run "detect_snaps_near_window_edge" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    set_pane_position pl canvas_id ~x:5.0 ~y:0.0;
    let snaps = detect_snaps pl ~dragged:canvas_id ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (List.exists (fun s ->
      s.snap_pane = canvas_id && s.edge = Left && s.target = Window_target Left
    ) snaps));

  run "detect_snaps_near_other_pane" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let toolbar_right = toolbar.x +. toolbar.width in
    let toolbar_id = toolbar.id in
    set_pane_position pl canvas_id ~x:(toolbar_right +. 5.0) ~y:0.0;
    let snaps = detect_snaps pl ~dragged:canvas_id ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (List.exists (fun s ->
      s.snap_pane = toolbar_id && s.edge = Right && s.target = Pane_target (canvas_id, Left)
    ) snaps));

  run "detect_snaps_no_match" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    set_pane_position pl canvas_id ~x:400.0 ~y:300.0;
    resize_pane pl canvas_id ~width:200.0 ~height:200.0;
    let snaps = detect_snaps pl ~dragged:canvas_id ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (snaps = []))

(* ================================================================== *)
(* Snap application                                                   *)
(* ================================================================== *)

let () =
  run "apply_snaps_aligns_position" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    set_pane_position pl canvas_id ~x:5.0 ~y:3.0;
    let new_snaps = [
      { snap_pane = canvas_id; edge = Left; target = Window_target Left };
      { snap_pane = canvas_id; edge = Top; target = Window_target Top };
    ] in
    apply_snaps pl canvas_id ~new_snaps ~viewport_w:1000.0 ~viewport_h:700.0;
    let p = Option.get (find_pane pl canvas_id) in
    assert (p.x = 0.0);
    assert (p.y = 0.0));

  run "apply_snaps_aligns_via_normalized_pane_snap" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    set_pane_position pl canvas_id ~x:80.0 ~y:0.0;
    let new_snaps = [
      { snap_pane = toolbar_id; edge = Right; target = Pane_target (canvas_id, Left) };
    ] in
    apply_snaps pl canvas_id ~new_snaps ~viewport_w:1000.0 ~viewport_h:700.0;
    let p = Option.get (find_pane pl canvas_id) in
    assert (near p.x 72.0));

  run "drag_canvas_snap_to_toolbar_full_workflow" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    (* 1. Drag canvas away *)
    set_pane_position pl canvas_id ~x:300.0 ~y:100.0;
    assert (List.for_all (fun s ->
      s.snap_pane <> canvas_id &&
      (match s.target with Pane_target (pid, _) -> pid <> canvas_id | _ -> true)
    ) pl.snaps);
    (* 2. Drag back near toolbar *)
    set_pane_position pl canvas_id ~x:77.0 ~y:0.0;
    (* 3. Detect snaps *)
    let snaps = detect_snaps pl ~dragged:canvas_id ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar_snap = List.find_opt (fun s ->
      s.edge = Right &&
      (match s.target with Pane_target (pid, Left) -> pid = canvas_id | _ -> false)
    ) snaps in
    assert (toolbar_snap <> None);
    (* 4. Apply snaps *)
    apply_snaps pl canvas_id ~new_snaps:snaps ~viewport_w:1000.0 ~viewport_h:700.0;
    (* 5. Canvas aligned *)
    let canvas = Option.get (find_pane pl canvas_id) in
    assert (near canvas.x 72.0);
    (* 6. Shared border findable *)
    let border = shared_border_at pl ~x:72.0 ~y:350.0 ~tolerance:border_hit_tolerance in
    assert (border <> None));

  run "apply_snaps_replaces_old" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let old_count = List.length pl.snaps in
    let new_snaps = [
      { snap_pane = canvas_id; edge = Left; target = Window_target Left };
    ] in
    apply_snaps pl canvas_id ~new_snaps ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (List.length pl.snaps < old_count);
    assert (List.exists (fun s -> s.snap_pane = canvas_id && s.edge = Left) pl.snaps));

  run "align_to_snaps_does_not_modify_snap_list" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    set_pane_position pl canvas_id ~x:80.0 ~y:5.0;
    let snaps_before = List.length pl.snaps in
    let new_snaps = [
      { snap_pane = toolbar_id; edge = Right; target = Pane_target (canvas_id, Left) };
      { snap_pane = canvas_id; edge = Top; target = Window_target Top };
    ] in
    align_to_snaps pl canvas_id ~snaps:new_snaps ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (List.length pl.snaps = snaps_before);
    let p = Option.get (find_pane pl canvas_id) in
    assert (near p.x 72.0);
    assert (p.y = 0.0))

(* ================================================================== *)
(* Shared border                                                      *)
(* ================================================================== *)

let () =
  run "shared_border_at_vertical" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let border_x = toolbar.x +. toolbar.width in
    let result = shared_border_at pl ~x:border_x ~y:350.0 ~tolerance:border_hit_tolerance in
    assert (result <> None);
    let (_, orientation) = Option.get result in
    assert (orientation = Left));

  run "shared_border_at_miss" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let result = shared_border_at pl ~x:500.0 ~y:350.0 ~tolerance:border_hit_tolerance in
    assert (result = None));

  run "drag_shared_border_widens_left_narrows_right" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas = Option.get (pane_by_kind pl Canvas) in
    let border_x = canvas.x +. canvas.width in
    let (snap_idx, _) = Option.get (shared_border_at pl ~x:border_x ~y:350.0 ~tolerance:border_hit_tolerance) in
    let canvas_w_before = (Option.get (pane_by_kind pl Canvas)).width in
    let dock_w_before = (Option.get (pane_by_kind pl Dock)).width in
    let dock_x_before = (Option.get (pane_by_kind pl Dock)).x in
    drag_shared_border pl ~snap_idx ~delta:30.0;
    let canvas_w_after = (Option.get (pane_by_kind pl Canvas)).width in
    let dock_w_after = (Option.get (pane_by_kind pl Dock)).width in
    let dock_x_after = (Option.get (pane_by_kind pl Dock)).x in
    assert (near canvas_w_after (canvas_w_before +. 30.0));
    assert (near dock_w_after (dock_w_before -. 30.0));
    assert (near dock_x_after (dock_x_before +. 30.0)));

  run "drag_shared_border_toolbar_is_fixed" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let border_x = toolbar.x +. toolbar.width in
    let result = shared_border_at pl ~x:border_x ~y:350.0 ~tolerance:border_hit_tolerance in
    assert (result <> None);
    let (snap_idx, _) = Option.get result in
    let toolbar_w_before = (Option.get (pane_by_kind pl Toolbar)).width in
    drag_shared_border pl ~snap_idx ~delta:30.0;
    let toolbar_w_after = (Option.get (pane_by_kind pl Toolbar)).width in
    assert (near toolbar_w_after toolbar_w_before));

  run "drag_shared_border_respects_min_size" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let border_x = toolbar.x +. toolbar.width in
    let (snap_idx, _) = Option.get (shared_border_at pl ~x:border_x ~y:350.0 ~tolerance:border_hit_tolerance) in
    drag_shared_border pl ~snap_idx ~delta:(-5000.0);
    let toolbar2 = Option.get (pane_by_kind pl Toolbar) in
    assert (toolbar2.width >= min_toolbar_width));

  run "drag_shared_border_propagates_to_chained_pane" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar = Option.get (pane_by_kind pl Toolbar) in
    let border_x = toolbar.x +. toolbar.width in
    let (snap_idx, _) = Option.get (shared_border_at pl ~x:border_x ~y:350.0 ~tolerance:border_hit_tolerance) in
    drag_shared_border pl ~snap_idx ~delta:30.0;
    let canvas = Option.get (pane_by_kind pl Canvas) in
    let dock = Option.get (pane_by_kind pl Dock) in
    assert (near (canvas.x +. canvas.width) dock.x))

(* ================================================================== *)
(* Z-order & visibility                                               *)
(* ================================================================== *)

let () =
  run "bring_pane_to_front" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    let dock_id = (Option.get (pane_by_kind pl Dock)).id in
    assert (List.nth pl.z_order (List.length pl.z_order - 1) = dock_id);
    bring_pane_to_front pl toolbar_id;
    assert (List.nth pl.z_order (List.length pl.z_order - 1) = toolbar_id));

  run "pane_z_index_ordering" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    let dock_id = (Option.get (pane_by_kind pl Dock)).id in
    assert (pane_z_index pl canvas_id < pane_z_index pl toolbar_id);
    assert (pane_z_index pl toolbar_id < pane_z_index pl dock_id));

  run "hide_show_pane_round_trip" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (is_pane_visible pl Toolbar);
    hide_pane pl Toolbar;
    assert (not (is_pane_visible pl Toolbar));
    show_pane pl Toolbar;
    assert (is_pane_visible pl Toolbar));

  run "hide_pane_idempotent" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    hide_pane pl Dock;
    hide_pane pl Dock;
    assert (List.length pl.hidden_panes = 1));

  run "show_pane_not_hidden_is_noop" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let count_before = List.length pl.hidden_panes in
    show_pane pl Canvas;
    assert (List.length pl.hidden_panes = count_before))

(* ================================================================== *)
(* Viewport resize                                                    *)
(* ================================================================== *)

let () =
  run "on_viewport_resize_proportional" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_w_before = (Option.get (pane_by_kind pl Canvas)).width in
    on_viewport_resize pl ~new_w:2000.0 ~new_h:700.0;
    let canvas_w_after = (Option.get (pane_by_kind pl Canvas)).width in
    assert (abs_float (canvas_w_after -. canvas_w_before *. 2.0) < 1.0));

  run "on_viewport_resize_clamps_min" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    on_viewport_resize pl ~new_w:100.0 ~new_h:100.0;
    Array.iter (fun p ->
      assert (p.width >= p.config.min_width);
      assert (p.height >= p.config.min_height)
    ) pl.panes)

(* ================================================================== *)
(* Utilities                                                          *)
(* ================================================================== *)

let () =
  run "clamp_panes_offscreen" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let id = (Option.get (pane_by_kind pl Canvas)).id in
    set_pane_position pl id ~x:5000.0 ~y:5000.0;
    clamp_panes pl ~viewport_w:1000.0 ~viewport_h:700.0;
    let p = Option.get (find_pane pl id) in
    assert (p.x <= 1000.0 -. min_pane_visible);
    assert (p.y <= 700.0 -. min_pane_visible));

  run "toggle_canvas_maximized" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    assert (not pl.canvas_maximized);
    toggle_canvas_maximized pl;
    assert pl.canvas_maximized;
    toggle_canvas_maximized pl;
    assert (not pl.canvas_maximized));

  run "repair_snaps_adds_missing" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    pl.snaps <- [];
    repair_snaps pl ~viewport_w:1000.0 ~viewport_h:700.0;
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    assert (List.exists (fun s ->
      s.snap_pane = toolbar_id && s.edge = Right && s.target = Pane_target (canvas_id, Left)
    ) pl.snaps));

  run "repair_snaps_no_duplicates" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let count_before = List.length pl.snaps in
    repair_snaps pl ~viewport_w:1000.0 ~viewport_h:700.0;
    assert (List.length pl.snaps = count_before))

(* ================================================================== *)
(* Tiling                                                             *)
(* ================================================================== *)

let () =
  run "tile_panes_fills_viewport" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    tile_panes pl ~collapsed_override:None;
    let t = Option.get (pane_by_kind pl Toolbar) in
    let c = Option.get (pane_by_kind pl Canvas) in
    let d = Option.get (pane_by_kind pl Dock) in
    assert (t.x = 0.0);
    assert (near c.x (t.x +. t.width));
    assert (near d.x (c.x +. c.width));
    assert (near (t.width +. c.width +. d.width) 1000.0);
    assert (t.height = 700.0);
    assert (c.height = 700.0);
    assert (d.height = 700.0);
    assert (t.width = default_toolbar_width));

  run "tile_panes_collapsed_dock" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let dock_id = (Option.get (pane_by_kind pl Dock)).id in
    tile_panes pl ~collapsed_override:(Some (dock_id, 36.0));
    let d = Option.get (pane_by_kind pl Dock) in
    let c = Option.get (pane_by_kind pl Canvas) in
    assert (d.width = 36.0);
    assert (near c.width (1000.0 -. default_toolbar_width -. 36.0));
    assert (near (d.x +. d.width) 1000.0));

  run "tile_panes_clears_hidden" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    hide_pane pl Toolbar;
    hide_pane pl Dock;
    assert (List.length pl.hidden_panes = 2);
    tile_panes pl ~collapsed_override:None;
    assert (pl.hidden_panes = []));

  run "tile_panes_rebuilds_snaps" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    pl.snaps <- [];
    tile_panes pl ~collapsed_override:None;
    assert (pl.snaps <> []);
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    assert (List.exists (fun s ->
      s.snap_pane = toolbar_id && s.edge = Right && s.target = Pane_target (canvas_id, Left)
    ) pl.snaps))

(* ================================================================== *)
(* show_pane brings to front                                         *)
(* ================================================================== *)

let () =
  run "show_pane_brings_to_front" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    hide_pane pl Toolbar;
    show_pane pl Toolbar;
    assert (List.nth pl.z_order (List.length pl.z_order - 1) = toolbar_id))

(* ================================================================== *)
(* hide_pane unmaximizes                                              *)
(* ================================================================== *)

let () =
  run "hide_maximized_pane_unmaximizes" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    assert pl.canvas_maximized;
    hide_pane pl Canvas;
    assert (not pl.canvas_maximized));

  run "hide_non_maximizable_pane_preserves_maximized" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    assert pl.canvas_maximized;
    hide_pane pl Toolbar;
    assert pl.canvas_maximized)

(* ================================================================== *)
(* fixed-width border drag unsnaps                                    *)
(* ================================================================== *)

let () =
  run "drag_shared_border_fixed_width_unsnaps" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let toolbar_id = (Option.get (pane_by_kind pl Toolbar)).id in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let snap_idx = ref 0 in
    List.iteri (fun i s ->
      if s.snap_pane = toolbar_id && s.edge = Right && s.target = Pane_target (canvas_id, Left) then
        snap_idx := i
    ) pl.snaps;
    drag_shared_border pl ~snap_idx:!snap_idx ~delta:30.0;
    assert (not (List.exists (fun s ->
      s.snap_pane = toolbar_id && s.edge = Right && s.target = Pane_target (canvas_id, Left)
    ) pl.snaps)))

(* ================================================================== *)

let () =
  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
