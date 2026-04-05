(** Units of measurement for element coordinates. *)

(** SVG/CSS length units. *)
type unit = Px | Pt | Pc | In | Cm | Mm | Em | Rem

(** A numeric value paired with a unit of measurement. *)
type measure = { value : float; unit : unit }

val px_per_unit : unit -> float
val to_px : ?font_size:float -> measure -> float

(** Shorthand constructors. *)

val px : float -> measure
val pt : float -> measure
val pc : float -> measure
val inches : float -> measure
val cm : float -> measure
val mm : float -> measure
val em : float -> measure
val rem : float -> measure
