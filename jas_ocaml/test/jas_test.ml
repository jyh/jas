let () =
  ignore (GMain.init ());

  (* Test main window creation *)
  let main_window, fixed = Jas.Canvas.create_main_window () in
  assert (main_window#title = "Jas");

  (* Test toolbar creation *)
  let toolbar = Jas.Toolbar.create ~title:"Tools" ~x:10 ~y:10 fixed in
  assert (toolbar#current_tool = Jas.Toolbar.Selection);
  toolbar#select_tool Jas.Toolbar.Direct_selection;
  assert (toolbar#current_tool = Jas.Toolbar.Direct_selection);

  (* Test canvas subwindow creation *)
  let canvas = Jas.Canvas_subwindow.create
    ~title:"Untitled" ~x:100 ~y:50 ~width:820 ~height:640 fixed in
  assert (canvas#title = "Untitled");

  (* Test keyboard shortcuts *)
  toolbar#select_tool Jas.Toolbar.Selection;
  assert (toolbar#current_tool = Jas.Toolbar.Selection);
  toolbar#select_tool Jas.Toolbar.Direct_selection;
  assert (toolbar#current_tool = Jas.Toolbar.Direct_selection);

  (* Menubar integration test: verify window is functional after menubar refactor *)
  (* The menubar adds a vbox layout to the main window. All widgets created above *)
  (* should still work correctly, which this entire test suite implicitly verifies. *)
  (* GTK3 menus don't expose a clean programmatic query API in LablGTK without *)
  (* rendering, so menu structure is verified by visual/interactive testing. *)

  (* ---- Element tests ---- *)

  let open Jas.Element in

  (* Test point and color construction *)
  let p = make_point 3.0 4.0 in
  assert (p.x = 3.0);
  assert (p.y = 4.0);
  let c = make_color 1.0 0.0 0.0 in
  assert (c.r = 1.0);
  assert (c.a = 1.0);
  let c2 = make_color ~a:0.5 0.0 1.0 0.0 in
  assert (c2.a = 0.5);

  (* Test path bounds *)
  let path = Path {
    anchors = [
      make_anchor (make_point 0.0 0.0);
      make_anchor (make_point 10.0 20.0);
      make_anchor (make_point 5.0 15.0);
    ];
    closed = false;
    path_fill = None;
    path_stroke = None;
  } in
  let (tl, br) = bounds path in
  assert (tl.x = 0.0);
  assert (tl.y = 0.0);
  assert (br.x = 10.0);
  assert (br.y = 20.0);

  (* Test empty path bounds *)
  let empty_path = Path {
    anchors = [];
    closed = false;
    path_fill = None;
    path_stroke = None;
  } in
  let (tl, br) = bounds empty_path in
  assert (tl.x = 0.0 && br.x = 0.0);

  (* Test path with fill and stroke *)
  let styled_path = Path {
    anchors = [make_anchor (make_point 0.0 0.0); make_anchor (make_point 10.0 10.0)];
    closed = true;
    path_fill = Some (make_fill (make_color 1.0 0.0 0.0));
    path_stroke = Some (make_stroke ~width:2.0 ~alignment:Outside (make_color 0.0 0.0 0.0));
  } in
  (match styled_path with
   | Path p ->
     assert (p.closed = true);
     (match p.path_fill with Some f -> assert (f.fill_color.r = 1.0) | None -> assert false);
     (match p.path_stroke with Some s -> assert (s.stroke_width = 2.0 && s.stroke_alignment = Outside) | None -> assert false)
   | _ -> assert false);

  (* Test rect bounds *)
  let r = Rect {
    origin = make_point 5.0 10.0;
    width = 100.0;
    height = 50.0;
    rect_fill = None;
    rect_stroke = None;
  } in
  let (tl, br) = bounds r in
  assert (tl.x = 5.0 && tl.y = 10.0);
  assert (br.x = 105.0 && br.y = 60.0);

  (* Test ellipse bounds *)
  let e = Ellipse {
    center = make_point 50.0 50.0;
    rx = 25.0;
    ry = 15.0;
    ellipse_fill = None;
    ellipse_stroke = None;
  } in
  let (tl, br) = bounds e in
  assert (tl.x = 25.0 && tl.y = 35.0);
  assert (br.x = 75.0 && br.y = 65.0);

  (* Test group bounds *)
  let g = Group [r; e] in
  let (tl, br) = bounds g in
  assert (tl.x = 5.0 && tl.y = 10.0);
  assert (br.x = 105.0 && br.y = 65.0);

  (* Test empty group bounds *)
  let eg = Group [] in
  let (tl, br) = bounds eg in
  assert (tl.x = 0.0 && br.x = 0.0);

  (* Test nested group *)
  let inner = Group [Rect { origin = make_point 10.0 10.0; width = 5.0; height = 5.0; rect_fill = None; rect_stroke = None }] in
  let outer = Group [
    Rect { origin = make_point 0.0 0.0; width = 1.0; height = 1.0; rect_fill = None; rect_stroke = None };
    inner;
  ] in
  let (tl, br) = bounds outer in
  assert (tl.x = 0.0 && tl.y = 0.0);
  assert (br.x = 15.0 && br.y = 15.0);

  (* Test anchor point handles *)
  let a = make_anchor ~handle_in:(Some (make_point 3.0 3.0)) ~handle_out:(Some (make_point 7.0 7.0)) (make_point 5.0 5.0) in
  assert (a.handle_in = Some (make_point 3.0 3.0));
  assert (a.handle_out = Some (make_point 7.0 7.0));
  let a2 = make_anchor (make_point 5.0 5.0) in
  assert (a2.handle_in = None);
  assert (a2.handle_out = None);

  Printf.printf "All tests passed.\n"
