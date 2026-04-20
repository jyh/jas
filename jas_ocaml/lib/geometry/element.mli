(** Immutable document elements conforming to SVG element types. *)

(** Line segments per Bezier curve when flattening paths. *)
val flatten_steps : int

(** Average character width as a fraction of font size. *)
val approx_char_width_factor : float

(** Color with support for RGB, HSB, and CMYK color spaces. *)
type color =
  | Rgb of { r : float; g : float; b : float; a : float }
  | Hsb of { h : float; s : float; b : float; a : float }
  | Cmyk of { c : float; m : float; y : float; k : float; a : float }

(** Convenience constructors for opaque colors. *)
val color_rgb : float -> float -> float -> color
val color_hsb : float -> float -> float -> color
val color_cmyk : float -> float -> float -> float -> color

(** Common color constants. *)
val black : color
val white : color

(** Alpha component, regardless of color space. *)
val color_alpha : color -> float

(** Return a copy of this color with the alpha component replaced. *)
val color_with_alpha : float -> color -> color

(** Convert any color to (r, g, b, a). *)
val color_to_rgba : color -> float * float * float * float

(** Convert any color to (h, s, b, a). *)
val color_to_hsba : color -> float * float * float * float

(** Convert any color to (c, m, y, k, a). *)
val color_to_cmyka : color -> float * float * float * float * float

(** Per-element visibility mode.

    Declaration order is chosen so that [compare] and [min] treat
    [Invisible] as the smallest and [Preview] as the largest —
    [min a b] therefore picks the more restrictive mode. That is
    the rule used to combine an element's own visibility with the
    cap inherited from its parent Group or Layer. *)
type visibility = Invisible | Outline | Preview

(** SVG stroke-linecap. *)
type linecap = Butt | Round_cap | Square

(** SVG stroke-linejoin. *)
type linejoin = Miter | Round_join | Bevel

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

(** Convert an arrowhead name string to the enum. *)
val arrowhead_of_string : string -> arrowhead

(** Convert an arrowhead enum to its name string. *)
val string_of_arrowhead : arrowhead -> string

(** SVG fill presentation attribute. *)
type fill = { fill_color : color; fill_opacity : float }

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

(** Convert a named profile preset to width control points. *)
val profile_to_width_points : string -> float -> bool -> stroke_width_point list

(** SVG transform as a 2D affine matrix [a b c d e f]. *)
type transform = {
  a : float; b : float; c : float;
  d : float; e : float; f : float;
}

(** Per-character-range formatting substructure of Text / Text_path.

    Owns a substring of the parent element's content plus a (possibly
    empty) set of attribute overrides. Missing overrides inherit from
    the parent element. See TSPAN.md at the repository root.

    Declared here (rather than in the [Tspan] module) so [Text] /
    [Text_path] can carry a [tspans] field without Element and Tspan
    forming a module cycle. [Tspan] consumes this type and provides
    the pure-function primitives ([split], [merge], etc). *)
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
  (** Marks a tspan as a paragraph wrapper when set to [Some "paragraph"].
      Wrapper tspans implicitly group subsequent content tspans (until
      the next wrapper) into one paragraph for the Paragraph panel. *)
  jas_role : string option;
  (** Phase 3b panel-surface paragraph attributes — effective on
      paragraph wrapper tspans (those whose [jas_role] is
      [Some "paragraph"]). The dialog attrs and the remaining
      panel-surface space-before / space-after / first-line-indent
      (CSS text-indent) land later. *)
  jas_left_indent : float option;
  jas_right_indent : float option;
  jas_hyphenate : bool option;
  jas_hanging_punctuation : bool option;
  (** Single backing attr for both BULLETS_DROPDOWN and
      NUMBERED_LIST_DROPDOWN. Values: [bullet-disc]/[bullet-open-circle]/
      [bullet-square]/[bullet-open-square]/[bullet-dash]/[bullet-check]/
      [num-decimal]/[num-lower-alpha]/[num-upper-alpha]/[num-lower-roman]/
      [num-upper-roman]; absent = no marker. *)
  jas_list_style : string option;
  (** Phase 1b1 panel-surface remainder. text_align + text_align_last
      drive the 7-button alignment radio group via PARAGRAPH.md
      alignment sub-mapping. text_indent backs FIRST_LINE_INDENT_DROPDOWN
      and is signed (negative produces hanging indent). *)
  text_align : string option;
  text_align_last : string option;
  text_indent : float option;
  jas_space_before : float option;
  jas_space_after : float option;
  (** Phase 1b2 / Phase 8 — Justification dialog attrs. Word/letter/
      glyph spacing min/desired/max are percent soft constraints fed
      to the every-line composer. auto_leading is the percent-of-
      font-size used when Character leading is Auto. single_word_justify
      is justify / left / center / right. *)
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
  (** Sorted-set of decoration members (``"underline"``, ``"line-through"``).
      [None] inherits the parent; [Some []] is an explicit no-decoration
      override; writers sort members alphabetically. *)
  text_decoration : string list option;
  text_rendering : string option;
  text_transform : string option;
  transform : transform option;
  xml_lang : string option;
}

(** SVG path commands (the 'd' attribute). *)
type path_command =
  | MoveTo of float * float
  | LineTo of float * float
  | CurveTo of float * float * float * float * float * float
  | SmoothCurveTo of float * float * float * float
  | QuadTo of float * float * float * float
  | SmoothQuadTo of float * float
  | ArcTo of float * float * float * bool * bool * float * float
  | ClosePath

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
      (** Ordered, non-empty list of per-range formatting fragments.
          Invariant: [concat_content tspans = content]. Constructors
          initialise to a single-tspan list with empty overrides;
          record-update writes to [content] currently leave [tspans]
          stale (callers that need consistency should rebuild via
          [sync_tspans_from_content]). Serialisation and editing of
          tspans will use this field once they land. *)
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
      (** See Text.tspans above. *)
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

(** Return the bounding box as (x, y, width, height). *)
val bounds : element -> float * float * float * float

(** Geometric bounding box — the bbox of the path / shape geometry
    alone, ignoring stroke width. Used by Align operations when
    Use Preview Bounds is off (the default) per ALIGN.md Bounding
    box selection. *)
val geometric_bounds : element -> float * float * float * float

(** {2 Helper constructors} *)

val make_color : ?a:float -> float -> float -> float -> color
val make_fill : ?opacity:float -> color -> fill
val make_stroke : ?width:float -> ?linecap:linecap -> ?linejoin:linejoin
  -> ?miter_limit:float -> ?align:stroke_align -> ?dash_pattern:float list
  -> ?start_arrow:arrowhead -> ?end_arrow:arrowhead
  -> ?start_arrow_scale:float -> ?end_arrow_scale:float
  -> ?arrow_align:arrow_align -> ?opacity:float -> color -> stroke
val identity_transform : transform
val make_translate : float -> float -> transform
val make_scale : float -> float -> transform
val make_rotate : float -> transform
val apply_point : transform -> float -> float -> float * float
val inverse : transform -> transform option
val transform_of : element -> transform option
val make_line : ?stroke:stroke option -> ?width_points:stroke_width_point list -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_rect : ?rx:float -> ?ry:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_circle : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> element
val make_ellipse : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> float -> float -> element
val make_polyline : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> (float * float) list -> element
val make_polygon : ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> (float * float) list -> element
val make_path : ?fill:fill option -> ?stroke:stroke option -> ?width_points:stroke_width_point list -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> path_command list -> element

val tspans_from_content : string -> tspan array
(** Build a one-element [tspan] array that mirrors the given content
    with no overrides. Used by constructors to seed the [tspans]
    field on Text / Text_path. *)

val sync_tspans_from_content : element -> element
(** Rebuild a Text / Text_path element's [tspans] field from its
    [content] field. The resulting tspans list has a single entry
    with empty overrides (the plain-text base case). Non-Text
    elements pass through unchanged. *)

val make_text : ?font_family:string -> ?font_size:float -> ?font_weight:string -> ?font_style:string -> ?text_decoration:string -> ?text_transform:string -> ?font_variant:string -> ?baseline_shift:string -> ?line_height:string -> ?letter_spacing:string -> ?xml_lang:string -> ?aa_mode:string -> ?rotate:string -> ?horizontal_scale:string -> ?vertical_scale:string -> ?kerning:string -> ?text_width:float -> ?text_height:float -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> float -> float -> string -> element
val make_text_path : ?start_offset:float -> ?font_family:string -> ?font_size:float -> ?font_weight:string -> ?font_style:string -> ?text_decoration:string -> ?text_transform:string -> ?font_variant:string -> ?baseline_shift:string -> ?line_height:string -> ?letter_spacing:string -> ?xml_lang:string -> ?aa_mode:string -> ?rotate:string -> ?horizontal_scale:string -> ?vertical_scale:string -> ?kerning:string -> ?fill:fill option -> ?stroke:stroke option -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> path_command list -> string -> element
val make_group : ?opacity:float -> ?transform:transform option -> ?locked:bool -> element array -> element
val make_layer : ?name:string -> ?opacity:float -> ?transform:transform option -> ?locked:bool -> element array -> element

(** {2 Lock state} *)

val is_locked : element -> bool
val set_locked : bool -> element -> element

(** {2 Visibility} *)

val get_visibility : element -> visibility
val set_visibility : visibility -> element -> element

(** {2 Fill and stroke} *)

val with_fill : element -> fill option -> element
val with_stroke : element -> stroke option -> element
val with_width_points : element -> stroke_width_point list -> element
val color_to_hex : color -> string
val color_from_hex : string -> color option

(** {2 Control points} *)

val path_handle_positions : path_command list -> int ->
  (float * float) option * (float * float) option
val move_path_handle : path_command list -> int -> string -> float -> float ->
  path_command list
val move_path_handle_independent :
  path_command list -> int -> string -> float -> float -> path_command list
val is_smooth_point : path_command list -> int -> bool
val convert_corner_to_smooth :
  path_command list -> int -> float -> float -> path_command list
val convert_smooth_to_corner : path_command list -> int -> path_command list
val control_point_count : element -> int
val control_points : element -> (float * float) list

val move_control_points :
  ?is_all:bool -> element -> int list -> float -> float -> element
(** Move the listed control points by [(dx, dy)]. Pass [~is_all:true]
    to indicate that the element is selected as a whole — this lets
    Rect/Circle/Ellipse translate in place instead of converting to a
    Polygon. *)

(** {2 Path geometry utilities} *)

val flatten_path_commands : path_command list -> (float * float) list
val path_point_at_offset : path_command list -> float -> float * float
val path_closest_offset : path_command list -> float -> float -> float
val path_distance_to_point : path_command list -> float -> float -> float
