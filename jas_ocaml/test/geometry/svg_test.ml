let () =
  let open Jas.Element in
  let open Jas.Document in
  let s = 96.0 /. 72.0 in
  let _ = s in

  (* Test empty document *)
  let doc = make_document [make_layer []] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (String.length svg > 0);
  assert (try let _ = String.index svg '<' in true with Not_found -> false);

  (* Test line coordinates converted: 72pt -> 96px *)
  let doc = make_document [make_layer [
    make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|x2="96"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|y2="48"|}) svg 0 in true
          with Not_found -> false);

  (* Test rect with fill and stroke *)
  let doc = make_document [make_layer [
    make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
      ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="rgb(255,0,0)"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|stroke="rgb(0,0,0)"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|width="96"|}) svg 0 in true
          with Not_found -> false);

  (* Test circle *)
  let doc = make_document [make_layer [
    make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|cx="48"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|r="24"|}) svg 0 in true
          with Not_found -> false);

  (* Test polygon *)
  let doc = make_document [make_layer [
    make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "<polygon") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "0,0 96,0 48,96") svg 0 in true
          with Not_found -> false);

  (* Test path with commands *)
  let doc = make_document [make_layer [
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string "M0,0") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "L96,96") svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string "Z") svg 0 in true
          with Not_found -> false);

  (* Test no fill => fill="none" *)
  let doc = make_document [make_layer [
    make_rect ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="none"|}) svg 0 in true
          with Not_found -> false);

  (* Test opacity *)
  let doc = make_document [make_layer [
    make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|opacity="0.5"|}) svg 0 in true
          with Not_found -> false);

  (* Test full opacity omitted *)
  let doc = make_document [make_layer [
    make_rect ~opacity:1.0 0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (not (try let _ : int = Str.search_forward (Str.regexp_string "opacity=") svg 0 in true
               with Not_found -> false));

  (* Test transform: translate(36,18) -> e=48, f=24 *)
  let doc = make_document [make_layer [
    make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|transform="matrix(1,0,0,1,48,24)"|}) svg 0 in true
          with Not_found -> false);

  (* Test layer name *)
  let doc = make_document [make_layer ~name:"Background" [
    make_rect 0.0 0.0 72.0 72.0
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|inkscape:label="Background"|}) svg 0 in true
          with Not_found -> false);

  (* Test text *)
  let doc = make_document [make_layer [
    make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
      ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
  ]] in
  let svg = Jas.Svg.document_to_svg doc in
  assert (try let _ : int = Str.search_forward (Str.regexp_string {|font-family="Arial"|}) svg 0 in true
          with Not_found -> false);
  assert (try let _ : int = Str.search_forward (Str.regexp_string ">Hello</text>") svg 0 in true
          with Not_found -> false);

  (* Test text XML escaping *)
  let doc = make_document [make_layer [
    make_text 0.0 0.0 "<b>&</b>"
  ]] in
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
  let doc = make_document [make_layer []] in
  let doc2 = roundtrip doc in
  assert (List.length doc2.Jas.Document.layers = 1);

  (* Round-trip line *)
  let doc = make_document [make_layer [
    make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Line { x2; y2; _ } ->
     assert (abs_float (x2 -. 72.0) < 0.1);
     assert (abs_float (y2 -. 36.0) < 0.1)
   | _ -> assert false);

  (* Round-trip rect with fill *)
  let doc = make_document [make_layer [
    make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
      ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      10.0 20.0 72.0 36.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Rect { width; height; fill; _ } ->
     assert (abs_float (width -. 72.0) < 0.1);
     assert (abs_float (height -. 36.0) < 0.1);
     assert (fill <> None)
   | _ -> assert false);

  (* Round-trip circle *)
  let doc = make_document [make_layer [
    make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Circle { r; _ } -> assert (abs_float (r -. 18.0) < 0.1)
   | _ -> assert false);

  (* Round-trip polygon *)
  let doc = make_document [make_layer [
    make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Polygon { points; _ } ->
     assert (List.length points = 3);
     let (x, _) = List.nth points 1 in
     assert (abs_float (x -. 72.0) < 0.1)
   | _ -> assert false);

  (* Round-trip path *)
  let doc = make_document [make_layer [
    make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
      [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Path { d; _ } ->
     assert (List.length d = 3);
     (match List.nth d 1 with
      | LineTo (x, y) ->
        assert (abs_float (x -. 72.0) < 0.1);
        assert (abs_float (y -. 72.0) < 0.1)
      | _ -> assert false)
   | _ -> assert false);

  (* Round-trip text *)
  let doc = make_document [make_layer [
    make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
      ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Text { content; font_family; _ } ->
     assert (content = "Hello");
     assert (font_family = "Arial")
   | _ -> assert false);

  (* Round-trip opacity *)
  let doc = make_document [make_layer [
    make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Rect { opacity; _ } -> assert (abs_float (opacity -. 0.5) < 0.1)
   | _ -> assert false);

  (* Round-trip transform *)
  let doc = make_document [make_layer [
    make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.nth (children_of (List.hd doc2.Jas.Document.layers)) 0 with
   | Rect { transform = Some t; _ } ->
     assert (abs_float (t.e -. 36.0) < 0.1);
     assert (abs_float (t.f -. 18.0) < 0.1)
   | _ -> assert false);

  (* Round-trip layer name *)
  let doc = make_document [make_layer ~name:"Background" [
    make_rect 0.0 0.0 72.0 72.0
  ]] in
  let doc2 = roundtrip doc in
  (match List.hd doc2.Jas.Document.layers with
   | Layer { name; _ } -> assert (name = "Background")
   | _ -> assert false);

  (* Round-trip multiple layers *)
  let doc = make_document [
    make_layer ~name:"L1" [
      make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
    ];
    make_layer ~name:"L2" [
      make_circle 36.0 36.0 18.0
    ]
  ] in
  let doc2 = roundtrip doc in
  assert (List.length doc2.Jas.Document.layers = 2);
  (match List.nth doc2.Jas.Document.layers 0 with
   | Layer { name; _ } -> assert (name = "L1")
   | _ -> assert false);
  (match List.nth doc2.Jas.Document.layers 1 with
   | Layer { name; _ } -> assert (name = "L2")
   | _ -> assert false);

  print_endline "All SVG tests passed."
