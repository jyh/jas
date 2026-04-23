(** Thread-local-equivalent point buffers for drag-accumulating tools. *)

(** Reset buffer [name] to empty. *)
val clear : string -> unit

(** Append (x, y) to buffer [name]. *)
val push : string -> float -> float -> unit

val length : string -> int
val points : string -> (float * float) list
