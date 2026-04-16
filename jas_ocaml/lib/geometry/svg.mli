(** Convert between Document and SVG format.

    Internal coordinates are in points (pt). SVG coordinates are in pixels (px). *)

val document_to_svg : Document.document -> string

val element_svg : string -> Element.element -> string
(** [element_svg indent elem] returns an SVG fragment for the element
    (recursively for groups/layers). The [indent] is prepended to each
    line for pretty-printing. *)

val svg_to_document : string -> Document.document
