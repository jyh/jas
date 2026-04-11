open Jas.Pane
open Jas.Pane_rendering

let near a b = abs_float (a -. b) < 0.001

let tests = [
  Alcotest.test_case "geometries_from_default_layout" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let geos = pane_geometries pl in
    assert (List.length geos = 3);
    assert (List.for_all (fun g -> g.visible) geos));

  Alcotest.test_case "geometries_pane_positions" `Quick (fun () ->
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

  Alcotest.test_case "geometries_canvas_maximized" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    let geos = pane_geometries pl in
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    assert (canvas.x = 0.0);
    assert (canvas.y = 0.0);
    assert (canvas.width = 1000.0);
    assert (canvas.height = 700.0);
    assert (canvas.z_index = 0));

  Alcotest.test_case "geometries_hidden_pane" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    hide_pane pl Toolbar;
    let geos = pane_geometries pl in
    let toolbar = List.find (fun g -> g.kind = Toolbar) geos in
    assert (not toolbar.visible);
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    assert canvas.visible);

  Alcotest.test_case "geometries_z_order" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let geos = pane_geometries pl in
    let canvas = List.find (fun g -> g.kind = Canvas) geos in
    let toolbar = List.find (fun g -> g.kind = Toolbar) geos in
    let dock = List.find (fun g -> g.kind = Dock) geos in
    assert (canvas.z_index < toolbar.z_index);
    assert (toolbar.z_index < dock.z_index));

  Alcotest.test_case "shared_borders_default" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let borders = shared_borders pl in
    (* toolbar|canvas and canvas|dock borders *)
    assert (List.length borders = 2);
    List.iter (fun b -> assert b.is_vertical; assert (b.bh = 700.0)) borders);

  Alcotest.test_case "no_borders_when_maximized" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    toggle_canvas_maximized pl;
    let borders = shared_borders pl in
    assert (borders = []));

  Alcotest.test_case "snap_lines_computation" `Quick (fun () ->
    let pl = default_three_pane ~viewport_w:1000.0 ~viewport_h:700.0 in
    let canvas_id = (Option.get (pane_by_kind pl Canvas)).id in
    let preview = [
      { snap_pane = canvas_id; edge = Left; target = Window_target Left };
      { snap_pane = canvas_id; edge = Top; target = Window_target Top };
    ] in
    let lines = snap_lines preview pl in
    assert (List.length lines = 2);
    (* Left edge snap line should be vertical (narrow width, tall height) *)
    assert (List.exists (fun l -> l.lw = 4.0 && l.lh > 4.0) lines));
]

let () =
  Alcotest.run "PaneRendering" [
    "Pane rendering tests", tests;
  ]
