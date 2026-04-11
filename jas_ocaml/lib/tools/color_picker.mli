(** Color picker state and dialog. *)

(** Radio channel selection. *)
type radio_channel = H | S | B | R | G | Blue

(** Mutable color picker state. *)
type state

(** Create a color picker state from an initial color.
    The boolean indicates whether the picker is for fill (true) or stroke (false). *)
val create_state : Element.color -> bool -> state

(** Whether the picker is for fill or stroke. *)
val for_fill : state -> bool

(** Get the current color. *)
val color : state -> Element.color

(** Set the color from RGB components (0-255 integer scale). *)
val set_rgb : state -> int -> int -> int -> unit

(** Set the color from HSB components (h: 0-360, s: 0-100, b: 0-100). *)
val set_hsb : state -> float -> float -> float -> unit

(** Set the color from CMYK components (all 0-100). *)
val set_cmyk : state -> float -> float -> float -> float -> unit

(** Set the color from a hex string (with or without '#'). *)
val set_hex : state -> string -> unit

(** Get RGB values as 0-255 integers. *)
val rgb_u8 : state -> int * int * int

(** Get HSB values (h: 0-360, s: 0-100, b: 0-100).
    Uses preserved hue/sat when the derived values would be lost. *)
val hsb_vals : state -> float * float * float

(** Get CMYK values (all 0-100). *)
val cmyk_vals : state -> float * float * float * float

(** Get hex string (no #). *)
val hex_str : state -> string

(** Set the selected radio channel. *)
val set_radio : state -> radio_channel -> unit

(** Get the selected radio channel. *)
val radio : state -> radio_channel

(** Set web-only mode. *)
val set_web_only : state -> bool -> unit

(** Get web-only mode. *)
val web_only : state -> bool

(** Snap a 0..1 component to the nearest web-safe value. *)
val snap_web : float -> float

(** Set the color from gradient position (x, y normalized 0..1). *)
val set_from_gradient : state -> float -> float -> unit

(** Set the color from colorbar position (t: 0..1, top=0, bottom=1). *)
val set_from_colorbar : state -> float -> unit

(** Get colorbar position (0..1, 0=top) for current color. *)
val colorbar_pos : state -> float

(** Get gradient position (x, y: 0..1) for current color. *)
val gradient_pos : state -> float * float

(** Show a modal color picker dialog.
    Returns [Some color] if the user clicks OK, [None] if cancelled.
    The [parent] window is used for modality. *)
val run_dialog : ?parent:GWindow.window -> state -> Element.color option
