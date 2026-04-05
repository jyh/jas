let () =
  let open Jas.Element in

  (* Test color construction *)
  let c = make_color 1.0 0.0 0.0 in
  assert (c.r = 1.0 && c.a = 1.0);
  let c2 = make_color ~a:0.5 0.0 1.0 0.0 in
  assert (c2.a = 0.5);

  (* Test stroke defaults *)
  let s = make_stroke (make_color 0.0 0.0 0.0) in
  assert (s.stroke_width = 1.0);
  assert (s.stroke_linecap = Butt);
  assert (s.stroke_linejoin = Miter);

  (* Test transform helpers *)
  let t = identity_transform in
  assert (t.a = 1.0 && t.d = 1.0 && t.e = 0.0);
  let t2 = make_translate 10.0 20.0 in
  assert (t2.e = 10.0 && t2.f = 20.0);
  let t3 = make_scale 2.0 3.0 in
  assert (t3.a = 2.0 && t3.d = 3.0);

  (* Test line bounds *)
  let ln = make_line 0.0 0.0 10.0 20.0 in
  let (x, y, w, h) = bounds ln in
  assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0);

  (* Test rect bounds *)
  let r = make_rect 5.0 10.0 100.0 50.0 in
  let (x, y, w, h) = bounds r in
  assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 50.0);

  (* Test rect rounded corners *)
  let rr = make_rect ~rx:2.0 ~ry:2.0 0.0 0.0 10.0 10.0 in
  (match rr with Rect { rx; ry; _ } -> assert (rx = 2.0 && ry = 2.0) | _ -> assert false);

  (* Test circle bounds *)
  let ci = make_circle 50.0 50.0 25.0 in
  let (x, y, w, h) = bounds ci in
  assert (x = 25.0 && y = 25.0 && w = 50.0 && h = 50.0);

  (* Test ellipse bounds *)
  let el = make_ellipse 50.0 50.0 25.0 15.0 in
  let (x, y, w, h) = bounds el in
  assert (x = 25.0 && y = 35.0 && w = 50.0 && h = 30.0);

  (* Test polyline bounds *)
  let pl = make_polyline [(0.0, 0.0); (10.0, 5.0); (20.0, 0.0)] in
  let (x, y, w, h) = bounds pl in
  assert (x = 0.0 && y = 0.0 && w = 20.0 && h = 5.0);

  (* Test polygon bounds *)
  let pg = make_polygon [(0.0, 0.0); (10.0, 0.0); (5.0, 10.0)] in
  let (x, y, w, h) = bounds pg in
  assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 10.0);

  (* Test path bounds with SVG commands *)
  let p = make_path [MoveTo (0.0, 0.0); LineTo (10.0, 20.0); LineTo (5.0, 15.0); ClosePath] in
  let (x, y, w, h) = bounds p in
  assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0);

  (* Test path with cubic bezier *)
  let p2 = make_path [MoveTo (0.0, 0.0); CurveTo (5.0, 10.0, 15.0, 10.0, 20.0, 0.0)] in
  let (x, _, w, _) = bounds p2 in
  assert (x = 0.0 && w = 20.0);

  (* Test empty path *)
  let ep = make_path [] in
  let (x, y, w, h) = bounds ep in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  (* Test path with fill and stroke *)
  let styled = make_path
    ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
    ~stroke:(Some (make_stroke ~width:2.0 ~linecap:Round_cap (make_color 0.0 0.0 0.0)))
    [MoveTo (0.0, 0.0); LineTo (10.0, 10.0); ClosePath] in
  (match styled with
   | Path { fill; stroke; _ } ->
     (match fill with Some f -> assert (f.fill_color.r = 1.0) | None -> assert false);
     (match stroke with Some s -> assert (s.stroke_width = 2.0 && s.stroke_linecap = Round_cap) | None -> assert false)
   | _ -> assert false);

  (* Test text bounds *)
  let txt = make_text 10.0 30.0 "Hello" in
  let (x, y, w, h) = bounds txt in
  assert (x = 10.0 && y = 14.0 && w > 0.0 && h = 16.0);

  (* Test text attributes *)
  let txt2 = make_text ~font_family:"monospace" ~font_size:24.0 0.0 0.0 "Hi" in
  (match txt2 with Text { font_family; font_size; _ } -> assert (font_family = "monospace" && font_size = 24.0) | _ -> assert false);

  (* Test group bounds *)
  let g = make_group [r; el] in
  let (x, y, w, h) = bounds g in
  assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 55.0);

  (* Test empty group *)
  let eg = make_group [] in
  let (x, y, w, h) = bounds eg in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  (* Test nested group *)
  let inner = make_group [make_rect 10.0 10.0 5.0 5.0] in
  let outer = make_group [make_rect 0.0 0.0 1.0 1.0; inner] in
  let (x, y, w, h) = bounds outer in
  assert (x = 0.0 && y = 0.0 && w = 15.0 && h = 15.0);

  (* Test group with transform *)
  let gt = make_group ~transform:(Some (make_translate 100.0 200.0)) [make_rect 0.0 0.0 10.0 10.0] in
  (match gt with Group { transform; _ } ->
    (match transform with Some t -> assert (t.e = 100.0) | None -> assert false)
   | _ -> assert false);

  (* Test element opacity *)
  let ro = make_rect ~opacity:0.5 0.0 0.0 10.0 10.0 in
  (match ro with Rect { opacity; _ } -> assert (opacity = 0.5) | _ -> assert false);

  (* Test path with SmoothCurveTo *)
  let psc = make_path [MoveTo (0.0, 0.0); CurveTo (1.0, 2.0, 3.0, 4.0, 5.0, 6.0); SmoothCurveTo (8.0, 9.0, 10.0, 12.0)] in
  let (x, _, w, h) = bounds psc in
  assert (x = 0.0 && w = 10.0 && h = 12.0);

  (* Test path with QuadTo *)
  let pq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0)] in
  let (x, _, w, _) = bounds pq in
  assert (x = 0.0 && w = 10.0);

  (* Test path with SmoothQuadTo *)
  let psq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0); SmoothQuadTo (20.0, 5.0)] in
  let (x, _, w, _) = bounds psq in
  assert (x = 0.0 && w = 20.0);

  (* Test path with ArcTo *)
  let pa = make_path [MoveTo (0.0, 0.0); ArcTo (25.0, 25.0, 0.0, true, false, 50.0, 0.0)] in
  let (x, _, w, _) = bounds pa in
  assert (x = 0.0 && w = 50.0);

  (* Test empty polyline *)
  let epl = make_polyline [] in
  let (x, y, w, h) = bounds epl in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  (* Test empty polygon *)
  let epg = make_polygon [] in
  let (x, y, w, h) = bounds epg in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  (* Test reversed line coordinates *)
  let rl = make_line 10.0 20.0 0.0 0.0 in
  let (x, y, w, h) = bounds rl in
  assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0);

  (* Test circle with fill and stroke *)
  let cfs = make_circle
    ~fill:(Some (make_fill (make_color 0.0 1.0 0.0)))
    ~stroke:(Some (make_stroke ~width:3.0 (make_color 0.0 0.0 0.0)))
    50.0 50.0 25.0 in
  (match cfs with
   | Circle { fill; stroke; _ } ->
     (match fill with Some f -> assert (f.fill_color.g = 1.0) | None -> assert false);
     (match stroke with Some s -> assert (s.stroke_width = 3.0) | None -> assert false)
   | _ -> assert false);

  (* Test ellipse with fill and stroke *)
  let efs = make_ellipse
    ~fill:(Some (make_fill (make_color 0.0 0.0 1.0)))
    ~stroke:(Some (make_stroke ~linecap:Square (make_color 1.0 1.0 1.0)))
    50.0 50.0 25.0 15.0 in
  (match efs with
   | Ellipse { fill; stroke; _ } ->
     (match fill with Some f -> assert (f.fill_color.b = 1.0) | None -> assert false);
     (match stroke with Some s -> assert (s.stroke_linecap = Square) | None -> assert false)
   | _ -> assert false);

  (* Test transform rotate *)
  let tr = make_rotate 90.0 in
  assert (abs_float tr.a < 1e-10);
  assert (abs_float (tr.b -. 1.0) < 1e-10);

  (* Test group with all element types *)
  let all_types = make_group [
    make_line 0.0 0.0 10.0 10.0;
    make_rect 0.0 0.0 20.0 20.0;
    make_circle 50.0 50.0 10.0;
    make_ellipse 50.0 50.0 10.0 5.0;
    make_polyline [(0.0, 0.0); (10.0, 10.0)];
    make_polygon [(0.0, 0.0); (10.0, 0.0); (5.0, 10.0)];
    make_path [MoveTo (0.0, 0.0); LineTo (10.0, 10.0)];
    make_text 0.0 20.0 "test";
  ] in
  let (x, _, w, h) = bounds all_types in
  assert (x = 0.0 && w > 0.0 && h > 0.0);

  (* Test deeply nested groups (3 levels) *)
  let deep_inner = make_group [make_rect 10.0 10.0 5.0 5.0] in
  let deep_mid = make_group [make_rect 0.0 0.0 1.0 1.0; deep_inner] in
  let deep_outer = make_group [make_rect 20.0 20.0 3.0 3.0; deep_mid] in
  let (x, y, w, h) = bounds deep_outer in
  assert (x = 0.0 && y = 0.0 && w = 23.0 && h = 23.0);

  (* Test layer default name *)
  let layer = make_layer [make_rect 0.0 0.0 10.0 10.0] in
  (match layer with Layer { name; _ } -> assert (name = "Layer") | _ -> assert false);

  (* Test layer custom name *)
  let layer2 = make_layer ~name:"Background" [make_rect 0.0 0.0 10.0 10.0] in
  (match layer2 with Layer { name; _ } -> assert (name = "Background") | _ -> assert false);

  (* Test layer bounds *)
  let layer3 = make_layer ~name:"Shapes" [make_rect 0.0 0.0 10.0 10.0; make_circle 50.0 50.0 5.0] in
  let (x, y, w, h) = bounds layer3 in
  assert (x = 0.0 && y = 0.0 && w = 55.0 && h = 55.0);

  (* Test empty layer *)
  let layer4 = make_layer ~name:"Empty" [] in
  let (x, y, w, h) = bounds layer4 in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  Printf.printf "All element tests passed.\n"
