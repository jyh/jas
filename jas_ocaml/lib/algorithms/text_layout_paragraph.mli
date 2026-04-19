(** Build [paragraph_segment] lists from a Text/Text_path's tspans.

    A [tspan] whose [jas_role = Some "paragraph"] is a paragraph
    wrapper: it carries the per-paragraph attribute set (indent,
    space, list style, alignment) but no text content. The body
    tspans that follow it (until the next wrapper or end) make up
    that paragraph.

    Phase 5: produces segments for the rendering pipeline so
    [Text_layout.layout_with_paragraphs] can apply each paragraph's
    constraints. When the element has no wrapper tspans the result
    is empty — the caller falls back to plain [Text_layout.layout]. *)

(** Build paragraph segments from a tspan array. The [is_area] flag
    coerces [justify] alignments to [Left] for point text per
    PARAGRAPH.md §Text-kind gating. Returns [[]] when no wrapper is
    present. *)
val build_segments_from_text :
  Element.tspan array -> string -> bool ->
  Text_layout.paragraph_segment list

(** Gap between marker and text per PARAGRAPH.md §Marker rendering. *)
val marker_gap_pt : float

(** The literal glyph string that renders as the marker for the
    given [jas:list-style] value at [counter] (1-based).
    Bullet styles ignore the counter; numbered styles format it per
    the §Bullets and numbered lists enumeration. Unknown styles
    return an empty string so the renderer skips drawing. *)
val marker_text : string -> int -> string

(** Spreadsheet-style base-26 with no zero digit:
    1 → "a", 26 → "z", 27 → "aa", 28 → "ab"... *)
val to_alpha : int -> bool -> string

(** Roman numerals: 1 → "i", 4 → "iv", 1990 → "mcmxc". Above 3999
    falls back to [(N)] since standard Roman tops out at MMMCMXCIX. *)
val to_roman : int -> bool -> string

(** Compute the 1-based counter for each numbered-list paragraph
    in [segs], in order. Bullet and non-list paragraphs get 0. Per
    PARAGRAPH.md §Counter run rule: consecutive paragraphs with the
    same [num-*] list style continue counting; a different style or
    a bullet / no-style paragraph breaks the run, and the next
    [num-*] paragraph starts again at 1. *)
val compute_counters : Text_layout.paragraph_segment list -> int list
