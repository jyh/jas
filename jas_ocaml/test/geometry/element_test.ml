let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  let open Jas.Element in
  Printf.printf "Element tests:\n";

  run_test "color construction" (fun () ->
    let c = make_color 1.0 0.0 0.0 in
    let (r, _, _, a) = color_to_rgba c in
    assert (r = 1.0 && a = 1.0);
    let c2 = make_color ~a:0.5 0.0 1.0 0.0 in
    assert (color_alpha c2 = 0.5));

  run_test "stroke defaults" (fun () ->
    let s = make_stroke (make_color 0.0 0.0 0.0) in
    assert (s.stroke_width = 1.0);
    assert (s.stroke_linecap = Butt);
    assert (s.stroke_linejoin = Miter));

  run_test "transform helpers" (fun () ->
    let t = identity_transform in
    assert (t.a = 1.0 && t.d = 1.0 && t.e = 0.0);
    let t2 = make_translate 10.0 20.0 in
    assert (t2.e = 10.0 && t2.f = 20.0);
    let t3 = make_scale 2.0 3.0 in
    assert (t3.a = 2.0 && t3.d = 3.0));

  run_test "line bounds" (fun () ->
    let ln = make_line 0.0 0.0 10.0 20.0 in
    let (x, y, w, h) = bounds ln in
    assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

  run_test "rect bounds" (fun () ->
    let r = make_rect 5.0 10.0 100.0 50.0 in
    let (x, y, w, h) = bounds r in
    assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 50.0));

  run_test "rect rounded corners" (fun () ->
    let rr = make_rect ~rx:2.0 ~ry:2.0 0.0 0.0 10.0 10.0 in
    match rr with Rect { rx; ry; _ } -> assert (rx = 2.0 && ry = 2.0) | _ -> assert false);

  run_test "circle bounds" (fun () ->
    let ci = make_circle 50.0 50.0 25.0 in
    let (x, y, w, h) = bounds ci in
    assert (x = 25.0 && y = 25.0 && w = 50.0 && h = 50.0));

  run_test "ellipse bounds" (fun () ->
    let el = make_ellipse 50.0 50.0 25.0 15.0 in
    let (x, y, w, h) = bounds el in
    assert (x = 25.0 && y = 35.0 && w = 50.0 && h = 30.0));

  run_test "polyline bounds" (fun () ->
    let pl = make_polyline [(0.0, 0.0); (10.0, 5.0); (20.0, 0.0)] in
    let (x, y, w, h) = bounds pl in
    assert (x = 0.0 && y = 0.0 && w = 20.0 && h = 5.0));

  run_test "polygon bounds" (fun () ->
    let pg = make_polygon [(0.0, 0.0); (10.0, 0.0); (5.0, 10.0)] in
    let (x, y, w, h) = bounds pg in
    assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 10.0));

  run_test "path with line commands" (fun () ->
    let p = make_path [MoveTo (0.0, 0.0); LineTo (10.0, 20.0); LineTo (5.0, 15.0); ClosePath] in
    let (x, y, w, h) = bounds p in
    assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

  run_test "path cubic bezier tight bounds" (fun () ->
    let p2 = make_path [MoveTo (0.0, 0.0); CurveTo (5.0, 10.0, 15.0, 10.0, 20.0, 0.0)] in
    let (x, _, w, h) = bounds p2 in
    assert (x = 0.0 && w = 20.0);
    assert (abs_float (h -. 7.5) < 1e-10));

  run_test "empty path" (fun () ->
    let ep = make_path [] in
    let (x, y, w, h) = bounds ep in
    assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

  run_test "path with fill and stroke" (fun () ->
    let styled = make_path
      ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
      ~stroke:(Some (make_stroke ~width:2.0 ~linecap:Round_cap (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (10.0, 10.0); ClosePath] in
    match styled with
    | Path { fill; stroke; _ } ->
      (match fill with Some f -> let (r, _, _, _) = color_to_rgba f.fill_color in assert (r = 1.0) | None -> assert false);
      (match stroke with Some s -> assert (s.stroke_width = 2.0 && s.stroke_linecap = Round_cap) | None -> assert false)
    | _ -> assert false);

  run_test "text bounds" (fun () ->
    let txt = make_text 10.0 30.0 "Hello" in
    let (x, y, w, h) = bounds txt in
    assert (x = 10.0 && y = 30.0 && w > 0.0 && h = 16.0));

  run_test "text bounds multi-line" (fun () ->
    let txt = make_text 0.0 0.0 "ab\ncde" in
    let (_, _, _, h) = bounds txt in
    assert (h = 32.0));

  run_test "text attributes" (fun () ->
    let txt2 = make_text ~font_family:"monospace" ~font_size:24.0 0.0 0.0 "Hi" in
    match txt2 with Text { font_family; font_size; _ } -> assert (font_family = "monospace" && font_size = 24.0) | _ -> assert false);

  run_test "group bounds" (fun () ->
    let r = make_rect 5.0 10.0 100.0 50.0 in
    let el = make_ellipse 50.0 50.0 25.0 15.0 in
    let g = make_group [|r; el|] in
    let (x, y, w, h) = bounds g in
    assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 55.0));

  run_test "empty group" (fun () ->
    let eg = make_group [||] in
    let (x, y, w, h) = bounds eg in
    assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

  run_test "nested group" (fun () ->
    let inner = make_group [|make_rect 10.0 10.0 5.0 5.0|] in
    let outer = make_group [|make_rect 0.0 0.0 1.0 1.0; inner|] in
    let (x, y, w, h) = bounds outer in
    assert (x = 0.0 && y = 0.0 && w = 15.0 && h = 15.0));

  run_test "group with transform" (fun () ->
    let gt = make_group ~transform:(Some (make_translate 100.0 200.0)) [|make_rect 0.0 0.0 10.0 10.0|] in
    match gt with Group { transform; _ } ->
      (match transform with Some t -> assert (t.e = 100.0) | None -> assert false)
    | _ -> assert false);

  run_test "element opacity" (fun () ->
    let ro = make_rect ~opacity:0.5 0.0 0.0 10.0 10.0 in
    match ro with Rect { opacity; _ } -> assert (opacity = 0.5) | _ -> assert false);

  run_test "path with SmoothCurveTo" (fun () ->
    let psc = make_path [MoveTo (0.0, 0.0); CurveTo (1.0, 2.0, 3.0, 4.0, 5.0, 6.0); SmoothCurveTo (8.0, 9.0, 10.0, 12.0)] in
    let (x, _, w, h) = bounds psc in
    assert (x = 0.0 && w = 10.0 && h = 12.0));

  run_test "path with QuadTo tight bounds" (fun () ->
    let pq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0)] in
    let (x, _, w, h) = bounds pq in
    assert (x = 0.0 && w = 10.0);
    assert (abs_float (h -. 5.0) < 1e-10));

  run_test "path with SmoothQuadTo" (fun () ->
    let psq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0); SmoothQuadTo (20.0, 5.0)] in
    let (x, _, w, h) = bounds psq in
    assert (x = 0.0 && w = 20.0);
    assert (abs_float (h -. 5.0) < 1e-10));

  run_test "path with ArcTo" (fun () ->
    let pa = make_path [MoveTo (0.0, 0.0); ArcTo (25.0, 25.0, 0.0, true, false, 50.0, 0.0)] in
    let (x, _, w, _) = bounds pa in
    assert (x = 0.0 && w = 50.0));

  run_test "empty polyline" (fun () ->
    let epl = make_polyline [] in
    let (x, y, w, h) = bounds epl in
    assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

  run_test "empty polygon" (fun () ->
    let epg = make_polygon [] in
    let (x, y, w, h) = bounds epg in
    assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

  run_test "reversed line coordinates" (fun () ->
    let rl = make_line 10.0 20.0 0.0 0.0 in
    let (x, y, w, h) = bounds rl in
    assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

  run_test "circle with fill and stroke" (fun () ->
    let cfs = make_circle
      ~fill:(Some (make_fill (make_color 0.0 1.0 0.0)))
      ~stroke:(Some (make_stroke ~width:3.0 (make_color 0.0 0.0 0.0)))
      50.0 50.0 25.0 in
    match cfs with
    | Circle { fill; stroke; _ } ->
      (match fill with Some f -> let (_, g, _, _) = color_to_rgba f.fill_color in assert (g = 1.0) | None -> assert false);
      (match stroke with Some s -> assert (s.stroke_width = 3.0) | None -> assert false)
    | _ -> assert false);

  run_test "ellipse with fill and stroke" (fun () ->
    let efs = make_ellipse
      ~fill:(Some (make_fill (make_color 0.0 0.0 1.0)))
      ~stroke:(Some (make_stroke ~linecap:Square (make_color 1.0 1.0 1.0)))
      50.0 50.0 25.0 15.0 in
    match efs with
    | Ellipse { fill; stroke; _ } ->
      (match fill with Some f -> let (_, _, b, _) = color_to_rgba f.fill_color in assert (b = 1.0) | None -> assert false);
      (match stroke with Some s -> assert (s.stroke_linecap = Square) | None -> assert false)
    | _ -> assert false);

  run_test "transform rotate" (fun () ->
    let tr = make_rotate 90.0 in
    assert (abs_float tr.a < 1e-10);
    assert (abs_float (tr.b -. 1.0) < 1e-10));

  run_test "group with all element types" (fun () ->
    let all_types = make_group [|
      make_line 0.0 0.0 10.0 10.0;
      make_rect 0.0 0.0 20.0 20.0;
      make_circle 50.0 50.0 10.0;
      make_ellipse 50.0 50.0 10.0 5.0;
      make_polyline [(0.0, 0.0); (10.0, 10.0)];
      make_polygon [(0.0, 0.0); (10.0, 0.0); (5.0, 10.0)];
      make_path [MoveTo (0.0, 0.0); LineTo (10.0, 10.0)];
      make_text 0.0 20.0 "test";
    |] in
    let (x, _, w, h) = bounds all_types in
    assert (x = 0.0 && w > 0.0 && h > 0.0));

  run_test "deeply nested groups" (fun () ->
    let deep_inner = make_group [|make_rect 10.0 10.0 5.0 5.0|] in
    let deep_mid = make_group [|make_rect 0.0 0.0 1.0 1.0; deep_inner|] in
    let deep_outer = make_group [|make_rect 20.0 20.0 3.0 3.0; deep_mid|] in
    let (x, y, w, h) = bounds deep_outer in
    assert (x = 0.0 && y = 0.0 && w = 23.0 && h = 23.0));

  run_test "layer default name" (fun () ->
    let layer = make_layer [|make_rect 0.0 0.0 10.0 10.0|] in
    match layer with Layer { name; _ } -> assert (name = "Layer") | _ -> assert false);

  run_test "layer custom name" (fun () ->
    let layer2 = make_layer ~name:"Background" [|make_rect 0.0 0.0 10.0 10.0|] in
    match layer2 with Layer { name; _ } -> assert (name = "Background") | _ -> assert false);

  run_test "layer bounds" (fun () ->
    let layer3 = make_layer ~name:"Shapes" [|make_rect 0.0 0.0 10.0 10.0; make_circle 50.0 50.0 5.0|] in
    let (x, y, w, h) = bounds layer3 in
    assert (x = 0.0 && y = 0.0 && w = 55.0 && h = 55.0));

  run_test "empty layer" (fun () ->
    let layer4 = make_layer ~name:"Empty" [||] in
    let (x, y, w, h) = bounds layer4 in
    assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

  (* Path offset tests *)
  let eps = 1e-6 in
  let straight = [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)] in

  run_test "point_at_offset start" (fun () ->
    let (px, py) = path_point_at_offset straight 0.0 in
    assert (abs_float px < eps && abs_float py < eps));

  run_test "point_at_offset end" (fun () ->
    let (px, py) = path_point_at_offset straight 1.0 in
    assert (abs_float (px -. 100.0) < eps && abs_float py < eps));

  run_test "point_at_offset midpoint" (fun () ->
    let (px, py) = path_point_at_offset straight 0.5 in
    assert (abs_float (px -. 50.0) < eps && abs_float py < eps));

  run_test "point_at_offset clamped below" (fun () ->
    let (px, py) = path_point_at_offset straight (-1.0) in
    assert (abs_float px < eps && abs_float py < eps));

  run_test "point_at_offset clamped above" (fun () ->
    let (px, py) = path_point_at_offset straight 2.0 in
    assert (abs_float (px -. 100.0) < eps && abs_float py < eps));

  run_test "point_at_offset multi-segment L-shape" (fun () ->
    let lpath = [MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (100.0, 100.0)] in
    let (px, py) = path_point_at_offset lpath 0.5 in
    assert (abs_float (px -. 100.0) < 1.0 && abs_float py < 1.0));

  run_test "closest_offset point on line" (fun () ->
    let off = path_closest_offset straight 50.0 0.0 in
    assert (abs_float (off -. 0.5) < 0.01));

  run_test "closest_offset start" (fun () ->
    let off = path_closest_offset straight (-10.0) 0.0 in
    assert (abs_float off < 0.01));

  run_test "closest_offset end" (fun () ->
    let off = path_closest_offset straight 200.0 0.0 in
    assert (abs_float (off -. 1.0) < 0.01));

  run_test "closest_offset perpendicular to midpoint" (fun () ->
    let off = path_closest_offset straight 50.0 30.0 in
    assert (abs_float (off -. 0.5) < 0.01));

  run_test "distance_to_point on path" (fun () ->
    let d = path_distance_to_point straight 50.0 0.0 in
    assert (d < eps));

  run_test "distance_to_point perpendicular" (fun () ->
    let d = path_distance_to_point straight 50.0 30.0 in
    assert (abs_float (d -. 30.0) < eps));

  (* ---- Color conversion tests ---- *)

  run_test "rgb to rgba identity" (fun () ->
    let c = color_rgb 0.5 0.6 0.7 in
    let (r, g, b, a) = color_to_rgba c in
    assert (r = 0.5 && g = 0.6 && b = 0.7 && a = 1.0));

  run_test "color_alpha on all variants" (fun () ->
    assert (color_alpha (Rgb { r = 0.; g = 0.; b = 0.; a = 0.3 }) = 0.3);
    assert (color_alpha (Hsb { h = 0.; s = 0.; b = 0.; a = 0.5 }) = 0.5);
    assert (color_alpha (Cmyk { c = 0.; m = 0.; y = 0.; k = 0.; a = 0.7 }) = 0.7));

  run_test "black and white constants" (fun () ->
    let (r, g, b, a) = color_to_rgba black in
    assert (r = 0. && g = 0. && b = 0. && a = 1.);
    let (r, g, b, a) = color_to_rgba white in
    assert (r = 1. && g = 1. && b = 1. && a = 1.));

  run_test "hsb black to rgba" (fun () ->
    let (_, _, _, a) = color_to_hsba black in
    let (h, s, br, _) = color_to_hsba black in
    assert (h = 0. && s = 0. && br = 0. && a = 1.));

  run_test "hsb white to hsba" (fun () ->
    let (h, s, br, a) = color_to_hsba white in
    assert (h = 0. && s = 0. && br = 1. && a = 1.));

  run_test "hsb pure red" (fun () ->
    let (h, s, br, _) = color_to_hsba (color_rgb 1.0 0.0 0.0) in
    assert (abs_float h < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

  run_test "hsb pure green" (fun () ->
    let (h, s, br, _) = color_to_hsba (color_rgb 0.0 1.0 0.0) in
    assert (abs_float (h -. 120.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

  run_test "hsb pure blue" (fun () ->
    let (h, s, br, _) = color_to_hsba (color_rgb 0.0 0.0 1.0) in
    assert (abs_float (h -. 240.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

  run_test "hsb yellow" (fun () ->
    let (h, s, br, _) = color_to_hsba (color_rgb 1.0 1.0 0.0) in
    assert (abs_float (h -. 60.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

  run_test "hsb(0, 1, 1) -> red" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_hsb 0.0 1.0 1.0) in
    assert (abs_float (r -. 1.0) < eps && abs_float g < eps && abs_float b < eps));

  run_test "hsb(120, 1, 1) -> green" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_hsb 120.0 1.0 1.0) in
    assert (abs_float r < eps && abs_float (g -. 1.0) < eps && abs_float b < eps));

  run_test "hsb(240, 1, 1) -> blue" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_hsb 240.0 1.0 1.0) in
    assert (abs_float r < eps && abs_float g < eps && abs_float (b -. 1.0) < eps));

  run_test "hsb(0, 0, 0) -> black" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_hsb 0.0 0.0 0.0) in
    assert (abs_float r < eps && abs_float g < eps && abs_float b < eps));

  run_test "hsb(0, 0, 1) -> white" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_hsb 0.0 0.0 1.0) in
    assert (abs_float (r -. 1.0) < eps && abs_float (g -. 1.0) < eps && abs_float (b -. 1.0) < eps));

  run_test "cmyk black" (fun () ->
    let (c, m, y, k, _) = color_to_cmyka black in
    assert (c = 0. && m = 0. && y = 0. && abs_float (k -. 1.0) < eps));

  run_test "cmyk white" (fun () ->
    let (c, m, y, k, _) = color_to_cmyka white in
    assert (abs_float c < eps && abs_float m < eps && abs_float y < eps && abs_float k < eps));

  run_test "cmyk pure red" (fun () ->
    let (c, m, y, k, _) = color_to_cmyka (color_rgb 1.0 0.0 0.0) in
    assert (abs_float c < eps && abs_float (m -. 1.0) < eps && abs_float (y -. 1.0) < eps && abs_float k < eps));

  run_test "cmyk(0,0,0,1) -> black" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 0.0 0.0 1.0) in
    assert (abs_float r < eps && abs_float g < eps && abs_float b < eps));

  run_test "cmyk(0,0,0,0) -> white" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 0.0 0.0 0.0) in
    assert (abs_float (r -. 1.0) < eps && abs_float (g -. 1.0) < eps && abs_float (b -. 1.0) < eps));

  run_test "cmyk(0,1,1,0) -> red" (fun () ->
    let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 1.0 1.0 0.0) in
    assert (abs_float (r -. 1.0) < eps && abs_float g < eps && abs_float b < eps));

  run_test "rgb -> hsb -> rgb roundtrip" (fun () ->
    let orig = color_rgb 0.3 0.6 0.9 in
    let (h, s, br, a) = color_to_hsba orig in
    let back = Hsb { h; s; b = br; a } in
    let (r, g, b, _) = color_to_rgba back in
    let (r0, g0, b0, _) = color_to_rgba orig in
    assert (abs_float (r -. r0) < eps && abs_float (g -. g0) < eps && abs_float (b -. b0) < eps));

  run_test "rgb -> cmyk -> rgb roundtrip" (fun () ->
    let orig = color_rgb 0.3 0.6 0.9 in
    let (c, m, y, k, a) = color_to_cmyka orig in
    let back = Cmyk { c; m; y; k; a } in
    let (r, g, b, _) = color_to_rgba back in
    let (r0, g0, b0, _) = color_to_rgba orig in
    assert (abs_float (r -. r0) < eps && abs_float (g -. g0) < eps && abs_float (b -. b0) < eps));

  run_test "hsb -> rgb -> hsb roundtrip" (fun () ->
    let orig = color_hsb 210.0 0.67 0.9 in
    let (r, g, b, a) = color_to_rgba orig in
    let back = Rgb { r; g; b; a } in
    let (h, s, br, _) = color_to_hsba back in
    let (h0, s0, br0, _) = color_to_hsba orig in
    assert (abs_float (h -. h0) < eps && abs_float (s -. s0) < eps && abs_float (br -. br0) < eps));

  run_test "rgb -> cmyk -> rgb roundtrip (via cmyk)" (fun () ->
    let orig = color_rgb 0.5 0.7 0.2 in
    let (c, m, y, k, a) = color_to_cmyka orig in
    let back = Cmyk { c; m; y; k; a } in
    let (r1, g1, b1, _) = color_to_rgba orig in
    let (r2, g2, b2, _) = color_to_rgba back in
    assert (abs_float (r1 -. r2) < eps && abs_float (g1 -. g2) < eps && abs_float (b1 -. b2) < eps));

  run_test "alpha preserved through rgb constructor" (fun () ->
    let c = make_color ~a:0.42 0.1 0.2 0.3 in
    let (_, _, _, a) = color_to_rgba c in
    assert (abs_float (a -. 0.42) < eps));

  run_test "hsb identity to hsba" (fun () ->
    let c = Hsb { h = 123.0; s = 0.45; b = 0.67; a = 0.89 } in
    let (h, s, br, a) = color_to_hsba c in
    assert (h = 123.0 && s = 0.45 && br = 0.67 && a = 0.89));

  run_test "cmyk identity to cmyka" (fun () ->
    let c = Cmyk { c = 0.1; m = 0.2; y = 0.3; k = 0.4; a = 0.5 } in
    let (cv, m, y, k, a) = color_to_cmyka c in
    assert (cv = 0.1 && m = 0.2 && y = 0.3 && k = 0.4 && a = 0.5));

  (* ---- with_fill / with_stroke tests ---- *)

  run_test "with_fill sets fill on rect" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
    let r2 = with_fill r f in
    match r2 with
    | Rect { fill = Some { fill_color; _ }; _ } ->
      let (rv, _, _, _) = color_to_rgba fill_color in
      assert (rv = 1.0)
    | _ -> assert false);

  run_test "with_fill on Line is noop" (fun () ->
    let ln = make_line 0.0 0.0 10.0 10.0 in
    let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
    let ln2 = with_fill ln f in
    (match ln2 with Line _ -> () | _ -> assert false));

  run_test "with_stroke sets stroke on path" (fun () ->
    let p = make_path [MoveTo (0.0, 0.0); LineTo (10.0, 10.0)] in
    let s = Some (make_stroke ~width:3.0 (color_rgb 0.0 0.0 1.0)) in
    let p2 = with_stroke p s in
    match p2 with
    | Path { stroke = Some { stroke_width; _ }; _ } ->
      assert (stroke_width = 3.0)
    | _ -> assert false);

  run_test "with_fill on Group is noop" (fun () ->
    let g = make_group [|make_rect 0.0 0.0 5.0 5.0|] in
    let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
    let g2 = with_fill g f in
    (match g2 with Group _ -> () | _ -> assert false));

  run_test "with_stroke on Layer is noop" (fun () ->
    let l = make_layer [|make_rect 0.0 0.0 5.0 5.0|] in
    let s = Some (make_stroke (color_rgb 1.0 0.0 0.0)) in
    let l2 = with_stroke l s in
    (match l2 with Layer _ -> () | _ -> assert false));

  (* ---- color_to_hex / color_from_hex tests ---- *)

  run_test "color_to_hex black -> 000000" (fun () ->
    assert (color_to_hex black = "000000"));

  run_test "color_to_hex red -> ff0000" (fun () ->
    assert (color_to_hex (color_rgb 1.0 0.0 0.0) = "ff0000"));

  run_test "color_to_hex white -> ffffff" (fun () ->
    assert (color_to_hex white = "ffffff"));

  run_test "color_from_hex valid" (fun () ->
    match color_from_hex "ff0000" with
    | Some c ->
      let (r, g, b, _) = color_to_rgba c in
      assert (abs_float (r -. 1.0) < 0.01 && abs_float g < 0.01 && abs_float b < 0.01)
    | None -> assert false);

  run_test "color_from_hex with # prefix" (fun () ->
    match color_from_hex "#00ff00" with
    | Some c ->
      let (r, g, b, _) = color_to_rgba c in
      assert (abs_float r < 0.01 && abs_float (g -. 1.0) < 0.01 && abs_float b < 0.01)
    | None -> assert false);

  run_test "color_from_hex invalid returns None" (fun () ->
    assert (color_from_hex "xyz" = None);
    assert (color_from_hex "gggggg" = None);
    assert (color_from_hex "" = None));

  run_test "hex roundtrip" (fun () ->
    let c = color_rgb 0.2 0.4 0.6 in
    let hex = color_to_hex c in
    match color_from_hex hex with
    | Some c2 ->
      let (r1, g1, b1, _) = color_to_rgba c in
      let (r2, g2, b2, _) = color_to_rgba c2 in
      assert (abs_float (r1 -. r2) < 0.01 &&
              abs_float (g1 -. g2) < 0.01 &&
              abs_float (b1 -. b2) < 0.01)
    | None -> assert false);

  Printf.printf "All element tests passed.\n"
