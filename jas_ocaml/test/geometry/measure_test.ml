open Jas.Measure

let () =
  Alcotest.run "Measure" [
    "measure", [
      Alcotest.test_case "px identity" `Quick (fun () ->
        let m = px 100.0 in
        assert (to_px m = 100.0));

      Alcotest.test_case "pt to px: 72pt = 96px" `Quick (fun () ->
        let m = pt 72.0 in
        assert (abs_float (to_px m -. 96.0) < 1e-10));

      Alcotest.test_case "pc to px: 1pc = 16px" `Quick (fun () ->
        let m = pc 1.0 in
        assert (abs_float (to_px m -. 16.0) < 1e-10));

      Alcotest.test_case "in to px: 1in = 96px" `Quick (fun () ->
        let m = inches 1.0 in
        assert (abs_float (to_px m -. 96.0) < 1e-10));

      Alcotest.test_case "cm to px: 2.54cm = 96px" `Quick (fun () ->
        let m = cm 2.54 in
        assert (abs_float (to_px m -. 96.0) < 1e-10));

      Alcotest.test_case "mm to px: 25.4mm = 96px" `Quick (fun () ->
        let m = mm 25.4 in
        assert (abs_float (to_px m -. 96.0) < 1e-10));

      Alcotest.test_case "em to px: 2em = 32px at default 16px font" `Quick (fun () ->
        let m = em 2.0 in
        assert (abs_float (to_px m -. 32.0) < 1e-10));

      Alcotest.test_case "em with custom font size: 2em = 48px at 24px font" `Quick (fun () ->
        let m = em 2.0 in
        assert (abs_float (to_px ~font_size:24.0 m -. 48.0) < 1e-10));

      Alcotest.test_case "rem to px: 1.5rem = 24px at default 16px font" `Quick (fun () ->
        let m = rem 1.5 in
        assert (abs_float (to_px m -. 24.0) < 1e-10));
    ];
  ]
