(* Tests for toolbar and tool definitions. *)

let () =
  ignore (GMain.init ());

  (* --- Tool type tests --- *)

  (* All 10 tool variants exist *)
  let all_tools : Jas.Toolbar.tool list = [
    Selection; Direct_selection; Group_selection;
    Pen; Pencil; Text_tool; Text_path;
    Line; Rect; Polygon;
  ] in
  assert (List.length all_tools = 10);

  (* Tool equality *)
  assert (Jas.Toolbar.Selection = Jas.Toolbar.Selection);
  assert (Jas.Toolbar.Direct_selection <> Jas.Toolbar.Selection);
  assert (Jas.Toolbar.Text_path <> Jas.Toolbar.Text_tool);
  assert (Jas.Toolbar.Polygon <> Jas.Toolbar.Rect);

  (* --- Tool constants --- *)
  assert (Jas.Canvas_tool.hit_radius = 8.0);
  assert (Jas.Canvas_tool.handle_draw_size = 10.0);
  assert (Jas.Canvas_tool.drag_threshold = 4.0);
  assert (Jas.Canvas_tool.paste_offset = 24.0);
  assert (Jas.Canvas_tool.long_press_ms = 500);
  assert (Jas.Canvas_tool.polygon_sides = 5);

  (* --- Toolbar creation and default tool --- *)
  let fixed = GPack.fixed () in
  let tb = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed in
  assert (tb#current_tool = Jas.Toolbar.Selection);

  (* --- Tool selection --- *)
  tb#select_tool Jas.Toolbar.Pen;
  assert (tb#current_tool = Jas.Toolbar.Pen);

  tb#select_tool Jas.Toolbar.Pencil;
  assert (tb#current_tool = Jas.Toolbar.Pencil);

  tb#select_tool Jas.Toolbar.Text_tool;
  assert (tb#current_tool = Jas.Toolbar.Text_tool);

  tb#select_tool Jas.Toolbar.Line;
  assert (tb#current_tool = Jas.Toolbar.Line);

  (* --- Arrow slot alternates --- *)
  tb#select_tool Jas.Toolbar.Direct_selection;
  assert (tb#current_tool = Jas.Toolbar.Direct_selection);

  tb#select_tool Jas.Toolbar.Group_selection;
  assert (tb#current_tool = Jas.Toolbar.Group_selection);

  (* --- Text slot alternates --- *)
  tb#select_tool Jas.Toolbar.Text_tool;
  assert (tb#current_tool = Jas.Toolbar.Text_tool);

  tb#select_tool Jas.Toolbar.Text_path;
  assert (tb#current_tool = Jas.Toolbar.Text_path);

  (* --- Shape slot alternates --- *)
  tb#select_tool Jas.Toolbar.Rect;
  assert (tb#current_tool = Jas.Toolbar.Rect);

  tb#select_tool Jas.Toolbar.Polygon;
  assert (tb#current_tool = Jas.Toolbar.Polygon);

  (* --- Cycle through all tools --- *)
  List.iter (fun t ->
    tb#select_tool t;
    assert (tb#current_tool = t)
  ) all_tools;

  (* --- constrain_angle helper --- *)
  let (cx, cy) = Jas.Canvas_tool.constrain_angle 0.0 0.0 10.0 0.0 in
  assert (abs_float (cx -. 10.0) < 0.001);
  assert (abs_float cy < 0.001);

  let (cx2, cy2) = Jas.Canvas_tool.constrain_angle 0.0 0.0 7.0 7.0 in
  let dist = sqrt (7.0 *. 7.0 +. 7.0 *. 7.0) in
  assert (abs_float (cx2 -. dist *. cos (Float.pi /. 4.0)) < 0.001);
  assert (abs_float (cy2 -. dist *. sin (Float.pi /. 4.0)) < 0.001);

  (* --- regular_polygon_points --- *)
  let pts = Jas.Canvas_tool.regular_polygon_points 0.0 0.0 10.0 0.0 5 in
  assert (List.length pts = 5);

  Printf.printf "All toolbar and tool tests passed.\n"
