(** Canonical test-JSON serialization — the OCaml side of the cross-language
    equivalence oracle.

    [document_to_test_json] emits the byte-stable representation that every app
    compares in the conformance corpus; the parse direction rebuilds a
    document/element from that representation.

    This interface deliberately exposes ONLY the five entry points used across
    the codebase. The ~60 field/builder/parse helpers (json_obj, common_fields,
    stroke_json, parse_transform, …) stay internal, so a refactor cannot
    silently change the public surface of the module that defines the
    equivalence contract. *)

val canonical_value : Yojson.Safe.t -> string
(** Canonicalize a parsed JSON value to the byte-stable string form (sorted
    keys, fixed number formatting) used by the cross-language comparison. *)

val element_json : Element.element -> string
(** Serialize a single element to its canonical test-JSON string. *)

val document_to_test_json : Document.document -> string
(** Serialize a whole document to its canonical test-JSON string — the golden
    the cross-language conformance corpus compares byte-for-byte. *)

val parse_element : Yojson.Safe.t -> Element.element
(** Rebuild an element from a parsed test-JSON value (inverse of
    [element_json]). *)

val test_json_to_document : string -> Document.document
(** Rebuild a document from a test-JSON string (inverse of
    [document_to_test_json]). *)
