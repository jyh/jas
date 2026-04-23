(** Document-aware evaluator primitives.

    Returns plain OCaml types so [Expr_eval] can wrap results as
    [value]s without introducing a module-dependency cycle. *)

(** Registration handle returned by [register_document]. Call
    [guard.restore ()] to reinstate the prior document slot. *)
type doc_guard = { restore : unit -> unit }

(** Register [doc] as the current document for doc-aware primitives.
    Nested registrations stack via the returned guard. *)
val register_document : Document.document -> doc_guard

(** Run [f] with [doc] registered, restoring the prior slot on exit. *)
val with_doc : Document.document -> (unit -> 'a) -> 'a

(** [hit_test x y]: top-level layer-child scan. [None] on miss,
    [Some path] on hit. *)
val hit_test : float -> float -> int list option

(** [hit_test_deep x y]: recurses into groups. *)
val hit_test_deep : float -> float -> int list option

(** [selection_contains path]: true when [path] is in the current
    doc's selection (regardless of kind). *)
val selection_contains : int list -> bool

(** [selection_empty]: true when the current doc's selection is
    empty (or no doc registered). *)
val selection_empty : unit -> bool
