let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  let open Jas.Measure in
  Printf.printf "Measure tests:\n";

  run_test "px identity" (fun () ->
    let m = px 100.0 in
    assert (to_px m = 100.0));

  run_test "pt to px: 72pt = 96px" (fun () ->
    let m = pt 72.0 in
    assert (abs_float (to_px m -. 96.0) < 1e-10));

  run_test "pc to px: 1pc = 16px" (fun () ->
    let m = pc 1.0 in
    assert (abs_float (to_px m -. 16.0) < 1e-10));

  run_test "in to px: 1in = 96px" (fun () ->
    let m = inches 1.0 in
    assert (abs_float (to_px m -. 96.0) < 1e-10));

  run_test "cm to px: 2.54cm = 96px" (fun () ->
    let m = cm 2.54 in
    assert (abs_float (to_px m -. 96.0) < 1e-10));

  run_test "mm to px: 25.4mm = 96px" (fun () ->
    let m = mm 25.4 in
    assert (abs_float (to_px m -. 96.0) < 1e-10));

  run_test "em to px: 2em = 32px at default 16px font" (fun () ->
    let m = em 2.0 in
    assert (abs_float (to_px m -. 32.0) < 1e-10));

  run_test "em with custom font size: 2em = 48px at 24px font" (fun () ->
    let m = em 2.0 in
    assert (abs_float (to_px ~font_size:24.0 m -. 48.0) < 1e-10));

  run_test "rem to px: 1.5rem = 24px at default 16px font" (fun () ->
    let m = rem 1.5 in
    assert (abs_float (to_px m -. 24.0) < 1e-10));

  Printf.printf "All measure tests passed.\n"
