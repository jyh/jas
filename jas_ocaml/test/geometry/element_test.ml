open Jas.Element

let eps = 1e-6
let straight = [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)]

let () =
  Alcotest.run "Element" [
    "element", [
      Alcotest.test_case "color construction" `Quick (fun () ->
        let c = make_color 1.0 0.0 0.0 in
        let (r, _, _, a) = color_to_rgba c in
        assert (r = 1.0 && a = 1.0);
        let c2 = make_color ~a:0.5 0.0 1.0 0.0 in
        assert (color_alpha c2 = 0.5));

      Alcotest.test_case "stroke defaults" `Quick (fun () ->
        let s = make_stroke (make_color 0.0 0.0 0.0) in
        assert (s.stroke_width = 1.0);
        assert (s.stroke_linecap = Butt);
        assert (s.stroke_linejoin = Miter));

      Alcotest.test_case "transform helpers" `Quick (fun () ->
        let t = identity_transform in
        assert (t.a = 1.0 && t.d = 1.0 && t.e = 0.0);
        let t2 = make_translate 10.0 20.0 in
        assert (t2.e = 10.0 && t2.f = 20.0);
        let t3 = make_scale 2.0 3.0 in
        assert (t3.a = 2.0 && t3.d = 3.0));

      Alcotest.test_case "line bounds" `Quick (fun () ->
        let ln = make_line 0.0 0.0 10.0 20.0 in
        let (x, y, w, h) = bounds ln in
        assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

      Alcotest.test_case "rect bounds" `Quick (fun () ->
        let r = make_rect 5.0 10.0 100.0 50.0 in
        let (x, y, w, h) = bounds r in
        assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 50.0));

      Alcotest.test_case "rect rounded corners" `Quick (fun () ->
        let rr = make_rect ~rx:2.0 ~ry:2.0 0.0 0.0 10.0 10.0 in
        match rr with Rect { rx; ry; _ } -> assert (rx = 2.0 && ry = 2.0) | _ -> assert false);

      Alcotest.test_case "circle bounds" `Quick (fun () ->
        let ci = make_circle 50.0 50.0 25.0 in
        let (x, y, w, h) = bounds ci in
        assert (x = 25.0 && y = 25.0 && w = 50.0 && h = 50.0));

      Alcotest.test_case "ellipse bounds" `Quick (fun () ->
        let el = make_ellipse 50.0 50.0 25.0 15.0 in
        let (x, y, w, h) = bounds el in
        assert (x = 25.0 && y = 35.0 && w = 50.0 && h = 30.0));

      Alcotest.test_case "polyline bounds" `Quick (fun () ->
        let pl = make_polyline [(0.0, 0.0); (10.0, 5.0); (20.0, 0.0)] in
        let (x, y, w, h) = bounds pl in
        assert (x = 0.0 && y = 0.0 && w = 20.0 && h = 5.0));

      Alcotest.test_case "polygon bounds" `Quick (fun () ->
        let pg = make_polygon [(0.0, 0.0); (10.0, 0.0); (5.0, 10.0)] in
        let (x, y, w, h) = bounds pg in
        assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 10.0));

      Alcotest.test_case "path with line commands" `Quick (fun () ->
        let p = make_path [MoveTo (0.0, 0.0); LineTo (10.0, 20.0); LineTo (5.0, 15.0); ClosePath] in
        let (x, y, w, h) = bounds p in
        assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

      Alcotest.test_case "path cubic bezier tight bounds" `Quick (fun () ->
        let p2 = make_path [MoveTo (0.0, 0.0); CurveTo (5.0, 10.0, 15.0, 10.0, 20.0, 0.0)] in
        let (x, _, w, h) = bounds p2 in
        assert (x = 0.0 && w = 20.0);
        assert (abs_float (h -. 7.5) < 1e-10));

      Alcotest.test_case "empty path" `Quick (fun () ->
        let ep = make_path [] in
        let (x, y, w, h) = bounds ep in
        assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

      Alcotest.test_case "path with fill and stroke" `Quick (fun () ->
        let styled = make_path
          ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
          ~stroke:(Some (make_stroke ~width:2.0 ~linecap:Round_cap (make_color 0.0 0.0 0.0)))
          [MoveTo (0.0, 0.0); LineTo (10.0, 10.0); ClosePath] in
        match styled with
        | Path { fill; stroke; _ } ->
          (match fill with Some f -> let (r, _, _, _) = color_to_rgba f.fill_color in assert (r = 1.0) | None -> assert false);
          (match stroke with Some s -> assert (s.stroke_width = 2.0 && s.stroke_linecap = Round_cap) | None -> assert false)
        | _ -> assert false);

      Alcotest.test_case "text bounds" `Quick (fun () ->
        let txt = make_text 10.0 30.0 "Hello" in
        let (x, y, w, h) = bounds txt in
        assert (x = 10.0 && y = 30.0 && w > 0.0 && h = 16.0));

      Alcotest.test_case "text bounds multi-line" `Quick (fun () ->
        let txt = make_text 0.0 0.0 "ab\ncde" in
        let (_, _, _, h) = bounds txt in
        assert (h = 32.0));

      Alcotest.test_case "text attributes" `Quick (fun () ->
        let txt2 = make_text ~font_family:"monospace" ~font_size:24.0 0.0 0.0 "Hi" in
        match txt2 with Text { font_family; font_size; _ } -> assert (font_family = "monospace" && font_size = 24.0) | _ -> assert false);

      Alcotest.test_case "group bounds" `Quick (fun () ->
        let r = make_rect 5.0 10.0 100.0 50.0 in
        let el = make_ellipse 50.0 50.0 25.0 15.0 in
        let g = make_group [|r; el|] in
        let (x, y, w, h) = bounds g in
        assert (x = 5.0 && y = 10.0 && w = 100.0 && h = 55.0));

      Alcotest.test_case "empty group" `Quick (fun () ->
        let eg = make_group [||] in
        let (x, y, w, h) = bounds eg in
        assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

      Alcotest.test_case "nested group" `Quick (fun () ->
        let inner = make_group [|make_rect 10.0 10.0 5.0 5.0|] in
        let outer = make_group [|make_rect 0.0 0.0 1.0 1.0; inner|] in
        let (x, y, w, h) = bounds outer in
        assert (x = 0.0 && y = 0.0 && w = 15.0 && h = 15.0));

      Alcotest.test_case "group with transform" `Quick (fun () ->
        let gt = make_group ~transform:(Some (make_translate 100.0 200.0)) [|make_rect 0.0 0.0 10.0 10.0|] in
        match gt with Group { transform; _ } ->
          (match transform with Some t -> assert (t.e = 100.0) | None -> assert false)
        | _ -> assert false);

      Alcotest.test_case "element opacity" `Quick (fun () ->
        let ro = make_rect ~opacity:0.5 0.0 0.0 10.0 10.0 in
        match ro with Rect { opacity; _ } -> assert (opacity = 0.5) | _ -> assert false);

      Alcotest.test_case "path with SmoothCurveTo" `Quick (fun () ->
        let psc = make_path [MoveTo (0.0, 0.0); CurveTo (1.0, 2.0, 3.0, 4.0, 5.0, 6.0); SmoothCurveTo (8.0, 9.0, 10.0, 12.0)] in
        let (x, _, w, h) = bounds psc in
        assert (x = 0.0 && w = 10.0 && h = 12.0));

      Alcotest.test_case "path with QuadTo tight bounds" `Quick (fun () ->
        let pq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0)] in
        let (x, _, w, h) = bounds pq in
        assert (x = 0.0 && w = 10.0);
        assert (abs_float (h -. 5.0) < 1e-10));

      Alcotest.test_case "path with SmoothQuadTo" `Quick (fun () ->
        let psq = make_path [MoveTo (0.0, 0.0); QuadTo (5.0, 10.0, 10.0, 0.0); SmoothQuadTo (20.0, 5.0)] in
        let (x, _, w, h) = bounds psq in
        assert (x = 0.0 && w = 20.0);
        assert (abs_float (h -. 5.0) < 1e-10));

      Alcotest.test_case "path with ArcTo" `Quick (fun () ->
        let pa = make_path [MoveTo (0.0, 0.0); ArcTo (25.0, 25.0, 0.0, true, false, 50.0, 0.0)] in
        let (x, _, w, _) = bounds pa in
        assert (x = 0.0 && w = 50.0));

      Alcotest.test_case "empty polyline" `Quick (fun () ->
        let epl = make_polyline [] in
        let (x, y, w, h) = bounds epl in
        assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

      Alcotest.test_case "empty polygon" `Quick (fun () ->
        let epg = make_polygon [] in
        let (x, y, w, h) = bounds epg in
        assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

      Alcotest.test_case "reversed line coordinates" `Quick (fun () ->
        let rl = make_line 10.0 20.0 0.0 0.0 in
        let (x, y, w, h) = bounds rl in
        assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 20.0));

      Alcotest.test_case "circle with fill and stroke" `Quick (fun () ->
        let cfs = make_circle
          ~fill:(Some (make_fill (make_color 0.0 1.0 0.0)))
          ~stroke:(Some (make_stroke ~width:3.0 (make_color 0.0 0.0 0.0)))
          50.0 50.0 25.0 in
        match cfs with
        | Circle { fill; stroke; _ } ->
          (match fill with Some f -> let (_, g, _, _) = color_to_rgba f.fill_color in assert (g = 1.0) | None -> assert false);
          (match stroke with Some s -> assert (s.stroke_width = 3.0) | None -> assert false)
        | _ -> assert false);

      Alcotest.test_case "ellipse with fill and stroke" `Quick (fun () ->
        let efs = make_ellipse
          ~fill:(Some (make_fill (make_color 0.0 0.0 1.0)))
          ~stroke:(Some (make_stroke ~linecap:Square (make_color 1.0 1.0 1.0)))
          50.0 50.0 25.0 15.0 in
        match efs with
        | Ellipse { fill; stroke; _ } ->
          (match fill with Some f -> let (_, _, b, _) = color_to_rgba f.fill_color in assert (b = 1.0) | None -> assert false);
          (match stroke with Some s -> assert (s.stroke_linecap = Square) | None -> assert false)
        | _ -> assert false);

      Alcotest.test_case "transform rotate" `Quick (fun () ->
        let tr = make_rotate 90.0 in
        assert (abs_float tr.a < 1e-10);
        assert (abs_float (tr.b -. 1.0) < 1e-10));

      Alcotest.test_case "group with all element types" `Quick (fun () ->
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

      Alcotest.test_case "deeply nested groups" `Quick (fun () ->
        let deep_inner = make_group [|make_rect 10.0 10.0 5.0 5.0|] in
        let deep_mid = make_group [|make_rect 0.0 0.0 1.0 1.0; deep_inner|] in
        let deep_outer = make_group [|make_rect 20.0 20.0 3.0 3.0; deep_mid|] in
        let (x, y, w, h) = bounds deep_outer in
        assert (x = 0.0 && y = 0.0 && w = 23.0 && h = 23.0));

      Alcotest.test_case "layer default name" `Quick (fun () ->
        let layer = make_layer [|make_rect 0.0 0.0 10.0 10.0|] in
        match layer with Layer { name; _ } -> assert (name = "Layer") | _ -> assert false);

      Alcotest.test_case "layer custom name" `Quick (fun () ->
        let layer2 = make_layer ~name:"Background" [|make_rect 0.0 0.0 10.0 10.0|] in
        match layer2 with Layer { name; _ } -> assert (name = "Background") | _ -> assert false);

      Alcotest.test_case "layer bounds" `Quick (fun () ->
        let layer3 = make_layer ~name:"Shapes" [|make_rect 0.0 0.0 10.0 10.0; make_circle 50.0 50.0 5.0|] in
        let (x, y, w, h) = bounds layer3 in
        assert (x = 0.0 && y = 0.0 && w = 55.0 && h = 55.0));

      Alcotest.test_case "empty layer" `Quick (fun () ->
        let layer4 = make_layer ~name:"Empty" [||] in
        let (x, y, w, h) = bounds layer4 in
        assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0));

      (* Path offset tests *)

      Alcotest.test_case "point_at_offset start" `Quick (fun () ->
        let (px, py) = path_point_at_offset straight 0.0 in
        assert (abs_float px < eps && abs_float py < eps));

      Alcotest.test_case "point_at_offset end" `Quick (fun () ->
        let (px, py) = path_point_at_offset straight 1.0 in
        assert (abs_float (px -. 100.0) < eps && abs_float py < eps));

      Alcotest.test_case "point_at_offset midpoint" `Quick (fun () ->
        let (px, py) = path_point_at_offset straight 0.5 in
        assert (abs_float (px -. 50.0) < eps && abs_float py < eps));

      Alcotest.test_case "point_at_offset clamped below" `Quick (fun () ->
        let (px, py) = path_point_at_offset straight (-1.0) in
        assert (abs_float px < eps && abs_float py < eps));

      Alcotest.test_case "point_at_offset clamped above" `Quick (fun () ->
        let (px, py) = path_point_at_offset straight 2.0 in
        assert (abs_float (px -. 100.0) < eps && abs_float py < eps));

      Alcotest.test_case "point_at_offset multi-segment L-shape" `Quick (fun () ->
        let lpath = [MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (100.0, 100.0)] in
        let (px, py) = path_point_at_offset lpath 0.5 in
        assert (abs_float (px -. 100.0) < 1.0 && abs_float py < 1.0));

      Alcotest.test_case "closest_offset point on line" `Quick (fun () ->
        let off = path_closest_offset straight 50.0 0.0 in
        assert (abs_float (off -. 0.5) < 0.01));

      Alcotest.test_case "closest_offset start" `Quick (fun () ->
        let off = path_closest_offset straight (-10.0) 0.0 in
        assert (abs_float off < 0.01));

      Alcotest.test_case "closest_offset end" `Quick (fun () ->
        let off = path_closest_offset straight 200.0 0.0 in
        assert (abs_float (off -. 1.0) < 0.01));

      Alcotest.test_case "closest_offset perpendicular to midpoint" `Quick (fun () ->
        let off = path_closest_offset straight 50.0 30.0 in
        assert (abs_float (off -. 0.5) < 0.01));

      Alcotest.test_case "distance_to_point on path" `Quick (fun () ->
        let d = path_distance_to_point straight 50.0 0.0 in
        assert (d < eps));

      Alcotest.test_case "distance_to_point perpendicular" `Quick (fun () ->
        let d = path_distance_to_point straight 50.0 30.0 in
        assert (abs_float (d -. 30.0) < eps));

      (* ---- Color conversion tests ---- *)

      Alcotest.test_case "rgb to rgba identity" `Quick (fun () ->
        let c = color_rgb 0.5 0.6 0.7 in
        let (r, g, b, a) = color_to_rgba c in
        assert (r = 0.5 && g = 0.6 && b = 0.7 && a = 1.0));

      Alcotest.test_case "color_alpha on all variants" `Quick (fun () ->
        assert (color_alpha (Rgb { r = 0.; g = 0.; b = 0.; a = 0.3 }) = 0.3);
        assert (color_alpha (Hsb { h = 0.; s = 0.; b = 0.; a = 0.5 }) = 0.5);
        assert (color_alpha (Cmyk { c = 0.; m = 0.; y = 0.; k = 0.; a = 0.7 }) = 0.7));

      Alcotest.test_case "black and white constants" `Quick (fun () ->
        let (r, g, b, a) = color_to_rgba black in
        assert (r = 0. && g = 0. && b = 0. && a = 1.);
        let (r, g, b, a) = color_to_rgba white in
        assert (r = 1. && g = 1. && b = 1. && a = 1.));

      Alcotest.test_case "hsb black to rgba" `Quick (fun () ->
        let (_, _, _, a) = color_to_hsba black in
        let (h, s, br, _) = color_to_hsba black in
        assert (h = 0. && s = 0. && br = 0. && a = 1.));

      Alcotest.test_case "hsb white to hsba" `Quick (fun () ->
        let (h, s, br, a) = color_to_hsba white in
        assert (h = 0. && s = 0. && br = 1. && a = 1.));

      Alcotest.test_case "hsb pure red" `Quick (fun () ->
        let (h, s, br, _) = color_to_hsba (color_rgb 1.0 0.0 0.0) in
        assert (abs_float h < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

      Alcotest.test_case "hsb pure green" `Quick (fun () ->
        let (h, s, br, _) = color_to_hsba (color_rgb 0.0 1.0 0.0) in
        assert (abs_float (h -. 120.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

      Alcotest.test_case "hsb pure blue" `Quick (fun () ->
        let (h, s, br, _) = color_to_hsba (color_rgb 0.0 0.0 1.0) in
        assert (abs_float (h -. 240.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

      Alcotest.test_case "hsb yellow" `Quick (fun () ->
        let (h, s, br, _) = color_to_hsba (color_rgb 1.0 1.0 0.0) in
        assert (abs_float (h -. 60.0) < eps && abs_float (s -. 1.0) < eps && abs_float (br -. 1.0) < eps));

      Alcotest.test_case "hsb(0, 1, 1) -> red" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_hsb 0.0 1.0 1.0) in
        assert (abs_float (r -. 1.0) < eps && abs_float g < eps && abs_float b < eps));

      Alcotest.test_case "hsb(120, 1, 1) -> green" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_hsb 120.0 1.0 1.0) in
        assert (abs_float r < eps && abs_float (g -. 1.0) < eps && abs_float b < eps));

      Alcotest.test_case "hsb(240, 1, 1) -> blue" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_hsb 240.0 1.0 1.0) in
        assert (abs_float r < eps && abs_float g < eps && abs_float (b -. 1.0) < eps));

      Alcotest.test_case "hsb(0, 0, 0) -> black" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_hsb 0.0 0.0 0.0) in
        assert (abs_float r < eps && abs_float g < eps && abs_float b < eps));

      Alcotest.test_case "hsb(0, 0, 1) -> white" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_hsb 0.0 0.0 1.0) in
        assert (abs_float (r -. 1.0) < eps && abs_float (g -. 1.0) < eps && abs_float (b -. 1.0) < eps));

      Alcotest.test_case "cmyk black" `Quick (fun () ->
        let (c, m, y, k, _) = color_to_cmyka black in
        assert (c = 0. && m = 0. && y = 0. && abs_float (k -. 1.0) < eps));

      Alcotest.test_case "cmyk white" `Quick (fun () ->
        let (c, m, y, k, _) = color_to_cmyka white in
        assert (abs_float c < eps && abs_float m < eps && abs_float y < eps && abs_float k < eps));

      Alcotest.test_case "cmyk pure red" `Quick (fun () ->
        let (c, m, y, k, _) = color_to_cmyka (color_rgb 1.0 0.0 0.0) in
        assert (abs_float c < eps && abs_float (m -. 1.0) < eps && abs_float (y -. 1.0) < eps && abs_float k < eps));

      Alcotest.test_case "cmyk(0,0,0,1) -> black" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 0.0 0.0 1.0) in
        assert (abs_float r < eps && abs_float g < eps && abs_float b < eps));

      Alcotest.test_case "cmyk(0,0,0,0) -> white" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 0.0 0.0 0.0) in
        assert (abs_float (r -. 1.0) < eps && abs_float (g -. 1.0) < eps && abs_float (b -. 1.0) < eps));

      Alcotest.test_case "cmyk(0,1,1,0) -> red" `Quick (fun () ->
        let (r, g, b, _) = color_to_rgba (color_cmyk 0.0 1.0 1.0 0.0) in
        assert (abs_float (r -. 1.0) < eps && abs_float g < eps && abs_float b < eps));

      Alcotest.test_case "rgb -> hsb -> rgb roundtrip" `Quick (fun () ->
        let orig = color_rgb 0.3 0.6 0.9 in
        let (h, s, br, a) = color_to_hsba orig in
        let back = Hsb { h; s; b = br; a } in
        let (r, g, b, _) = color_to_rgba back in
        let (r0, g0, b0, _) = color_to_rgba orig in
        assert (abs_float (r -. r0) < eps && abs_float (g -. g0) < eps && abs_float (b -. b0) < eps));

      Alcotest.test_case "rgb -> cmyk -> rgb roundtrip" `Quick (fun () ->
        let orig = color_rgb 0.3 0.6 0.9 in
        let (c, m, y, k, a) = color_to_cmyka orig in
        let back = Cmyk { c; m; y; k; a } in
        let (r, g, b, _) = color_to_rgba back in
        let (r0, g0, b0, _) = color_to_rgba orig in
        assert (abs_float (r -. r0) < eps && abs_float (g -. g0) < eps && abs_float (b -. b0) < eps));

      Alcotest.test_case "hsb -> rgb -> hsb roundtrip" `Quick (fun () ->
        let orig = color_hsb 210.0 0.67 0.9 in
        let (r, g, b, a) = color_to_rgba orig in
        let back = Rgb { r; g; b; a } in
        let (h, s, br, _) = color_to_hsba back in
        let (h0, s0, br0, _) = color_to_hsba orig in
        assert (abs_float (h -. h0) < eps && abs_float (s -. s0) < eps && abs_float (br -. br0) < eps));

      Alcotest.test_case "rgb -> cmyk -> rgb roundtrip (via cmyk)" `Quick (fun () ->
        let orig = color_rgb 0.5 0.7 0.2 in
        let (c, m, y, k, a) = color_to_cmyka orig in
        let back = Cmyk { c; m; y; k; a } in
        let (r1, g1, b1, _) = color_to_rgba orig in
        let (r2, g2, b2, _) = color_to_rgba back in
        assert (abs_float (r1 -. r2) < eps && abs_float (g1 -. g2) < eps && abs_float (b1 -. b2) < eps));

      Alcotest.test_case "alpha preserved through rgb constructor" `Quick (fun () ->
        let c = make_color ~a:0.42 0.1 0.2 0.3 in
        let (_, _, _, a) = color_to_rgba c in
        assert (abs_float (a -. 0.42) < eps));

      Alcotest.test_case "hsb identity to hsba" `Quick (fun () ->
        let c = Hsb { h = 123.0; s = 0.45; b = 0.67; a = 0.89 } in
        let (h, s, br, a) = color_to_hsba c in
        assert (h = 123.0 && s = 0.45 && br = 0.67 && a = 0.89));

      Alcotest.test_case "cmyk identity to cmyka" `Quick (fun () ->
        let c = Cmyk { c = 0.1; m = 0.2; y = 0.3; k = 0.4; a = 0.5 } in
        let (cv, m, y, k, a) = color_to_cmyka c in
        assert (cv = 0.1 && m = 0.2 && y = 0.3 && k = 0.4 && a = 0.5));

      (* ---- with_fill / with_stroke tests ---- *)

      Alcotest.test_case "with_fill sets fill on rect" `Quick (fun () ->
        let r = make_rect 0.0 0.0 10.0 10.0 in
        let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
        let r2 = with_fill r f in
        match r2 with
        | Rect { fill = Some { fill_color; _ }; _ } ->
          let (rv, _, _, _) = color_to_rgba fill_color in
          assert (rv = 1.0)
        | _ -> assert false);

      Alcotest.test_case "with_fill on Line is noop" `Quick (fun () ->
        let ln = make_line 0.0 0.0 10.0 10.0 in
        let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
        let ln2 = with_fill ln f in
        (match ln2 with Line _ -> () | _ -> assert false));

      Alcotest.test_case "with_stroke sets stroke on path" `Quick (fun () ->
        let p = make_path [MoveTo (0.0, 0.0); LineTo (10.0, 10.0)] in
        let s = Some (make_stroke ~width:3.0 (color_rgb 0.0 0.0 1.0)) in
        let p2 = with_stroke p s in
        match p2 with
        | Path { stroke = Some { stroke_width; _ }; _ } ->
          assert (stroke_width = 3.0)
        | _ -> assert false);

      Alcotest.test_case "with_fill on Group is noop" `Quick (fun () ->
        let g = make_group [|make_rect 0.0 0.0 5.0 5.0|] in
        let f = Some (make_fill (color_rgb 1.0 0.0 0.0)) in
        let g2 = with_fill g f in
        (match g2 with Group _ -> () | _ -> assert false));

      Alcotest.test_case "with_stroke on Layer is noop" `Quick (fun () ->
        let l = make_layer [|make_rect 0.0 0.0 5.0 5.0|] in
        let s = Some (make_stroke (color_rgb 1.0 0.0 0.0)) in
        let l2 = with_stroke l s in
        (match l2 with Layer _ -> () | _ -> assert false));

      (* ---- color_to_hex / color_from_hex tests ---- *)

      Alcotest.test_case "color_to_hex black -> 000000" `Quick (fun () ->
        assert (color_to_hex black = "000000"));

      Alcotest.test_case "color_to_hex red -> ff0000" `Quick (fun () ->
        assert (color_to_hex (color_rgb 1.0 0.0 0.0) = "ff0000"));

      Alcotest.test_case "color_to_hex white -> ffffff" `Quick (fun () ->
        assert (color_to_hex white = "ffffff"));

      Alcotest.test_case "color_from_hex valid" `Quick (fun () ->
        match color_from_hex "ff0000" with
        | Some c ->
          let (r, g, b, _) = color_to_rgba c in
          assert (abs_float (r -. 1.0) < 0.01 && abs_float g < 0.01 && abs_float b < 0.01)
        | None -> assert false);

      Alcotest.test_case "color_from_hex with # prefix" `Quick (fun () ->
        match color_from_hex "#00ff00" with
        | Some c ->
          let (r, g, b, _) = color_to_rgba c in
          assert (abs_float r < 0.01 && abs_float (g -. 1.0) < 0.01 && abs_float b < 0.01)
        | None -> assert false);

      Alcotest.test_case "color_from_hex invalid returns None" `Quick (fun () ->
        assert (color_from_hex "xyz" = None);
        assert (color_from_hex "gggggg" = None);
        assert (color_from_hex "" = None));

      Alcotest.test_case "hex roundtrip" `Quick (fun () ->
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

      (* geometric_bounds — Align reads this when Use Preview
         Bounds is off per ALIGN.md Bounding box selection. *)

      Alcotest.test_case "geometric_bounds ignores stroke inflation on line" `Quick (fun () ->
        let ln = make_line ~stroke:(Some (make_stroke ~width:4.0 (make_color 0.0 0.0 0.0)))
          0.0 0.0 50.0 50.0 in
        let (x, y, w, h) = geometric_bounds ln in
        assert (x = 0.0 && y = 0.0 && w = 50.0 && h = 50.0));

      Alcotest.test_case "geometric_bounds rect" `Quick (fun () ->
        let r = make_rect 10.0 20.0 30.0 40.0 in
        let (x, y, w, h) = geometric_bounds r in
        assert (x = 10.0 && y = 20.0 && w = 30.0 && h = 40.0));

      Alcotest.test_case "geometric_bounds circle" `Quick (fun () ->
        let c = make_circle 50.0 50.0 20.0 in
        let (x, y, w, h) = geometric_bounds c in
        assert (x = 30.0 && y = 30.0 && w = 40.0 && h = 40.0));

      Alcotest.test_case "geometric_bounds ellipse" `Quick (fun () ->
        let e = make_ellipse 50.0 50.0 30.0 15.0 in
        let (x, y, w, h) = geometric_bounds e in
        assert (x = 20.0 && y = 35.0 && w = 60.0 && h = 30.0));

      Alcotest.test_case "geometric_bounds group unions children without inflation" `Quick (fun () ->
        let g = make_group [| make_rect 0.0 0.0 10.0 10.0;
                              make_rect 20.0 20.0 10.0 10.0 |] in
        let (x, y, w, h) = geometric_bounds g in
        assert (x = 0.0 && y = 0.0 && w = 30.0 && h = 30.0));

      Alcotest.test_case "geometric_bounds matches bounds on unstroked shape" `Quick (fun () ->
        let c = make_circle 50.0 50.0 20.0 in
        let g = geometric_bounds c in
        let b = bounds c in
        assert (g = b));

      Alcotest.test_case "geometric_bounds narrower than preview for stroked line" `Quick (fun () ->
        let ln = make_line ~stroke:(Some (make_stroke ~width:4.0 (make_color 0.0 0.0 0.0)))
          0.0 0.0 50.0 50.0 in
        let (_, _, gw, gh) = geometric_bounds ln in
        let (_, _, pw, ph) = bounds ln in
        assert (pw > gw);
        assert (ph > gh));

      (* BlendMode value and string helpers. *)

      Alcotest.test_case "blend_mode_to_string snake_case for compound names" `Quick (fun () ->
        assert (blend_mode_to_string Normal = "normal");
        assert (blend_mode_to_string Color_burn = "color_burn");
        assert (blend_mode_to_string Color_dodge = "color_dodge");
        assert (blend_mode_to_string Soft_light = "soft_light");
        assert (blend_mode_to_string Hard_light = "hard_light");
        assert (blend_mode_to_string Luminosity = "luminosity"));

      Alcotest.test_case "blend_mode_of_string round-trip for all sixteen" `Quick (fun () ->
        let all = [ Normal; Darken; Multiply; Color_burn;
                    Lighten; Screen; Color_dodge;
                    Overlay; Soft_light; Hard_light;
                    Difference; Exclusion;
                    Hue; Saturation; Color; Luminosity ] in
        assert (List.length all = 16);
        List.iter (fun m ->
          let s = blend_mode_to_string m in
          match blend_mode_of_string s with
          | Some back -> assert (back = m)
          | None -> assert false
        ) all);

      Alcotest.test_case "blend_mode_of_string unknown returns None" `Quick (fun () ->
        assert (blend_mode_of_string "not_a_mode" = None);
        assert (blend_mode_of_string "" = None);
        assert (blend_mode_of_string "ColorBurn" = None));
    ];
  ]
