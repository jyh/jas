(* Tests for toolbar and tool definitions. *)

let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  ignore (GMain.init ());
  Printf.printf "Toolbar and tool tests:\n";

  (* All 10 tool variants exist *)
  let all_tools : Jas.Toolbar.tool list = [
    Selection; Direct_selection; Group_selection;
    Pen; Pencil; Text_tool; Text_path;
    Line; Rect; Polygon;
  ] in

  run_test "all 10 tool variants exist" (fun () ->
    assert (List.length all_tools = 10)
  );

  run_test "tool equality" (fun () ->
    assert (Jas.Toolbar.Selection = Jas.Toolbar.Selection);
    assert (Jas.Toolbar.Direct_selection <> Jas.Toolbar.Selection);
    assert (Jas.Toolbar.Text_path <> Jas.Toolbar.Text_tool);
    assert (Jas.Toolbar.Polygon <> Jas.Toolbar.Rect)
  );

  run_test "tool constants" (fun () ->
    assert (Jas.Canvas_tool.hit_radius = 8.0);
    assert (Jas.Canvas_tool.handle_draw_size = 10.0);
    assert (Jas.Canvas_tool.drag_threshold = 4.0);
    assert (Jas.Canvas_tool.paste_offset = 24.0);
    assert (Jas.Canvas_tool.long_press_ms = 500);
    assert (Jas.Canvas_tool.polygon_sides = 5)
  );

  let fixed = GPack.fixed () in
  let tb = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed in

  run_test "toolbar creation and default tool" (fun () ->
    assert (tb#current_tool = Jas.Toolbar.Selection)
  );

  run_test "select pen tool" (fun () ->
    tb#select_tool Jas.Toolbar.Pen;
    assert (tb#current_tool = Jas.Toolbar.Pen)
  );

  run_test "select pencil tool" (fun () ->
    tb#select_tool Jas.Toolbar.Pencil;
    assert (tb#current_tool = Jas.Toolbar.Pencil)
  );

  run_test "select text tool" (fun () ->
    tb#select_tool Jas.Toolbar.Text_tool;
    assert (tb#current_tool = Jas.Toolbar.Text_tool)
  );

  run_test "select line tool" (fun () ->
    tb#select_tool Jas.Toolbar.Line;
    assert (tb#current_tool = Jas.Toolbar.Line)
  );

  run_test "arrow slot alternate: direct selection" (fun () ->
    tb#select_tool Jas.Toolbar.Direct_selection;
    assert (tb#current_tool = Jas.Toolbar.Direct_selection)
  );

  run_test "arrow slot alternate: group selection" (fun () ->
    tb#select_tool Jas.Toolbar.Group_selection;
    assert (tb#current_tool = Jas.Toolbar.Group_selection)
  );

  run_test "text slot alternate: text tool" (fun () ->
    tb#select_tool Jas.Toolbar.Text_tool;
    assert (tb#current_tool = Jas.Toolbar.Text_tool)
  );

  run_test "text slot alternate: text path" (fun () ->
    tb#select_tool Jas.Toolbar.Text_path;
    assert (tb#current_tool = Jas.Toolbar.Text_path)
  );

  run_test "shape slot alternate: rect" (fun () ->
    tb#select_tool Jas.Toolbar.Rect;
    assert (tb#current_tool = Jas.Toolbar.Rect)
  );

  run_test "shape slot alternate: polygon" (fun () ->
    tb#select_tool Jas.Toolbar.Polygon;
    assert (tb#current_tool = Jas.Toolbar.Polygon)
  );

  run_test "cycle through all tools" (fun () ->
    List.iter (fun t ->
      tb#select_tool t;
      assert (tb#current_tool = t)
    ) all_tools
  );

  run_test "constrain_angle horizontal" (fun () ->
    let (cx, cy) = Jas.Canvas_tool.constrain_angle 0.0 0.0 10.0 0.0 in
    assert (abs_float (cx -. 10.0) < 0.001);
    assert (abs_float cy < 0.001)
  );

  run_test "constrain_angle diagonal 45 degrees" (fun () ->
    let (cx2, cy2) = Jas.Canvas_tool.constrain_angle 0.0 0.0 7.0 7.0 in
    let dist = sqrt (7.0 *. 7.0 +. 7.0 *. 7.0) in
    assert (abs_float (cx2 -. dist *. cos (Float.pi /. 4.0)) < 0.001);
    assert (abs_float (cy2 -. dist *. sin (Float.pi /. 4.0)) < 0.001)
  );

  run_test "regular_polygon_points returns correct count" (fun () ->
    let pts = Jas.Canvas_tool.regular_polygon_points 0.0 0.0 10.0 0.0 5 in
    assert (List.length pts = 5)
  );

  Printf.printf "All toolbar and tool tests passed.\n"
