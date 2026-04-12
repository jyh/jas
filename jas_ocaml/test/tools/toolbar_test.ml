(* Tests for toolbar and tool definitions. *)

let () = ignore (GMain.init ())

let all_tools : Jas.Toolbar.tool list = [
  Selection; Partial_selection; Interior_selection;
  Pen; Add_anchor_point; Pencil; Type_tool; Type_on_path;
  Line; Rect; Rounded_rect; Polygon; Star;
]

let fixed = GPack.fixed ()
let tb = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed

let () =
  Alcotest.run "Toolbar" [
    "tool variants", [
      Alcotest.test_case "all 13 tool variants exist" `Quick (fun () ->
        assert (List.length all_tools = 13)
      );

      Alcotest.test_case "tool equality" `Quick (fun () ->
        assert (Jas.Toolbar.Selection = Jas.Toolbar.Selection);
        assert (Jas.Toolbar.Partial_selection <> Jas.Toolbar.Selection);
        assert (Jas.Toolbar.Type_on_path <> Jas.Toolbar.Type_tool);
        assert (Jas.Toolbar.Polygon <> Jas.Toolbar.Rect)
      );

      Alcotest.test_case "tool constants" `Quick (fun () ->
        assert (Jas.Canvas_tool.hit_radius = 8.0);
        assert (Jas.Canvas_tool.handle_draw_size = 10.0);
        assert (Jas.Canvas_tool.drag_threshold = 4.0);
        assert (Jas.Canvas_tool.paste_offset = 24.0);
        assert (Jas.Canvas_tool.long_press_ms = 500);
        assert (Jas.Canvas_tool.polygon_sides = 5)
      );
    ];

    "toolbar creation", [
      Alcotest.test_case "toolbar creation and default tool" `Quick (fun () ->
        assert (tb#current_tool = Jas.Toolbar.Selection)
      );

      Alcotest.test_case "select pen tool" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Pen;
        assert (tb#current_tool = Jas.Toolbar.Pen)
      );

      Alcotest.test_case "select pencil tool" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Pencil;
        assert (tb#current_tool = Jas.Toolbar.Pencil)
      );

      Alcotest.test_case "select type tool" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Type_tool;
        assert (tb#current_tool = Jas.Toolbar.Type_tool)
      );

      Alcotest.test_case "select line tool" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Line;
        assert (tb#current_tool = Jas.Toolbar.Line)
      );
    ];

    "tool alternates", [
      Alcotest.test_case "arrow slot alternate: partial selection" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Partial_selection;
        assert (tb#current_tool = Jas.Toolbar.Partial_selection)
      );

      Alcotest.test_case "arrow slot alternate: interior selection" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Interior_selection;
        assert (tb#current_tool = Jas.Toolbar.Interior_selection)
      );

      Alcotest.test_case "pen slot alternate: add anchor point" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Add_anchor_point;
        assert (tb#current_tool = Jas.Toolbar.Add_anchor_point)
      );

      Alcotest.test_case "text slot alternate: type tool" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Type_tool;
        assert (tb#current_tool = Jas.Toolbar.Type_tool)
      );

      Alcotest.test_case "text slot alternate: type on a path" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Type_on_path;
        assert (tb#current_tool = Jas.Toolbar.Type_on_path)
      );

      Alcotest.test_case "shape slot alternate: rect" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Rect;
        assert (tb#current_tool = Jas.Toolbar.Rect)
      );

      Alcotest.test_case "shape slot alternate: rounded rect" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Rounded_rect;
        assert (tb#current_tool = Jas.Toolbar.Rounded_rect)
      );

      Alcotest.test_case "shape slot alternate: polygon" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Polygon;
        assert (tb#current_tool = Jas.Toolbar.Polygon)
      );

      Alcotest.test_case "shape slot alternate: star" `Quick (fun () ->
        tb#select_tool Jas.Toolbar.Star;
        assert (tb#current_tool = Jas.Toolbar.Star)
      );

      Alcotest.test_case "cycle through all tools" `Quick (fun () ->
        List.iter (fun t ->
          tb#select_tool t;
          assert (tb#current_tool = t)
        ) all_tools
      );
    ];

    "geometry helpers", [
      Alcotest.test_case "constrain_angle horizontal" `Quick (fun () ->
        let (cx, cy) = Jas.Canvas_tool.constrain_angle 0.0 0.0 10.0 0.0 in
        assert (abs_float (cx -. 10.0) < 0.001);
        assert (abs_float cy < 0.001)
      );

      Alcotest.test_case "constrain_angle diagonal 45 degrees" `Quick (fun () ->
        let (cx2, cy2) = Jas.Canvas_tool.constrain_angle 0.0 0.0 7.0 7.0 in
        let dist = sqrt (7.0 *. 7.0 +. 7.0 *. 7.0) in
        assert (abs_float (cx2 -. dist *. cos (Float.pi /. 4.0)) < 0.001);
        assert (abs_float (cy2 -. dist *. sin (Float.pi /. 4.0)) < 0.001)
      );

      Alcotest.test_case "regular_polygon_points returns correct count" `Quick (fun () ->
        let pts = Jas.Canvas_tool.regular_polygon_points 0.0 0.0 10.0 0.0 5 in
        assert (List.length pts = 5)
      );
    ];
  ]
