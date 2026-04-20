(** Immutable document elements conforming to SVG element types.

    All elements are immutable value types. Element types and attributes
    follow the SVG 1.1 specification. *)

(** Line segments per Bezier curve when flattening paths. *)
let flatten_steps = 20

(** Average character width as a fraction of font size. *)
let approx_char_width_factor = 0.6

(** Color with support for RGB, HSB, and CMYK color spaces. *)
type color =
  | Rgb of { r : float; g : float; b : float; a : float }
  | Hsb of { h : float; s : float; b : float; a : float }
  | Cmyk of { c : float; m : float; y : float; k : float; a : float }

(** Convenience constructors for opaque colors. *)
let color_rgb r g b = Rgb { r; g; b; a = 1.0 }
let color_hsb h s b = Hsb { h; s; b; a = 1.0 }
let color_cmyk c m y k = Cmyk { c; m; y; k; a = 1.0 }
let black = Rgb { r = 0.; g = 0.; b = 0.; a = 1. }
let white = Rgb { r = 1.; g = 1.; b = 1.; a = 1. }
let color_alpha = function Rgb { a; _ } | Hsb { a; _ } | Cmyk { a; _ } -> a

(** Return a copy of this color with the alpha component replaced. *)
let color_with_alpha a = function
  | Rgb { r; g; b; _ } -> Rgb { r; g; b; a }
  | Hsb { h; s; b; _ } -> Hsb { h; s; b; a }
  | Cmyk { c; m; y; k; _ } -> Cmyk { c; m; y; k; a }

(** HSB to RGB component conversion. *)
let hsb_to_rgb_components h s v =
  if s = 0.0 then (v, v, v)
  else
    let h = Float.rem (Float.rem h 360.0 +. 360.0) 360.0 in
    let hi = int_of_float (floor (h /. 60.0)) mod 6 in
    let f = h /. 60.0 -. float_of_int hi in
    let p = v *. (1.0 -. s) in
    let q = v *. (1.0 -. s *. f) in
    let t = v *. (1.0 -. s *. (1.0 -. f)) in
    match hi with
    | 0 -> (v, t, p)
    | 1 -> (q, v, p)
    | 2 -> (p, v, t)
    | 3 -> (p, q, v)
    | 4 -> (t, p, v)
    | _ -> (v, p, q)

(** RGB to HSB component conversion. *)
let rgb_to_hsb_components r g b =
  let mx = Float.max r (Float.max g b) in
  let mn = Float.min r (Float.min g b) in
  let delta = mx -. mn in
  let brightness = mx in
  let saturation = if mx = 0.0 then 0.0 else delta /. mx in
  let hue =
    if delta = 0.0 then 0.0
    else if mx = r then 60.0 *. Float.rem ((g -. b) /. delta) 6.0
    else if mx = g then 60.0 *. ((b -. r) /. delta +. 2.0)
    else 60.0 *. ((r -. g) /. delta +. 4.0)
  in
  let hue = Float.rem (Float.rem hue 360.0 +. 360.0) 360.0 in
  (hue, saturation, brightness)

(** Convert any color to (r, g, b, a). *)
let color_to_rgba = function
  | Rgb { r; g; b; a } -> (r, g, b, a)
  | Hsb { h; s; b; a } ->
    let (r, g, bl) = hsb_to_rgb_components h s b in
    (r, g, bl, a)
  | Cmyk { c; m; y; k; a } ->
    let r = (1.0 -. c) *. (1.0 -. k) in
    let g = (1.0 -. m) *. (1.0 -. k) in
    let b = (1.0 -. y) *. (1.0 -. k) in
    (r, g, b, a)

(** Convert any color to (h, s, b, a). *)
let color_to_hsba = function
  | Hsb { h; s; b; a } -> (h, s, b, a)
  | other ->
    let (r, g, b, a) = color_to_rgba other in
    let (h, s, br) = rgb_to_hsb_components r g b in
    (h, s, br, a)

(** Convert any color to (c, m, y, k, a). *)
let color_to_cmyka = function
  | Cmyk { c; m; y; k; a } -> (c, m, y, k, a)
  | other ->
    let (r, g, b, a) = color_to_rgba other in
    let mx = Float.max r (Float.max g b) in
    let k = 1.0 -. mx in
    if k >= 1.0 then (0.0, 0.0, 0.0, 1.0, a)
    else
      let c = (1.0 -. r -. k) /. (1.0 -. k) in
      let m = (1.0 -. g -. k) /. (1.0 -. k) in
      let y = (1.0 -. b -. k) /. (1.0 -. k) in
      (c, m, y, k, a)

(** Per-element visibility mode. Declaration order places
    [Invisible] first so that [compare] / [min] pick the more
    restrictive mode — the rule used to combine an element's own
    visibility with the cap inherited from its parent Group or
    Layer. *)
type visibility =
  | Invisible
  | Outline
  | Preview

(** SVG stroke-linecap. *)
type linecap =
  | Butt
  | Round_cap
  | Square

(** SVG stroke-linejoin. *)
type linejoin =
  | Miter
  | Round_join
  | Bevel

(** Stroke alignment relative to the path. *)
type stroke_align = Center | Inside | Outside

(** Arrowhead shape identifier. *)
type arrowhead =
  | Arrow_none | Simple_arrow | Open_arrow | Closed_arrow
  | Stealth_arrow | Barbed_arrow | Half_arrow_upper | Half_arrow_lower
  | Arrow_circle | Open_circle | Arrow_square | Open_square
  | Arrow_diamond | Open_diamond | Arrow_slash

(** Arrow alignment mode. *)
type arrow_align = Tip_at_end | Center_at_end

let arrowhead_of_string = function
  | "simple_arrow" -> Simple_arrow
  | "open_arrow" -> Open_arrow
  | "closed_arrow" -> Closed_arrow
  | "stealth_arrow" -> Stealth_arrow
  | "barbed_arrow" -> Barbed_arrow
  | "half_arrow_upper" -> Half_arrow_upper
  | "half_arrow_lower" -> Half_arrow_lower
  | "circle" -> Arrow_circle
  | "open_circle" -> Open_circle
  | "square" -> Arrow_square
  | "open_square" -> Open_square
  | "diamond" -> Arrow_diamond
  | "open_diamond" -> Open_diamond
  | "slash" -> Arrow_slash
  | _ -> Arrow_none

let string_of_arrowhead = function
  | Arrow_none -> "none"
  | Simple_arrow -> "simple_arrow"
  | Open_arrow -> "open_arrow"
  | Closed_arrow -> "closed_arrow"
  | Stealth_arrow -> "stealth_arrow"
  | Barbed_arrow -> "barbed_arrow"
  | Half_arrow_upper -> "half_arrow_upper"
  | Half_arrow_lower -> "half_arrow_lower"
  | Arrow_circle -> "circle"
  | Open_circle -> "open_circle"
  | Arrow_square -> "square"
  | Open_square -> "open_square"
  | Arrow_diamond -> "diamond"
  | Open_diamond -> "open_diamond"
  | Arrow_slash -> "slash"

(** SVG fill presentation attribute. *)
type fill = {
  fill_color : color;
  fill_opacity : float;
}

(** SVG stroke presentation attributes. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_linecap : linecap;
  stroke_linejoin : linejoin;
  stroke_miter_limit : float;
  stroke_align : stroke_align;
  stroke_dash_pattern : float list;
  stroke_start_arrow : arrowhead;
  stroke_end_arrow : arrowhead;
  stroke_start_arrow_scale : float;
  stroke_end_arrow_scale : float;
  stroke_arrow_align : arrow_align;
  stroke_opacity : float;
}

(** A width control point for variable-width stroke profiles. *)
type stroke_width_point = {
  swp_t : float;
  swp_width_left : float;
  swp_width_right : float;
}

let profile_to_width_points profile width flipped =
  let hw = width /. 2.0 in
  let pts = match profile with
    | "taper_both" ->
      [{ swp_t = 0.0; swp_width_left = 0.0; swp_width_right = 0.0 };
       { swp_t = 0.5; swp_width_left = hw; swp_width_right = hw };
       { swp_t = 1.0; swp_width_left = 0.0; swp_width_right = 0.0 }]
    | "taper_start" ->
      [{ swp_t = 0.0; swp_width_left = 0.0; swp_width_right = 0.0 };
       { swp_t = 1.0; swp_width_left = hw; swp_width_right = hw }]
    | "taper_end" ->
      [{ swp_t = 0.0; swp_width_left = hw; swp_width_right = hw };
       { swp_t = 1.0; swp_width_left = 0.0; swp_width_right = 0.0 }]
    | "bulge" ->
      [{ swp_t = 0.0; swp_width_left = hw; swp_width_right = hw };
       { swp_t = 0.5; swp_width_left = hw *. 1.5; swp_width_right = hw *. 1.5 };
       { swp_t = 1.0; swp_width_left = hw; swp_width_right = hw }]
    | "pinch" ->
      [{ swp_t = 0.0; swp_width_left = hw; swp_width_right = hw };
       { swp_t = 0.5; swp_width_left = hw *. 0.5; swp_width_right = hw *. 0.5 };
       { swp_t = 1.0; swp_width_left = hw; swp_width_right = hw }]
    | _ -> []  (* "uniform" or unknown *)
  in
  if flipped then
    List.rev_map (fun p ->
      { swp_t = 1.0 -. p.swp_t;
        swp_width_left = p.swp_width_left;
        swp_width_right = p.swp_width_right }
    ) pts
  else pts

(** SVG transform as a 2D affine matrix [a b c d e f]. *)
type transform = {
  a : float;
  b : float;
  c : float;
  d : float;
  e : float;
  f : float;
}

(** Per-character-range formatting substructure of Text / Text_path.
    Declared here (rather than in [Tspan]) to break the circular
    module dep: Text needs to carry a [tspans] field, and [Tspan]
    needs [transform] from Element. [Tspan] consumes this type and
    provides the pure-function primitives. See TSPAN.md. *)
type tspan_id = int

type tspan = {
  id : tspan_id;
  content : string;
  baseline_shift : float option;
  dx : float option;
  font_family : string option;
  font_size : float option;
  font_style : string option;
  font_variant : string option;
  font_weight : string option;
  jas_aa_mode : string option;
  jas_fractional_widths : bool option;
  jas_kerning_mode : string option;
  jas_no_break : bool option;
  jas_role : string option;
  jas_left_indent : float option;
  jas_right_indent : float option;
  jas_hyphenate : bool option;
  jas_hanging_punctuation : bool option;
  jas_list_style : string option;
  text_align : string option;
  text_align_last : string option;
  text_indent : float option;
  jas_space_before : float option;
  jas_space_after : float option;
  jas_word_spacing_min : float option;
  jas_word_spacing_desired : float option;
  jas_word_spacing_max : float option;
  jas_letter_spacing_min : float option;
  jas_letter_spacing_desired : float option;
  jas_letter_spacing_max : float option;
  jas_glyph_scaling_min : float option;
  jas_glyph_scaling_desired : float option;
  jas_glyph_scaling_max : float option;
  jas_auto_leading : float option;
  jas_single_word_justify : string option;
  jas_hyphenate_min_word : float option;
  jas_hyphenate_min_before : float option;
  jas_hyphenate_min_after : float option;
  jas_hyphenate_limit : float option;
  jas_hyphenate_zone : float option;
  jas_hyphenate_bias : float option;
  jas_hyphenate_capitalized : bool option;
  letter_spacing : float option;
  line_height : float option;
  rotate : float option;
  style_name : string option;
  text_decoration : string list option;
  text_rendering : string option;
  text_transform : string option;
  transform : transform option;
  xml_lang : string option;
}

(** SVG path commands (the 'd' attribute). *)
type path_command =
  | MoveTo of float * float                                       (** M x y *)
  | LineTo of float * float                                       (** L x y *)
  | CurveTo of float * float * float * float * float * float      (** C x1 y1 x2 y2 x y *)
  | SmoothCurveTo of float * float * float * float                (** S x2 y2 x y *)
  | QuadTo of float * float * float * float                       (** Q x1 y1 x y *)
  | SmoothQuadTo of float * float                                 (** T x y *)
  | ArcTo of float * float * float * bool * bool * float * float  (** A rx ry rot large sweep x y *)
  | ClosePath                                                     (** Z *)

(** SVG element types. All elements are immutable. *)
type element =
  | Line of {
      x1 : float; y1 : float;
      x2 : float; y2 : float;
      stroke : stroke option;
      width_points : stroke_width_point list;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Rect of {
      x : float; y : float;
      width : float; height : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Circle of {
      cx : float; cy : float; r : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Ellipse of {
      cx : float; cy : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Polyline of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Polygon of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Path of {
      d : path_command list;
      fill : fill option;
      stroke : stroke option;
      width_points : stroke_width_point list;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Text of {
      x : float; y : float;
      content : string;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      (* 11 Character-panel attributes — empty string = omit /
         inherit default per CHARACTER.md's identity-omission rule.
         Mirrors the Rust TextElem shape. *)
      text_transform : string;
      font_variant : string;
      baseline_shift : string;
      line_height : string;
      letter_spacing : string;
      xml_lang : string;
      aa_mode : string;
      rotate : string;
      horizontal_scale : string;
      vertical_scale : string;
      kerning : string;
      text_width : float;
      text_height : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
      (* See element.mli for the tspans invariant. *)
      tspans : tspan array;
    }
  | Text_path of {
      d : path_command list;
      content : string;
      start_offset : float;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      text_transform : string;
      font_variant : string;
      baseline_shift : string;
      line_height : string;
      letter_spacing : string;
      xml_lang : string;
      aa_mode : string;
      rotate : string;
      horizontal_scale : string;
      vertical_scale : string;
      kerning : string;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
      tspans : tspan array;
    }
  | Group of {
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }
  | Layer of {
      name : string;
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
      visibility : visibility;
    }

(** Expand a bounding box by half the stroke width on all sides. *)
let inflate_bounds (bx, by, bw, bh) stroke =
  match stroke with
  | None -> (bx, by, bw, bh)
  | Some { stroke_width; _ } ->
    let half = stroke_width /. 2.0 in
    (bx -. half, by -. half, bw +. 2.0 *. half, bh +. 2.0 *. half)

let cubic_extrema p0 p1 p2 p3 =
  let a = -3.0 *. p0 +. 9.0 *. p1 -. 9.0 *. p2 +. 3.0 *. p3 in
  let b = 6.0 *. p0 -. 12.0 *. p1 +. 6.0 *. p2 in
  let c = -3.0 *. p0 +. 3.0 *. p1 in
  if abs_float a < 1e-12 then
    if abs_float b > 1e-12 then
      let t = -. c /. b in
      if t > 0.0 && t < 1.0 then [t] else []
    else []
  else
    let disc = b *. b -. 4.0 *. a *. c in
    if disc < 0.0 then []
    else
      let sq = sqrt disc in
      let t1 = (-. b +. sq) /. (2.0 *. a) in
      let t2 = (-. b -. sq) /. (2.0 *. a) in
      List.filter (fun t -> t > 0.0 && t < 1.0) [t1; t2]

let quadratic_extremum p0 p1 p2 =
  let denom = p0 -. 2.0 *. p1 +. p2 in
  if abs_float denom < 1e-12 then []
  else
    let t = (p0 -. p1) /. denom in
    if t > 0.0 && t < 1.0 then [t] else []

let cubic_eval p0 p1 p2 p3 t =
  let u = 1.0 -. t in
  u *. u *. u *. p0 +. 3.0 *. u *. u *. t *. p1 +. 3.0 *. u *. t *. t *. p2 +. t *. t *. t *. p3

let quadratic_eval p0 p1 p2 t =
  let u = 1.0 -. t in
  u *. u *. p0 +. 2.0 *. u *. t *. p1 +. t *. t *. p2

let path_cmd_bounds cmds =
  let xs = ref [] and ys = ref [] in
  let add_x x = xs := x :: !xs in
  let add_y y = ys := y :: !ys in
  let cx = ref 0.0 and cy = ref 0.0 in
  let sx = ref 0.0 and sy = ref 0.0 in
  let prev_x2 = ref 0.0 and prev_y2 = ref 0.0 in
  let prev_cmd = ref None in
  List.iter (fun cmd ->
    (match cmd with
    | MoveTo (x, y) ->
      add_x x; add_y y;
      cx := x; cy := y; sx := x; sy := y
    | LineTo (x, y) ->
      add_x x; add_y y;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      add_x !cx; add_x x; add_y !cy; add_y y;
      List.iter (fun t -> add_x (cubic_eval !cx x1 x2 x t))
        (cubic_extrema !cx x1 x2 x);
      List.iter (fun t -> add_y (cubic_eval !cy y1 y2 y t))
        (cubic_extrema !cy y1 y2 y);
      prev_x2 := x2; prev_y2 := y2;
      cx := x; cy := y
    | SmoothCurveTo (x2, y2, x, y) ->
      let rx1, ry1 = match !prev_cmd with
        | Some (CurveTo _) | Some (SmoothCurveTo _) ->
          (2.0 *. !cx -. !prev_x2, 2.0 *. !cy -. !prev_y2)
        | _ -> (!cx, !cy)
      in
      add_x !cx; add_x x; add_y !cy; add_y y;
      List.iter (fun t -> add_x (cubic_eval !cx rx1 x2 x t))
        (cubic_extrema !cx rx1 x2 x);
      List.iter (fun t -> add_y (cubic_eval !cy ry1 y2 y t))
        (cubic_extrema !cy ry1 y2 y);
      prev_x2 := x2; prev_y2 := y2;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      add_x !cx; add_x x; add_y !cy; add_y y;
      List.iter (fun t -> add_x (quadratic_eval !cx x1 x t))
        (quadratic_extremum !cx x1 x);
      List.iter (fun t -> add_y (quadratic_eval !cy y1 y t))
        (quadratic_extremum !cy y1 y);
      cx := x; cy := y
    | SmoothQuadTo (x, y) ->
      add_x x; add_y y;
      cx := x; cy := y
    | ArcTo (_, _, _, _, _, x, y) ->
      add_x x; add_y y;
      cx := x; cy := y
    | ClosePath ->
      cx := !sx; cy := !sy);
    prev_cmd := Some cmd
  ) cmds;
  match !xs, !ys with
  | [], [] -> (0.0, 0.0, 0.0, 0.0)
  | xs, ys ->
    let min_f = List.fold_left min infinity in
    let max_f = List.fold_left max neg_infinity in
    let min_x = min_f xs and min_y = min_f ys in
    (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y)

(** Return the bounding box as (x, y, width, height). *)
let rec bounds = function
  | Line { x1; y1; x2; y2; stroke; _ } ->
    let min_x = min x1 x2 in
    let min_y = min y1 y2 in
    inflate_bounds (min_x, min_y, abs_float (x2 -. x1), abs_float (y2 -. y1)) stroke
  | Rect { x; y; width; height; stroke; _ } ->
    inflate_bounds (x, y, width, height) stroke
  | Circle { cx; cy; r; stroke; _ } ->
    inflate_bounds (cx -. r, cy -. r, r *. 2.0, r *. 2.0) stroke
  | Ellipse { cx; cy; rx; ry; stroke; _ } ->
    inflate_bounds (cx -. rx, cy -. ry, rx *. 2.0, ry *. 2.0) stroke
  | Polyline { points; stroke; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      inflate_bounds (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y) stroke
    end
  | Polygon { points; stroke; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      inflate_bounds (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y) stroke
    end
  | Path { d; stroke; _ } ->
    inflate_bounds (path_cmd_bounds d) stroke
  | Text_path { d; stroke; _ } ->
    inflate_bounds (path_cmd_bounds d) stroke
  | Text { x; y; content; font_family; font_size; font_weight; font_style;
           text_width; text_height; _ } ->
    if text_width > 0.0 && text_height > 0.0 then
      (x, y, text_width, text_height)
    else
      (* Measure each line with Cairo (matching the renderer and editor)
         so the selection bounding box hugs the real glyphs instead of
         the 0.6 * font_size character-width stub. Falls back to the
         stub if Cairo cannot be initialized (which shouldn't happen in
         practice, but keeps bounds computations total). *)
      let lines = if content = "" then [""]
        else String.split_on_char '\n' content in
      let measure =
        try
          let surf = Cairo.Image.create Cairo.Image.ARGB32 ~w:1 ~h:1 in
          let cr = Cairo.create surf in
          let slant = if font_style = "italic" || font_style = "oblique"
                      then Cairo.Italic else Cairo.Upright in
          let weight = if font_weight = "bold"
                       then Cairo.Bold else Cairo.Normal in
          Cairo.select_font_face cr font_family ~slant ~weight;
          Cairo.set_font_size cr font_size;
          fun s ->
            if s = "" then 0.0
            else (Cairo.text_extents cr s).Cairo.x_advance
        with _ ->
          fun s ->
            float_of_int (String.length s) *. font_size *. approx_char_width_factor
      in
      let max_width = List.fold_left
        (fun acc l -> max acc (measure l)) 0.0 lines in
      let height = float_of_int (List.length lines) *. font_size in
      (x, y, max_width, height)
  | Group { children; _ } | Layer { children; _ } ->
    if Array.length children = 0 then (0.0, 0.0, 0.0, 0.0)
    else
      let all_bounds = Array.map bounds children in
      let min_x = Array.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all_bounds in
      let min_y = Array.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all_bounds in
      let max_x = Array.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all_bounds in
      let max_y = Array.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all_bounds in
      (min_x, min_y, max_x -. min_x, max_y -. min_y)

(** Geometric bounding box — bbox of the path / shape geometry
    alone, ignoring stroke width and any fill bleed. Align
    operations read it when Use Preview Bounds is off, the
    default per ALIGN.md Bounding box selection. *)
let rec geometric_bounds = function
  | Line { x1; y1; x2; y2; _ } ->
    let min_x = min x1 x2 in
    let min_y = min y1 y2 in
    (min_x, min_y, abs_float (x2 -. x1), abs_float (y2 -. y1))
  | Rect { x; y; width; height; _ } -> (x, y, width, height)
  | Circle { cx; cy; r; _ } -> (cx -. r, cy -. r, r *. 2.0, r *. 2.0)
  | Ellipse { cx; cy; rx; ry; _ } -> (cx -. rx, cy -. ry, rx *. 2.0, ry *. 2.0)
  | Polyline { points; _ } | Polygon { points; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y)
    end
  | Path { d; _ } | Text_path { d; _ } -> path_cmd_bounds d
  | Text _ as e -> bounds e
  | Group { children; _ } | Layer { children; _ } ->
    if Array.length children = 0 then (0.0, 0.0, 0.0, 0.0)
    else
      let all = Array.map geometric_bounds children in
      let min_x = Array.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all in
      let min_y = Array.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all in
      let max_x = Array.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all in
      let max_y = Array.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all in
      (min_x, min_y, max_x -. min_x, max_y -. min_y)

(** Helper constructors. *)

let make_color ?(a = 1.0) r g b = Rgb { r; g; b; a }

let make_fill ?(opacity = 1.0) color = { fill_color = color; fill_opacity = opacity }

let make_stroke ?(width = 1.0) ?(linecap = Butt) ?(linejoin = Miter)
    ?(miter_limit = 10.0) ?(align = Center) ?(dash_pattern = [])
    ?(start_arrow = Arrow_none) ?(end_arrow = Arrow_none)
    ?(start_arrow_scale = 100.0) ?(end_arrow_scale = 100.0)
    ?(arrow_align = Tip_at_end) ?(opacity = 1.0) color =
  { stroke_color = color; stroke_width = width;
    stroke_linecap = linecap; stroke_linejoin = linejoin;
    stroke_miter_limit = miter_limit; stroke_align = align;
    stroke_dash_pattern = dash_pattern;
    stroke_start_arrow = start_arrow; stroke_end_arrow = end_arrow;
    stroke_start_arrow_scale = start_arrow_scale;
    stroke_end_arrow_scale = end_arrow_scale;
    stroke_arrow_align = arrow_align;
    stroke_opacity = opacity }

let identity_transform = { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 0.0; f = 0.0 }

let make_translate tx ty = { identity_transform with e = tx; f = ty }

let make_scale sx sy = { identity_transform with a = sx; d = sy }

let make_rotate angle_deg =
  let rad = angle_deg *. Float.pi /. 180.0 in
  { identity_transform with a = cos rad; b = sin rad; c = -. sin rad; d = cos rad }

let apply_point t x y =
  (t.a *. x +. t.c *. y +. t.e,
   t.b *. x +. t.d *. y +. t.f)

let inverse t =
  let det = t.a *. t.d -. t.b *. t.c in
  if abs_float det < 1e-12 then None
  else
    let inv_det = 1.0 /. det in
    Some {
      a = t.d *. inv_det;
      b = -. t.b *. inv_det;
      c = -. t.c *. inv_det;
      d = t.a *. inv_det;
      e = (t.c *. t.f -. t.d *. t.e) *. inv_det;
      f = (t.b *. t.e -. t.a *. t.f) *. inv_det;
    }

let transform_of elem =
  match elem with
  | Line r -> r.transform | Rect r -> r.transform | Circle r -> r.transform
  | Ellipse r -> r.transform | Polyline r -> r.transform | Polygon r -> r.transform
  | Path r -> r.transform | Text r -> r.transform | Text_path r -> r.transform
  | Group r -> r.transform | Layer r -> r.transform

let make_line ?(stroke = None) ?(width_points = []) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x1 y1 x2 y2 =
  Line { x1; y1; x2; y2; stroke; width_points; opacity; transform; locked; visibility = Preview }

let make_rect ?(rx = 0.0) ?(ry = 0.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x y width height =
  Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; locked; visibility = Preview }

let make_circle ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) cx cy r =
  Circle { cx; cy; r; fill; stroke; opacity; transform; locked; visibility = Preview }

let make_ellipse ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) cx cy rx ry =
  Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; locked; visibility = Preview }

let make_polyline ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) points =
  Polyline { points; fill; stroke; opacity; transform; locked; visibility = Preview }

let make_polygon ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) points =
  Polygon { points; fill; stroke; opacity; transform; locked; visibility = Preview }

let make_path ?(fill = None) ?(stroke = None) ?(width_points = []) ?(opacity = 1.0) ?(transform = None) ?(locked = false) d =
  Path { d; fill; stroke; width_points; opacity; transform; locked; visibility = Preview }

(** Build a one-element tspan array that mirrors [content] with no
    overrides. Seeds the [tspans] field on newly-constructed Text /
    Text_path elements. *)
let tspans_from_content (content : string) : tspan array =
  let default : tspan = {
    id = 0;
    content;
    baseline_shift = None; dx = None;
    font_family = None; font_size = None;
    font_style = None; font_variant = None; font_weight = None;
    jas_aa_mode = None; jas_fractional_widths = None;
    jas_kerning_mode = None; jas_no_break = None;
    jas_role = None;
    jas_left_indent = None; jas_right_indent = None;
    jas_hyphenate = None; jas_hanging_punctuation = None;
    jas_list_style = None;
    text_align = None; text_align_last = None; text_indent = None;
    jas_space_before = None; jas_space_after = None;
    jas_word_spacing_min = None; jas_word_spacing_desired = None;
    jas_word_spacing_max = None;
    jas_letter_spacing_min = None; jas_letter_spacing_desired = None;
    jas_letter_spacing_max = None;
    jas_glyph_scaling_min = None; jas_glyph_scaling_desired = None;
    jas_glyph_scaling_max = None;
    jas_auto_leading = None; jas_single_word_justify = None;
    jas_hyphenate_min_word = None; jas_hyphenate_min_before = None;
    jas_hyphenate_min_after = None; jas_hyphenate_limit = None;
    jas_hyphenate_zone = None; jas_hyphenate_bias = None;
    jas_hyphenate_capitalized = None;
    letter_spacing = None; line_height = None;
    rotate = None; style_name = None;
    text_decoration = None; text_rendering = None;
    text_transform = None; transform = None; xml_lang = None;
  } in
  [| default |]

let sync_tspans_from_content elem =
  match elem with
  | Text r -> Text { r with tspans = tspans_from_content r.content }
  | Text_path r -> Text_path { r with tspans = tspans_from_content r.content }
  | _ -> elem

let make_text ?(font_family = "sans-serif") ?(font_size = 16.0) ?(font_weight = "normal") ?(font_style = "normal") ?(text_decoration = "none")
    ?(text_transform = "") ?(font_variant = "") ?(baseline_shift = "")
    ?(line_height = "") ?(letter_spacing = "") ?(xml_lang = "")
    ?(aa_mode = "") ?(rotate = "") ?(horizontal_scale = "")
    ?(vertical_scale = "") ?(kerning = "")
    ?(text_width = 0.0) ?(text_height = 0.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x y content =
  Text { x; y; content; font_family; font_size; font_weight; font_style; text_decoration;
         text_transform; font_variant; baseline_shift; line_height; letter_spacing;
         xml_lang; aa_mode; rotate; horizontal_scale; vertical_scale; kerning;
         text_width; text_height; fill; stroke; opacity; transform; locked; visibility = Preview;
         tspans = tspans_from_content content }

let make_text_path ?(start_offset = 0.0) ?(font_family = "sans-serif") ?(font_size = 16.0) ?(font_weight = "normal") ?(font_style = "normal") ?(text_decoration = "none")
    ?(text_transform = "") ?(font_variant = "") ?(baseline_shift = "")
    ?(line_height = "") ?(letter_spacing = "") ?(xml_lang = "")
    ?(aa_mode = "") ?(rotate = "") ?(horizontal_scale = "")
    ?(vertical_scale = "") ?(kerning = "")
    ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) d content =
  Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; text_decoration;
              text_transform; font_variant; baseline_shift; line_height; letter_spacing;
              xml_lang; aa_mode; rotate; horizontal_scale; vertical_scale; kerning;
              fill; stroke; opacity; transform; locked; visibility = Preview;
              tspans = tspans_from_content content }

let make_group ?(opacity = 1.0) ?(transform = None) ?(locked = false) children =
  Group { children; opacity; transform; locked; visibility = Preview }

let make_layer ?(name = "Layer") ?(opacity = 1.0) ?(transform = None) ?(locked = false) children =
  Layer { name; children; opacity; transform; locked; visibility = Preview }

let is_locked = function
  | Line { locked; _ } | Rect { locked; _ } | Circle { locked; _ }
  | Ellipse { locked; _ } | Polyline { locked; _ } | Polygon { locked; _ }
  | Path { locked; _ } | Text { locked; _ } | Text_path { locked; _ }
  | Group { locked; _ } | Layer { locked; _ } -> locked

let set_locked v = function
  | Line r -> Line { r with locked = v }
  | Rect r -> Rect { r with locked = v }
  | Circle r -> Circle { r with locked = v }
  | Ellipse r -> Ellipse { r with locked = v }
  | Polyline r -> Polyline { r with locked = v }
  | Polygon r -> Polygon { r with locked = v }
  | Path r -> Path { r with locked = v }
  | Text r -> Text { r with locked = v }
  | Text_path r -> Text_path { r with locked = v }
  | Group r -> Group { r with locked = v }
  | Layer r -> Layer { r with locked = v }

let get_visibility = function
  | Line { visibility; _ } | Rect { visibility; _ } | Circle { visibility; _ }
  | Ellipse { visibility; _ } | Polyline { visibility; _ }
  | Polygon { visibility; _ } | Path { visibility; _ } | Text { visibility; _ }
  | Text_path { visibility; _ } | Group { visibility; _ }
  | Layer { visibility; _ } -> visibility

let set_visibility v = function
  | Line r -> Line { r with visibility = v }
  | Rect r -> Rect { r with visibility = v }
  | Circle r -> Circle { r with visibility = v }
  | Ellipse r -> Ellipse { r with visibility = v }
  | Polyline r -> Polyline { r with visibility = v }
  | Polygon r -> Polygon { r with visibility = v }
  | Path r -> Path { r with visibility = v }
  | Text r -> Text { r with visibility = v }
  | Text_path r -> Text_path { r with visibility = v }
  | Group r -> Group { r with visibility = v }
  | Layer r -> Layer { r with visibility = v }

let with_fill elem f =
  match elem with
  | Rect r -> Rect { r with fill = f }
  | Circle r -> Circle { r with fill = f }
  | Ellipse r -> Ellipse { r with fill = f }
  | Polyline r -> Polyline { r with fill = f }
  | Polygon r -> Polygon { r with fill = f }
  | Path r -> Path { r with fill = f }
  | Text r -> Text { r with fill = f }
  | Text_path r -> Text_path { r with fill = f }
  | Line _ | Group _ | Layer _ -> elem

let with_stroke elem s =
  match elem with
  | Line r -> Line { r with stroke = s }
  | Rect r -> Rect { r with stroke = s }
  | Circle r -> Circle { r with stroke = s }
  | Ellipse r -> Ellipse { r with stroke = s }
  | Polyline r -> Polyline { r with stroke = s }
  | Polygon r -> Polygon { r with stroke = s }
  | Path r -> Path { r with stroke = s }
  | Text r -> Text { r with stroke = s }
  | Text_path r -> Text_path { r with stroke = s }
  | Group _ | Layer _ -> elem

let with_width_points elem wp =
  match elem with
  | Line r -> Line { r with width_points = wp }
  | Path r -> Path { r with width_points = wp }
  | _ -> elem

let color_to_hex c =
  let (r, g, b, _) = color_to_rgba c in
  let ri = int_of_float (Float.round (r *. 255.0)) in
  let gi = int_of_float (Float.round (g *. 255.0)) in
  let bi = int_of_float (Float.round (b *. 255.0)) in
  Printf.sprintf "%02x%02x%02x" ri gi bi

let color_from_hex s =
  let s = if String.length s > 0 && s.[0] = '#' then String.sub s 1 (String.length s - 1) else s in
  if String.length s <> 6 then None
  else
    let is_hex c =
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
    in
    let all_hex = ref true in
    String.iter (fun c -> if not (is_hex c) then all_hex := false) s;
    if not !all_hex then None
    else
      let v = int_of_string ("0x" ^ s) in
      let r = float_of_int ((v lsr 16) land 0xff) /. 255.0 in
      let g = float_of_int ((v lsr 8) land 0xff) /. 255.0 in
      let b = float_of_int (v land 0xff) /. 255.0 in
      Some (Rgb { r; g; b; a = 1.0 })

let path_anchor_points d =
  List.fold_left (fun acc cmd ->
    match cmd with
    | MoveTo (x, y) | LineTo (x, y) | SmoothQuadTo (x, y) -> (x, y) :: acc
    | CurveTo (_, _, _, _, x, y) | SmoothCurveTo (_, _, x, y) -> (x, y) :: acc
    | QuadTo (_, _, x, y) -> (x, y) :: acc
    | ArcTo (_, _, _, _, _, x, y) -> (x, y) :: acc
    | ClosePath -> acc
  ) [] d |> List.rev

let path_handle_positions d anchor_idx =
  (* Map anchor indices to command indices (skip ClosePath) *)
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then (None, None)
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    match anchor with
    | None -> (None, None)
    | Some (ax, ay) ->
      let h_in = match cmd with
        | CurveTo (_, _, x2, y2, _, _) ->
          if abs_float (x2 -. ax) > 0.01 || abs_float (y2 -. ay) > 0.01
          then Some (x2, y2) else None
        | _ -> None
      in
      let h_out =
        if ci + 1 < n then
          match cmd_arr.(ci + 1) with
          | CurveTo (x1, y1, _, _, _, _) ->
            if abs_float (x1 -. ax) > 0.01 || abs_float (y1 -. ay) > 0.01
            then Some (x1, y1) else None
          | _ -> None
        else None
      in
      (h_in, h_out)
  end

let reflect_handle_keep_distance ax ay nhx nhy opp_hx opp_hy =
  let dnx = nhx -. ax in
  let dny = nhy -. ay in
  let dist_new = sqrt (dnx *. dnx +. dny *. dny) in
  let dist_opp = sqrt ((opp_hx -. ax) *. (opp_hx -. ax) +. (opp_hy -. ay) *. (opp_hy -. ay)) in
  if dist_new < 1e-6 then (opp_hx, opp_hy)
  else
    let scale = -. dist_opp /. dist_new in
    (ax +. dnx *. scale, ay +. dny *. scale)

let move_path_handle d anchor_idx handle_type dx dy =
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then d
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    (* Get anchor position *)
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    (match anchor with
     | None -> ()
     | Some (ax, ay) ->
       if handle_type = "in" then begin
         match cmd with
         | CurveTo (x1, y1, x2, y2, x, y) ->
           let nhx = x2 +. dx in
           let nhy = y2 +. dy in
           cmd_arr.(ci) <- CurveTo (x1, y1, nhx, nhy, x, y);
           (* Rotate opposite (out) handle to stay collinear, keep its distance *)
           if ci + 1 < n then
             (match cmd_arr.(ci + 1) with
              | CurveTo (ox1, oy1, nx2, ny2, nx, ny) ->
                let (rx, ry) = reflect_handle_keep_distance ax ay nhx nhy ox1 oy1 in
                cmd_arr.(ci + 1) <- CurveTo (rx, ry, nx2, ny2, nx, ny)
              | _ -> ())
         | _ -> ()
       end else if handle_type = "out" then begin
         if ci + 1 < n then
           match cmd_arr.(ci + 1) with
           | CurveTo (x1, y1, x2, y2, x, y) ->
             let nhx = x1 +. dx in
             let nhy = y1 +. dy in
             cmd_arr.(ci + 1) <- CurveTo (nhx, nhy, x2, y2, x, y);
             (* Rotate opposite (in) handle to stay collinear, keep its distance *)
             (match cmd with
              | CurveTo (cx1, cy1, cx2, cy2, cx, cy) ->
                let (rx, ry) = reflect_handle_keep_distance ax ay nhx nhy cx2 cy2 in
                cmd_arr.(ci) <- CurveTo (cx1, cy1, rx, ry, cx, cy)
              | _ -> ())
           | _ -> ()
       end);
    Array.to_list cmd_arr
  end

(* Move a single handle without reflecting the opposite handle (cusp behavior). *)
let move_path_handle_independent d anchor_idx handle_type dx dy =
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then d
  else begin
    let ci = cmd_indices.(anchor_idx) in
    if handle_type = "in" then begin
      match cmd_arr.(ci) with
      | CurveTo (x1, y1, x2, y2, x, y) ->
        cmd_arr.(ci) <- CurveTo (x1, y1, x2 +. dx, y2 +. dy, x, y)
      | _ -> ()
    end else if handle_type = "out" then begin
      if ci + 1 < n then
        match cmd_arr.(ci + 1) with
        | CurveTo (x1, y1, x2, y2, x, y) ->
          cmd_arr.(ci + 1) <- CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
        | _ -> ()
    end;
    Array.to_list cmd_arr
  end

(* True if a path anchor has at least one non-degenerate handle. *)
let is_smooth_point d anchor_idx =
  let (h_in, h_out) = path_handle_positions d anchor_idx in
  h_in <> None || h_out <> None

(* Convert a corner anchor to a smooth anchor. The outgoing handle is
   placed at (hx, hy) and the incoming handle is reflected through the
   anchor. *)
let convert_corner_to_smooth d anchor_idx hx hy =
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then d
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    (match anchor with
     | None -> ()
     | Some (ax, ay) ->
       let rhx = 2.0 *. ax -. hx in
       let rhy = 2.0 *. ay -. hy in
       (* Set incoming handle on this command. *)
       (match cmd_arr.(ci) with
        | LineTo (x, y) ->
          let (px, py) =
            if ci > 0 then
              match cmd_arr.(ci - 1) with
              | MoveTo (mx, my) | LineTo (mx, my) -> (mx, my)
              | CurveTo (_, _, _, _, ex, ey) -> (ex, ey)
              | _ -> (x, y)
            else (x, y)
          in
          cmd_arr.(ci) <- CurveTo (px, py, rhx, rhy, x, y)
        | CurveTo (x1, y1, _, _, x, y) ->
          cmd_arr.(ci) <- CurveTo (x1, y1, rhx, rhy, x, y)
        | MoveTo _ -> () (* No incoming handle on MoveTo. *)
        | _ -> ());
       (* Set outgoing handle on the next command. *)
       if ci + 1 < n then
         (match cmd_arr.(ci + 1) with
          | LineTo (x, y) ->
            cmd_arr.(ci + 1) <- CurveTo (hx, hy, x, y, x, y)
          | CurveTo (_, _, x2, y2, x, y) ->
            cmd_arr.(ci + 1) <- CurveTo (hx, hy, x2, y2, x, y)
          | _ -> ()));
    Array.to_list cmd_arr
  end

(* Convert a smooth anchor to a corner by collapsing both handles to the
   anchor position. *)
let convert_smooth_to_corner d anchor_idx =
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then d
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    (match anchor with
     | None -> ()
     | Some (ax, ay) ->
       (match cmd_arr.(ci) with
        | CurveTo (x1, y1, _, _, x, y) ->
          cmd_arr.(ci) <- CurveTo (x1, y1, ax, ay, x, y)
        | _ -> ());
       if ci + 1 < n then
         (match cmd_arr.(ci + 1) with
          | CurveTo (_, _, x2, y2, x, y) ->
            cmd_arr.(ci + 1) <- CurveTo (ax, ay, x2, y2, x, y)
          | _ -> ()));
    Array.to_list cmd_arr
  end

let control_point_count = function
  | Line _ -> 2
  | Rect _ | Circle _ | Ellipse _ -> 4
  | Polygon { points; _ } -> List.length points
  | Path { d; _ } | Text_path { d; _ } -> List.length (path_anchor_points d)
  | _ -> 4

let control_points = function
  | Line { x1; y1; x2; y2; _ } -> [(x1, y1); (x2, y2)]
  | Rect { x; y; width; height; _ } ->
    [(x, y); (x +. width, y); (x +. width, y +. height); (x, y +. height)]
  | Circle { cx; cy; r; _ } ->
    [(cx, cy -. r); (cx +. r, cy); (cx, cy +. r); (cx -. r, cy)]
  | Ellipse { cx; cy; rx; ry; _ } ->
    [(cx, cy -. ry); (cx +. rx, cy); (cx, cy +. ry); (cx -. rx, cy)]
  | Polygon { points; _ } -> points
  | Path { d; _ } | Text_path { d; _ } -> path_anchor_points d
  | elem ->
    let (bx, by, bw, bh) = bounds elem in
    [(bx, by); (bx +. bw, by); (bx +. bw, by +. bh); (bx, by +. bh)]

(** Move the listed control points by [(dx, dy)].

    [is_all_for_total ~total] should be true when *every* CP of the
    primitive is selected as part of an "element-as-a-whole" intent.
    For primitives that can collapse to a translation (Rect, Circle,
    Ellipse), the is-all case translates in place; otherwise the
    primitive is converted to a Polygon (Rect) or its bounding-box
    representation (Circle, Ellipse).

    [Partial []] — [is_all=false] with an empty [indices] list,
    meaning "element selected, no CPs highlighted" — is a no-op:
    [elem] is returned unchanged. Without this guard, the
    Rect/Circle/Ellipse branches would fall through to their
    polygon-conversion path and silently change the primitive type
    without any visible movement. *)
let move_control_points ?(is_all = false) elem indices dx dy =
  if (not is_all) && indices = [] then elem
  else
  let mem i = List.mem i indices in
  match elem with
  | Line r ->
    Line { r with
      x1 = r.x1 +. (if is_all || mem 0 then dx else 0.0);
      y1 = r.y1 +. (if is_all || mem 0 then dy else 0.0);
      x2 = r.x2 +. (if is_all || mem 1 then dx else 0.0);
      y2 = r.y2 +. (if is_all || mem 1 then dy else 0.0);
    }
  | Rect r ->
    if is_all then
      Rect { r with x = r.x +. dx; y = r.y +. dy }
    else
      let pts = [| (r.x, r.y); (r.x +. r.width, r.y);
                   (r.x +. r.width, r.y +. r.height); (r.x, r.y +. r.height) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = pts.(i) in
          pts.(i) <- (px +. dx, py +. dy)
      done;
      Polygon { points = Array.to_list pts;
                fill = r.fill; stroke = r.stroke;
                opacity = r.opacity; transform = r.transform;
                locked = r.locked; visibility = r.visibility }
  | Circle r ->
    if is_all then
      Circle { r with cx = r.cx +. dx; cy = r.cy +. dy }
    else
      let cps = [| (r.cx, r.cy -. r.r); (r.cx +. r.r, r.cy);
                    (r.cx, r.cy +. r.r); (r.cx -. r.r, r.cy) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = cps.(i) in
          cps.(i) <- (px +. dx, py +. dy)
      done;
      let ncx = (fst cps.(1) +. fst cps.(3)) /. 2.0 in
      let ncy = (snd cps.(0) +. snd cps.(2)) /. 2.0 in
      let nr = max (abs_float (fst cps.(1) -. ncx)) (abs_float (snd cps.(0) -. ncy)) in
      Circle { r with cx = ncx; cy = ncy; r = nr }
  | Ellipse r ->
    if is_all then
      Ellipse { r with cx = r.cx +. dx; cy = r.cy +. dy }
    else
      let cps = [| (r.cx, r.cy -. r.ry); (r.cx +. r.rx, r.cy);
                    (r.cx, r.cy +. r.ry); (r.cx -. r.rx, r.cy) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = cps.(i) in
          cps.(i) <- (px +. dx, py +. dy)
      done;
      let ncx = (fst cps.(1) +. fst cps.(3)) /. 2.0 in
      let ncy = (snd cps.(0) +. snd cps.(2)) /. 2.0 in
      Ellipse { r with cx = ncx; cy = ncy;
                rx = abs_float (fst cps.(1) -. ncx);
                ry = abs_float (snd cps.(0) -. ncy) }
  | Polygon r ->
    let new_points = List.mapi (fun i (px, py) ->
      if mem i then (px +. dx, py +. dy) else (px, py)
    ) r.points in
    Polygon { r with points = new_points }
  | Path r ->
    let cmds = Array.of_list r.d in
    let n = Array.length cmds in
    let anchor_idx = ref 0 in
    for ci = 0 to n - 1 do
      match cmds.(ci) with
      | ClosePath -> ()
      | _ ->
        if mem !anchor_idx then begin
          (match cmds.(ci) with
           | MoveTo (x, y) ->
             cmds.(ci) <- MoveTo (x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (x1, y1, x2, y2, x, y) ->
                  cmds.(ci + 1) <- CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
                | _ -> ())
           | CurveTo (x1, y1, x2, y2, x, y) ->
             cmds.(ci) <- CurveTo (x1, y1, x2 +. dx, y2 +. dy, x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (nx1, ny1, nx2, ny2, nx, ny) ->
                  cmds.(ci + 1) <- CurveTo (nx1 +. dx, ny1 +. dy, nx2, ny2, nx, ny)
                | _ -> ())
           | LineTo (x, y) ->
             cmds.(ci) <- LineTo (x +. dx, y +. dy)
           | _ -> ())
        end;
        incr anchor_idx
    done;
    Path { r with d = Array.to_list cmds }
  | Text_path r ->
    let cmds = Array.of_list r.d in
    let n = Array.length cmds in
    let anchor_idx = ref 0 in
    for ci = 0 to n - 1 do
      match cmds.(ci) with
      | ClosePath -> ()
      | _ ->
        if mem !anchor_idx then begin
          (match cmds.(ci) with
           | MoveTo (x, y) ->
             cmds.(ci) <- MoveTo (x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (x1, y1, x2, y2, x, y) ->
                  cmds.(ci + 1) <- CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
                | _ -> ())
           | CurveTo (x1, y1, x2, y2, x, y) ->
             cmds.(ci) <- CurveTo (x1, y1, x2 +. dx, y2 +. dy, x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (nx1, ny1, nx2, ny2, nx, ny) ->
                  cmds.(ci + 1) <- CurveTo (nx1 +. dx, ny1 +. dy, nx2, ny2, nx, ny)
                | _ -> ())
           | LineTo (x, y) ->
             cmds.(ci) <- LineTo (x +. dx, y +. dy)
           | _ -> ())
        end;
        incr anchor_idx
    done;
    Text_path { r with d = Array.to_list cmds }
  | _ -> elem


(* ----------------------------------------------------------------- *)
(* Path geometry utilities                                           *)
(* ----------------------------------------------------------------- *)

let flatten_path_commands d =
  let pts = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  let steps = flatten_steps in
  let first = ref (0.0, 0.0) in
  List.iter (fun cmd ->
    match cmd with
    | MoveTo (x, y) ->
      pts := (x, y) :: !pts;
      cx := x; cy := y; first := (x, y)
    | LineTo (x, y) ->
      pts := (x, y) :: !pts;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let mt2 = mt *. mt in
        let mt3 = mt2 *. mt in
        let t2 = t *. t in
        let t3 = t2 *. t in
        let px = mt3 *. !cx +. 3.0 *. mt2 *. t *. x1 +. 3.0 *. mt *. t2 *. x2 +. t3 *. x in
        let py = mt3 *. !cy +. 3.0 *. mt2 *. t *. y1 +. 3.0 *. mt *. t2 *. y2 +. t3 *. y in
        pts := (px, py) :: !pts
      done;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. !cx +. 2.0 *. mt *. t *. x1 +. t *. t *. x in
        let py = mt *. mt *. !cy +. 2.0 *. mt *. t *. y1 +. t *. t *. y in
        pts := (px, py) :: !pts
      done;
      cx := x; cy := y
    | ClosePath ->
      let (fx, fy) = !first in
      pts := (fx, fy) :: !pts
    | _ ->
      (* SmoothCurveTo, SmoothQuadTo, ArcTo: approximate as line *)
      let (x, y) = match cmd with
        | SmoothCurveTo (_, _, x, y) | SmoothQuadTo (x, y) | ArcTo (_, _, _, _, _, x, y) -> (x, y)
        | _ -> (!cx, !cy)
      in
      pts := (x, y) :: !pts;
      cx := x; cy := y
  ) d;
  List.rev !pts

let arc_lengths pts =
  let rec go acc prev = function
    | [] -> List.rev acc
    | (x, y) :: rest ->
      let (px, py) = prev in
      let dx = x -. px in
      let dy = y -. py in
      let len = (List.hd acc) +. sqrt (dx *. dx +. dy *. dy) in
      go (len :: acc) (x, y) rest
  in
  match pts with
  | [] -> [0.0]
  | first :: rest -> go [0.0] first rest

let path_point_at_offset d t =
  let pts = flatten_path_commands d in
  match pts with
  | [] -> (0.0, 0.0)
  | [p] -> p
  | _ ->
    let lengths = arc_lengths pts in
    let total = List.nth lengths (List.length lengths - 1) in
    if total = 0.0 then List.hd pts
    else
      let target = (max 0.0 (min 1.0 t)) *. total in
      let pts_arr = Array.of_list pts in
      let len_arr = Array.of_list lengths in
      let n = Array.length len_arr in
      let result = ref pts_arr.(n - 1) in
      (try
        for i = 1 to n - 1 do
          if len_arr.(i) >= target then begin
            let seg_len = len_arr.(i) -. len_arr.(i - 1) in
            if seg_len = 0.0 then result := pts_arr.(i)
            else begin
              let frac = (target -. len_arr.(i - 1)) /. seg_len in
              let (ax, ay) = pts_arr.(i - 1) in
              let (bx, by) = pts_arr.(i) in
              result := (ax +. frac *. (bx -. ax), ay +. frac *. (by -. ay))
            end;
            raise Exit
          end
        done
      with Exit -> ());
      !result

let path_closest_offset d px py =
  let pts = flatten_path_commands d in
  match pts with
  | [] | [_] -> 0.0
  | _ ->
    let lengths = arc_lengths pts in
    let total = List.nth lengths (List.length lengths - 1) in
    if total = 0.0 then 0.0
    else
      let pts_arr = Array.of_list pts in
      let len_arr = Array.of_list lengths in
      let n = Array.length pts_arr in
      let best_dist = ref infinity in
      let best_offset = ref 0.0 in
      for i = 1 to n - 1 do
        let (ax, ay) = pts_arr.(i - 1) in
        let (bx, by) = pts_arr.(i) in
        let dx = bx -. ax in
        let dy = by -. ay in
        let seg_len_sq = dx *. dx +. dy *. dy in
        if seg_len_sq > 0.0 then begin
          let t = max 0.0 (min 1.0 (((px -. ax) *. dx +. (py -. ay) *. dy) /. seg_len_sq)) in
          let qx = ax +. t *. dx in
          let qy = ay +. t *. dy in
          let dist = sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
          if dist < !best_dist then begin
            best_dist := dist;
            best_offset := (len_arr.(i - 1) +. t *. (len_arr.(i) -. len_arr.(i - 1))) /. total
          end
        end
      done;
      !best_offset

let path_distance_to_point d px py =
  let pts = flatten_path_commands d in
  match pts with
  | [] -> infinity
  | [p] -> let (x, y) = p in sqrt ((px -. x) *. (px -. x) +. (py -. y) *. (py -. y))
  | _ ->
    let pts_arr = Array.of_list pts in
    let n = Array.length pts_arr in
    let best_dist = ref infinity in
    for i = 1 to n - 1 do
      let (ax, ay) = pts_arr.(i - 1) in
      let (bx, by) = pts_arr.(i) in
      let dx = bx -. ax in
      let dy = by -. ay in
      let seg_len_sq = dx *. dx +. dy *. dy in
      if seg_len_sq > 0.0 then begin
        let t = max 0.0 (min 1.0 (((px -. ax) *. dx +. (py -. ay) *. dy) /. seg_len_sq)) in
        let qx = ax +. t *. dx in
        let qy = ay +. t *. dy in
        let dist = sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
        if dist < !best_dist then best_dist := dist
      end
    done;
    !best_dist
