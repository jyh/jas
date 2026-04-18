(** App-global rich clipboard cache for cross-element rich paste. *)

val write : string -> Element.tspan array -> unit
val read_matching : string -> Element.tspan array option
