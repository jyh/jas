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
    box width minus left/right indents). Phase 10 lights up
    [Justify] (area-text only — point text and text-on-path coerce
    back to [Left]). *)
type text_align = Left | Center | Right | Justify

(** Per-paragraph layout constraints derived from the wrapper tspan
    attributes (or panel defaults when there is no wrapper). All
    indent / space values are in pixels. *)
type paragraph_segment = {
  char_start : int;
  char_end : int;
  left_indent : float;
  right_indent : float;
  first_line_indent : float;
  space_before : float;
  space_after : float;
  text_align : text_align;
  list_style : string option;
  marker_gap : float;
  hanging_punctuation : bool;
  (* Phase 10: Justification dialog soft constraints. *)
  word_spacing_min : float;
  word_spacing_desired : float;
  word_spacing_max : float;
  last_line_align : text_align;
  (* Phase 10: Hyphenation dialog wiring. *)
  hyphenate : bool;
  hyphenate_min_word : int;
  hyphenate_min_before : int;
  hyphenate_min_after : int;
  hyphenate_bias : int;
}

(** True if [c] may hang into the *left* margin. *)
val is_left_hanger : Uchar.t -> bool

(** True if [c] may hang into the *right* margin (caller passes
    last visible glyph; dashes only ever hang at line end). *)
val is_right_hanger : Uchar.t -> bool

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
