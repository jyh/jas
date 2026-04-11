(** path_text_layout tests. Mirrors jas_dioxus/src/algorithms/path_text_layout.rs. *)

open Jas.Path_text_layout

let straight () : Jas.Element.path_command list =
  [Jas.Element.MoveTo (0.0, 0.0); Jas.Element.LineTo (100.0, 0.0)]

let fixed_measure w =
  fun s -> float_of_int (String.length s) *. w

let approx a b = abs_float (a -. b) < 1e-6

let () =
  Alcotest.run "PathTextLayout" [
    "path_text_layout", [
      Alcotest.test_case "empty content is empty layout" `Quick (fun () ->
        let l = layout (straight ()) "" 0.0 16.0 (fixed_measure 10.0) in
        assert (l.char_count = 0);
        assert (Array.length l.glyphs = 0));

      Alcotest.test_case "glyphs advance along straight path" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.0 16.0 (fixed_measure 10.0) in
        assert (Array.length l.glyphs = 3);
        assert (approx l.glyphs.(0).cx 5.0);
        assert (approx l.glyphs.(1).cx 15.0);
        assert (approx l.glyphs.(2).cx 25.0);
        Array.iter (fun g ->
          assert (approx g.cy 0.0);
          assert (approx g.angle 0.0)
        ) l.glyphs);

      Alcotest.test_case "cursor pos at start is path origin" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.0 16.0 (fixed_measure 10.0) in
        match cursor_pos l 0 with
        | Some (x, y, _) -> assert (approx x 0.0); assert (approx y 0.0)
        | None -> assert false);

      Alcotest.test_case "cursor pos at end is after last glyph" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.0 16.0 (fixed_measure 10.0) in
        match cursor_pos l 3 with
        | Some (x, _, _) -> assert (approx x 30.0)
        | None -> assert false);

      Alcotest.test_case "hit_test picks nearest cursor index" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.0 16.0 (fixed_measure 10.0) in
        assert (hit_test l 12.0 0.0 = 1);
        assert (hit_test l 1000.0 0.0 = 3);
        assert (hit_test l (-100.0) 0.0 = 0));

      Alcotest.test_case "start_offset shifts glyphs along path" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.5 16.0 (fixed_measure 10.0) in
        assert (approx l.glyphs.(0).cx 55.0);
        assert (approx l.glyphs.(1).cx 65.0);
        assert (approx l.glyphs.(2).cx 75.0));

      Alcotest.test_case "total length matches straight path" `Quick (fun () ->
        let l = layout (straight ()) "ab" 0.0 16.0 (fixed_measure 10.0) in
        assert (approx l.total_length 100.0));

      Alcotest.test_case "cursor_pos for index in middle" `Quick (fun () ->
        let l = layout (straight ()) "abc" 0.0 16.0 (fixed_measure 10.0) in
        match cursor_pos l 1 with
        | Some (x, _, _) -> assert (approx x 10.0)
        | None -> assert false);

      Alcotest.test_case "empty path has zero total length" `Quick (fun () ->
        let l = layout [] "abc" 0.0 16.0 (fixed_measure 10.0) in
        assert (l.total_length = 0.0));

      Alcotest.test_case "glyphs overflow when path too short" `Quick (fun () ->
        let l = layout (straight ()) "abcdefghijkl" 0.0 16.0 (fixed_measure 10.0) in
        assert (Array.exists (fun g -> g.overflow) l.glyphs));
    ];
  ]
