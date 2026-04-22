(** Binary document serialization using MessagePack + deflate.

    Format:
      [Magic 4B "JAS\000"] [Version u16 LE] [Flags u16 LE] [Payload]

    Flags bits 0-1: compression method (0=none, 1=raw deflate).
    Payload: MessagePack-encoded document using positional arrays. *)

open Element
open Document

(* -- Constants ----------------------------------------------------------- *)

let magic = "JAS\000"
let version = 1
let header_size = 8

let compress_none = 0
let compress_deflate = 1

(* Element type tags *)
let tag_layer = 0
let tag_line = 1
let tag_rect = 2
let tag_circle = 3
let tag_ellipse = 4
let tag_polyline = 5
let tag_polygon = 6
let tag_path = 7
let tag_text = 8
let tag_text_path = 9
let tag_group = 10

(* Path command tags *)
let cmd_move_to = 0
let cmd_line_to = 1
let cmd_curve_to = 2
let cmd_smooth_curve_to = 3
let cmd_quad_to = 4
let cmd_smooth_quad_to = 5
let cmd_arc_to = 6
let cmd_close_path = 7

(* Color space tags *)
let space_rgb = 0
let space_hsb = 1
let space_cmyk = 2

(* -- Helpers ------------------------------------------------------------- *)

let vint n = Msgpck.Int n
let vf64 f = Msgpck.Float f
let vbool b = Msgpck.Bool b
let vstr s = Msgpck.String s
let vlist l = Msgpck.List l

let as_int = function
  | Msgpck.Int n -> n
  | Msgpck.Float f -> int_of_float f
  | v -> failwith (Printf.sprintf "expected int, got %s" (Msgpck.show v))

let as_f64 = function
  | Msgpck.Float f -> f
  | Msgpck.Int n -> float_of_int n
  | v -> failwith (Printf.sprintf "expected float, got %s" (Msgpck.show v))

let as_bool = function
  | Msgpck.Bool b -> b
  | v -> failwith (Printf.sprintf "expected bool, got %s" (Msgpck.show v))

let as_str = function
  | Msgpck.String s -> s
  | v -> failwith (Printf.sprintf "expected string, got %s" (Msgpck.show v))

let as_list = function
  | Msgpck.List l -> l
  | v -> failwith (Printf.sprintf "expected list, got %s" (Msgpck.show v))

let is_nil = function Msgpck.Nil -> true | _ -> false

let vnil = Msgpck.Nil

(* Optional-aware packers: [None] packs as msgpack nil. *)
let opt_f64 = function Some f -> vf64 f | None -> vnil
let opt_str = function Some s -> vstr s | None -> vnil
let opt_bool = function Some b -> vbool b | None -> vnil

let as_opt_f64 = function Msgpck.Nil -> None | v -> Some (as_f64 v)
let as_opt_str = function Msgpck.Nil -> None | v -> Some (as_str v)
let as_opt_bool = function Msgpck.Nil -> None | v -> Some (as_bool v)

(* -- Pack ---------------------------------------------------------------- *)

let pack_color c =
  match c with
  | Rgb { r; g; b; a } ->
    vlist [vint space_rgb; vf64 r; vf64 g; vf64 b; vf64 0.0; vf64 a]
  | Hsb { h; s; b; a } ->
    vlist [vint space_hsb; vf64 h; vf64 s; vf64 b; vf64 0.0; vf64 a]
  | Cmyk { c; m; y; k; a } ->
    vlist [vint space_cmyk; vf64 c; vf64 m; vf64 y; vf64 k; vf64 a]

let pack_fill = function
  | None -> Msgpck.Nil
  | Some f -> vlist [pack_color f.fill_color; vf64 f.fill_opacity]

let pack_stroke = function
  | None -> Msgpck.Nil
  | Some s ->
    let cap = match s.stroke_linecap with Butt -> 0 | Round_cap -> 1 | Square -> 2 in
    let join = match s.stroke_linejoin with Miter -> 0 | Round_join -> 1 | Bevel -> 2 in
    let align = match s.stroke_align with Center -> 0 | Inside -> 1 | Outside -> 2 in
    let arrow_align = match s.stroke_arrow_align with Tip_at_end -> 0 | Center_at_end -> 1 in
    let dash = vlist (List.map vf64 s.stroke_dash_pattern) in
    vlist [pack_color s.stroke_color; vf64 s.stroke_width;
           vint cap; vint join; vf64 s.stroke_opacity;
           vf64 s.stroke_miter_limit; vint align; dash;
           vstr (string_of_arrowhead s.stroke_start_arrow);
           vstr (string_of_arrowhead s.stroke_end_arrow);
           vf64 s.stroke_start_arrow_scale;
           vf64 s.stroke_end_arrow_scale;
           vint arrow_align]

let pack_width_points pts =
  if pts = [] then Msgpck.Nil
  else vlist (List.map (fun (p : stroke_width_point) ->
    vlist [vf64 p.swp_t; vf64 p.swp_width_left; vf64 p.swp_width_right]
  ) pts)

let pack_transform = function
  | None -> Msgpck.Nil
  | Some t -> vlist [vf64 t.a; vf64 t.b; vf64 t.c; vf64 t.d; vf64 t.e; vf64 t.f]

let pack_vis = function
  | Invisible -> vint 0 | Outline -> vint 1 | Preview -> vint 2

(** Pack a single Tspan as a compact msgpack list, 22 elements in
    the same order Rust / Swift use. *)
let pack_tspan (t : Element.tspan) : Msgpck.t =
  let decor = match t.text_decoration with
    | Some members -> vlist (List.map vstr members)
    | None -> vnil
  in
  let transform = match t.transform with
    | Some tr -> vlist [vf64 tr.a; vf64 tr.b; vf64 tr.c;
                        vf64 tr.d; vf64 tr.e; vf64 tr.f]
    | None -> vnil
  in
  vlist [
    vint t.id;
    vstr t.content;
    opt_f64 t.baseline_shift;
    opt_f64 t.dx;
    opt_str t.font_family;
    opt_f64 t.font_size;
    opt_str t.font_style;
    opt_str t.font_variant;
    opt_str t.font_weight;
    opt_str t.jas_aa_mode;
    opt_bool t.jas_fractional_widths;
    opt_str t.jas_kerning_mode;
    opt_bool t.jas_no_break;
    opt_f64 t.letter_spacing;
    opt_f64 t.line_height;
    opt_f64 t.rotate;
    opt_str t.style_name;
    decor;
    opt_str t.text_rendering;
    opt_str t.text_transform;
    transform;
    opt_str t.xml_lang;
    opt_str t.jas_role;
    opt_f64 t.jas_left_indent;
    opt_f64 t.jas_right_indent;
    opt_bool t.jas_hyphenate;
    opt_bool t.jas_hanging_punctuation;
    opt_str t.jas_list_style;
    opt_str t.text_align;
    opt_str t.text_align_last;
    opt_f64 t.text_indent;
    opt_f64 t.jas_space_before;
    opt_f64 t.jas_space_after;
    opt_f64 t.jas_word_spacing_min;
    opt_f64 t.jas_word_spacing_desired;
    opt_f64 t.jas_word_spacing_max;
    opt_f64 t.jas_letter_spacing_min;
    opt_f64 t.jas_letter_spacing_desired;
    opt_f64 t.jas_letter_spacing_max;
    opt_f64 t.jas_glyph_scaling_min;
    opt_f64 t.jas_glyph_scaling_desired;
    opt_f64 t.jas_glyph_scaling_max;
    opt_f64 t.jas_auto_leading;
    opt_str t.jas_single_word_justify;
    opt_f64 t.jas_hyphenate_min_word;
    opt_f64 t.jas_hyphenate_min_before;
    opt_f64 t.jas_hyphenate_min_after;
    opt_f64 t.jas_hyphenate_limit;
    opt_f64 t.jas_hyphenate_zone;
    opt_f64 t.jas_hyphenate_bias;
    opt_bool t.jas_hyphenate_capitalized;
  ]

(** Inverse of [pack_tspan]. Tolerant of trailing field additions —
    missing indices fall back to the [default_tspan] value. *)
let unpack_tspan v : Element.tspan =
  let arr = as_list v in
  let n = List.length arr in
  let get i = if i < n then List.nth arr i else Msgpck.Nil in
  let id = if n > 0 then as_int (List.nth arr 0) else 0 in
  let content = if n > 1 then as_str (List.nth arr 1) else "" in
  let decor = match get 17 with
    | Msgpck.List xs -> Some (List.map as_str xs)
    | _ -> None in
  let transform = match get 20 with
    | Msgpck.List xs when List.length xs >= 6 ->
      let f i = as_f64 (List.nth xs i) in
      Some { Element.a = f 0; b = f 1; c = f 2; d = f 3; e = f 4; f = f 5 }
    | _ -> None in
  { id; content;
    baseline_shift = as_opt_f64 (get 2);
    dx = as_opt_f64 (get 3);
    font_family = as_opt_str (get 4);
    font_size = as_opt_f64 (get 5);
    font_style = as_opt_str (get 6);
    font_variant = as_opt_str (get 7);
    font_weight = as_opt_str (get 8);
    jas_aa_mode = as_opt_str (get 9);
    jas_fractional_widths = as_opt_bool (get 10);
    jas_kerning_mode = as_opt_str (get 11);
    jas_no_break = as_opt_bool (get 12);
    letter_spacing = as_opt_f64 (get 13);
    line_height = as_opt_f64 (get 14);
    rotate = as_opt_f64 (get 15);
    style_name = as_opt_str (get 16);
    text_decoration = decor;
    text_rendering = as_opt_str (get 18);
    text_transform = as_opt_str (get 19);
    transform;
    xml_lang = as_opt_str (get 21);
    jas_role = as_opt_str (get 22);
    jas_left_indent = as_opt_f64 (get 23);
    jas_right_indent = as_opt_f64 (get 24);
    jas_hyphenate = as_opt_bool (get 25);
    jas_hanging_punctuation = as_opt_bool (get 26);
    jas_list_style = as_opt_str (get 27);
    text_align = as_opt_str (get 28);
    text_align_last = as_opt_str (get 29);
    text_indent = as_opt_f64 (get 30);
    jas_space_before = as_opt_f64 (get 31);
    jas_space_after = as_opt_f64 (get 32);
    jas_word_spacing_min = as_opt_f64 (get 33);
    jas_word_spacing_desired = as_opt_f64 (get 34);
    jas_word_spacing_max = as_opt_f64 (get 35);
    jas_letter_spacing_min = as_opt_f64 (get 36);
    jas_letter_spacing_desired = as_opt_f64 (get 37);
    jas_letter_spacing_max = as_opt_f64 (get 38);
    jas_glyph_scaling_min = as_opt_f64 (get 39);
    jas_glyph_scaling_desired = as_opt_f64 (get 40);
    jas_glyph_scaling_max = as_opt_f64 (get 41);
    jas_auto_leading = as_opt_f64 (get 42);
    jas_single_word_justify = as_opt_str (get 43);
    jas_hyphenate_min_word = as_opt_f64 (get 44);
    jas_hyphenate_min_before = as_opt_f64 (get 45);
    jas_hyphenate_min_after = as_opt_f64 (get 46);
    jas_hyphenate_limit = as_opt_f64 (get 47);
    jas_hyphenate_zone = as_opt_f64 (get 48);
    jas_hyphenate_bias = as_opt_f64 (get 49);
    jas_hyphenate_capitalized = as_opt_bool (get 50);
  }

let pack_path_command = function
  | MoveTo (x, y) -> vlist [vint cmd_move_to; vf64 x; vf64 y]
  | LineTo (x, y) -> vlist [vint cmd_line_to; vf64 x; vf64 y]
  | CurveTo (x1, y1, x2, y2, x, y) ->
    vlist [vint cmd_curve_to; vf64 x1; vf64 y1; vf64 x2; vf64 y2; vf64 x; vf64 y]
  | SmoothCurveTo (x2, y2, x, y) ->
    vlist [vint cmd_smooth_curve_to; vf64 x2; vf64 y2; vf64 x; vf64 y]
  | QuadTo (x1, y1, x, y) ->
    vlist [vint cmd_quad_to; vf64 x1; vf64 y1; vf64 x; vf64 y]
  | SmoothQuadTo (x, y) ->
    vlist [vint cmd_smooth_quad_to; vf64 x; vf64 y]
  | ArcTo (rx, ry, rot, la, sw, x, y) ->
    vlist [vint cmd_arc_to; vf64 rx; vf64 ry; vf64 rot;
           vbool la; vbool sw; vf64 x; vf64 y]
  | ClosePath -> vlist [vint cmd_close_path]

let rec pack_element = function
  | Layer { name; children; opacity; transform; locked; visibility; _ } ->
    let ch = Array.to_list (Array.map pack_element children) in
    vlist [vint tag_layer; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform; vstr name; vlist ch]
  | Group { children; opacity; transform; locked; visibility; _ } ->
    let ch = Array.to_list (Array.map pack_element children) in
    vlist [vint tag_group; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform; vlist ch]
  | Line { x1; y1; x2; y2; stroke; width_points; opacity; transform; locked; visibility; _ } ->
    vlist [vint tag_line; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x1; vf64 y1; vf64 x2; vf64 y2; pack_stroke stroke;
           pack_width_points width_points]
  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; locked; visibility; _ } ->
    vlist [vint tag_rect; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x; vf64 y; vf64 width; vf64 height; vf64 rx; vf64 ry;
           pack_fill fill; pack_stroke stroke]
  | Circle { cx; cy; r; fill; stroke; opacity; transform; locked; visibility; _ } ->
    vlist [vint tag_circle; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 cx; vf64 cy; vf64 r; pack_fill fill; pack_stroke stroke]
  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; locked; visibility; _ } ->
    vlist [vint tag_ellipse; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 cx; vf64 cy; vf64 rx; vf64 ry;
           pack_fill fill; pack_stroke stroke]
  | Polyline { points; fill; stroke; opacity; transform; locked; visibility; _ } ->
    let pts = List.map (fun (x, y) -> vlist [vf64 x; vf64 y]) points in
    vlist [vint tag_polyline; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist pts; pack_fill fill; pack_stroke stroke]
  | Polygon { points; fill; stroke; opacity; transform; locked; visibility; _ } ->
    let pts = List.map (fun (x, y) -> vlist [vf64 x; vf64 y]) points in
    vlist [vint tag_polygon; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist pts; pack_fill fill; pack_stroke stroke]
  | Path { d; fill; stroke; width_points; opacity; transform; locked; visibility; _ } ->
    let cmds = List.map pack_path_command d in
    vlist [vint tag_path; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist cmds; pack_fill fill; pack_stroke stroke;
           pack_width_points width_points]
  | Text { x; y; content; font_family; font_size; font_weight; font_style;
           text_decoration; text_width; text_height; fill; stroke;
           opacity; transform; locked; visibility; tspans; _ } ->
    let tspans_list = Array.to_list (Array.map pack_tspan tspans) in
    vlist [vint tag_text; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x; vf64 y; vstr content;
           vstr font_family; vf64 font_size;
           vstr font_weight; vstr font_style; vstr text_decoration;
           vf64 text_width; vf64 text_height;
           pack_fill fill; pack_stroke stroke;
           vlist tspans_list]
  | Text_path { d; content; start_offset; font_family; font_size; font_weight;
                font_style; text_decoration; fill; stroke;
                opacity; transform; locked; visibility; tspans; _ } ->
    let cmds = List.map pack_path_command d in
    let tspans_list = Array.to_list (Array.map pack_tspan tspans) in
    vlist [vint tag_text_path; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist cmds; vstr content; vf64 start_offset;
           vstr font_family; vf64 font_size;
           vstr font_weight; vstr font_style; vstr text_decoration;
           pack_fill fill; pack_stroke stroke;
           vlist tspans_list]
  | Live _ ->
    (* Phase 1: binary serialization of Live elements is deferred to
       the phase that implements compound-shape document I/O. *)
    failwith "binary serialization of Live elements not yet implemented"

let pack_selection sel =
  let entries = PathMap.fold (fun _path es acc ->
    let p = List.map vint es.es_path in
    let kind = match es.es_kind with
      | SelKindAll -> vint 0
      | SelKindPartial cps ->
        vlist (vint 1 :: List.map vint (SortedCps.to_list cps))
    in
    (es.es_path, vlist [vlist p; kind]) :: acc
  ) sel [] in
  let sorted = List.sort (fun (a, _) (b, _) -> compare a b) entries in
  vlist (List.map snd sorted)

let pack_document doc =
  let layers = Array.to_list (Array.map pack_element doc.layers) in
  vlist [vlist layers; vint doc.selected_layer; pack_selection doc.selection]

(* -- Unpack -------------------------------------------------------------- *)

let unpack_color v =
  let arr = as_list v in
  let space = as_int (List.nth arr 0) in
  if space = space_rgb then
    Rgb { r = as_f64 (List.nth arr 1); g = as_f64 (List.nth arr 2);
          b = as_f64 (List.nth arr 3); a = as_f64 (List.nth arr 5) }
  else if space = space_hsb then
    Hsb { h = as_f64 (List.nth arr 1); s = as_f64 (List.nth arr 2);
          b = as_f64 (List.nth arr 3); a = as_f64 (List.nth arr 5) }
  else if space = space_cmyk then
    Cmyk { c = as_f64 (List.nth arr 1); m = as_f64 (List.nth arr 2);
           y = as_f64 (List.nth arr 3); k = as_f64 (List.nth arr 4);
           a = as_f64 (List.nth arr 5) }
  else failwith (Printf.sprintf "unknown color space: %d" space)

let unpack_fill v =
  if is_nil v then None
  else let arr = as_list v in
    Some { fill_color = unpack_color (List.nth arr 0);
           fill_opacity = as_f64 (List.nth arr 1) }

let unpack_stroke v =
  if is_nil v then None
  else let arr = as_list v in
    let cap = match as_int (List.nth arr 2) with
      | 0 -> Butt | 1 -> Round_cap | 2 -> Square
      | n -> failwith (Printf.sprintf "unknown linecap: %d" n) in
    let join = match as_int (List.nth arr 3) with
      | 0 -> Miter | 1 -> Round_join | 2 -> Bevel
      | n -> failwith (Printf.sprintf "unknown linejoin: %d" n) in
    if List.length arr > 5 then
      let miter_limit = as_f64 (List.nth arr 5) in
      let align = match as_int (List.nth arr 6) with
        | 1 -> Inside | 2 -> Outside | _ -> Center in
      let dash_pattern = List.map as_f64 (as_list (List.nth arr 7)) in
      let start_arrow = arrowhead_of_string (as_str (List.nth arr 8)) in
      let end_arrow = arrowhead_of_string (as_str (List.nth arr 9)) in
      let start_arrow_scale = as_f64 (List.nth arr 10) in
      let end_arrow_scale = as_f64 (List.nth arr 11) in
      let arrow_align = match as_int (List.nth arr 12) with
        | 1 -> Center_at_end | _ -> Tip_at_end in
      Some { stroke_color = unpack_color (List.nth arr 0);
             stroke_width = as_f64 (List.nth arr 1);
             stroke_linecap = cap; stroke_linejoin = join;
             stroke_miter_limit = miter_limit; stroke_align = align;
             stroke_dash_pattern = dash_pattern;
             stroke_start_arrow = start_arrow; stroke_end_arrow = end_arrow;
             stroke_start_arrow_scale = start_arrow_scale;
             stroke_end_arrow_scale = end_arrow_scale;
             stroke_arrow_align = arrow_align;
             stroke_opacity = as_f64 (List.nth arr 4) }
    else
      Some { stroke_color = unpack_color (List.nth arr 0);
             stroke_width = as_f64 (List.nth arr 1);
             stroke_linecap = cap; stroke_linejoin = join;
             stroke_miter_limit = 10.0; stroke_align = Center;
             stroke_dash_pattern = [];
             stroke_start_arrow = Arrow_none; stroke_end_arrow = Arrow_none;
             stroke_start_arrow_scale = 100.0; stroke_end_arrow_scale = 100.0;
             stroke_arrow_align = Tip_at_end;
             stroke_opacity = as_f64 (List.nth arr 4) }

let unpack_width_points v =
  if is_nil v then []
  else List.map (fun p ->
    let a = as_list p in
    { swp_t = as_f64 (List.nth a 0);
      swp_width_left = as_f64 (List.nth a 1);
      swp_width_right = as_f64 (List.nth a 2) }
  ) (as_list v)

let unpack_transform v =
  if is_nil v then None
  else let arr = as_list v in
    Some { a = as_f64 (List.nth arr 0); b = as_f64 (List.nth arr 1);
           c = as_f64 (List.nth arr 2); d = as_f64 (List.nth arr 3);
           e = as_f64 (List.nth arr 4); f = as_f64 (List.nth arr 5) }

let unpack_path_command v =
  let arr = as_list v in
  let tag = as_int (List.nth arr 0) in
  if tag = cmd_move_to then MoveTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2))
  else if tag = cmd_line_to then LineTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2))
  else if tag = cmd_curve_to then
    CurveTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2),
             as_f64 (List.nth arr 3), as_f64 (List.nth arr 4),
             as_f64 (List.nth arr 5), as_f64 (List.nth arr 6))
  else if tag = cmd_smooth_curve_to then
    SmoothCurveTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2),
                   as_f64 (List.nth arr 3), as_f64 (List.nth arr 4))
  else if tag = cmd_quad_to then
    QuadTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2),
            as_f64 (List.nth arr 3), as_f64 (List.nth arr 4))
  else if tag = cmd_smooth_quad_to then
    SmoothQuadTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2))
  else if tag = cmd_arc_to then
    ArcTo (as_f64 (List.nth arr 1), as_f64 (List.nth arr 2),
           as_f64 (List.nth arr 3),
           as_bool (List.nth arr 4), as_bool (List.nth arr 5),
           as_f64 (List.nth arr 6), as_f64 (List.nth arr 7))
  else if tag = cmd_close_path then ClosePath
  else failwith (Printf.sprintf "unknown path command tag: %d" tag)

let unpack_common arr =
  let locked = as_bool (List.nth arr 1) in
  let opacity = as_f64 (List.nth arr 2) in
  let visibility = match as_int (List.nth arr 3) with
    | 0 -> Invisible | 1 -> Outline | _ -> Preview in
  let transform = unpack_transform (List.nth arr 4) in
  (locked, opacity, visibility, transform)

let rec unpack_element v =
  let arr = as_list v in
  let tag = as_int (List.nth arr 0) in
  let (locked, opacity, visibility, transform) = unpack_common arr in
  if tag = tag_layer then
    let name = as_str (List.nth arr 5) in
    let children = Array.of_list (List.map unpack_element (as_list (List.nth arr 6))) in
    Layer { name; children; opacity; transform; locked; visibility; blend_mode = Element.Normal;
            mask = None;
            isolated_blending = false; knockout_group = false }
  else if tag = tag_group then
    let children = Array.of_list (List.map unpack_element (as_list (List.nth arr 5))) in
    Group { children; opacity; transform; locked; visibility; blend_mode = Element.Normal;
            mask = None;
            isolated_blending = false; knockout_group = false }
  else if tag = tag_line then
    let wp = if List.length arr > 10 then unpack_width_points (List.nth arr 10) else [] in
    Line { x1 = as_f64 (List.nth arr 5); y1 = as_f64 (List.nth arr 6);
           x2 = as_f64 (List.nth arr 7); y2 = as_f64 (List.nth arr 8);
           stroke = unpack_stroke (List.nth arr 9);
           width_points = wp;
           opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
             stroke_gradient = None;
           }
  else if tag = tag_rect then
    Rect { x = as_f64 (List.nth arr 5); y = as_f64 (List.nth arr 6);
           width = as_f64 (List.nth arr 7); height = as_f64 (List.nth arr 8);
           rx = as_f64 (List.nth arr 9); ry = as_f64 (List.nth arr 10);
           fill = unpack_fill (List.nth arr 11);
           stroke = unpack_stroke (List.nth arr 12);
           opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
             fill_gradient = None;
             stroke_gradient = None;
           }
  else if tag = tag_circle then
    Circle { cx = as_f64 (List.nth arr 5); cy = as_f64 (List.nth arr 6);
             r = as_f64 (List.nth arr 7);
             fill = unpack_fill (List.nth arr 8);
             stroke = unpack_stroke (List.nth arr 9);
             opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
               fill_gradient = None;
               stroke_gradient = None;
             }
  else if tag = tag_ellipse then
    Ellipse { cx = as_f64 (List.nth arr 5); cy = as_f64 (List.nth arr 6);
              rx = as_f64 (List.nth arr 7); ry = as_f64 (List.nth arr 8);
              fill = unpack_fill (List.nth arr 9);
              stroke = unpack_stroke (List.nth arr 10);
              opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
                fill_gradient = None;
                stroke_gradient = None;
              }
  else if tag = tag_polyline then
    let points = List.map (fun p ->
      let a = as_list p in (as_f64 (List.nth a 0), as_f64 (List.nth a 1))
    ) (as_list (List.nth arr 5)) in
    Polyline { points; fill = unpack_fill (List.nth arr 6);
               stroke = unpack_stroke (List.nth arr 7);
               opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
                 fill_gradient = None;
                 stroke_gradient = None;
               }
  else if tag = tag_polygon then
    let points = List.map (fun p ->
      let a = as_list p in (as_f64 (List.nth a 0), as_f64 (List.nth a 1))
    ) (as_list (List.nth arr 5)) in
    Polygon { points; fill = unpack_fill (List.nth arr 6);
              stroke = unpack_stroke (List.nth arr 7);
              opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
                fill_gradient = None;
                stroke_gradient = None;
              }
  else if tag = tag_path then
    let cmds = List.map unpack_path_command (as_list (List.nth arr 5)) in
    let wp = if List.length arr > 8 then unpack_width_points (List.nth arr 8) else [] in
    Path { d = cmds; fill = unpack_fill (List.nth arr 6);
           stroke = unpack_stroke (List.nth arr 7);
           width_points = wp;
           opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None;
             fill_gradient = None;
             stroke_gradient = None;
           }
  else if tag = tag_text then
    let content = as_str (List.nth arr 7) in
    (* Prefer the trailing tspans field when present; otherwise fall
       back to the single-default-tspan seeded from content (blobs
       predating the tspan codec extension). *)
    let tspans = if List.length arr > 17 then
      (match List.nth arr 17 with
       | Msgpck.List xs when xs <> [] ->
         Array.of_list (List.map unpack_tspan xs)
       | _ -> tspans_from_content content)
    else tspans_from_content content
    in
    Text { x = as_f64 (List.nth arr 5); y = as_f64 (List.nth arr 6);
           content;
           font_family = as_str (List.nth arr 8);
           font_size = as_f64 (List.nth arr 9);
           font_weight = as_str (List.nth arr 10);
           font_style = as_str (List.nth arr 11);
           text_decoration = as_str (List.nth arr 12);
           (* Character-panel attributes not yet persisted in the binary
              codec — default to empty on decode (a follow-up extends
              the format when partial-tspan editing lands). *)
           text_transform = ""; font_variant = ""; baseline_shift = "";
           line_height = ""; letter_spacing = ""; xml_lang = "";
           aa_mode = ""; rotate = ""; horizontal_scale = "";
           vertical_scale = ""; kerning = "";
           text_width = as_f64 (List.nth arr 13);
           text_height = as_f64 (List.nth arr 14);
           fill = unpack_fill (List.nth arr 15);
           stroke = unpack_stroke (List.nth arr 16);
           opacity; transform; locked; visibility; tspans; blend_mode = Element.Normal; mask = None }
  else if tag = tag_text_path then
    let cmds = List.map unpack_path_command (as_list (List.nth arr 5)) in
    let content = as_str (List.nth arr 6) in
    let tspans = if List.length arr > 15 then
      (match List.nth arr 15 with
       | Msgpck.List xs when xs <> [] ->
         Array.of_list (List.map unpack_tspan xs)
       | _ -> tspans_from_content content)
    else tspans_from_content content
    in
    Text_path { d = cmds; content;
                start_offset = as_f64 (List.nth arr 7);
                font_family = as_str (List.nth arr 8);
                font_size = as_f64 (List.nth arr 9);
                font_weight = as_str (List.nth arr 10);
                font_style = as_str (List.nth arr 11);
                text_decoration = as_str (List.nth arr 12);
                text_transform = ""; font_variant = ""; baseline_shift = "";
                line_height = ""; letter_spacing = ""; xml_lang = "";
                aa_mode = ""; rotate = ""; horizontal_scale = "";
                vertical_scale = ""; kerning = "";
                fill = unpack_fill (List.nth arr 13);
                stroke = unpack_stroke (List.nth arr 14);
                opacity; transform; locked; visibility; tspans; blend_mode = Element.Normal; mask = None }
  else failwith (Printf.sprintf "unknown element tag: %d" tag)

let unpack_selection v =
  let arr = as_list v in
  List.fold_left (fun acc item ->
    let item_arr = as_list item in
    let path = List.map as_int (as_list (List.nth item_arr 0)) in
    let kind = match List.nth item_arr 1 with
      | Msgpck.Int 0 -> SelKindAll
      | v ->
        let kind_arr = as_list v in
        let cps = SortedCps.from_list
          (List.map as_int (List.tl kind_arr)) in
        SelKindPartial cps
    in
    PathMap.add path { es_path = path; es_kind = kind } acc
  ) PathMap.empty arr

let unpack_document v =
  let arr = as_list v in
  let layers = Array.of_list (List.map unpack_element (as_list (List.nth arr 0))) in
  let selected_layer = as_int (List.nth arr 1) in
  let selection = unpack_selection (List.nth arr 2) in
  (* Binary format predates artboards — parsed docs have empty
     artboards; app load-time repair seeds a default. *)
  { layers; selected_layer; selection;
    artboards = [];
    artboard_options = Artboard.default_options }

(* -- Raw deflate compression --------------------------------------------- *)

let deflate_compress_bytes input =
  let pos = ref 0 in
  let buf = Buffer.create (String.length input) in
  Zlib.compress ~header:false
    (fun obuf ->
      let avail = String.length input - !pos in
      let len = min (Bytes.length obuf) avail in
      Bytes.blit_string input !pos obuf 0 len;
      pos := !pos + len;
      len)
    (fun obuf len -> Buffer.add_subbytes buf obuf 0 len);
  Buffer.contents buf

let deflate_decompress_bytes input =
  let pos = ref 0 in
  let buf = Buffer.create (String.length input * 4) in
  Zlib.uncompress ~header:false
    (fun obuf ->
      let avail = String.length input - !pos in
      let len = min (Bytes.length obuf) avail in
      Bytes.blit_string input !pos obuf 0 len;
      pos := !pos + len;
      len)
    (fun obuf len -> Buffer.add_subbytes buf obuf 0 len);
  Buffer.contents buf

(* -- Public API ---------------------------------------------------------- *)

let document_to_binary ?(compress=true) doc =
  let value = pack_document doc in
  let buf = Buffer.create 256 in
  let _ = Msgpck.StringBuf.write buf value in
  let raw = Buffer.contents buf in
  let payload, flags =
    if compress then (deflate_compress_bytes raw, compress_deflate)
    else (raw, compress_none)
  in
  let out = Buffer.create (header_size + String.length payload) in
  Buffer.add_string out magic;
  (* version u16 LE *)
  Buffer.add_char out (Char.chr (version land 0xFF));
  Buffer.add_char out (Char.chr ((version lsr 8) land 0xFF));
  (* flags u16 LE *)
  Buffer.add_char out (Char.chr (flags land 0xFF));
  Buffer.add_char out (Char.chr ((flags lsr 8) land 0xFF));
  Buffer.add_string out payload;
  Buffer.contents out

let binary_to_document data =
  let len = String.length data in
  if len < header_size then
    failwith (Printf.sprintf "data too short: %d bytes, need at least %d" len header_size);
  if String.sub data 0 4 <> magic then
    failwith "invalid magic";
  let ver = Char.code data.[4] lor (Char.code data.[5] lsl 8) in
  if ver > version then
    failwith (Printf.sprintf "unsupported version: %d, max supported is %d" ver version);
  let flags = Char.code data.[6] lor (Char.code data.[7] lsl 8) in
  let compression = flags land 0x03 in
  let payload_str = String.sub data header_size (len - header_size) in
  let raw =
    if compression = compress_none then payload_str
    else if compression = compress_deflate then deflate_decompress_bytes payload_str
    else failwith (Printf.sprintf "unsupported compression method: %d" compression)
  in
  let (_pos, value) = Msgpck.StringBuf.read raw in
  unpack_document value
