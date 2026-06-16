(** SVG opacity normalizer.

    Extracts color alpha into fill/stroke opacity (multiplicative),
    then sets color alpha to 1.0.  This ensures that element
    transparency is expressed through opacity attributes rather than
    color alpha channels. *)

val normalize_document : Document.document -> Document.document

(** Enforce the unique-id invariant after import (REFERENCE_GRAPH.md section
    2.5): walk the document in canonical pre-order; the FIRST element to use a
    given id keeps it, every later element with the same id has its id cleared
    to [None] (first-pre-order-wins). A no-op when ids are already unique.
    Called by every document reader (SVG, test-json, binary). *)
val dedupe_element_ids : Document.document -> Document.document
