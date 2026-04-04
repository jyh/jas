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
  | Text { x; y; content; font_family; font_size; fill; stroke; opacity; transform } ->
    Printf.sprintf "%s<text x=\"%s\" y=\"%s\" font-family=\"%s\" font-size=\"%s\"%s%s%s%s>%s</text>"
      indent (fmt (px x)) (fmt (px y)) (escape_xml font_family) (fmt (px font_size))
      (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform) (escape_xml content)
  | Group { children; opacity; transform } ->
    let header = Printf.sprintf "%s<g%s%s>"
      indent (opacity_attr opacity) (transform_attr transform) in
    let child_lines = List.map (element_svg (indent ^ "  ")) children in
    let footer = Printf.sprintf "%s</g>" indent in
    String.concat "\n" (header :: child_lines @ [footer])
  | Layer { name; children; opacity; transform } ->
    let label = if name <> "" then Printf.sprintf " inkscape:label=\"%s\"" (escape_xml name) else "" in
    let header = Printf.sprintf "%s<g%s%s%s>"
      indent label (opacity_attr opacity) (transform_attr transform) in
    let child_lines = List.map (element_svg (indent ^ "  ")) children in
    let footer = Printf.sprintf "%s</g>" indent in
    String.concat "\n" (header :: child_lines @ [footer])

let document_to_svg doc =
  let (bx, by, bw, bh) = Document.bounds doc in
  let vb = Printf.sprintf "%s %s %s %s"
    (fmt (px bx)) (fmt (px by)) (fmt (px bw)) (fmt (px bh)) in
  let lines = [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";
    Printf.sprintf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" width=\"%s\" height=\"%s\">"
      vb (fmt (px bw)) (fmt (px bh));
  ] in
  let layer_lines = List.map (element_svg "  ") doc.Document.layers in
  String.concat "\n" (lines @ layer_lines @ ["</svg>"])
