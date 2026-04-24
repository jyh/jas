(** LiveElement framework helpers.

    Evaluates [Element.compound_shape] operand trees through the
    boolean algorithm, computes bounds of the result, and installs the
    [Element.live_bounds_hook] at module init time. See
    [transcripts/BOOLEAN.md] § Live element framework. *)

(** Default geometric tolerance in points. Matches the Precision
    default in the Boolean Options dialog. Equals 0.01 mm. *)
val default_precision : float

(** Ring-aware path flattening. MoveTo starts a new ring; ClosePath
    finalizes. Open subpaths finalize at the next MoveTo or end.
    Rings with fewer than 3 points are dropped. Bezier / quad use
    20 steps; Smooth / Arc approximate as a line to the endpoint.

    Exposed so [Path_ops] can bridge [Element.path_command] lists
    into the boolean module's [polygon_set] shape — see
    BLOB_BRUSH_TOOL.md Commit pipeline. *)
val flatten_path_to_rings :
  Element.path_command list -> Boolean.polygon_set

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

(** Replace a compound shape with Polygon elements derived from its
    evaluated geometry. Each polygon carries the compound shape's
    own paint; rings with fewer than 3 points are dropped. *)
val expand : Element.compound_shape -> float -> Element.element list

(** Inverse of Make. Returns the operand array verbatim. *)
val release : Element.compound_shape -> Element.element array
