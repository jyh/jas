(** Anchor buffers for the Pen tool. Each anchor has position,
    in/out handles, and a smooth/corner flag. *)

type anchor = {
  x : float;
  y : float;
  hx_in : float;
  hy_in : float;
  hx_out : float;
  hy_out : float;
  smooth : bool;
}

val clear : string -> unit

(** Append a corner anchor (handles coincident with the anchor). *)
val push : string -> float -> float -> unit

(** Drop the last anchor. *)
val pop : string -> unit

(** Set the out-handle of the last anchor, mirroring the in-handle
    through the anchor; marks the anchor smooth. *)
val set_last_out_handle : string -> float -> float -> unit

val length : string -> int
val first : string -> anchor option
val anchors : string -> anchor list

(** True when (x, y) is within [radius] of the first anchor AND the
    buffer has >= 2 anchors. *)
val close_hit : string -> float -> float -> float -> bool
