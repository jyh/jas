(** Convert a Document to SVG format.

    Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
    The conversion factor is 96/72 (CSS px per pt at 96 DPI). *)

let pt_to_px = 96.0 /. 72.0

let px v = v *. pt_to_px

let fmt v =
  let s = Printf.sprintf "%.4f" v in
  (* Strip trailing zeros and dot *)
  let len = String.length s in
  let i = ref (len - 1) in
  while !i > 0 && s.[!i] = '0' do decr i done;
  if !i > 0 && s.[!i] = '.' then decr i;
  String.sub s 0 (!i + 1)

let color_str (c : Element.color) =
  let r = int_of_float (Float.round (c.r *. 255.0)) in
  let g = int_of_float (Float.round (c.g *. 255.0)) in
  let b = int_of_float (Float.round (c.b *. 255.0)) in
  if c.a < 1.0 then Printf.sprintf "rgba(%d,%d,%d,%s)" r g b (fmt c.a)
  else Printf.sprintf "rgb(%d,%d,%d)" r g b

let escape_xml s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let fill_attrs = function
  | None -> " fill=\"none\""
  | Some (f : Element.fill) -> Printf.sprintf " fill=\"%s\"" (color_str f.fill_color)

let stroke_attrs = function
  | None -> " stroke=\"none\""
  | Some (s : Element.stroke) ->
    let parts = ref [] in
    parts := Printf.sprintf " stroke=\"%s\"" (color_str s.stroke_color) :: !parts;
    parts := Printf.sprintf " stroke-width=\"%s\"" (fmt (px s.stroke_width)) :: !parts;
    (match s.stroke_linecap with
     | Element.Butt -> ()
     | Element.Round_cap -> parts := " stroke-linecap=\"round\"" :: !parts
     | Element.Square -> parts := " stroke-linecap=\"square\"" :: !parts);
    (match s.stroke_linejoin with
     | Element.Miter -> ()
     | Element.Round_join -> parts := " stroke-linejoin=\"round\"" :: !parts
     | Element.Bevel -> parts := " stroke-linejoin=\"bevel\"" :: !parts);
    String.concat "" (List.rev !parts)

let transform_attr = function
  | None -> ""
  | Some (t : Element.transform) ->
    Printf.sprintf " transform=\"matrix(%s,%s,%s,%s,%s,%s)\""
      (fmt t.a) (fmt t.b) (fmt t.c) (fmt t.d)
      (fmt (px t.e)) (fmt (px t.f))

let opacity_attr o =
  if o >= 1.0 then "" else Printf.sprintf " opacity=\"%s\"" (fmt o)

let path_data cmds =
  let parts = List.map (fun cmd ->
    let open Element in
    match cmd with
    | MoveTo (x, y) -> Printf.sprintf "M%s,%s" (fmt (px x)) (fmt (px y))
    | LineTo (x, y) -> Printf.sprintf "L%s,%s" (fmt (px x)) (fmt (px y))
    | CurveTo (x1, y1, x2, y2, x, y) ->
      Printf.sprintf "C%s,%s %s,%s %s,%s"
        (fmt (px x1)) (fmt (px y1)) (fmt (px x2)) (fmt (px y2))
        (fmt (px x)) (fmt (px y))
    | SmoothCurveTo (x2, y2, x, y) ->
      Printf.sprintf "S%s,%s %s,%s"
        (fmt (px x2)) (fmt (px y2)) (fmt (px x)) (fmt (px y))
    | QuadTo (x1, y1, x, y) ->
      Printf.sprintf "Q%s,%s %s,%s"
        (fmt (px x1)) (fmt (px y1)) (fmt (px x)) (fmt (px y))
    | SmoothQuadTo (x, y) -> Printf.sprintf "T%s,%s" (fmt (px x)) (fmt (px y))
    | ArcTo (rx, ry, rot, large, sweep, x, y) ->
      Printf.sprintf "A%s,%s %s %d,%d %s,%s"
        (fmt (px rx)) (fmt (px ry)) (fmt rot)
        (if large then 1 else 0) (if sweep then 1 else 0)
        (fmt (px x)) (fmt (px y))
    | ClosePath -> "Z"
  ) cmds in
  String.concat " " parts

let rec element_svg indent (elem : Element.element) =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; stroke; opacity; transform } ->
    Printf.sprintf "%s<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"%s%s%s/>"
      indent (fmt (px x1)) (fmt (px y1)) (fmt (px x2)) (fmt (px y2))
      (stroke_attrs stroke) (opacity_attr opacity) (transform_attr transform)
  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform } ->
    let rxy = (if rx > 0.0 then Printf.sprintf " rx=\"%s\"" (fmt (px rx)) else "")
            ^ (if ry > 0.0 then Printf.sprintf " ry=\"%s\"" (fmt (px ry)) else "") in
    Printf.sprintf "%s<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\"%s%s%s%s%s/>"
      indent (fmt (px x)) (fmt (px y)) (fmt (px width)) (fmt (px height))
      rxy (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Circle { cx; cy; r; fill; stroke; opacity; transform } ->
    Printf.sprintf "%s<circle cx=\"%s\" cy=\"%s\" r=\"%s\"%s%s%s%s/>"
      indent (fmt (px cx)) (fmt (px cy)) (fmt (px r))
      (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform } ->
    Printf.sprintf "%s<ellipse cx=\"%s\" cy=\"%s\" rx=\"%s\" ry=\"%s\"%s%s%s%s/>"
      indent (fmt (px cx)) (fmt (px cy)) (fmt (px rx)) (fmt (px ry))
      (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Polyline { points; fill; stroke; opacity; transform } ->
    let ps = String.concat " "
      (List.map (fun (x, y) -> Printf.sprintf "%s,%s" (fmt (px x)) (fmt (px y))) points) in
    Printf.sprintf "%s<polyline points=\"%s\"%s%s%s%s/>"
      indent ps (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Polygon { points; fill; stroke; opacity; transform } ->
    let ps = String.concat " "
      (List.map (fun (x, y) -> Printf.sprintf "%s,%s" (fmt (px x)) (fmt (px y))) points) in
    Printf.sprintf "%s<polygon points=\"%s\"%s%s%s%s/>"
      indent ps (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Path { d; fill; stroke; opacity; transform } ->
    Printf.sprintf "%s<path d=\"%s\"%s%s%s%s/>"
      indent (path_data d) (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Text { x; y; content; font_family; font_size; font_weight; font_style; text_decoration; text_width; text_height = _; fill; stroke; opacity; transform } ->
    let area_attrs = if text_width > 0.0 then
      Printf.sprintf " style=\"inline-size: %spx; white-space: pre-wrap;\"" (fmt (px text_width))
    else "" in
    let fw_attr = if font_weight <> "normal" then Printf.sprintf " font-weight=\"%s\"" font_weight else "" in
    let fs_attr = if font_style <> "normal" then Printf.sprintf " font-style=\"%s\"" font_style else "" in
    let td_attr = if text_decoration <> "none" then Printf.sprintf " text-decoration=\"%s\"" text_decoration else "" in
    Printf.sprintf "%s<text x=\"%s\" y=\"%s\" font-family=\"%s\" font-size=\"%s\"%s%s%s%s%s%s%s%s>%s</text>"
      indent (fmt (px x)) (fmt (px y)) (escape_xml font_family) (fmt (px font_size))
      fw_attr fs_attr td_attr
      area_attrs (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform) (escape_xml content)
  | Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; text_decoration; fill; stroke; opacity; transform } ->
    let offset_attr = if start_offset > 0.0 then
      Printf.sprintf " startOffset=\"%s%%\"" (fmt (start_offset *. 100.0))
    else "" in
    let fw_attr = if font_weight <> "normal" then Printf.sprintf " font-weight=\"%s\"" font_weight else "" in
    let fs_attr = if font_style <> "normal" then Printf.sprintf " font-style=\"%s\"" font_style else "" in
    let td_attr = if text_decoration <> "none" then Printf.sprintf " text-decoration=\"%s\"" text_decoration else "" in
    Printf.sprintf "%s<text%s%s font-family=\"%s\" font-size=\"%s\"%s%s%s%s%s><textPath path=\"%s\"%s>%s</textPath></text>"
      indent (fill_attrs fill) (stroke_attrs stroke)
      (escape_xml font_family) (fmt (px font_size))
      fw_attr fs_attr td_attr
      (opacity_attr opacity) (transform_attr transform)
      (path_data d) offset_attr (escape_xml content)
  | Group { children; opacity; transform } ->
    let header = Printf.sprintf "%s<g%s%s>"
      indent (opacity_attr opacity) (transform_attr transform) in
    let child_lines = Array.to_list (Array.map (element_svg (indent ^ "  ")) children) in
    let footer = Printf.sprintf "%s</g>" indent in
    String.concat "\n" (header :: child_lines @ [footer])
  | Layer { name; children; opacity; transform } ->
    let label = if name <> "" then Printf.sprintf " inkscape:label=\"%s\"" (escape_xml name) else "" in
    let header = Printf.sprintf "%s<g%s%s%s>"
      indent label (opacity_attr opacity) (transform_attr transform) in
    let child_lines = Array.to_list (Array.map (element_svg (indent ^ "  ")) children) in
    let footer = Printf.sprintf "%s</g>" indent in
    String.concat "\n" (header :: child_lines @ [footer])

let document_to_svg doc =
  let (bx, by, bw, bh) = Document.bounds doc in
  let vb = Printf.sprintf "%s %s %s %s"
    (fmt (px bx)) (fmt (px by)) (fmt (px bw)) (fmt (px bh)) in
  let lines = [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    Printf.sprintf "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"http://www.inkscape.org/namespaces/inkscape\" viewBox=\"%s\" width=\"%s\" height=\"%s\">"
      vb (fmt (px bw)) (fmt (px bh));
  ] in
  let layer_lines = Array.to_list (Array.map (element_svg "  ") doc.Document.layers) in
  String.concat "\n" (lines @ layer_lines @ ["</svg>"])

(* ----------------------------------------------------------------------- *)
(* SVG Import: parse SVG XML string back to a Document                     *)
(* ----------------------------------------------------------------------- *)

let px_to_pt = 72.0 /. 96.0

let pt v = v *. px_to_pt

let parse_color s =
  let s = String.trim s in
  if s = "none" then None
  else
    try Scanf.sscanf s "rgba(%d,%d,%d,%f)"
      (fun r g b a -> Some (Element.make_color ~a (float r /. 255.0) (float g /. 255.0) (float b /. 255.0)))
    with _ ->
    try Scanf.sscanf s "rgb(%d,%d,%d)"
      (fun r g b -> Some (Element.make_color (float r /. 255.0) (float g /. 255.0) (float b /. 255.0)))
    with _ -> None

let get_attr attrs name =
  try Some (List.assoc name attrs) with Not_found -> None

let get_attr_f attrs name default =
  match get_attr attrs name with
  | Some s -> (try float_of_string s with _ -> default)
  | None -> default

let parse_fill attrs =
  match get_attr attrs "fill" with
  | None | Some "none" -> None
  | Some s ->
    match parse_color s with
    | Some c -> Some (Element.make_fill c)
    | None -> None

let parse_stroke attrs =
  match get_attr attrs "stroke" with
  | None | Some "none" -> None
  | Some s ->
    match parse_color s with
    | None -> None
    | Some c ->
      let width = get_attr_f attrs "stroke-width" 1.0 *. px_to_pt in
      let linecap = match get_attr attrs "stroke-linecap" with
        | Some "round" -> Element.Round_cap
        | Some "square" -> Element.Square
        | _ -> Element.Butt in
      let linejoin = match get_attr attrs "stroke-linejoin" with
        | Some "round" -> Element.Round_join
        | Some "bevel" -> Element.Bevel
        | _ -> Element.Miter in
      Some (Element.make_stroke ~width ~linecap ~linejoin c)

let parse_transform attrs =
  match get_attr attrs "transform" with
  | None -> None
  | Some s ->
    try Scanf.sscanf s "matrix(%f,%f,%f,%f,%f,%f)"
      (fun a b c d e f ->
        Some { Element.a; b; c; d; e = pt e; f = pt f })
    with _ ->
    try Scanf.sscanf s "translate(%f,%f)"
      (fun tx ty -> Some (Element.make_translate (pt tx) (pt ty)))
    with _ ->
    try Scanf.sscanf s "rotate(%f)"
      (fun deg -> Some (Element.make_rotate deg))
    with _ ->
    try Scanf.sscanf s "scale(%f,%f)"
      (fun sx sy -> Some (Element.make_scale sx sy))
    with _ -> None

let parse_opacity attrs =
  get_attr_f attrs "opacity" 1.0

let parse_points s =
  let pairs = String.split_on_char ' ' (String.trim s) in
  List.filter_map (fun pair ->
    match String.split_on_char ',' pair with
    | [x; y] -> (try Some (pt (float_of_string x), pt (float_of_string y))
                 with _ -> None)
    | _ -> None
  ) pairs

(* Path d-attribute tokenizer *)
let parse_path_d d =
  let len = String.length d in
  let pos = ref 0 in
  let skip_ws () =
    while !pos < len && (d.[!pos] = ' ' || d.[!pos] = ',' || d.[!pos] = '\n' || d.[!pos] = '\r' || d.[!pos] = '\t') do
      incr pos
    done
  in
  let read_num () =
    skip_ws ();
    let start = !pos in
    if !pos < len && (d.[!pos] = '-' || d.[!pos] = '+') then incr pos;
    while !pos < len && ((d.[!pos] >= '0' && d.[!pos] <= '9') || d.[!pos] = '.') do
      incr pos
    done;
    (* handle exponent *)
    if !pos < len && (d.[!pos] = 'e' || d.[!pos] = 'E') then begin
      incr pos;
      if !pos < len && (d.[!pos] = '-' || d.[!pos] = '+') then incr pos;
      while !pos < len && d.[!pos] >= '0' && d.[!pos] <= '9' do incr pos done
    end;
    float_of_string (String.sub d start (!pos - start))
  in
  let cmds = ref [] in
  let add c = cmds := c :: !cmds in
  while !pos < len do
    skip_ws ();
    if !pos >= len then ()
    else
      let c = d.[!pos] in
      match c with
      | 'M' -> incr pos; add (Element.MoveTo (pt (read_num ()), pt (read_num ())))
      | 'L' -> incr pos; add (Element.LineTo (pt (read_num ()), pt (read_num ())))
      | 'C' -> incr pos;
        let x1 = pt (read_num ()) in let y1 = pt (read_num ()) in
        let x2 = pt (read_num ()) in let y2 = pt (read_num ()) in
        let x = pt (read_num ()) in let y = pt (read_num ()) in
        add (Element.CurveTo (x1, y1, x2, y2, x, y))
      | 'S' -> incr pos;
        let x2 = pt (read_num ()) in let y2 = pt (read_num ()) in
        let x = pt (read_num ()) in let y = pt (read_num ()) in
        add (Element.SmoothCurveTo (x2, y2, x, y))
      | 'Q' -> incr pos;
        let x1 = pt (read_num ()) in let y1 = pt (read_num ()) in
        let x = pt (read_num ()) in let y = pt (read_num ()) in
        add (Element.QuadTo (x1, y1, x, y))
      | 'T' -> incr pos; add (Element.SmoothQuadTo (pt (read_num ()), pt (read_num ())))
      | 'A' -> incr pos;
        let rx = pt (read_num ()) in let ry = pt (read_num ()) in
        let rot = read_num () in
        let large = read_num () <> 0.0 in
        let sweep = read_num () <> 0.0 in
        let x = pt (read_num ()) in let y = pt (read_num ()) in
        add (Element.ArcTo (rx, ry, rot, large, sweep, x, y))
      | 'Z' | 'z' -> incr pos; add Element.ClosePath
      | _ -> incr pos  (* skip unknown *)
  done;
  List.rev !cmds

(* Collect attributes from xmlm *)
let attrs_of_xmlm_attrs xmlm_attrs =
  List.map (fun ((_, name), value) -> (name, value)) xmlm_attrs

(* Parse element from xmlm input *)
let rec parse_element i =
  match Xmlm.peek i with
  | `El_start ((_, tag), xmlm_attrs) ->
    let _ = Xmlm.input i in (* consume start *)
    let attrs = attrs_of_xmlm_attrs xmlm_attrs in
    let fill = parse_fill attrs in
    let stroke = parse_stroke attrs in
    let opacity = parse_opacity attrs in
    let transform = parse_transform attrs in
    let elem = match tag with
      | "line" ->
        Some (Element.make_line
          ~stroke ~opacity ~transform
          (pt (get_attr_f attrs "x1" 0.0))
          (pt (get_attr_f attrs "y1" 0.0))
          (pt (get_attr_f attrs "x2" 0.0))
          (pt (get_attr_f attrs "y2" 0.0)))
      | "rect" ->
        Some (Element.make_rect
          ~rx:(pt (get_attr_f attrs "rx" 0.0))
          ~ry:(pt (get_attr_f attrs "ry" 0.0))
          ~fill ~stroke ~opacity ~transform
          (pt (get_attr_f attrs "x" 0.0))
          (pt (get_attr_f attrs "y" 0.0))
          (pt (get_attr_f attrs "width" 0.0))
          (pt (get_attr_f attrs "height" 0.0)))
      | "circle" ->
        Some (Element.make_circle
          ~fill ~stroke ~opacity ~transform
          (pt (get_attr_f attrs "cx" 0.0))
          (pt (get_attr_f attrs "cy" 0.0))
          (pt (get_attr_f attrs "r" 0.0)))
      | "ellipse" ->
        Some (Element.make_ellipse
          ~fill ~stroke ~opacity ~transform
          (pt (get_attr_f attrs "cx" 0.0))
          (pt (get_attr_f attrs "cy" 0.0))
          (pt (get_attr_f attrs "rx" 0.0))
          (pt (get_attr_f attrs "ry" 0.0)))
      | "polyline" ->
        let pts = parse_points (match get_attr attrs "points" with Some s -> s | None -> "") in
        Some (Element.make_polyline ~fill ~stroke ~opacity ~transform pts)
      | "polygon" ->
        let pts = parse_points (match get_attr attrs "points" with Some s -> s | None -> "") in
        Some (Element.make_polygon ~fill ~stroke ~opacity ~transform pts)
      | "path" ->
        let d = parse_path_d (match get_attr attrs "d" with Some s -> s | None -> "") in
        Some (Element.make_path ~fill ~stroke ~opacity ~transform d)
      | "text" ->
        let content = collect_text i in
        let ff = match get_attr attrs "font-family" with Some s -> s | None -> "sans-serif" in
        let fs = pt (get_attr_f attrs "font-size" 16.0) in
        let fw = match get_attr attrs "font-weight" with Some s -> s | None -> "normal" in
        let fst = match get_attr attrs "font-style" with Some s -> s | None -> "normal" in
        let td = match get_attr attrs "text-decoration" with Some s -> s | None -> "none" in
        let tw = match get_attr attrs "style" with
          | Some style ->
            (try
              let re = Str.regexp {|inline-size:[ ]*\([0-9.]+\)px|} in
              ignore (Str.search_forward re style 0);
              pt (float_of_string (Str.matched_group 1 style))
            with Not_found -> 0.0)
          | None -> 0.0
        in
        let th = if tw > 0.0 then
          let lines = max 1 (int_of_float (float_of_int (String.length content) *. fs *. 0.6 /. tw) + 1) in
          float_of_int lines *. fs *. 1.2
        else 0.0 in
        Some (Element.make_text ~font_family:ff ~font_size:fs ~font_weight:fw ~font_style:fst ~text_decoration:td ~text_width:tw ~text_height:th ~fill ~stroke ~opacity ~transform
          (pt (get_attr_f attrs "x" 0.0))
          (pt (get_attr_f attrs "y" 0.0))
          content)
      | "g" ->
        let children = parse_children i in
        let label = get_attr attrs "label" in
        (match label with
         | Some name ->
           Some (Element.make_layer ~name ~opacity ~transform children)
         | None ->
           Some (Element.make_group ~opacity ~transform children))
      | _ ->
        skip_element i;
        None
    in
    (* consume end tag for non-text, non-g, non-skipped elements *)
    (match tag with
     | "text" | "g" -> ()  (* already consumed *)
     | _ -> if elem <> None then (match Xmlm.peek i with `El_end -> let _ = Xmlm.input i in () | _ -> ()));
    elem
  | _ -> None

and collect_text i =
  let buf = Buffer.create 64 in
  let rec loop () =
    match Xmlm.peek i with
    | `El_end -> let _ = Xmlm.input i in ()
    | `Data s -> let _ = Xmlm.input i in Buffer.add_string buf s; loop ()
    | `El_start _ -> skip_element_full i; loop ()
    | `Dtd _ -> let _ = Xmlm.input i in loop ()
  in
  loop ();
  Buffer.contents buf

and parse_children i =
  let children = ref [] in
  let rec loop () =
    match Xmlm.peek i with
    | `El_end -> let _ = Xmlm.input i in ()
    | `Data _ -> let _ = Xmlm.input i in loop ()
    | `El_start _ ->
      (match parse_element i with
       | Some e -> children := e :: !children
       | None -> ());
      loop ()
    | `Dtd _ -> let _ = Xmlm.input i in loop ()
  in
  loop ();
  Array.of_list (List.rev !children)

and skip_element i =
  (* skip all children until end tag *)
  let rec loop depth =
    match Xmlm.input i with
    | `El_start _ -> loop (depth + 1)
    | `El_end -> if depth > 0 then loop (depth - 1)
    | _ -> loop depth
  in
  loop 0

and skip_element_full i =
  (* skip start tag + children + end tag *)
  match Xmlm.input i with
  | `El_start _ -> skip_element i
  | _ -> ()

let svg_to_document svg =
  let i = Xmlm.make_input (`String (0, svg)) in
  (* skip dtd *)
  (match Xmlm.peek i with `Dtd _ -> let _ = Xmlm.input i in () | _ -> ());
  (* expect <svg> start *)
  (match Xmlm.input i with `El_start _ -> () | _ -> failwith "expected <svg> element");
  let children = parse_children i in
  let layers = Array.to_list (Array.map (fun elem ->
    match elem with
    | Element.Layer _ -> elem
    | Element.Group { children; opacity; transform } ->
      Element.make_layer ~name:"" ~opacity ~transform children
    | _ ->
      Element.make_layer ~name:"" [|elem|]
  ) children) in
  let layers = if layers = [] then [Element.make_layer [||]] else layers in
  Document.make_document (Array.of_list layers)
