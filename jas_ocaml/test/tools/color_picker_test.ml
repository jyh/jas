(* Tests for color picker state logic. *)

let assert_float_eq ?(eps = 1.0) name a b =
  if abs_float (a -. b) > eps then
    failwith (Printf.sprintf "%s: expected %f, got %f" name a b)

let () =
  Alcotest.run "Color_picker" [
    "create and rgb", [
      Alcotest.test_case "new from black" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 0 && g = 0 && b = 0);
        assert (Jas.Color_picker.hex_str cp = "000000")
      );

      Alcotest.test_case "new from red" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_rgb 1.0 0.0 0.0) false in
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 255 && g = 0 && b = 0);
        assert (Jas.Color_picker.hex_str cp = "ff0000")
      );

      Alcotest.test_case "set_rgb" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        Jas.Color_picker.set_rgb cp 128 64 32;
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 128 && g = 64 && b = 32)
      );
    ];

    "hsb and cmyk", [
      Alcotest.test_case "set_hsb pure red" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        Jas.Color_picker.set_hsb cp 0.0 100.0 100.0;
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 255 && g = 0 && b = 0)
      );

      Alcotest.test_case "set_cmyk white" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        Jas.Color_picker.set_cmyk cp 0.0 0.0 0.0 0.0;
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 255 && g = 255 && b = 255)
      );

      Alcotest.test_case "set_hex" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        Jas.Color_picker.set_hex cp "ff8000";
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        assert (r = 255 && g = 128 && b = 0)
      );

      Alcotest.test_case "hsb_vals red" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_rgb 1.0 0.0 0.0) true in
        let (h, s, b) = Jas.Color_picker.hsb_vals cp in
        assert_float_eq "h" h 0.0;
        assert_float_eq "s" s 100.0;
        assert_float_eq "b" b 100.0
      );

      Alcotest.test_case "cmyk_vals white" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.white true in
        let (c, m, y, k) = Jas.Color_picker.cmyk_vals cp in
        assert_float_eq "c" c 0.0;
        assert_float_eq "m" m 0.0;
        assert_float_eq "y" y 0.0;
        assert_float_eq "k" k 0.0
      );
    ];

    "web snap", [
      Alcotest.test_case "web snap" `Quick (fun () ->
        assert (Jas.Color_picker.snap_web 0.0 = 0.0);
        assert (Jas.Color_picker.snap_web 1.0 = 1.0);
        assert (Jas.Color_picker.snap_web 0.19 = 0.2);
        assert (Jas.Color_picker.snap_web 0.5 = 0.4)
      );

      Alcotest.test_case "web_only snaps" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state Jas.Element.black true in
        Jas.Color_picker.set_web_only cp true;
        Jas.Color_picker.set_rgb cp 100 150 200;
        let (r, g, b) = Jas.Color_picker.rgb_u8 cp in
        let web_vals = [0; 51; 102; 153; 204; 255] in
        assert (List.mem r web_vals);
        assert (List.mem g web_vals);
        assert (List.mem b web_vals)
      );
    ];

    "colorbar and gradient", [
      Alcotest.test_case "colorbar_pos roundtrip H" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_hsb 180.0 0.5 0.8) true in
        Jas.Color_picker.set_radio cp Jas.Color_picker.H;
        let pos = Jas.Color_picker.colorbar_pos cp in
        assert_float_eq ~eps:0.02 "pos" pos 0.5
      );

      Alcotest.test_case "gradient_pos roundtrip H" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_hsb 120.0 0.7 0.9) true in
        Jas.Color_picker.set_radio cp Jas.Color_picker.H;
        let (x, y) = Jas.Color_picker.gradient_pos cp in
        assert_float_eq ~eps:0.02 "x" x 0.7;
        assert_float_eq ~eps:0.02 "y" y 0.1
      );

      Alcotest.test_case "set_from_gradient H channel" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_hsb 60.0 1.0 1.0) true in
        Jas.Color_picker.set_radio cp Jas.Color_picker.H;
        Jas.Color_picker.set_from_gradient cp 0.5 0.0;
        (* x=S=0.5, y=0 means B=1.0 *)
        let (h, s, b) = Jas.Color_picker.hsb_vals cp in
        assert_float_eq "h" h 60.0;
        assert_float_eq "s" s 50.0;
        assert_float_eq "b" b 100.0
      );

      Alcotest.test_case "set_from_colorbar H channel" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_hsb 0.0 1.0 1.0) true in
        Jas.Color_picker.set_radio cp Jas.Color_picker.H;
        Jas.Color_picker.set_from_colorbar cp 0.5;
        let (h, _s, _b) = Jas.Color_picker.hsb_vals cp in
        assert_float_eq "h" h 180.0
      );
    ];

    "preserved hue and extraction", [
      Alcotest.test_case "preserved hue survives zero brightness" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_hsb 120.0 0.8 1.0) true in
        (* Set brightness to 0 *)
        Jas.Color_picker.set_hsb cp 120.0 80.0 0.0;
        let (h, s, b) = Jas.Color_picker.hsb_vals cp in
        assert_float_eq "h" h 120.0;
        assert_float_eq "s" s 80.0;
        assert_float_eq "b" b 0.0
      );

      Alcotest.test_case "color extraction" `Quick (fun () ->
        let cp = Jas.Color_picker.create_state (Jas.Element.color_rgb 0.5 0.25 0.75) true in
        let c = Jas.Color_picker.color cp in
        let (r, g, b, _) = Jas.Element.color_to_rgba c in
        assert_float_eq ~eps:0.01 "r" r 0.5;
        assert_float_eq ~eps:0.01 "g" g 0.25;
        assert_float_eq ~eps:0.01 "b" b 0.75
      );

      Alcotest.test_case "for_fill flag" `Quick (fun () ->
        let cp1 = Jas.Color_picker.create_state Jas.Element.black true in
        let cp2 = Jas.Color_picker.create_state Jas.Element.black false in
        assert (Jas.Color_picker.for_fill cp1 = true);
        assert (Jas.Color_picker.for_fill cp2 = false)
      );
    ];
  ]
