(** Convert a Document to SVG format.

    Internal coordinates are in points (pt). SVG coordinates are in pixels (px). *)

val document_to_svg : Document.document -> string
