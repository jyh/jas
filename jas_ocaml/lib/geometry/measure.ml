(** Units of measurement for element coordinates.

    Element coordinates can use any unit. The canvas bounding box is in px.
    A measure pairs a numeric value with a unit. *)

(** SVG/CSS length units. *)
type unit =
  | Px   (** Pixels (default, relative to viewing device) *)
  | Pt   (** Points (1/72 inch) *)
  | Pc   (** Picas (12 points) *)
  | In   (** Inches *)
  | Cm   (** Centimeters *)
  | Mm   (** Millimeters *)
  | Em   (** Relative to font size *)
  | Rem  (** Relative to root font size *)

(** A numeric value paired with a unit of measurement. *)
type measure = {
  value : float;
  unit : unit;
}

(** Pixels per unit at 96 DPI. *)
let px_per_unit = function
  | Px -> 1.0
  | Pt -> 96.0 /. 72.0
  | Pc -> 96.0 /. 72.0 *. 12.0
  | In -> 96.0
  | Cm -> 96.0 /. 2.54
  | Mm -> 96.0 /. 25.4
  | Em | Rem -> 1.0  (* placeholder, use to_px with font_size *)

(** Convert to pixels.

    @param font_size The reference font size in px, used for em/rem. Default 16. *)
let to_px ?(font_size = 16.0) m =
  match m.unit with
  | Em | Rem -> m.value *. font_size
  | u -> m.value *. px_per_unit u

(** Shorthand constructors. *)
let px value = { value; unit = Px }
let pt value = { value; unit = Pt }
let pc value = { value; unit = Pc }
let inches value = { value; unit = In }
let cm value = { value; unit = Cm }
let mm value = { value; unit = Mm }
let em value = { value; unit = Em }
let rem value = { value; unit = Rem }
