(** Word-wrapped text layout with per-character hit testing.

    Pure layout: takes a [measure] function returning the pixel width of a
    string and produces glyphs and lines. Used by both rendering and the
    type tool for hit-testing and cursor placement.

    All indices ([start], [end_], [idx], cursor positions) are *char*
    (Unicode scalar value) indices, not byte indices. Strings are
    decoded as UTF-8. *)

(** Number of Unicode scalar values in a UTF-8 string. *)
val utf8_char_count : string -> int

(** Byte index of the [k]-th char. Returns [String.length s] if out of range. *)
val char_to_byte : string -> int -> int

(** Substring from char index [k] spanning [n] chars (UTF-8 safe). *)
val utf8_sub : string -> int -> int -> string

type glyph = {
  idx : int;
  line : int;
  x : float;
  right : float;
  baseline_y : float;
  top : float;
  height : float;
  mutable is_trailing_space : bool;
}

type line_info = {
  start : int;
  end_ : int;
  hard_break : bool;
  top : float;
  baseline_y : float;
  height : float;
  width : float;
  mutable glyph_start : int;
  mutable glyph_end : int;
}

type t = {
  glyphs : glyph array;
  lines : line_info array;
  font_size : float;
  char_count : int;
}

(** Compute layout. If [max_width <= 0] no wrapping (point text). *)
val layout : string -> float -> float -> (string -> float) -> t

(** Cursor pixel position: returns (x, baseline_y, height). *)
val cursor_xy : t -> int -> float * float * float

(** Line index containing the cursor position. *)
val line_for_cursor : t -> int -> int

(** Hit-test: convert (x,y) to char index. *)
val hit_test : t -> float -> float -> int

(** Move cursor up one line preserving x. *)
val cursor_up : t -> int -> int

(** Move cursor down one line preserving x. *)
val cursor_down : t -> int -> int

(** Order two indices ascending. *)
val ordered_range : int -> int -> int * int

(** {2 Phase 5 paragraph-aware layout} *)

(** Horizontal alignment within a paragraph's effective box (the
    box width minus left/right indents). Phase 5 supports the three
    non-justify alignments; the four [JUSTIFY_*] variants land with
    the composer in Phase 8 — they fall back to [Left] for now. *)
type text_align = Left | Center | Right

(** Per-paragraph layout constraints derived from the wrapper tspan
    attributes (or panel defaults when there is no wrapper). All
    indent / space values are in pixels. *)
type paragraph_segment = {
  char_start : int;
  char_end : int;
  left_indent : float;
  right_indent : float;
  (** [text-indent] — additional x offset on the *first* line only.
      Signed; negative produces a hanging indent. Phase 5 supports
      non-negative values; negative falls back to 0. Ignored when
      [list_style] is [Some _] per PARAGRAPH.md §Marker rendering. *)
  first_line_indent : float;
  (** [jas:space-before] — extra vertical gap above this paragraph.
      Always 0 for the first paragraph in the element. *)
  space_before : float;
  space_after : float;
  text_align : text_align;
  (** [jas:list-style] — Phase 6. When [Some _], the paragraph is
      a list item: the layout pushes every line by an extra
      [marker_gap] and ignores [first_line_indent]. The marker
      glyph itself is drawn at [x = left_indent] by the renderer. *)
  list_style : string option;
  (** Gap between marker and text. Phase 6 uses a fixed 12pt per
      PARAGRAPH.md §Marker rendering. *)
  marker_gap : float;
}

val default_segment : paragraph_segment

(** Paragraph-aware layout. Lays out each segment in turn with the
    segment's effective wrap width ([max_width - left_indent -
    right_indent]), inserts [space_before] / [space_after] vertical
    gaps between paragraphs (the very first paragraph's
    [space_before] is always skipped per PARAGRAPH.md), shifts the
    first line by [first_line_indent], and applies the segment's
    horizontal alignment.

    [paragraphs] must be ordered by [char_start]; gaps and content
    past the last segment fall back to a default paragraph. When
    empty the entire content is one default paragraph — equivalent
    to [layout]. *)
val layout_with_paragraphs :
  string -> float -> float ->
  paragraph_segment list ->
  (string -> float) -> t
