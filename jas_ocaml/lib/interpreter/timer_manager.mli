(** GTK timer management — schedule and cancel named timeouts.

    Each timer is keyed by a string id.  Starting a new timer with an
    existing id cancels the previous one. *)

(** Start a recurring timer that fires [callback] every [delay_ms]
    milliseconds, identified by [id]. *)
val start_timer : string -> int -> (unit -> unit) -> unit

(** Cancel the named timer if it exists; a no-op otherwise. *)
val cancel_timer : string -> unit
