let () =
  let open Jas.Measure in

  (* px identity *)
  let m = px 100.0 in
  assert (to_px m = 100.0);

  (* pt to px: 72pt = 96px *)
  let m = pt 72.0 in
  assert (abs_float (to_px m -. 96.0) < 1e-10);

  (* pc to px: 1pc = 16px *)
  let m = pc 1.0 in
  assert (abs_float (to_px m -. 16.0) < 1e-10);

  (* in to px: 1in = 96px *)
  let m = inches 1.0 in
  assert (abs_float (to_px m -. 96.0) < 1e-10);

  (* cm to px: 2.54cm = 96px *)
  let m = cm 2.54 in
  assert (abs_float (to_px m -. 96.0) < 1e-10);

  (* mm to px: 25.4mm = 96px *)
  let m = mm 25.4 in
  assert (abs_float (to_px m -. 96.0) < 1e-10);

  (* em to px: 2em = 32px at default 16px font *)
  let m = em 2.0 in
  assert (abs_float (to_px m -. 32.0) < 1e-10);

  (* em with custom font size *)
  let m = em 2.0 in
  assert (abs_float (to_px ~font_size:24.0 m -. 48.0) < 1e-10);

  (* rem to px: 1.5rem = 24px at default 16px font *)
  let m = rem 1.5 in
  assert (abs_float (to_px m -. 24.0) < 1e-10);

  Printf.printf "All measure tests passed.\n"
