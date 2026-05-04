(** PDF emitter (PRINT.md §Phase 1B). Uses Cairo's PDF surface. *)

(** Convert a document to PDF bytes. One page per artboard, or one
    union page when [print_preferences.ignore_artboards] is set.
    Coverage: paths, rect, line, circle, ellipse, polyline, polygon,
    basic text, groups, layers. Composite RGB only. *)
val document_to_pdf : Document.document -> string
