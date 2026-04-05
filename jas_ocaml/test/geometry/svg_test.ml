let () =
  let open Jas.Element in
  let open Jas.Document in
  let s = 96.0 /. 72.0 in
  let _ = s in

  (* Test empty document *)
  let doc = make_document [|make_layer [||]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (String.length svg > 0);
  assert (try let _ = String.index svg '<' in true with Not_found -> false);

  (* Test line coordinates converted: 72pt -> 96px *)
  let doc = make_document [|make_layer [|
    make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|x2="96"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|y2="48"|}) svg 0 in true
          with Not_found -> false);

  (* Test rect with fill and stroke *)
  let doc = make_document [|make_layer [|
    make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
      ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="rgb(255,0,0)"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|stroke="rgb(0,0,0)"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|width="96"|}) svg 0 in true
          with Not_found -> false);

  (* Test circle *)
  let doc = make_document [|make_layer [|
    make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|cx="48"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|r="24"|}) svg 0 in true
          with Not_found -> false);

  (* Test polygon *)
  let doc = make_document [|make_layer [|
    make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "<polygon") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "0,0 96,0 48,96") svg 0 in true
          with Not_found -> false);

  (* Test path with commands *)
  let doc = make_document [|make_layer [|
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "M0,0") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "L96,96") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "Z") svg 0 in true
          with Not_found -> false);

  (* Test no fill => fill="none" *)
  let doc = make_document [|make_layer [|
    make_rect ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="none"|}) svg 0 in true
          with Not_found -> false);

  (* Test opacity *)
  let doc = make_document [|make_layer [|
    make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|opacity="0.5"|}) svg 0 in true
          with Not_found -> false);

  (* Test full opacity omitted *)
  let doc = make_document [|make_layer [|
    make_rect ~opacity:1.0 0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (not (try let _ : int = Str.search_forward (Str.regexp_string "opacity=") svg 0 in true
               with Not_found -> false));

  (* Test transform: translate(36,18) -> e=48, f=24 *)
  let doc = make_document [|make_layer [|
    make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|transform="matrix(1,0,0,1,48,24)"|}) svg 0 in true
          with Not_found -> false);

  (* Test layer name *)
  let doc = make_document [|make_layer ~name:"Background" [|
    make_rect 0.0 0.0 72.0 72.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|inkscape:label="Background"|}) svg 0 in true
          with Not_found -> false);

  (* Test text *)
  let doc = make_document [|make_layer [|
    make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
      ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|font-family="Arial"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string ">Hello</text>") svg 0 in true
          with Not_found -> false);

  (* Test text XML escaping *)
  let doc = make_document [|make_layer [|
    make_text 0.0 0.0 "<b>&</b>"
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "&lt;b&gt;&amp;&lt;/b&gt;") svg 0 in true
          with Not_found -> false);

  (* ------------------------------------------------------------------- *)
  (* SVG Import round-trip tests                                         *)
  (* ------------------------------------------------------------------- *)

  let roundtrip doc =
    let svg = Jas.Svg.document_to_svg doc in
    Jas.Svg.svg_to_document svg
  in

  (* Round-trip empty *)
  let doc = make_document [|make_layer [||]|] in
  let doc2 = roundtrip doc in
  assert (Array.length doc2.Jas.Document.layers = 1);

  (* Round-trip line *)
  let doc = make_document [|make_layer [|
    make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Line { x2; y2; _ } ->
     assert (abs_float (x2 -. 72.0) < 0.1);
     assert (abs_float (y2 -. 36.0) < 0.1)
   | _ -> assert false);

  (* Round-trip rect with fill *)
  let doc = make_document [|make_layer [|
    make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
      ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      10.0 20.0 72.0 36.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Rect { width; height; fill; _ } ->
     assert (abs_float (width -. 72.0) < 0.1);
     assert (abs_float (height -. 36.0) < 0.1);
     assert (fill <> None)
   | _ -> assert false);

  (* Round-trip circle *)
  let doc = make_document [|make_layer [|
    make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Circle { r; _ } -> assert (abs_float (r -. 18.0) < 0.1)
   | _ -> assert false);

  (* Round-trip polygon *)
  let doc = make_document [|make_layer [|
    make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Polygon { points; _ } ->
     assert (List.length points = 3);
     let (x, _) = List.nth points 1 in
     assert (abs_float (x -. 72.0) < 0.1)
   | _ -> assert false);

  (* Round-trip path *)
  let doc = make_document [|make_layer [|
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     assert (List.length d = 3);
     (match List.nth d 1 with
      | LineTo (x, y) ->
        assert (abs_float (x -. 72.0) < 0.1);
        assert (abs_float (y -. 72.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Round-trip text *)
  let doc = make_document [|make_layer [|
    make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
      ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Text { content; font_family; _ } ->
     assert (content = "Hello");
     assert (font_family = "Arial")
   | _ -> assert false);

  (* Round-trip opacity *)
  let doc = make_document [|make_layer [|
    make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Rect { opacity; _ } -> assert (abs_float (opacity -. 0.5) < 0.1)
   | _ -> assert false);

  (* Round-trip transform *)
  let doc = make_document [|make_layer [|
    make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Rect { transform = Some t; _ } ->
     assert (abs_float (t.e -. 36.0) < 0.1);
     assert (abs_float (t.f -. 18.0) < 0.1)
   | _ -> assert false);

  (* Round-trip layer name *)
  let doc = make_document [|make_layer ~name:"Background" [|
    make_rect 0.0 0.0 72.0 72.0
  |]|] in
  let doc2 = roundtrip doc in
  (match doc2.Jas.Document.layers.(0) with
   | Layer { name; _ } -> assert (name = "Background")
   | _ -> assert false);

  (* Round-trip multiple layers *)
  let doc = make_document [|
    make_layer ~name:"L1" [|
      make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
    |];
    make_layer ~name:"L2" [|
      make_circle 36.0 36.0 18.0
    |]
  |] in
  let doc2 = roundtrip doc in
  assert (Array.length doc2.Jas.Document.layers = 2);
  (match doc2.Jas.Document.layers.(0) with
   | Layer { name; _ } -> assert (name = "L1")
   | _ -> assert false);
  (match doc2.Jas.Document.layers.(1) with
   | Layer { name; _ } -> assert (name = "L2")
   | _ -> assert false);

  (* Import relative path commands *)
  let svg_rel = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="m 10,20 l 30,0 l 0,40 z" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
  let doc_rel = Jas.Svg.svg_to_document svg_rel in
  let pt v = v *. 72.0 /. 96.0 in
  (match (children_of doc_rel.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     assert (List.length d = 4);
     (* m 10,20 => MoveTo(pt 10, pt 20) *)
     (match List.nth d 0 with
      | MoveTo (x, y) ->
        assert (abs_float (x -. pt 10.0) < 0.1);
        assert (abs_float (y -. pt 20.0) < 0.1)
      | _ -> assert false);
     (* l 30,0 => LineTo(pt 40, pt 20) *)
     (match List.nth d 1 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 40.0) < 0.1);
        assert (abs_float (y -. pt 20.0) < 0.1)
      | _ -> assert false);
     (* l 0,40 => LineTo(pt 40, pt 60) *)
     (match List.nth d 2 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 40.0) < 0.1);
        assert (abs_float (y -. pt 60.0) < 0.1)
      | _ -> assert false);
     (match List.nth d 3 with ClosePath -> () | _ -> assert false)
   | _ -> assert false);

  (* Import relative cubic curve *)
  let svg_c = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="M 0,0 c 10,20 30,40 50,60" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
  let doc_c = Jas.Svg.svg_to_document svg_c in
  (match (children_of doc_c.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     (match List.nth d 1 with
      | CurveTo (x1, y1, _, _, x, y) ->
        assert (abs_float (x1 -. pt 10.0) < 0.1);
        assert (abs_float (y1 -. pt 20.0) < 0.1);
        assert (abs_float (x -. pt 50.0) < 0.1);
        assert (abs_float (y -. pt 60.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Import H/h/V/v commands *)
  let svg_hv = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="M 10,10 H 50 V 80 h -20 v -30" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
  let doc_hv = Jas.Svg.svg_to_document svg_hv in
  (match (children_of doc_hv.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     assert (List.length d = 5);
     (* H 50 => LineTo(pt 50, pt 10) *)
     (match List.nth d 1 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 50.0) < 0.1);
        assert (abs_float (y -. pt 10.0) < 0.1)
      | _ -> assert false);
     (* V 80 => LineTo(pt 50, pt 80) *)
     (match List.nth d 2 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 50.0) < 0.1);
        assert (abs_float (y -. pt 80.0) < 0.1)
      | _ -> assert false);
     (* h -20 => LineTo(pt 30, pt 80) *)
     (match List.nth d 3 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 30.0) < 0.1);
        assert (abs_float (y -. pt 80.0) < 0.1)
      | _ -> assert false);
     (* v -30 => LineTo(pt 30, pt 50) *)
     (match List.nth d 4 with
      | LineTo (x, y) ->
        assert (abs_float (x -. pt 30.0) < 0.1);
        assert (abs_float (y -. pt 50.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Import #RRGGBB hex color *)
  let svg_hex6 = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="#ff8000"/></g></svg>|} in
  let doc_hex6 = Jas.Svg.svg_to_document svg_hex6 in
  (match (children_of doc_hex6.Jas.Document.layers.(0)).(0) with
   | Rect { fill = Some { fill_color; _ }; _ } ->
     assert (abs_float (fill_color.r -. 1.0) < 0.01);
     assert (abs_float (fill_color.g -. (128.0 /. 255.0)) < 0.01);
     assert (abs_float (fill_color.b -. 0.0) < 0.01)
   | _ -> assert false);

  (* Import #RGB shorthand hex color *)
  let svg_hex3 = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="#f00"/></g></svg>|} in
  let doc_hex3 = Jas.Svg.svg_to_document svg_hex3 in
  (match (children_of doc_hex3.Jas.Document.layers.(0)).(0) with
   | Rect { fill = Some { fill_color; _ }; _ } ->
     assert (abs_float (fill_color.r -. 1.0) < 0.01);
     assert (abs_float (fill_color.g -. 0.0) < 0.01);
     assert (abs_float (fill_color.b -. 0.0) < 0.01)
   | _ -> assert false);

  (* Import hex color on stroke *)
  let svg_hex_stroke = {|<svg xmlns="http://www.w3.org/2000/svg"><g><line x1="0" y1="0" x2="96" y2="96" stroke="#0000ff" stroke-width="2"/></g></svg>|} in
  let doc_hex_s = Jas.Svg.svg_to_document svg_hex_stroke in
  (match (children_of doc_hex_s.Jas.Document.layers.(0)).(0) with
   | Line { stroke = Some { stroke_color; _ }; _ } ->
     assert (abs_float (stroke_color.b -. 1.0) < 0.01)
   | _ -> assert false);

  (* Test ellipse *)
  let doc = make_document [|make_layer [|
    make_ellipse ~fill:(Some (make_fill (make_color 0.0 1.0 0.0))) 36.0 36.0 18.0 9.0
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|cx="48"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|rx="24"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|ry="12"|}) svg 0 in true
          with Not_found -> false);

  (* Test group export *)
  let doc = make_document [|make_layer [|
    make_group [|make_rect 0.0 0.0 72.0 72.0; make_circle 36.0 36.0 18.0|]
  |]|] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "<g>") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "<rect") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "<circle") svg 0 in true
          with Not_found -> false);

  (* Round-trip ellipse *)
  let doc = make_document [|make_layer [|
    make_ellipse ~fill:(Some (make_fill (make_color 0.0 1.0 0.0))) 36.0 36.0 18.0 9.0
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Ellipse { rx; ry; _ } ->
     assert (abs_float (rx -. 18.0) < 0.1);
     assert (abs_float (ry -. 9.0) < 0.1)
   | _ -> assert false);

  (* Round-trip path with curves *)
  let doc = make_document [|make_layer [|
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); CurveTo (10.0, 20.0, 30.0, 40.0, 50.0, 60.0)]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     (match List.nth d 1 with
      | CurveTo (x1, y1, _, _, x, y) ->
        assert (abs_float (x1 -. 10.0) < 0.1);
        assert (abs_float (y1 -. 20.0) < 0.1);
        assert (abs_float (x -. 50.0) < 0.1);
        assert (abs_float (y -. 60.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Round-trip group *)
  let doc = make_document [|make_layer [|
    make_group [|
      make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0))) 0.0 0.0 72.0 72.0;
      make_circle 36.0 36.0 18.0
    |]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Group { children; _ } ->
     assert (Array.length children = 2);
     (match children.(0) with Rect _ -> () | _ -> assert false);
     (match children.(1) with Circle _ -> () | _ -> assert false)
   | _ -> assert false);

  (* Round-trip arc with large_arc=true, sweep=true *)
  let doc = make_document [|make_layer [|
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); ArcTo (36.0, 36.0, 0.0, true, true, 72.0, 0.0)]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     (match List.nth d 1 with
      | ArcTo (rx, _, _, la, sw, x, _) ->
        assert (abs_float (rx -. 36.0) < 0.1);
        assert (la = true);
        assert (sw = true);
        assert (abs_float (x -. 72.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Round-trip arc with large_arc=false, sweep=false, rotated *)
  let doc = make_document [|make_layer [|
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); ArcTo (36.0, 18.0, 30.0, false, false, 72.0, 36.0)]
  |]|] in
  let doc2 = roundtrip doc in
  (match (children_of doc2.Jas.Document.layers.(0)).(0) with
   | Path { d; _ } ->
     (match List.nth d 1 with
      | ArcTo (_, ry, rot, la, sw, _, _) ->
        assert (abs_float (ry -. 18.0) < 0.1);
        assert (abs_float (rot -. 30.0) < 0.1);
        assert (la = false);
        assert (sw = false)
      | _ -> assert false)
   | _ -> assert false);

  (* Import named color "red" *)
  let svg_red = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="red"/></g></svg>|} in
  let doc_red = Jas.Svg.svg_to_document svg_red in
  (match (children_of doc_red.Jas.Document.layers.(0)).(0) with
   | Rect { fill = Some { fill_color; _ }; _ } ->
     assert (abs_float (fill_color.r -. 1.0) < 0.01);
     assert (abs_float (fill_color.g -. 0.0) < 0.01)
   | _ -> assert false);

  (* Import named color "steelblue" *)
  let svg_sb = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="steelblue"/></g></svg>|} in
  let doc_sb = Jas.Svg.svg_to_document svg_sb in
  (match (children_of doc_sb.Jas.Document.layers.(0)).(0) with
   | Rect { fill = Some { fill_color; _ }; _ } ->
     assert (abs_float (fill_color.r -. 70.0 /. 255.0) < 0.01);
     assert (abs_float (fill_color.g -. 130.0 /. 255.0) < 0.01);
     assert (abs_float (fill_color.b -. 180.0 /. 255.0) < 0.01)
   | _ -> assert false);

  print_endline "All SVG tests passed."
