(** Canonical Test JSON serialization for cross-language equivalence testing.

    See [CROSS_LANGUAGE_TESTING.md] at the repository root for the full
    specification.  Every semantic document value has exactly one JSON
    string representation, so byte-for-byte comparison of the output is a
    valid equivalence check. *)

open Element
open Document

(* ------------------------------------------------------------------ *)
(* Float formatting: round to 4 decimal places                        *)
(* ------------------------------------------------------------------ *)

let fmt v =
  let rounded = Float.round (v *. 10000.0) /. 10000.0 in
  if rounded = Float.round rounded && Float.rem rounded 1.0 = 0.0 then
    Printf.sprintf "%.1f" rounded
  else begin
    let s = Printf.sprintf "%.4f" rounded in
    (* Strip trailing zeros but keep at least one digit after decimal. *)
    let len = ref (String.length s) in
    while !len > 0
          && s.[!len - 1] = '0'
          && !len >= 2
          && s.[!len - 2] <> '.' do
      decr len
    done;
    String.sub s 0 !len
  end

(* ------------------------------------------------------------------ *)
(* JSON building helpers                                              *)
(* ------------------------------------------------------------------ *)

(** A tiny JSON builder that always emits keys in sorted order. *)
type json_obj = {
  mutable entries : (string * string) list;
}

let json_obj () = { entries = [] }

let json_str o key v =
  let escaped =
    v |> String.to_seq
      |> Seq.flat_map (fun c ->
        match c with
        | '\\' -> String.to_seq "\\\\"
        | '"'  -> String.to_seq "\\\""
        | c    -> Seq.return c)
      |> String.of_seq
  in
  o.entries <- (key, Printf.sprintf "\"%s\"" escaped) :: o.entries

let json_num o key v =
  o.entries <- (key, fmt v) :: o.entries

let json_int o key v =
  o.entries <- (key, string_of_int v) :: o.entries

let json_bool o key v =
  o.entries <- (key, if v then "true" else "false") :: o.entries

let json_null o key =
  o.entries <- (key, "null") :: o.entries

let json_raw o key v =
  o.entries <- (key, v) :: o.entries

(** Emit an empty string as null, otherwise as a JSON string.
    Matches the canonical-JSON rule that default / omitted
    attributes render as null. *)
let json_empty_as_null o key v =
  if v = "" then json_null o key
  else json_str o key v

let json_build o =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) o.entries in
  let pairs = List.map (fun (k, v) -> Printf.sprintf "\"%s\":%s" k v) sorted in
  Printf.sprintf "{%s}" (String.concat "," pairs)

let json_array items =
  Printf.sprintf "[%s]" (String.concat "," items)

(* ------------------------------------------------------------------ *)
(* Type serializers                                                   *)
(* ------------------------------------------------------------------ *)

let color_json (c : color) =
  let o = json_obj () in
  (match c with
   | Rgb { r; g; b; a } ->
     json_num o "a" a;
     json_num o "b" b;
     json_num o "g" g;
     json_num o "r" r;
     json_str o "space" "rgb"
   | Hsb { h; s; b; a } ->
     json_num o "a" a;
     json_num o "b" b;
     json_num o "h" h;
     json_num o "s" s;
     json_str o "space" "hsb"
   | Cmyk { c; m; y; k; a } ->
     json_num o "a" a;
     json_num o "c" c;
     json_num o "k" k;
     json_num o "m" m;
     json_str o "space" "cmyk";
     json_num o "y" y);
  json_build o

let fill_json = function
  | None -> "null"
  | Some f ->
    let o = json_obj () in
    json_raw o "color" (color_json f.fill_color);
    json_num o "opacity" f.fill_opacity;
    json_build o

let linecap_str = function
  | Butt -> "butt"
  | Round_cap -> "round"
  | Square -> "square"

let linejoin_str = function
  | Miter -> "miter"
  | Round_join -> "round"
  | Bevel -> "bevel"

let stroke_json = function
  | None -> "null"
  | Some s ->
    let o = json_obj () in
    json_raw o "color" (color_json s.stroke_color);
    json_str o "linecap" (linecap_str s.stroke_linecap);
    json_str o "linejoin" (linejoin_str s.stroke_linejoin);
    json_num o "opacity" s.stroke_opacity;
    json_num o "width" s.stroke_width;
    json_build o

let transform_json = function
  | None -> "null"
  | Some t ->
    let o = json_obj () in
    json_num o "a" t.a;
    json_num o "b" t.b;
    json_num o "c" t.c;
    json_num o "d" t.d;
    json_num o "e" t.e;
    json_num o "f" t.f;
    json_build o

let visibility_str = function
  | Invisible -> "invisible"
  | Outline -> "outline"
  | Preview -> "preview"

let common_fields o ~opacity ~transform ~locked ~visibility =
  json_bool o "locked" locked;
  json_num o "opacity" opacity;
  json_raw o "transform" (transform_json transform);
  json_str o "visibility" (visibility_str visibility)

(** Emit `text_decoration` as a sorted JSON array of CSS tokens. Empty
    string or `"none"` produces `[]`. Matches Rust's canonical form. *)
let text_decoration_array_json (td : string) =
  let tokens =
    String.split_on_char ' ' td
    |> List.filter (fun t -> t <> "" && t <> "none")
    |> List.sort_uniq String.compare
  in
  let quoted = List.map (fun t -> Printf.sprintf "\"%s\"" t) tokens in
  Printf.sprintf "[%s]" (String.concat "," quoted)

(** Emit a single default tspan carrying `content`, with id 0 and
    every override field `null`. Used to derive the `tspans` array
    from the flat `content` string on canonical-JSON emit. *)
let default_tspan_json (content : string) =
  let o = json_obj () in
  json_null o "baseline_shift";
  json_str o "content" content;
  json_null o "dx";
  json_null o "font_family";
  json_null o "font_size";
  json_null o "font_style";
  json_null o "font_variant";
  json_null o "font_weight";
  json_int o "id" 0;
  json_null o "jas_aa_mode";
  json_null o "jas_fractional_widths";
  json_null o "jas_kerning_mode";
  json_null o "jas_no_break";
  json_null o "letter_spacing";
  json_null o "line_height";
  json_null o "rotate";
  json_null o "style_name";
  json_null o "text_decoration";
  json_null o "text_rendering";
  json_null o "text_transform";
  json_null o "transform";
  json_null o "xml_lang";
  json_build o

let path_command_json cmd =
  let o = json_obj () in
  (match cmd with
   | MoveTo (x, y) ->
     json_str o "cmd" "M";
     json_num o "x" x;
     json_num o "y" y
   | LineTo (x, y) ->
     json_str o "cmd" "L";
     json_num o "x" x;
     json_num o "y" y
   | CurveTo (x1, y1, x2, y2, x, y) ->
     json_str o "cmd" "C";
     json_num o "x" x;
     json_num o "x1" x1;
     json_num o "x2" x2;
     json_num o "y" y;
     json_num o "y1" y1;
     json_num o "y2" y2
   | SmoothCurveTo (x2, y2, x, y) ->
     json_str o "cmd" "S";
     json_num o "x" x;
     json_num o "x2" x2;
     json_num o "y" y;
     json_num o "y2" y2
   | QuadTo (x1, y1, x, y) ->
     json_str o "cmd" "Q";
     json_num o "x" x;
     json_num o "x1" x1;
     json_num o "y" y;
     json_num o "y1" y1
   | SmoothQuadTo (x, y) ->
     json_str o "cmd" "T";
     json_num o "x" x;
     json_num o "y" y
   | ArcTo (rx, ry, x_rotation, large_arc, sweep, x, y) ->
     json_str o "cmd" "A";
     json_bool o "large_arc" large_arc;
     json_num o "rx" rx;
     json_num o "ry" ry;
     json_bool o "sweep" sweep;
     json_num o "x" x;
     json_num o "x_rotation" x_rotation;
     json_num o "y" y
   | ClosePath ->
     json_str o "cmd" "Z");
  json_build o

let points_json pts =
  let items = List.map (fun (x, y) -> Printf.sprintf "[%s,%s]" (fmt x) (fmt y)) pts in
  json_array items

(* ------------------------------------------------------------------ *)
(* Element serializer                                                 *)
(* ------------------------------------------------------------------ *)

let rec element_json = function
  | Line e ->
    let o = json_obj () in
    json_str o "type" "line";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_raw o "stroke" (stroke_json e.stroke);
    json_num o "x1" e.x1;
    json_num o "x2" e.x2;
    json_num o "y1" e.y1;
    json_num o "y2" e.y2;
    json_build o
  | Rect e ->
    let o = json_obj () in
    json_str o "type" "rect";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_raw o "fill" (fill_json e.fill);
    json_num o "height" e.height;
    json_num o "rx" e.rx;
    json_num o "ry" e.ry;
    json_raw o "stroke" (stroke_json e.stroke);
    json_num o "width" e.width;
    json_num o "x" e.x;
    json_num o "y" e.y;
    json_build o
  | Circle e ->
    let o = json_obj () in
    json_str o "type" "circle";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_num o "cx" e.cx;
    json_num o "cy" e.cy;
    json_raw o "fill" (fill_json e.fill);
    json_num o "r" e.r;
    json_raw o "stroke" (stroke_json e.stroke);
    json_build o
  | Ellipse e ->
    let o = json_obj () in
    json_str o "type" "ellipse";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_num o "cx" e.cx;
    json_num o "cy" e.cy;
    json_raw o "fill" (fill_json e.fill);
    json_num o "rx" e.rx;
    json_num o "ry" e.ry;
    json_raw o "stroke" (stroke_json e.stroke);
    json_build o
  | Polyline e ->
    let o = json_obj () in
    json_str o "type" "polyline";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_raw o "fill" (fill_json e.fill);
    json_raw o "points" (points_json e.points);
    json_raw o "stroke" (stroke_json e.stroke);
    json_build o
  | Polygon e ->
    let o = json_obj () in
    json_str o "type" "polygon";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_raw o "fill" (fill_json e.fill);
    json_raw o "points" (points_json e.points);
    json_raw o "stroke" (stroke_json e.stroke);
    json_build o
  | Path e ->
    let o = json_obj () in
    json_str o "type" "path";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    let cmds = List.map path_command_json e.d in
    json_raw o "d" (json_array cmds);
    json_raw o "fill" (fill_json e.fill);
    json_raw o "stroke" (stroke_json e.stroke);
    json_build o
  | Text e ->
    let o = json_obj () in
    json_str o "type" "text";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    (* Extended element-wide attribute slots. Still-null slots are
       placeholders until Text grows per-element override fields
       (see TSPAN.md Attribute Home). *)
    json_empty_as_null o "baseline_shift" e.baseline_shift;
    json_null o "dx";
    json_raw o "fill" (fill_json e.fill);
    json_str o "font_family" e.font_family;
    json_num o "font_size" e.font_size;
    json_str o "font_style" e.font_style;
    json_empty_as_null o "font_variant" e.font_variant;
    json_str o "font_weight" e.font_weight;
    json_num o "height" e.text_height;
    json_empty_as_null o "horizontal_scale" e.horizontal_scale;
    json_empty_as_null o "jas_aa_mode" e.aa_mode;
    json_null o "jas_fractional_widths";
    json_empty_as_null o "jas_kerning_mode" e.kerning;
    json_null o "jas_no_break";
    json_empty_as_null o "letter_spacing" e.letter_spacing;
    json_empty_as_null o "line_height" e.line_height;
    json_empty_as_null o "rotate" e.rotate;
    json_raw o "stroke" (stroke_json e.stroke);
    json_null o "style_name";
    json_raw o "text_decoration" (text_decoration_array_json e.text_decoration);
    json_null o "text_rendering";
    json_empty_as_null o "text_transform" e.text_transform;
    json_raw o "tspans" (json_array [default_tspan_json e.content]);
    json_empty_as_null o "vertical_scale" e.vertical_scale;
    json_num o "width" e.text_width;
    json_num o "x" e.x;
    json_empty_as_null o "xml_lang" e.xml_lang;
    json_num o "y" e.y;
    json_build o
  | Text_path e ->
    let o = json_obj () in
    json_str o "type" "text_path";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    json_empty_as_null o "baseline_shift" e.baseline_shift;
    let cmds = List.map path_command_json e.d in
    json_raw o "d" (json_array cmds);
    json_null o "dx";
    json_raw o "fill" (fill_json e.fill);
    json_str o "font_family" e.font_family;
    json_num o "font_size" e.font_size;
    json_str o "font_style" e.font_style;
    json_empty_as_null o "font_variant" e.font_variant;
    json_str o "font_weight" e.font_weight;
    json_empty_as_null o "horizontal_scale" e.horizontal_scale;
    json_empty_as_null o "jas_aa_mode" e.aa_mode;
    json_null o "jas_fractional_widths";
    json_empty_as_null o "jas_kerning_mode" e.kerning;
    json_null o "jas_no_break";
    json_empty_as_null o "letter_spacing" e.letter_spacing;
    json_empty_as_null o "line_height" e.line_height;
    json_empty_as_null o "rotate" e.rotate;
    json_num o "start_offset" e.start_offset;
    json_raw o "stroke" (stroke_json e.stroke);
    json_null o "style_name";
    json_raw o "text_decoration" (text_decoration_array_json e.text_decoration);
    json_null o "text_rendering";
    json_empty_as_null o "text_transform" e.text_transform;
    json_raw o "tspans" (json_array [default_tspan_json e.content]);
    json_empty_as_null o "vertical_scale" e.vertical_scale;
    json_empty_as_null o "xml_lang" e.xml_lang;
    json_build o
  | Group e ->
    let o = json_obj () in
    json_str o "type" "group";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    let children = Array.to_list e.children |> List.map element_json in
    json_raw o "children" (json_array children);
    json_build o
  | Layer e ->
    let o = json_obj () in
    json_str o "type" "layer";
    common_fields o ~opacity:e.opacity ~transform:e.transform
      ~locked:e.locked ~visibility:e.visibility;
    let children = Array.to_list e.children |> List.map element_json in
    json_raw o "children" (json_array children);
    json_str o "name" e.name;
    json_build o
  | Live (Compound_shape cs) ->
    let o = json_obj () in
    json_str o "type" "live";
    json_str o "kind" "compound_shape";
    common_fields o ~opacity:cs.opacity ~transform:cs.transform
      ~locked:cs.locked ~visibility:cs.visibility;
    let children = Array.to_list cs.operands |> List.map element_json in
    json_raw o "children" (json_array children);
    json_build o

(* ------------------------------------------------------------------ *)
(* Selection serializer                                               *)
(* ------------------------------------------------------------------ *)

let selection_json sel =
  let entries =
    PathMap.fold (fun _path es acc ->
      let o = json_obj () in
      (match es.es_kind with
       | SelKindAll ->
         json_str o "kind" "all"
       | SelKindPartial cps ->
         let indices = List.map string_of_int (SortedCps.to_list cps) in
         json_raw o "kind"
           (Printf.sprintf "{\"partial\":[%s]}" (String.concat "," indices)));
      let path = List.map string_of_int es.es_path in
      json_raw o "path" (Printf.sprintf "[%s]" (String.concat "," path));
      (es.es_path, json_build o) :: acc
    ) sel []
  in
  (* Sort by path lexicographically. *)
  let sorted =
    List.sort (fun (a, _) (b, _) -> compare a b) entries
  in
  let items = List.map snd sorted in
  json_array items

(* ------------------------------------------------------------------ *)
(* Document serializer (public API)                                   *)
(* ------------------------------------------------------------------ *)

(** Serialize a single artboard to canonical JSON. *)
let artboard_json (ab : Artboard.artboard) =
  let o = json_obj () in
  json_str o "id" ab.id;
  json_str o "name" ab.name;
  json_num o "x" ab.x;
  json_num o "y" ab.y;
  json_num o "width" ab.width;
  json_num o "height" ab.height;
  json_str o "fill" (Artboard.fill_as_canonical ab.fill);
  json_bool o "show_center_mark" ab.show_center_mark;
  json_bool o "show_cross_hairs" ab.show_cross_hairs;
  json_bool o "show_video_safe_areas" ab.show_video_safe_areas;
  json_num o "video_ruler_pixel_aspect_ratio" ab.video_ruler_pixel_aspect_ratio;
  json_build o

let artboards_json artboards =
  json_array (List.map artboard_json artboards)

let artboard_options_json (opts : Artboard.options) =
  let o = json_obj () in
  json_bool o "fade_region_outside_artboard" opts.fade_region_outside_artboard;
  json_bool o "update_while_dragging" opts.update_while_dragging;
  json_build o

(** Serialize a Document to canonical test JSON.

    Artboards and artboard_options are omitted when they carry
    defaults, preserving byte-for-byte compatibility with legacy
    fixtures that predate the artboards feature (cross-app
    contract, ART-441). *)
let document_to_test_json doc =
  let layers =
    Array.to_list doc.layers |> List.map element_json
  in
  let o = json_obj () in
  if doc.artboard_options <> Artboard.default_options then
    json_raw o "artboard_options" (artboard_options_json doc.artboard_options);
  if doc.artboards <> [] then
    json_raw o "artboards" (artboards_json doc.artboards);
  json_raw o "layers" (json_array layers);
  json_int o "selected_layer" doc.selected_layer;
  json_raw o "selection" (selection_json doc.selection);
  json_build o

(* ------------------------------------------------------------------ *)
(* JSON -> Document parser (inverse of document_to_test_json)         *)
(* ------------------------------------------------------------------ *)

open Yojson.Safe.Util

(** Parse a numeric JSON value, handling both floats and ints. *)
let to_num j =
  try to_float j with _ -> float_of_int (to_int j)

(** Parse an optional string: `null` → empty, else the string value. *)
let nullable_str j =
  try to_string j with _ -> ""

(** Parse the Text / Text_path `content` field. Accepts the canonical
    shape `tspans: [...]` (concatenates each tspan's content) or the
    legacy `content: "..."` string. *)
let parse_content_or_tspans j =
  try
    let tspans = j |> member "tspans" |> to_list in
    String.concat "" (List.map (fun t -> t |> member "content" |> to_string) tspans)
  with _ ->
    (try j |> member "content" |> to_string with _ -> "")

(** Parse the canonical-JSON `text_decoration` field, which is now a
    sorted array of CSS tokens (e.g. `["underline"]`) and was a
    legacy CSS string. Returns a space-separated CSS string for
    Text.text_decoration. *)
let parse_text_decoration j =
  try
    let tokens = j |> to_list |> List.map to_string in
    if tokens = [] then "none" else String.concat " " tokens
  with _ ->
    try to_string j with _ -> "none"

let parse_color j =
  let space = try j |> member "space" |> to_string with _ -> "rgb" in
  match space with
  | "hsb" ->
    Hsb { h = j |> member "h" |> to_num;
          s = j |> member "s" |> to_num;
          b = j |> member "b" |> to_num;
          a = j |> member "a" |> to_num }
  | "cmyk" ->
    Cmyk { c = j |> member "c" |> to_num;
           m = j |> member "m" |> to_num;
           y = j |> member "y" |> to_num;
           k = j |> member "k" |> to_num;
           a = j |> member "a" |> to_num }
  | _ ->
    Rgb { r = j |> member "r" |> to_num;
          g = j |> member "g" |> to_num;
          b = j |> member "b" |> to_num;
          a = j |> member "a" |> to_num }

let parse_fill j =
  if j = `Null then None
  else
    let opacity = try j |> member "opacity" |> to_num with _ -> 1.0 in
    Some { fill_color = parse_color (j |> member "color"); fill_opacity = opacity }

let parse_stroke j =
  if j = `Null then None
  else
    let lc = match j |> member "linecap" |> to_string with
      | "round" -> Round_cap
      | "square" -> Square
      | _ -> Butt
    in
    let lj = match j |> member "linejoin" |> to_string with
      | "round" -> Round_join
      | "bevel" -> Bevel
      | _ -> Miter
    in
    let opacity = try j |> member "opacity" |> to_num with _ -> 1.0 in
    let miter_limit = try j |> member "miter_limit" |> to_num with _ -> 10.0 in
    let align = match (try j |> member "align" |> to_string with _ -> "center") with
      | "inside" -> Inside | "outside" -> Outside | _ -> Center in
    let dash_pattern = try
      let dl = j |> member "dash_pattern" in
      (match dl with `List l -> List.map to_num l | _ -> [])
    with _ -> [] in
    let start_arrow = arrowhead_of_string
      (try j |> member "start_arrow" |> to_string with _ -> "none") in
    let end_arrow = arrowhead_of_string
      (try j |> member "end_arrow" |> to_string with _ -> "none") in
    let start_arrow_scale = try j |> member "start_arrow_scale" |> to_num with _ -> 100.0 in
    let end_arrow_scale = try j |> member "end_arrow_scale" |> to_num with _ -> 100.0 in
    let arrow_align = match (try j |> member "arrow_align" |> to_string with _ -> "tip_at_end") with
      | "center_at_end" -> Center_at_end | _ -> Tip_at_end in
    Some { stroke_color = parse_color (j |> member "color");
           stroke_width = j |> member "width" |> to_num;
           stroke_linecap = lc;
           stroke_linejoin = lj;
           stroke_miter_limit = miter_limit;
           stroke_align = align;
           stroke_dash_pattern = dash_pattern;
           stroke_start_arrow = start_arrow;
           stroke_end_arrow = end_arrow;
           stroke_start_arrow_scale = start_arrow_scale;
           stroke_end_arrow_scale = end_arrow_scale;
           stroke_arrow_align = arrow_align;
           stroke_opacity = opacity }

let parse_transform j =
  if j = `Null then None
  else Some { a = j |> member "a" |> to_num;
              b = j |> member "b" |> to_num;
              c = j |> member "c" |> to_num;
              d = j |> member "d" |> to_num;
              e = j |> member "e" |> to_num;
              f = j |> member "f" |> to_num }

let parse_visibility j =
  match to_string j with
  | "invisible" -> Invisible
  | "outline" -> Outline
  | _ -> Preview

let parse_path_command j =
  match j |> member "cmd" |> to_string with
  | "M" -> MoveTo (j |> member "x" |> to_num,
                    j |> member "y" |> to_num)
  | "L" -> LineTo (j |> member "x" |> to_num,
                    j |> member "y" |> to_num)
  | "C" -> CurveTo (j |> member "x1" |> to_num,
                     j |> member "y1" |> to_num,
                     j |> member "x2" |> to_num,
                     j |> member "y2" |> to_num,
                     j |> member "x" |> to_num,
                     j |> member "y" |> to_num)
  | "S" -> SmoothCurveTo (j |> member "x2" |> to_num,
                           j |> member "y2" |> to_num,
                           j |> member "x" |> to_num,
                           j |> member "y" |> to_num)
  | "Q" -> QuadTo (j |> member "x1" |> to_num,
                    j |> member "y1" |> to_num,
                    j |> member "x" |> to_num,
                    j |> member "y" |> to_num)
  | "T" -> SmoothQuadTo (j |> member "x" |> to_num,
                          j |> member "y" |> to_num)
  | "A" -> ArcTo (j |> member "rx" |> to_num,
                   j |> member "ry" |> to_num,
                   j |> member "x_rotation" |> to_num,
                   j |> member "large_arc" |> to_bool,
                   j |> member "sweep" |> to_bool,
                   j |> member "x" |> to_num,
                   j |> member "y" |> to_num)
  | _ -> ClosePath

let parse_points j =
  j |> to_list |> List.map (fun p ->
    let a = to_list p in
    (List.nth a 0 |> to_num, List.nth a 1 |> to_num))

let rec parse_element j =
  let typ = j |> member "type" |> to_string in
  let opacity = j |> member "opacity" |> to_num in
  let transform = parse_transform (j |> member "transform") in
  let locked = j |> member "locked" |> to_bool in
  let visibility = parse_visibility (j |> member "visibility") in
  match typ with
  | "line" ->
    Line { x1 = j |> member "x1" |> to_num;
           y1 = j |> member "y1" |> to_num;
           x2 = j |> member "x2" |> to_num;
           y2 = j |> member "y2" |> to_num;
           stroke = parse_stroke (j |> member "stroke");
           width_points = [];
           opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
             stroke_gradient = None;
           }
  | "rect" ->
    Rect { x = j |> member "x" |> to_num;
           y = j |> member "y" |> to_num;
           width = j |> member "width" |> to_num;
           height = j |> member "height" |> to_num;
           rx = j |> member "rx" |> to_num;
           ry = j |> member "ry" |> to_num;
           fill = parse_fill (j |> member "fill");
           stroke = parse_stroke (j |> member "stroke");
           opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
             fill_gradient = None;
             stroke_gradient = None;
           }
  | "circle" ->
    Circle { cx = j |> member "cx" |> to_num;
             cy = j |> member "cy" |> to_num;
             r = j |> member "r" |> to_num;
             fill = parse_fill (j |> member "fill");
             stroke = parse_stroke (j |> member "stroke");
             opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
               fill_gradient = None;
               stroke_gradient = None;
             }
  | "ellipse" ->
    Ellipse { cx = j |> member "cx" |> to_num;
              cy = j |> member "cy" |> to_num;
              rx = j |> member "rx" |> to_num;
              ry = j |> member "ry" |> to_num;
              fill = parse_fill (j |> member "fill");
              stroke = parse_stroke (j |> member "stroke");
              opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
                fill_gradient = None;
                stroke_gradient = None;
              }
  | "polyline" ->
    Polyline { points = parse_points (j |> member "points");
               fill = parse_fill (j |> member "fill");
               stroke = parse_stroke (j |> member "stroke");
               opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
                 fill_gradient = None;
                 stroke_gradient = None;
               }
  | "polygon" ->
    Polygon { points = parse_points (j |> member "points");
              fill = parse_fill (j |> member "fill");
              stroke = parse_stroke (j |> member "stroke");
              opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
                fill_gradient = None;
                stroke_gradient = None;
              }
  | "path" ->
    Path { d = j |> member "d" |> to_list |> List.map parse_path_command;
           fill = parse_fill (j |> member "fill");
           stroke = parse_stroke (j |> member "stroke");
           width_points = [];
           opacity; transform; locked; visibility; blend_mode = Normal; mask = None;
             fill_gradient = None;
             stroke_gradient = None;
           }
  | "text" ->
    let content = parse_content_or_tspans j in
    Text { x = j |> member "x" |> to_num;
           y = j |> member "y" |> to_num;
           content;
           font_family = j |> member "font_family" |> to_string;
           font_size = j |> member "font_size" |> to_num;
           font_weight = j |> member "font_weight" |> to_string;
           font_style = j |> member "font_style" |> to_string;
           text_decoration = parse_text_decoration (j |> member "text_decoration");
           text_transform = nullable_str (j |> member "text_transform");
           font_variant = nullable_str (j |> member "font_variant");
           baseline_shift = nullable_str (j |> member "baseline_shift");
           line_height = nullable_str (j |> member "line_height");
           letter_spacing = nullable_str (j |> member "letter_spacing");
           xml_lang = nullable_str (j |> member "xml_lang");
           aa_mode = nullable_str (j |> member "jas_aa_mode");
           rotate = nullable_str (j |> member "rotate");
           horizontal_scale = nullable_str (j |> member "horizontal_scale");
           vertical_scale = nullable_str (j |> member "vertical_scale");
           kerning = nullable_str (j |> member "jas_kerning_mode");
           text_width = j |> member "width" |> to_num;
           text_height = j |> member "height" |> to_num;
           fill = parse_fill (j |> member "fill");
           stroke = parse_stroke (j |> member "stroke");
           opacity; transform; locked; visibility; blend_mode = Normal;
           mask = None;
           tspans = tspans_from_content content }
  | "text_path" ->
    let content = parse_content_or_tspans j in
    Text_path { d = j |> member "d" |> to_list |> List.map parse_path_command;
                content;
                start_offset = j |> member "start_offset" |> to_num;
                font_family = j |> member "font_family" |> to_string;
                font_size = j |> member "font_size" |> to_num;
                font_weight = j |> member "font_weight" |> to_string;
                font_style = j |> member "font_style" |> to_string;
                text_decoration = parse_text_decoration (j |> member "text_decoration");
                text_transform = nullable_str (j |> member "text_transform");
                font_variant = nullable_str (j |> member "font_variant");
                baseline_shift = nullable_str (j |> member "baseline_shift");
                line_height = nullable_str (j |> member "line_height");
                letter_spacing = nullable_str (j |> member "letter_spacing");
                xml_lang = nullable_str (j |> member "xml_lang");
                aa_mode = nullable_str (j |> member "jas_aa_mode");
                rotate = nullable_str (j |> member "rotate");
                horizontal_scale = nullable_str (j |> member "horizontal_scale");
                vertical_scale = nullable_str (j |> member "vertical_scale");
                kerning = nullable_str (j |> member "jas_kerning_mode");
                fill = parse_fill (j |> member "fill");
                stroke = parse_stroke (j |> member "stroke");
                opacity; transform; locked; visibility; blend_mode = Normal;
                mask = None;
                tspans = tspans_from_content content }
  | "group" ->
    let children = j |> member "children" |> to_list
      |> List.map parse_element |> Array.of_list in
    Group { children; opacity; transform; locked; visibility; blend_mode = Normal;
            mask = None;
            isolated_blending = false; knockout_group = false }
  | "layer" ->
    let children = j |> member "children" |> to_list
      |> List.map parse_element |> Array.of_list in
    let name = j |> member "name" |> to_string in
    Layer { name; children; opacity; transform; locked; visibility; blend_mode = Normal;
            mask = None;
            isolated_blending = false; knockout_group = false }
  | _ -> failwith (Printf.sprintf "Unknown element type: %s" typ)

let parse_selection j =
  let entries = j |> to_list |> List.map (fun es ->
    let path = es |> member "path" |> to_list |> List.map to_int in
    let kind_j = es |> member "kind" in
    let kind = match kind_j with
      | `String "all" -> SelKindAll
      | `Assoc _ ->
        let partial = kind_j |> member "partial" |> to_list |> List.map to_int in
        SelKindPartial (SortedCps.from_list partial)
      | _ -> SelKindAll
    in
    { es_path = path; es_kind = kind }
  ) in
  List.fold_left (fun m es ->
    PathMap.add es.es_path es m
  ) PathMap.empty entries

let parse_artboard j : Artboard.artboard =
  let open Yojson.Safe.Util in
  let try_str k = try j |> member k |> to_string with _ -> "" in
  let try_bool k = try j |> member k |> to_bool with _ -> false in
  let try_num k = try j |> member k |> to_num with _ -> 0.0 in
  let raw_aspect = try_num "video_ruler_pixel_aspect_ratio" in
  {
    Artboard.id = try_str "id";
    name = try_str "name";
    x = try_num "x";
    y = try_num "y";
    width = try_num "width";
    height = try_num "height";
    fill = Artboard.fill_from_canonical (
      try try_str "fill" with _ -> "transparent"
    );
    show_center_mark = try_bool "show_center_mark";
    show_cross_hairs = try_bool "show_cross_hairs";
    show_video_safe_areas = try_bool "show_video_safe_areas";
    video_ruler_pixel_aspect_ratio =
      (if raw_aspect = 0.0 then 1.0 else raw_aspect);
  }

let parse_artboards j =
  try j |> Yojson.Safe.Util.to_list |> List.map parse_artboard
  with _ -> []

let parse_artboard_options j : Artboard.options =
  let open Yojson.Safe.Util in
  try
    {
      Artboard.fade_region_outside_artboard =
        (try j |> member "fade_region_outside_artboard" |> to_bool with _ -> true);
      update_while_dragging =
        (try j |> member "update_while_dragging" |> to_bool with _ -> true);
    }
  with _ -> Artboard.default_options

(** Parse canonical test JSON into a Document.
    This is the inverse of [document_to_test_json]. *)
let test_json_to_document json_str =
  let open Yojson.Safe.Util in
  let j = Yojson.Safe.from_string json_str in
  let layers = j |> member "layers" |> to_list
    |> List.map parse_element |> Array.of_list in
  let selected_layer = j |> member "selected_layer" |> to_int in
  let selection = parse_selection (j |> member "selection") in
  let artboards =
    match j |> member "artboards" with
    | `Null -> []
    | v -> parse_artboards v
  in
  let artboard_options =
    match j |> member "artboard_options" with
    | `Null -> Artboard.default_options
    | v -> parse_artboard_options v
  in
  make_document ~selected_layer ~selection ~artboards ~artboard_options layers
