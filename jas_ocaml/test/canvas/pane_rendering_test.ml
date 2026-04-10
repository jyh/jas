open Jas.Pane
open Jas.Pane_rendering

let pass = ref 0
let fail = ref 0

let run name f =
  try f (); incr pass; Printf.printf "  PASS: %s\n" name
  with e -> incr fail; Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let near a b = abs_float (a -. b) < 0.001

let () = Printf.printf "Pane rendering tests:\n"

let () =
  run "geometries_from_default_layout" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let geos = pane_geometries pl in
    assert (List.length geos = 3);
    assert (List.for_all (fun g -> g.visible) geos));

  run "geometries_pane_positions" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let geos = pane_geometries pl in
    let toolbar = List.find (fun g -> g.kind = Toolbar) geos in
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    let dock = List.find (fun g -> g.kind = Dock) geos in
    assert (toolbar.x = 0.0);
    assert (toolbar.width = default_toolbar_width);
    assert (near canvas.x (toolbar.x +. toolbar.width));
    assert (near dock.x (canvas.x +. canvas.width));
    assert (toolbar.height = 700.0);
    assert (canvas.height = 700.0);
    assert (dock.height = 700.0));

  run "geometries_canvas_maximized" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    let geos = pane_geometries pl in
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    assert (canvas.x = 0.0);
    assert (canvas.y = 0.0);
    assert (canvas.width = 1000.0);
    assert (canvas.height = 700.0);
    assert (canvas.z_index = 0));

  run "geometries_hidden_pane" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    hide_pane pl Toolbar;
    let geos = pane_geometries pl in
    let toolbar = List.find (fun g -> g.kind = Toolbar) geos in
    assert (not toolbar.visible);
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    assert canvas.visible);

  run "geometries_z_order" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let geos = pane_geometries pl in
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    let toolbar = List.find (fun g -> g.kind = Toolbar) geos in
    let dock = List.find (fun g -> g.kind = Dock) geos in
    assert (canvas.z_index < toolbar.z_index);
    assert (toolbar.z_index < dock.z_index));

  run "shared_borders_default" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let borders = shared_borders pl in
    (* toolbar|canvas and canvas|dock borders *)
    assert (List.length borders = 2);
    List.iter (fun b -> assert b.is_vertical; assert (b.bh = 700.0)) borders);

  run "no_borders_when_maximized" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    let borders = shared_borders pl in
    assert (borders = []));

  run "snap_lines_computation" (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let preview = [
      { snap_pane = canvas_id; edge = Left; target = Window_target Left };
      { snap_pane = canvas_id; edge = Top; target = Window_target Top };
    ] in
    let lines = snap_lines preview pl in
    assert (List.length lines = 2);
    (* Left edge snap line should be vertical (narrow width, tall height) *)
    assert (List.exists (fun l -> l.lw = 4.0 && l.lh > 4.0) lines))

let () =
  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
