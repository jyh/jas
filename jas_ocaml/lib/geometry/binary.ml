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
    vlist [pack_color s.stroke_color; vf64 s.stroke_width;
           vint cap; vint join; vf64 s.stroke_opacity]

let pack_transform = function
  | None -> Msgpck.Nil
  | Some t -> vlist [vf64 t.a; vf64 t.b; vf64 t.c; vf64 t.d; vf64 t.e; vf64 t.f]

let pack_vis = function
  | Invisible -> vint 0 | Outline -> vint 1 | Preview -> vint 2

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
  | Layer { name; children; opacity; transform; locked; visibility } ->
    let ch = Array.to_list (Array.map pack_element children) in
    vlist [vint tag_layer; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform; vstr name; vlist ch]
  | Group { children; opacity; transform; locked; visibility } ->
    let ch = Array.to_list (Array.map pack_element children) in
    vlist [vint tag_group; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform; vlist ch]
  | Line { x1; y1; x2; y2; stroke; opacity; transform; locked; visibility } ->
    vlist [vint tag_line; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x1; vf64 y1; vf64 x2; vf64 y2; pack_stroke stroke]
  | Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; locked; visibility } ->
    vlist [vint tag_rect; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x; vf64 y; vf64 width; vf64 height; vf64 rx; vf64 ry;
           pack_fill fill; pack_stroke stroke]
  | Circle { cx; cy; r; fill; stroke; opacity; transform; locked; visibility } ->
    vlist [vint tag_circle; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 cx; vf64 cy; vf64 r; pack_fill fill; pack_stroke stroke]
  | Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; locked; visibility } ->
    vlist [vint tag_ellipse; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 cx; vf64 cy; vf64 rx; vf64 ry;
           pack_fill fill; pack_stroke stroke]
  | Polyline { points; fill; stroke; opacity; transform; locked; visibility } ->
    let pts = List.map (fun (x, y) -> vlist [vf64 x; vf64 y]) points in
    vlist [vint tag_polyline; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist pts; pack_fill fill; pack_stroke stroke]
  | Polygon { points; fill; stroke; opacity; transform; locked; visibility } ->
    let pts = List.map (fun (x, y) -> vlist [vf64 x; vf64 y]) points in
    vlist [vint tag_polygon; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist pts; pack_fill fill; pack_stroke stroke]
  | Path { d; fill; stroke; opacity; transform; locked; visibility } ->
    let cmds = List.map pack_path_command d in
    vlist [vint tag_path; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist cmds; pack_fill fill; pack_stroke stroke]
  | Text { x; y; content; font_family; font_size; font_weight; font_style;
           text_decoration; text_width; text_height; fill; stroke;
           opacity; transform; locked; visibility } ->
    vlist [vint tag_text; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vf64 x; vf64 y; vstr content;
           vstr font_family; vf64 font_size;
           vstr font_weight; vstr font_style; vstr text_decoration;
           vf64 text_width; vf64 text_height;
           pack_fill fill; pack_stroke stroke]
  | Text_path { d; content; start_offset; font_family; font_size; font_weight;
                font_style; text_decoration; fill; stroke;
                opacity; transform; locked; visibility } ->
    let cmds = List.map pack_path_command d in
    vlist [vint tag_text_path; vbool locked; vf64 opacity; pack_vis visibility;
           pack_transform transform;
           vlist cmds; vstr content; vf64 start_offset;
           vstr font_family; vf64 font_size;
           vstr font_weight; vstr font_style; vstr text_decoration;
           pack_fill fill; pack_stroke stroke]

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
    Some { stroke_color = unpack_color (List.nth arr 0);
           stroke_width = as_f64 (List.nth arr 1);
           stroke_linecap = cap; stroke_linejoin = join;
           stroke_opacity = as_f64 (List.nth arr 4) }

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
    Layer { name; children; opacity; transform; locked; visibility }
  else if tag = tag_group then
    let children = Array.of_list (List.map unpack_element (as_list (List.nth arr 5))) in
    Group { children; opacity; transform; locked; visibility }
  else if tag = tag_line then
    Line { x1 = as_f64 (List.nth arr 5); y1 = as_f64 (List.nth arr 6);
           x2 = as_f64 (List.nth arr 7); y2 = as_f64 (List.nth arr 8);
           stroke = unpack_stroke (List.nth arr 9);
           opacity; transform; locked; visibility }
  else if tag = tag_rect then
    Rect { x = as_f64 (List.nth arr 5); y = as_f64 (List.nth arr 6);
           width = as_f64 (List.nth arr 7); height = as_f64 (List.nth arr 8);
           rx = as_f64 (List.nth arr 9); ry = as_f64 (List.nth arr 10);
           fill = unpack_fill (List.nth arr 11);
           stroke = unpack_stroke (List.nth arr 12);
           opacity; transform; locked; visibility }
  else if tag = tag_circle then
    Circle { cx = as_f64 (List.nth arr 5); cy = as_f64 (List.nth arr 6);
             r = as_f64 (List.nth arr 7);
             fill = unpack_fill (List.nth arr 8);
             stroke = unpack_stroke (List.nth arr 9);
             opacity; transform; locked; visibility }
  else if tag = tag_ellipse then
    Ellipse { cx = as_f64 (List.nth arr 5); cy = as_f64 (List.nth arr 6);
              rx = as_f64 (List.nth arr 7); ry = as_f64 (List.nth arr 8);
              fill = unpack_fill (List.nth arr 9);
              stroke = unpack_stroke (List.nth arr 10);
              opacity; transform; locked; visibility }
  else if tag = tag_polyline then
    let points = List.map (fun p ->
      let a = as_list p in (as_f64 (List.nth a 0), as_f64 (List.nth a 1))
    ) (as_list (List.nth arr 5)) in
    Polyline { points; fill = unpack_fill (List.nth arr 6);
               stroke = unpack_stroke (List.nth arr 7);
               opacity; transform; locked; visibility }
  else if tag = tag_polygon then
    let points = List.map (fun p ->
      let a = as_list p in (as_f64 (List.nth a 0), as_f64 (List.nth a 1))
    ) (as_list (List.nth arr 5)) in
    Polygon { points; fill = unpack_fill (List.nth arr 6);
              stroke = unpack_stroke (List.nth arr 7);
              opacity; transform; locked; visibility }
  else if tag = tag_path then
    let cmds = List.map unpack_path_command (as_list (List.nth arr 5)) in
    Path { d = cmds; fill = unpack_fill (List.nth arr 6);
           stroke = unpack_stroke (List.nth arr 7);
           opacity; transform; locked; visibility }
  else if tag = tag_text then
    Text { x = as_f64 (List.nth arr 5); y = as_f64 (List.nth arr 6);
           content = as_str (List.nth arr 7);
           font_family = as_str (List.nth arr 8);
           font_size = as_f64 (List.nth arr 9);
           font_weight = as_str (List.nth arr 10);
           font_style = as_str (List.nth arr 11);
           text_decoration = as_str (List.nth arr 12);
           text_width = as_f64 (List.nth arr 13);
           text_height = as_f64 (List.nth arr 14);
           fill = unpack_fill (List.nth arr 15);
           stroke = unpack_stroke (List.nth arr 16);
           opacity; transform; locked; visibility }
  else if tag = tag_text_path then
    let cmds = List.map unpack_path_command (as_list (List.nth arr 5)) in
    Text_path { d = cmds; content = as_str (List.nth arr 6);
                start_offset = as_f64 (List.nth arr 7);
                font_family = as_str (List.nth arr 8);
                font_size = as_f64 (List.nth arr 9);
                font_weight = as_str (List.nth arr 10);
                font_style = as_str (List.nth arr 11);
                text_decoration = as_str (List.nth arr 12);
                fill = unpack_fill (List.nth arr 13);
                stroke = unpack_stroke (List.nth arr 14);
                opacity; transform; locked; visibility }
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
  { layers; selected_layer; selection }

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
