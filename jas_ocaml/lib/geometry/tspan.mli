(** Per-character-range formatting substructure of Text and Text_path.

    See [TSPAN.md] at the repository root for the full language-
    agnostic design. This module covers the OCaml side of step
    B.3.1 (data model) and B.3.2 (pure-function primitives).
    Integration with [Text] / [Text_path] (making [tspans] a field
    on each) lives in a separate step; this module is standalone so
    the primitives can be tested against the shared algorithm
    vectors before that integration. *)

(** Stable in-memory tspan identifier. Unique within a single
    [Text] / [Text_path] element. Monotonic; a fresh id is always
    strictly greater than every existing id in the element.
    Not serialized — on SVG load, fresh ids are assigned per
    tspan starting from 0. *)
type tspan_id = int

(** A tspan: one contiguous character range inside a [Text] or
    [Text_path], carrying per-range attribute overrides.

    Every override field is [None] to mean "inherit the parent
    element's effective value". See TSPAN.md Attribute Inheritance. *)
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
  transform : Element.transform option;
  xml_lang : string option;
}

(** Construct a tspan with empty content, id [0], and every override
    [None]. Mirrors the [tspan_default] algorithm vector. *)
val default_tspan : unit -> tspan

(** [true] when every override field is [None]. A tspan with no
    overrides is purely content — it inherits everything from its
    parent element. *)
val has_no_overrides : tspan -> bool

(** Returns the concatenation of every tspan's content in reading
    order. This is the derived [Text.content] value; see TSPAN.md
    Primitives. *)
val concat_content : tspan array -> string

(** Return the current index of the tspan with [id], or [None] when
    no such tspan exists (e.g., dropped by [merge]). O(n). *)
val resolve_id : tspan array -> tspan_id -> int option

(** Split the tspan at [tspan_idx] at byte [offset] within its
    content. Returns [(new_tspans, left_idx, right_idx)]:

    - [offset = 0]: no split; [left_idx = Some (tspan_idx - 1)] or
      [None] when [tspan_idx = 0]; [right_idx = Some tspan_idx].
    - [offset = String.length content]: no split; [left_idx =
      Some tspan_idx]; [right_idx = Some (tspan_idx + 1)] or [None]
      at the end of the list.
    - Otherwise: the tspan at [tspan_idx] is replaced by two
      fragments sharing the original's attribute overrides. The
      left fragment keeps the original id; the right gets
      [(max_id of original list) + 1]. Left / right indices are
      [tspan_idx] and [tspan_idx + 1].

    Raises [Invalid_argument] if [tspan_idx] is out of range or
    [offset] exceeds the tspan's content length. *)
val split : tspan array -> int -> int -> tspan array * int option * int option

(** Split tspans so the character range [[char_start, char_end)] of
    the concatenated content is covered exactly by a contiguous run.
    Returns [(new_tspans, first_idx, last_idx)] with inclusive
    bounds; both [None] when the range is empty.

    Raises [Invalid_argument] if [char_start > char_end] or
    [char_end] exceeds the total content length. *)
val split_range : tspan array -> int -> int -> tspan array * int option * int option

(** Merge adjacent tspans with identical resolved override sets.
    Empty-content tspans are dropped unconditionally. The surviving
    (left) tspan keeps its id; the right tspan's id is dropped.

    Preserves the "at least one tspan" invariant: if every tspan
    would collapse to empty, returns a one-element array with
    [default_tspan ()]. *)
val merge : tspan array -> tspan array
