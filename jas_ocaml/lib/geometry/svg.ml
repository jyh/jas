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
  let (rv, gv, bv, av) = Element.color_to_rgba c in
  let r = int_of_float (Float.round (rv *. 255.0)) in
  let g = int_of_float (Float.round (gv *. 255.0)) in
  let b = int_of_float (Float.round (bv *. 255.0)) in
  if av < 1.0 then Printf.sprintf "rgba(%d,%d,%d,%s)" r g b (fmt av)
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
  | Some (f : Element.fill) ->
    let s = Printf.sprintf " fill=\"%s\"" (color_str f.fill_color) in
    if f.fill_opacity < 1.0 then s ^ Printf.sprintf " fill-opacity=\"%s\"" (fmt f.fill_opacity)
    else s

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
    if s.stroke_opacity < 1.0 then
      parts := Printf.sprintf " stroke-opacity=\"%s\"" (fmt s.stroke_opacity) :: !parts;
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

(** Build the attribute-string fragment for the 11 Character-panel
    attributes on a [<text>] element, emitting each attribute only
    when non-empty (per CHARACTER.md's identity-omission rule). *)
let text_extra_attrs tt fv bs lh ls lang aa rot hs vs kern =
  let attr name v =
    if v = "" then "" else Printf.sprintf " %s=\"%s\"" name (escape_xml v)
  in
  String.concat "" [
    attr "text-transform" tt;
    attr "font-variant" fv;
    attr "baseline-shift" bs;
    attr "line-height" lh;
    attr "letter-spacing" ls;
    attr "xml:lang" lang;
    attr "urn:jas:1:aa-mode" aa;
    attr "rotate" rot;
    attr "horizontal-scale" hs;
    attr "vertical-scale" vs;
    attr "urn:jas:1:kerning-mode" kern;
  ]

(** Emit a single tspan as an SVG [<tspan ...>content</tspan>]. Only
    overridden attributes are written (inherited values are absent).
    Matches Rust's [tspan_svg] and Swift's [tspanSvg] — the 5
    attributes that round-trip natively through SVG: font-family,
    font-size, font-weight, font-style, text-decoration. *)
let tspan_svg (t : Element.tspan) : string =
  let attr_str name = function
    | Some v -> Printf.sprintf " %s=\"%s\"" name (escape_xml v)
    | None -> ""
  in
  let attr_f name = function
    | Some v -> Printf.sprintf " %s=\"%s\"" name (fmt (px v))
    | None -> ""
  in
  let decor_attr = match t.text_decoration with
    | Some ds when ds <> [] ->
      Printf.sprintf " text-decoration=\"%s\"" (escape_xml (String.concat " " ds))
    | _ -> ""
  in
  (* Per-tspan rotation. Our model stores a single float per tspan,
     so per-glyph varying rotations require each glyph to live in its
     own tspan (enforced by the Touch Type tool). SVG's multi-value
     [rotate="a1 a2 …"] form is handled on the parse side by
     splitting the tspan into one per glyph. *)
  let rotate_attr = match t.rotate with
    | Some v -> Printf.sprintf " rotate=\"%s\"" (fmt v)
    | None -> ""
  in
  Printf.sprintf "<tspan%s%s%s%s%s%s>%s</tspan>"
    (attr_str "font-family" t.font_family)
    (attr_f "font-size" t.font_size)
    (attr_str "font-weight" t.font_weight)
    (attr_str "font-style" t.font_style)
    decor_attr
    rotate_attr
    (escape_xml t.content)

let rec element_svg indent (elem : Element.element) =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; stroke; opacity; transform; _ } ->
    Printf.sprintf "%s<line x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"%s%s%s/>"
      indent (fmt (px x1)) (fmt (px y1)) (fmt (px x2)) (fmt (px y2))
      (stroke_attrs stroke) (opacity_attr opacity) (transform_attr transform)
  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; _ } ->
    let rxy = (if rx > 0.0 then Printf.sprintf " rx=\"%s\"" (fmt (px rx)) else "")
            ^ (if ry > 0.0 then Printf.sprintf " ry=\"%s\"" (fmt (px ry)) else "") in
    Printf.sprintf "%s<rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\"%s%s%s%s%s/>"
      indent (fmt (px x)) (fmt (px y)) (fmt (px width)) (fmt (px height))
      rxy (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Circle { cx; cy; r; fill; stroke; opacity; transform; _ } ->
    Printf.sprintf "%s<circle cx=\"%s\" cy=\"%s\" r=\"%s\"%s%s%s%s/>"
      indent (fmt (px cx)) (fmt (px cy)) (fmt (px r))
      (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; _ } ->
    Printf.sprintf "%s<ellipse cx=\"%s\" cy=\"%s\" rx=\"%s\" ry=\"%s\"%s%s%s%s/>"
      indent (fmt (px cx)) (fmt (px cy)) (fmt (px rx)) (fmt (px ry))
      (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform)
  | Polyline { points; fill; stroke; opacity; transform; _ } ->
    let ps = String.concat " "
      (List.map (fun (x, y) -> Printf.sprintf "%s,%s" (fmt (px x)) (fmt (px y))) points) in
    Printf.sprintf "%s<polyline points=\"%s\"%s%s%s%s/>"
      indent ps (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Polygon { points; fill; stroke; opacity; transform; _ } ->
    let ps = String.concat " "
      (List.map (fun (x, y) -> Printf.sprintf "%s,%s" (fmt (px x)) (fmt (px y))) points) in
    Printf.sprintf "%s<polygon points=\"%s\"%s%s%s%s/>"
      indent ps (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Path { d; fill; stroke; opacity; transform; _ } ->
    Printf.sprintf "%s<path d=\"%s\"%s%s%s%s/>"
      indent (path_data d) (fill_attrs fill) (stroke_attrs stroke)
      (opacity_attr opacity) (transform_attr transform)
  | Text { x; y; content; font_family; font_size; font_weight; font_style; text_decoration;
           text_transform; font_variant; baseline_shift; line_height; letter_spacing;
           xml_lang; aa_mode; rotate; horizontal_scale; vertical_scale; kerning;
           text_width; text_height = _; fill; stroke; opacity; transform;
           tspans; _ } ->
    let area_attrs = if text_width > 0.0 then
      Printf.sprintf " style=\"inline-size: %spx; white-space: pre-wrap;\"" (fmt (px text_width))
    else "" in
    let fw_attr = if font_weight <> "normal" then Printf.sprintf " font-weight=\"%s\"" font_weight else "" in
    let fs_attr = if font_style <> "normal" then Printf.sprintf " font-style=\"%s\"" font_style else "" in
    let td_attr = if text_decoration <> "none" && text_decoration <> "" then Printf.sprintf " text-decoration=\"%s\"" text_decoration else "" in
    let extra = text_extra_attrs text_transform font_variant baseline_shift line_height letter_spacing xml_lang aa_mode rotate horizontal_scale vertical_scale kerning in
    (* SVG `y` is the baseline of the first line; internally `y` is the
       *top* of the layout box, so add the ascent (0.8 *. font_size,
       matching [Text_layout]). *)
    let svg_y = y +. font_size *. 0.8 in
    (* Pre-Tspan-compatible emission: a single no-override tspan
       round-trips as a flat <text>contents</text>. Multi-tspan or any
       override carries xml:space="preserve" so inter-tspan whitespace
       is byte-stable across round-trips (TSPAN.md SVG serialization). *)
    let is_flat = Array.length tspans = 1 && Tspan.has_no_overrides tspans.(0) in
    let body = if is_flat then escape_xml content
               else String.concat "" (Array.to_list (Array.map tspan_svg tspans)) in
    let space_attr = if is_flat then "" else " xml:space=\"preserve\"" in
    Printf.sprintf "%s<text x=\"%s\" y=\"%s\" font-family=\"%s\" font-size=\"%s\"%s%s%s%s%s%s%s%s%s%s>%s</text>"
      indent (fmt (px x)) (fmt (px svg_y)) (escape_xml font_family) (fmt (px font_size))
      fw_attr fs_attr td_attr extra
      area_attrs (fill_attrs fill) (stroke_attrs stroke) (opacity_attr opacity)
      (transform_attr transform) space_attr body
  | Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; text_decoration;
                text_transform; font_variant; baseline_shift; line_height; letter_spacing;
                xml_lang; aa_mode; rotate; horizontal_scale; vertical_scale; kerning;
                fill; stroke; opacity; transform; tspans; _ } ->
    let offset_attr = if start_offset > 0.0 then
      Printf.sprintf " startOffset=\"%s%%\"" (fmt (start_offset *. 100.0))
    else "" in
    let fw_attr = if font_weight <> "normal" then Printf.sprintf " font-weight=\"%s\"" font_weight else "" in
    let fs_attr = if font_style <> "normal" then Printf.sprintf " font-style=\"%s\"" font_style else "" in
    let td_attr = if text_decoration <> "none" && text_decoration <> "" then Printf.sprintf " text-decoration=\"%s\"" text_decoration else "" in
    let extra = text_extra_attrs text_transform font_variant baseline_shift line_height letter_spacing xml_lang aa_mode rotate horizontal_scale vertical_scale kerning in
    let is_flat = Array.length tspans = 1 && Tspan.has_no_overrides tspans.(0) in
    let body = if is_flat then escape_xml content
               else String.concat "" (Array.to_list (Array.map tspan_svg tspans)) in
    let space_attr = if is_flat then "" else " xml:space=\"preserve\"" in
    Printf.sprintf "%s<text%s%s font-family=\"%s\" font-size=\"%s\"%s%s%s%s%s%s><textPath path=\"%s\"%s%s>%s</textPath></text>"
      indent (fill_attrs fill) (stroke_attrs stroke)
      (escape_xml font_family) (fmt (px font_size))
      fw_attr fs_attr td_attr extra
      (opacity_attr opacity) (transform_attr transform)
      (path_data d) offset_attr space_attr body
  | Group { children; opacity; transform; _ } ->
    let header = Printf.sprintf "%s<g%s%s>"
      indent (opacity_attr opacity) (transform_attr transform) in
    let child_lines = Array.to_list (Array.map (element_svg (indent ^ "  ")) children) in
    let footer = Printf.sprintf "%s</g>" indent in
    String.concat "\n" (header :: child_lines @ [footer])
  | Layer { name; children; opacity; transform; _ } ->
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

let parse_hex2 s i =
  int_of_string ("0x" ^ String.sub s i 2)

let named_colors = [
  "black", (0, 0, 0); "white", (255, 255, 255); "red", (255, 0, 0);
  "green", (0, 128, 0); "blue", (0, 0, 255); "yellow", (255, 255, 0);
  "cyan", (0, 255, 255); "magenta", (255, 0, 255); "gray", (128, 128, 128);
  "grey", (128, 128, 128); "silver", (192, 192, 192); "maroon", (128, 0, 0);
  "olive", (128, 128, 0); "lime", (0, 255, 0); "aqua", (0, 255, 255);
  "teal", (0, 128, 128); "navy", (0, 0, 128); "fuchsia", (255, 0, 255);
  "purple", (128, 0, 128); "orange", (255, 165, 0); "pink", (255, 192, 203);
  "brown", (165, 42, 42); "coral", (255, 127, 80); "crimson", (220, 20, 60);
  "gold", (255, 215, 0); "indigo", (75, 0, 130); "ivory", (255, 255, 240);
  "khaki", (240, 230, 140); "lavender", (230, 230, 250); "plum", (221, 160, 221);
  "salmon", (250, 128, 114); "sienna", (160, 82, 45); "tan", (210, 180, 140);
  "tomato", (255, 99, 71); "turquoise", (64, 224, 208); "violet", (238, 130, 238);
  "wheat", (245, 222, 179); "steelblue", (70, 130, 180); "skyblue", (135, 206, 235);
  "slategray", (112, 128, 144); "slategrey", (112, 128, 144);
  "darkgray", (169, 169, 169); "darkgrey", (169, 169, 169);
  "lightgray", (211, 211, 211); "lightgrey", (211, 211, 211);
  "darkblue", (0, 0, 139); "darkgreen", (0, 100, 0); "darkred", (139, 0, 0);
]

let lookup_named_color name =
  let lower = String.lowercase_ascii name in
  match List.assoc_opt lower named_colors with
  | Some (r, g, b) ->
    Some (Element.make_color (float r /. 255.0) (float g /. 255.0) (float b /. 255.0))
  | None -> None

let parse_color s =
  let s = String.trim s in
  if s = "none" then None
  else match lookup_named_color s with
  | Some _ as c -> c
  | None ->
  if String.length s = 4 && s.[0] = '#' then
    (* #RGB *)
    (try
       let c1 = int_of_string ("0x" ^ String.make 2 s.[1]) in
       let c2 = int_of_string ("0x" ^ String.make 2 s.[2]) in
       let c3 = int_of_string ("0x" ^ String.make 2 s.[3]) in
       Some (Element.make_color (float c1 /. 255.0) (float c2 /. 255.0) (float c3 /. 255.0))
     with _ -> None)
  else if String.length s = 5 && s.[0] = '#' then
    (* #RGBA *)
    (try
       let c1 = int_of_string ("0x" ^ String.make 2 s.[1]) in
       let c2 = int_of_string ("0x" ^ String.make 2 s.[2]) in
       let c3 = int_of_string ("0x" ^ String.make 2 s.[3]) in
       let c4 = int_of_string ("0x" ^ String.make 2 s.[4]) in
       Some (Element.make_color ~a:(float c4 /. 255.0) (float c1 /. 255.0) (float c2 /. 255.0) (float c3 /. 255.0))
     with _ -> None)
  else if String.length s = 7 && s.[0] = '#' then
    (* #RRGGBB *)
    (try
       let r = parse_hex2 s 1 in let g = parse_hex2 s 3 in let b = parse_hex2 s 5 in
       Some (Element.make_color (float r /. 255.0) (float g /. 255.0) (float b /. 255.0))
     with _ -> None)
  else if String.length s = 9 && s.[0] = '#' then
    (* #RRGGBBAA *)
    (try
       let r = parse_hex2 s 1 in let g = parse_hex2 s 3 in let b = parse_hex2 s 5 in let a = parse_hex2 s 7 in
       Some (Element.make_color ~a:(float a /. 255.0) (float r /. 255.0) (float g /. 255.0) (float b /. 255.0))
     with _ -> None)
  else
    try Scanf.sscanf s "rgba(%d,%d,%d,%f)"
      (fun r g b a -> Some (Element.make_color ~a (float r /. 255.0) (float g /. 255.0) (float b /. 255.0)))
    with _ ->
    try Scanf.sscanf s "rgb(%d,%d,%d)"
      (fun r g b -> Some (Element.make_color (float r /. 255.0) (float g /. 255.0) (float b /. 255.0)))
    with _ ->
      Printf.eprintf "Warning: unrecognized SVG color value: %s\n" s;
      None

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
    | Some c ->
      let opacity = get_attr_f attrs "fill-opacity" 1.0 in
      Some (Element.make_fill ~opacity c)
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
      let opacity = get_attr_f attrs "stroke-opacity" 1.0 in
      Some (Element.make_stroke ~width ~linecap ~linejoin ~opacity c)

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
  let cur_x = ref 0.0 in let cur_y = ref 0.0 in
  let start_x = ref 0.0 in let start_y = ref 0.0 in
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
  let update x y = cur_x := x; cur_y := y in
  let cmds = ref [] in
  let add c = cmds := c :: !cmds in
  while !pos < len do
    skip_ws ();
    if !pos >= len then ()
    else
      let c = d.[!pos] in
      match c with
      | 'M' -> incr pos;
        let x = read_num () in let y = read_num () in
        add (Element.MoveTo (pt x, pt y));
        update x y; start_x := x; start_y := y
      | 'm' -> incr pos;
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.MoveTo (pt x, pt y));
        update x y; start_x := x; start_y := y
      | 'L' -> incr pos;
        let x = read_num () in let y = read_num () in
        add (Element.LineTo (pt x, pt y));
        update x y
      | 'l' -> incr pos;
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.LineTo (pt x, pt y));
        update x y
      | 'H' -> incr pos;
        let x = read_num () in
        add (Element.LineTo (pt x, pt !cur_y));
        cur_x := x
      | 'h' -> incr pos;
        let x = !cur_x +. read_num () in
        add (Element.LineTo (pt x, pt !cur_y));
        cur_x := x
      | 'V' -> incr pos;
        let y = read_num () in
        add (Element.LineTo (pt !cur_x, pt y));
        cur_y := y
      | 'v' -> incr pos;
        let y = !cur_y +. read_num () in
        add (Element.LineTo (pt !cur_x, pt y));
        cur_y := y
      | 'C' -> incr pos;
        let x1 = read_num () in let y1 = read_num () in
        let x2 = read_num () in let y2 = read_num () in
        let x = read_num () in let y = read_num () in
        add (Element.CurveTo (pt x1, pt y1, pt x2, pt y2, pt x, pt y));
        update x y
      | 'c' -> incr pos;
        let x1 = !cur_x +. read_num () in let y1 = !cur_y +. read_num () in
        let x2 = !cur_x +. read_num () in let y2 = !cur_y +. read_num () in
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.CurveTo (pt x1, pt y1, pt x2, pt y2, pt x, pt y));
        update x y
      | 'S' -> incr pos;
        let x2 = read_num () in let y2 = read_num () in
        let x = read_num () in let y = read_num () in
        add (Element.SmoothCurveTo (pt x2, pt y2, pt x, pt y));
        update x y
      | 's' -> incr pos;
        let x2 = !cur_x +. read_num () in let y2 = !cur_y +. read_num () in
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.SmoothCurveTo (pt x2, pt y2, pt x, pt y));
        update x y
      | 'Q' -> incr pos;
        let x1 = read_num () in let y1 = read_num () in
        let x = read_num () in let y = read_num () in
        add (Element.QuadTo (pt x1, pt y1, pt x, pt y));
        update x y
      | 'q' -> incr pos;
        let x1 = !cur_x +. read_num () in let y1 = !cur_y +. read_num () in
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.QuadTo (pt x1, pt y1, pt x, pt y));
        update x y
      | 'T' -> incr pos;
        let x = read_num () in let y = read_num () in
        add (Element.SmoothQuadTo (pt x, pt y));
        update x y
      | 't' -> incr pos;
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.SmoothQuadTo (pt x, pt y));
        update x y
      | 'A' -> incr pos;
        let rx = read_num () in let ry = read_num () in
        let rot = read_num () in
        let large = read_num () <> 0.0 in
        let sweep = read_num () <> 0.0 in
        let x = read_num () in let y = read_num () in
        add (Element.ArcTo (pt rx, pt ry, rot, large, sweep, pt x, pt y));
        update x y
      | 'a' -> incr pos;
        let rx = read_num () in let ry = read_num () in
        let rot = read_num () in
        let large = read_num () <> 0.0 in
        let sweep = read_num () <> 0.0 in
        let x = !cur_x +. read_num () in let y = !cur_y +. read_num () in
        add (Element.ArcTo (pt rx, pt ry, rot, large, sweep, pt x, pt y));
        update x y
      | 'Z' | 'z' -> incr pos; add Element.ClosePath;
        cur_x := !start_x; cur_y := !start_y
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
        let ff = match get_attr attrs "font-family" with Some s -> s | None -> "sans-serif" in
        let fs = pt (get_attr_f attrs "font-size" 16.0) in
        let fw = match get_attr attrs "font-weight" with Some s -> s | None -> "normal" in
        let fst = match get_attr attrs "font-style" with Some s -> s | None -> "normal" in
        let td = match get_attr attrs "text-decoration" with Some s -> s | None -> "none" in
        let getopt name = match get_attr attrs name with Some s -> s | None -> "" in
        let tt = getopt "text-transform" in
        let fv = getopt "font-variant" in
        let bs = getopt "baseline-shift" in
        let lh = getopt "line-height" in
        let ls = getopt "letter-spacing" in
        let lang = match get_attr attrs "xml:lang" with
          | Some s -> s
          | None -> (match get_attr attrs "lang" with Some s -> s | None -> "") in
        let aa = getopt "urn:jas:1:aa-mode" in
        let rotate = getopt "rotate" in
        let hs = getopt "horizontal-scale" in
        let vs = getopt "vertical-scale" in
        let kerning = getopt "urn:jas:1:kerning-mode" in
        let (tp_result, content, tspans_opt) = collect_text_or_textpath i in
        (match tp_result with
         | Some (tp_d, tp_content, tp_offset, tp_tspans_opt) ->
           let base = Element.make_text_path ~start_offset:tp_offset
             ~font_family:ff ~font_size:fs ~font_weight:fw ~font_style:fst ~text_decoration:td
             ~text_transform:tt ~font_variant:fv ~baseline_shift:bs
             ~line_height:lh ~letter_spacing:ls ~xml_lang:lang
             ~aa_mode:aa ~rotate ~horizontal_scale:hs ~vertical_scale:vs ~kerning
             ~fill ~stroke ~opacity ~transform tp_d tp_content in
           (* Preserve the parsed tspans when the <textPath> body had
              explicit children; make_text_path seeded tspans from the
              content string which would drop per-range overrides. *)
           (match tp_tspans_opt, base with
            | Some parsed, Element.Text_path r ->
              Some (Element.Text_path { r with tspans = parsed })
            | _ -> Some base)
         | None ->
           let tw = match get_attr attrs "style" with
             | Some style ->
               (try
                 let re = Str.regexp {|inline-size:[ ]*\([0-9.]+\)px|} in
                 ignore (Str.search_forward re style 0);
                 pt (float_of_string (Str.matched_group 1 style))
               with Not_found | Failure _ -> 0.0)
             | None -> 0.0
           in
           let th = if tw > 0.0 then
             let lines = max 1 (int_of_float (float_of_int (String.length content) *. fs *. Element.approx_char_width_factor /. tw) + 1) in
             float_of_int lines *. fs *. 1.2
           else 0.0 in
           (* SVG `y` is the baseline of the first line; convert to the
              layout-box top by subtracting the ascent (0.8 *. fs). *)
           let svg_y = pt (get_attr_f attrs "y" 0.0) in
           let base = Element.make_text ~font_family:ff ~font_size:fs ~font_weight:fw ~font_style:fst ~text_decoration:td
             ~text_transform:tt ~font_variant:fv ~baseline_shift:bs
             ~line_height:lh ~letter_spacing:ls ~xml_lang:lang
             ~aa_mode:aa ~rotate ~horizontal_scale:hs ~vertical_scale:vs ~kerning
             ~text_width:tw ~text_height:th ~fill ~stroke ~opacity ~transform
             (pt (get_attr_f attrs "x" 0.0))
             (svg_y -. fs *. 0.8)
             content in
           (match tspans_opt, base with
            | Some parsed, Element.Text r ->
              Some (Element.Text { r with tspans = parsed })
            | _ -> Some base))
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

and parse_tspan_body i attrs : Element.tspan list =
  (* Consume the body of a <tspan> start, returning one or more
     parsed tspans. Returns multiple tspans (one per glyph) when the
     SVG attribute [rotate="a b c …"] lists more than one angle and
     the content has multiple characters — the only legal way to
     express per-glyph varying rotates in our single-value-per-tspan
     model. Ids are left at 0; the caller assigns fresh sequential
     ids across the whole tspan list. *)
  let a = attrs_of_xmlm_attrs attrs in
  let content_buf = Buffer.create 16 in
  let rec loop () =
    match Xmlm.peek i with
    | `El_end -> let _ = Xmlm.input i in ()
    | `Data s -> let _ = Xmlm.input i in Buffer.add_string content_buf s; loop ()
    | `El_start _ -> skip_element_full i; loop ()
    | `Dtd _ -> let _ = Xmlm.input i in loop ()
  in
  loop ();
  let content = Buffer.contents content_buf in
  let font_size = match get_attr a "font-size" with
    | Some s -> (try Some (pt (float_of_string s)) with _ -> None)
    | None -> None
  in
  let decoration = match get_attr a "text-decoration" with
    | Some s ->
      let toks = String.split_on_char ' ' s
        |> List.filter (fun t -> t <> "" && t <> "none") in
      let sorted = List.sort compare toks in
      Some sorted
    | None -> None
  in
  let rotate_vals = match get_attr a "rotate" with
    | Some s ->
      String.split_on_char ' ' s
      |> List.filter_map (fun p ->
           let p = String.trim p in
           if p = "" then None else try Some (float_of_string p) with _ -> None)
    | None -> []
  in
  let base : Element.tspan = { (Tspan.default_tspan ()) with
    id = 0;
    content;
    font_family = get_attr a "font-family";
    font_size;
    font_weight = get_attr a "font-weight";
    font_style = get_attr a "font-style";
    text_decoration = decoration;
  } in
  match rotate_vals with
  | [] -> [base]
  | [v] -> [{ base with rotate = Some v }]
  | _ ->
    let char_count = Text_layout.utf8_char_count content in
    if char_count <= 1 then
      [{ base with rotate = Some (List.hd rotate_vals) }]
    else begin
      (* Split the tspan into one per glyph. Each inherits the base's
         override fields and gets the matching rotate angle; the last
         angle is reused for any trailing glyphs past the end of the
         list (per SVG spec). *)
      let angles = Array.of_list rotate_vals in
      let n_angles = Array.length angles in
      let last_angle = angles.(n_angles - 1) in
      let out = ref [] in
      for i = char_count - 1 downto 0 do
        let ch = Text_layout.utf8_sub content i 1 in
        let angle = if i < n_angles then angles.(i) else last_angle in
        out := { base with content = ch; rotate = Some angle } :: !out
      done;
      !out
    end

and collect_text_or_textpath i =
  (* Parse <text> children. Returns
     (textpath_option, plain_text, tspans_option). When any <tspan>
     children are seen they are returned in tspans_option; callers
     prefer those over plain_text. textPath's internal <tspan>
     children are collected inside the textPath path. *)
  let buf = Buffer.create 64 in
  let tspans_acc : Element.tspan list ref = ref [] in
  let next_id = ref 0 in
  let tp_result = ref None in
  let rec loop () =
    match Xmlm.peek i with
    | `El_end -> let _ = Xmlm.input i in ()
    | `Data s -> let _ = Xmlm.input i in Buffer.add_string buf s; loop ()
    | `El_start ((_, tag), attrs) when tag = "tspan" ->
      let _ = Xmlm.input i in  (* consume the El_start *)
      let parsed = parse_tspan_body i attrs in
      List.iter (fun (t : Element.tspan) ->
        let t = { t with id = !next_id } in
        incr next_id;
        tspans_acc := t :: !tspans_acc;
        Buffer.add_string buf t.content
      ) parsed;
      loop ()
    | `El_start ((_, tag), _) when tag = "textPath" ->
      let (_, tp_attrs) = match Xmlm.input i with `El_start (_, a) -> ("", a) | _ -> ("", []) in
      let tp_a = attrs_of_xmlm_attrs tp_attrs in
      let d_str = match get_attr tp_a "path" with Some s -> s | None ->
        match get_attr tp_a "d" with Some s -> s | None -> "" in
      let d = parse_path_d d_str in
      let tp_content = Buffer.create 32 in
      let tp_tspans_acc : Element.tspan list ref = ref [] in
      let tp_next_id = ref 0 in
      let rec collect_tp () =
        match Xmlm.peek i with
        | `El_end -> let _ = Xmlm.input i in ()
        | `Data s -> let _ = Xmlm.input i in Buffer.add_string tp_content s; collect_tp ()
        | `El_start ((_, tag), attrs) when tag = "tspan" ->
          let _ = Xmlm.input i in
          let parsed = parse_tspan_body i attrs in
          List.iter (fun (t : Element.tspan) ->
            let t = { t with id = !tp_next_id } in
            incr tp_next_id;
            tp_tspans_acc := t :: !tp_tspans_acc;
            Buffer.add_string tp_content t.content
          ) parsed;
          collect_tp ()
        | `El_start _ -> skip_element_full i; collect_tp ()
        | `Dtd _ -> let _ = Xmlm.input i in collect_tp ()
      in
      collect_tp ();
      let offset_str = match get_attr tp_a "startOffset" with Some s -> s | None -> "0" in
      let start_offset =
        let len = String.length offset_str in
        if len > 0 && offset_str.[len - 1] = '%' then
          (try float_of_string (String.sub offset_str 0 (len - 1)) /. 100.0
           with Failure _ -> 0.0)
        else
          (try float_of_string offset_str with _ -> 0.0)
      in
      let tp_tspans_opt =
        match List.rev !tp_tspans_acc with
        | [] -> None
        | xs -> Some (Array.of_list xs)
      in
      tp_result := Some (d, Buffer.contents tp_content, start_offset, tp_tspans_opt);
      loop ()
    | `El_start _ -> skip_element_full i; loop ()
    | `Dtd _ -> let _ = Xmlm.input i in loop ()
  in
  loop ();
  let tspans_opt = match List.rev !tspans_acc with
    | [] -> None
    | xs -> Some (Array.of_list xs)
  in
  (!tp_result, Buffer.contents buf, tspans_opt)

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
  try
    let i = Xmlm.make_input (`String (0, svg)) in
    (* skip dtd *)
    (match Xmlm.peek i with `Dtd _ -> let _ = Xmlm.input i in () | _ -> ());
    (* expect <svg> start *)
    (match Xmlm.input i with `El_start _ -> () | _ -> failwith "expected <svg> element");
    let children = parse_children i in
    let layers = Array.to_list (Array.map (fun elem ->
      match elem with
      | Element.Layer _ -> elem
      | Element.Group { children; opacity; transform; _ } ->
        Element.make_layer ~name:"" ~opacity ~transform children
      | _ ->
        Element.make_layer ~name:"" [|elem|]
    ) children) in
    let layers = if layers = [] then [Element.make_layer [||]] else layers in
    Normalize.normalize_document (Document.make_document (Array.of_list layers))
  with e ->
    Printf.eprintf "Warning: SVG parse error: %s\n" (Printexc.to_string e);
    Document.make_document [|Element.make_layer [||]|]
