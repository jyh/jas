(* Affine transform builders for Scale / Rotate / Shear tools.
   See transform_apply.mli for documentation. *)

let scale_matrix ~sx ~sy ~rx ~ry =
  Element.around_point (Element.make_scale sx sy) rx ry

let rotate_matrix ~theta_deg ~rx ~ry =
  Element.around_point (Element.make_rotate theta_deg) rx ry

let shear_matrix ~angle_deg ~axis ~axis_angle_deg ~rx ~ry =
  let k = tan (angle_deg *. Float.pi /. 180.0) in
  let base = match axis with
    | "horizontal" -> Element.make_shear k 0.0
    | "vertical" -> Element.make_shear 0.0 k
    | "custom" ->
      (* Custom-axis shear = R(-axis_angle) shear(k, 0) R(axis_angle):
         rotate the selection so the custom axis becomes horizontal,
         shear horizontally, rotate back. *)
      let r_back = Element.make_rotate axis_angle_deg in
      let r_fwd = Element.make_rotate (-. axis_angle_deg) in
      let s = Element.make_shear k 0.0 in
      Element.multiply (Element.multiply r_back s) r_fwd
    | _ -> Element.identity_transform
  in
  Element.around_point base rx ry

let stroke_width_factor ~sx ~sy =
  sqrt (abs_float sx *. abs_float sy)
