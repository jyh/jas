(** Pure-function primitives over tspan lists.

    The [tspan] / [tspan_id] types live in [Element] to break the
    circular module dep (Text carries a [tspans] field; [tspan]
    references [Element.transform]). This module re-exports the
    types as aliases so consumers can keep writing [Tspan.tspan]
    and provides the algorithms from TSPAN.md — split / merge /
    split_range / resolve_id. *)

type tspan_id = Element.tspan_id
type tspan = Element.tspan

(** Construct a tspan with empty content, id [0], and every override
    [None]. Mirrors the [tspan_default] algorithm vector. *)
val default_tspan : unit -> tspan

(** [true] when every override field is [None]. A tspan with no
    overrides is purely content — it inherits everything from its
    parent element. *)
val has_no_overrides : tspan -> bool

(** Concatenation of every tspan's content in reading order. Used to
    reconstruct the derived [Text.content] value. *)
val concat_content : tspan array -> string

(** Return the current index of the tspan with [id], or [None] when
    no such tspan exists (e.g. dropped by [merge]). O(n). *)
val resolve_id : tspan array -> tspan_id -> int option

(** Copy every [Some _] override field from [source] into [target],
    leaving [id] and [content] untouched. Used by the next-typed-
    character state (the "pending override" template). *)
val merge_tspan_overrides : tspan -> tspan -> tspan

(** Serialize [tspans] as the rich-clipboard JSON payload described
    in TSPAN.md — [{"tspans": [...]}] with each tspan's override
    fields in snake_case. Ids are stripped; [None] overrides are
    omitted for compactness. *)
val tspans_to_json_clipboard : tspan array -> string

(** Parse a rich-clipboard JSON payload back into a tspan list with
    fresh ids. [None] on malformed input. *)
val tspans_from_json_clipboard : string -> tspan array option

(** Serialize [tspans] as an SVG fragment suitable for the
    [image/svg+xml] clipboard format — a single [<text>] element
    wrapping the tspan children with standard CSS-style attribute
    names, alphabetically sorted. *)
val tspans_to_svg_fragment : tspan array -> string

(** Parse an SVG fragment produced by [tspans_to_svg_fragment] or a
    compatible shape into a tspan list with fresh ids. [None] when
    the root is not a [<text>] element. *)
val tspans_from_svg_fragment : string -> tspan array option

(** Caret side at a tspan boundary. See TSPAN.md Text-edit session
    integration — when a character index lands exactly on the join
    between two tspans, the affinity decides which side "wins".
    [Left] is the spec's default: new text inherits from the previous
    character. [Right] is set by callers that crossed a boundary
    rightward (e.g. ArrowRight over a join). *)
type affinity = Left | Right

(** Resolve a flat character index to a concrete [(tspan_idx, offset)]
    position given the tspan list and a caret affinity.

    Mid-tspan: returns [(i, char_idx - prefix_chars)]. At a boundary
    between tspans [i] and [i+1], [Left] returns the end of [i] and
    [Right] returns the start of [i+1]; the final boundary (end of
    last tspan) always returns the end regardless of affinity.
    Out-of-range saturates to the end; an empty list returns
    [(0, 0)]. *)
val char_to_tspan_pos : tspan array -> int -> affinity -> int * int

(** Split the tspan at [tspan_idx] at byte [offset]. See TSPAN.md
    Primitives > Split at offset. Raises [Invalid_argument] on
    out-of-range indices. *)
val split : tspan array -> int -> int -> tspan array * int option * int option

(** Split tspans so the character range [[char_start, char_end)] is
    covered exactly by a contiguous run. Returns inclusive bounds;
    both [None] when the range is empty. Raises [Invalid_argument]
    on out-of-range indices. *)
val split_range : tspan array -> int -> int -> tspan array * int option * int option

(** Merge adjacent tspans with identical resolved override sets;
    drop empty-content tspans. Preserves the "at least one tspan"
    invariant: an all-empty input collapses to [[| default_tspan () |]]. *)
val merge : tspan array -> tspan array

(** Extract the covered slice [[char_start, char_end)] as a fresh
    tspan array. Each returned tspan carries its source tspan's
    overrides and id, with [content] truncated to the overlap.
    Empty / inverted range returns [[||]]; out-of-range bounds
    saturate. Building block for tspan-aware clipboard. *)
val copy_range : tspan array -> int -> int -> tspan array

(** Splice [to_insert] into [original] at character position
    [char_pos]. Boundary insert slots between neighbours; mid-tspan
    insert splits that tspan around the insertion. Ids on
    [to_insert] are reassigned above [original]'s max id to avoid
    collisions. Final [merge] pass collapses adjacent-equal tspans. *)
val insert_tspans_at : tspan array -> int -> tspan array -> tspan array

(** Reconcile a new flat content string back onto the original
    tspan structure, preserving per-range overrides where possible.

    Common prefix and suffix (byte-level, snapped to UTF-8 scalar
    boundaries) keep their original tspan assignments. The changed
    middle region is absorbed into the first overlapping tspan, with
    adjacent-equal tspans collapsed by a final [merge] pass.

    Mirrors the Rust / Swift [reconcile_content]. *)
val reconcile_content : tspan array -> string -> tspan array
