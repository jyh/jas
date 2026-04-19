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
