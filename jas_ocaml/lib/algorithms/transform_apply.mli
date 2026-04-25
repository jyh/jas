(** Affine transform builders for the Scale / Rotate / Shear tools.

    Each function returns an [Element.transform] that composes:

    - [Element.make_translate (-. rx) (-. ry)] to move the
      reference point to the origin,
    - the tool-specific base transform (scale / rotate / shear),
    - [Element.make_translate rx ry] to move the reference point
      back.

    Composition is delegated to [Element.around_point] so every
    tool's matrix pivots around the same reference point. See
    [SCALE_TOOL.md] / [ROTATE_TOOL.md] / [SHEAR_TOOL.md]
    \167 Apply behavior. *)

(** Scale matrix with factors [(sx, sy)] around [(rx, ry)].
    Negative factors flip the selection on that axis. A factor
    of [1.0] on both axes is the identity transform. *)
val scale_matrix : sx:float -> sy:float -> rx:float -> ry:float -> Element.transform

(** Rotation matrix: [theta_deg] degrees CCW around [(rx, ry)].
    [theta_deg = 0.0] is the identity transform. *)
val rotate_matrix : theta_deg:float -> rx:float -> ry:float -> Element.transform

(** Shear matrix: [angle_deg] degrees of slant along [axis] around
    [(rx, ry)]. [axis] is one of ["horizontal"], ["vertical"],
    or ["custom"]. When custom, [axis_angle_deg] is the axis
    direction in degrees from horizontal.

    The shear factor is [tan(angle_deg)]. Angles approaching
    plus or minus 90 degrees become unstable; callers clamp to
    a reasonable range (the dialog uses plus or minus 89.9). *)
val shear_matrix :
  angle_deg:float -> axis:string -> axis_angle_deg:float ->
  rx:float -> ry:float -> Element.transform

(** Geometric mean of [(sx, sy)] for use as the stroke-width
    multiplier under non-uniform scaling. Always returns a
    non-negative value. See [SCALE_TOOL.md] \167 Apply behavior:
    "stroke width: when state.scale_strokes is true, multiply by
    the unsigned geometric mean square root of |sx sy|." *)
val stroke_width_factor : sx:float -> sy:float -> float
