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

  print_endline "All SVG tests passed."
