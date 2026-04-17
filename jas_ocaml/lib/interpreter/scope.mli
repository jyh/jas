(** Nested lexical scope for expression evaluation.

    A scope is a chain of binding frames: [extend] pushes a child,
    [merge] adds bindings at the same level (shadowing).  [to_json]
    flattens the chain into a single JSON context object. *)

type t

(** Create a new root scope with the given bindings. *)
val create : (string * Yojson.Safe.t) list -> t

(** Build a root scope from a JSON context object. *)
val from_json : Yojson.Safe.t -> t

(** Look up a key, walking from the current frame to the root. *)
val get : t -> string -> Yojson.Safe.t option

(** Push a child frame with additional bindings. *)
val extend : t -> (string * Yojson.Safe.t) list -> t

(** Merge bindings into a new frame at the same level as [scope]
    (new bindings shadow existing ones). *)
val merge : t -> (string * Yojson.Safe.t) list -> t

(** Flatten the scope chain back to a JSON context object. *)
val to_json : t -> Yojson.Safe.t
