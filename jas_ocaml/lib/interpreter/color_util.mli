(** Color conversion utilities used by the expression evaluator. *)

(** Parse [#rrggbb] into [(r, g, b)] with channels in [0..255]. *)
val parse_hex : string -> int * int * int

(** Format [(r, g, b)] (channels in [0..255]) as [#rrggbb]. *)
val rgb_to_hex : int -> int -> int -> string

(** Convert [(r, g, b)] to HSB: [h] in [0..360), [s] and [b] in [0..100]. *)
val rgb_to_hsb : int -> int -> int -> int * int * int

(** Convert HSB (floats) to [(r, g, b)] in [0..255]. *)
val hsb_to_rgb : float -> float -> float -> int * int * int

(** Convert [(r, g, b)] to CMYK: each channel in [0..100]. *)
val rgb_to_cmyk : int -> int -> int -> int * int * int * int
