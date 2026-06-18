(** Polyline-to-Bezier simplification tests.
    Mirrors jas_dioxus/src/algorithms/simplify.rs tests. *)

open Jas.Simplify
module E = Jas.Element

let is_move = function E.MoveTo _ -> true | _ -> false
let is_line = function E.LineTo _ -> true | _ -> false
let is_curve = function E.CurveTo _ -> true | _ -> false
let is_close = function E.ClosePath -> true | _ -> false

let count p lst = List.length (List.filter p lst)
let last lst = List.nth lst (List.length lst - 1)

let () =
  Alcotest.run "Simplify" [
    "simplify_polyline", [
      Alcotest.test_case "empty input returns empty" `Quick (fun () ->
        assert (simplify_polyline [] 0.5 true = []));

      Alcotest.test_case "two points emits MoveTo + LineTo" `Quick (fun () ->
        let out = simplify_polyline [(0.0, 0.0); (10.0, 0.0)] 0.5 false in
        assert (List.length out = 2);
        assert (is_move (List.nth out 0));
        assert (is_line (List.nth out 1)));

      Alcotest.test_case "two points closed appends ClosePath" `Quick (fun () ->
        let out = simplify_polyline [(0.0, 0.0); (10.0, 0.0)] 0.5 true in
        assert (List.length out = 3);
        assert (is_move (List.nth out 0));
        assert (is_line (List.nth out 1));
        assert (is_close (List.nth out 2)));

      Alcotest.test_case "square keeps lines (no curves)" `Quick (fun () ->
        (* Closed square — every edge is straight, so the output should
           be 4 LineTo + ClosePath after the initial MoveTo. *)
        let sq = [(0.0, 0.0); (10.0, 0.0); (10.0, 10.0); (0.0, 10.0)] in
        let out = simplify_polyline sq 0.5 true in
        assert (count is_curve out = 0);
        assert (count is_line out = 4);
        assert (is_close (last out)));

      Alcotest.test_case "circle sampling recovers curves" `Quick (fun () ->
        let n = 32 in
        let r = 50.0 in
        let pts = List.init n (fun i ->
          let t = 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
          (r *. cos t, r *. sin t)) in
        let out = simplify_polyline pts 0.5 true in
        assert (count is_curve out > 0);
        assert (count is_line out = 0);
        assert (is_close (last out)));
    ];

    "detect_corners", [
      Alcotest.test_case "closed square -> all 4 vertices" `Quick (fun () ->
        let sq = [(0.0, 0.0); (10.0, 0.0); (10.0, 10.0); (0.0, 10.0)] in
        let corners = detect_corners sq default_corner_angle true in
        assert (corners = [0; 1; 2; 3]));

      Alcotest.test_case "collinear points -> none" `Quick (fun () ->
        let line = List.init 10 (fun i -> (float_of_int i, 0.0)) in
        let corners = detect_corners line default_corner_angle false in
        assert (corners = []));

      Alcotest.test_case "25 degree turn below threshold -> none" `Quick (fun () ->
        let angle = 25.0 *. Float.pi /. 180.0 in
        let pts = [
          (0.0, 0.0);
          (10.0, 0.0);
          (10.0 +. 10.0 *. cos angle, 10.0 *. sin angle);
        ] in
        let corners = detect_corners pts default_corner_angle false in
        assert (corners = []));

      Alcotest.test_case "45 degree turn above threshold -> corner" `Quick (fun () ->
        let angle = 45.0 *. Float.pi /. 180.0 in
        let pts = [
          (0.0, 0.0);
          (10.0, 0.0);
          (10.0 +. 10.0 *. cos angle, 10.0 *. sin angle);
        ] in
        let corners = detect_corners pts default_corner_angle false in
        assert (corners = [1]));

      Alcotest.test_case "open polyline endpoints are not corners" `Quick (fun () ->
        let pts = [(0.0, 0.0); (5.0, 0.0); (10.0, 0.0)] in
        let corners = detect_corners pts default_corner_angle false in
        assert (corners = []));
    ];
  ]
