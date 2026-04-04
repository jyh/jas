(** Convert between Document and SVG format.

    Internal coordinates are in points (pt). SVG coordinates are in pixels (px). *)

val document_to_svg : Document.document -> string

val svg_to_document : string -> Document.document
