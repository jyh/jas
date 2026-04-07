(** Layout for text flowing along a path. *)

type path_glyph = {
  idx : int;
  offset : float;
  width : float;
  cx : float;
  cy : float;
  angle : float;
  overflow : bool;
}

type t = {
  glyphs : path_glyph array;
  total_length : float;
  font_size : float;
  char_count : int;
}

val layout :
  Element.path_command list -> string -> float -> float ->
  (string -> float) -> t

(** Cursor pixel pos: returns (x, y, angle) or [None] if empty. *)
val cursor_pos : t -> int -> (float * float * float) option

(** Hit-test: convert (x,y) to glyph index. *)
val hit_test : t -> float -> float -> int
