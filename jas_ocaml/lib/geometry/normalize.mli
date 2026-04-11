(** SVG opacity normalizer.

    Extracts color alpha into fill/stroke opacity (multiplicative),
    then sets color alpha to 1.0.  This ensures that element
    transparency is expressed through opacity attributes rather than
    color alpha channels. *)

val normalize_document : Document.document -> Document.document
