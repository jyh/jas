(** LiveElement framework helpers.

    Evaluates [Element.compound_shape] operand trees through the
    boolean algorithm, computes bounds of the result, and installs the
    [Element.live_bounds_hook] at module init time. See
    [transcripts/BOOLEAN.md] § Live element framework. *)

(** Default geometric tolerance in points. Matches the Precision
    default in the Boolean Options dialog. Equals 0.01 mm. *)
val default_precision : float

(** Flatten a document element into a polygon set for the boolean
    algorithm. See BOOLEAN.md § Geometry and precision for per-kind
    handling. *)
val element_to_polygon_set :
  Element.element -> float -> Boolean.polygon_set

(** Dispatch a boolean operation across an arbitrary number of
    operands. See BOOLEAN.md § Operand and paint rules. *)
val apply_operation :
  Element.compound_operation ->
  Boolean.polygon_set list ->
  Boolean.polygon_set

(** Tight bounding box of a polygon set. Returns (0, 0, 0, 0) for
    empty input. *)
val bounds_of_polygon_set :
  Boolean.polygon_set -> float * float * float * float

(** Evaluate a compound shape's operand tree through the boolean
    algorithm at the given precision. *)
val evaluate :
  Element.compound_shape -> float -> Boolean.polygon_set
