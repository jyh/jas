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
