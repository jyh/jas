(* Mirrors workspace_interpreter/tests/test_dash_renderer.py and
   jas_dioxus/src/algorithms/dash_renderer.rs tests. *)

open Jas.Element
open Jas.Dash_renderer

let approx_eq a b = abs_float (a -. b) < 1e-6

let endpoints = function
  | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
  | _ -> None

let edge_cases = [
  Alcotest.test_case "empty array returns path unchanged" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0); LineTo (10.0, 10.0); ClosePath] in
    let r = expand_dashed_stroke path [] false in
    assert (List.length r = 1);
    assert (List.hd r = path));

  Alcotest.test_case "empty path returns empty" `Quick (fun () ->
    let r = expand_dashed_stroke [] [4.0; 2.0] false in
    assert (r = []));
]

let preserve_tests = [
  Alcotest.test_case "simple line one period" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (6.0, 0.0)] in
    let r = expand_dashed_stroke path [4.0; 2.0] false in
    assert (List.length r = 1);
    assert (List.hd r = [MoveTo (0.0, 0.0); LineTo (4.0, 0.0)]));

  Alcotest.test_case "simple line partial period" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0)] in
    let r = expand_dashed_stroke path [4.0; 2.0] false in
    assert (List.length r = 2);
    assert (List.nth r 0 = [MoveTo (0.0, 0.0); LineTo (4.0, 0.0)]);
    assert (List.nth r 1 = [MoveTo (6.0, 0.0); LineTo (10.0, 0.0)]));

  Alcotest.test_case "dash spans corner" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (5.0, 0.0); LineTo (5.0, 5.0)] in
    let r = expand_dashed_stroke path [4.0; 2.0] false in
    assert (List.length r = 2);
    assert (List.nth r 0 = [MoveTo (0.0, 0.0); LineTo (4.0, 0.0)]);
    assert (List.nth r 1 = [MoveTo (5.0, 1.0); LineTo (5.0, 5.0)]));
]

let align_tests = [
  Alcotest.test_case "open two-anchor line no flex" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0)] in
    let r = expand_dashed_stroke path [4.0; 2.0] true in
    assert (List.length r = 2);
    assert (List.nth r 0 = [MoveTo (0.0, 0.0); LineTo (4.0, 0.0)]);
    assert (List.nth r 1 = [MoveTo (6.0, 0.0); LineTo (10.0, 0.0)]));

  Alcotest.test_case "open path endpoint starts with full dash" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (20.0, 0.0)] in
    let r = expand_dashed_stroke path [4.0; 2.0] true in
    assert (List.length r > 0);
    assert (List.hd (List.hd r) = MoveTo (0.0, 0.0)));

  Alcotest.test_case "closed rect dash spans corner" `Quick (fun () ->
    let path = [
      MoveTo (0.0, 0.0); LineTo (24.0, 0.0); LineTo (24.0, 24.0);
      LineTo (0.0, 24.0); ClosePath;
    ] in
    let r = expand_dashed_stroke path [16.0; 4.0] true in
    let spans_corner = ref false in
    List.iter (fun sub ->
      let arr = Array.of_list sub in
      let n = Array.length arr in
      Array.iteri (fun idx cmd ->
        match endpoints cmd with
        | Some (x, y) when approx_eq x 24.0 && approx_eq y 0.0 ->
          if idx > 0 && idx < n - 1 then spans_corner := true
        | _ -> ()
      ) arr
    ) r;
    assert !spans_corner);

  Alcotest.test_case "open zigzag terminates at endpoint" `Quick (fun () ->
    let path = [MoveTo (0.0, 0.0); LineTo (50.0, 0.0); LineTo (50.0, 75.0)] in
    let r = expand_dashed_stroke path [12.0; 6.0] true in
    assert (List.length r > 0);
    let last = List.nth r (List.length r - 1) in
    let last_cmd = List.nth last (List.length last - 1) in
    match endpoints last_cmd with
    | Some (x, y) ->
      assert (approx_eq x 50.0);
      assert (approx_eq y 75.0)
    | None -> assert false);
]

let determinism_tests = [
  Alcotest.test_case "idempotent" `Quick (fun () ->
    let path = [
      MoveTo (0.0, 0.0); LineTo (100.0, 0.0); LineTo (100.0, 60.0);
      LineTo (0.0, 60.0); ClosePath;
    ] in
    let r1 = expand_dashed_stroke path [12.0; 6.0] true in
    let r2 = expand_dashed_stroke path [12.0; 6.0] true in
    assert (r1 = r2));
]

let () =
  Alcotest.run "DashRenderer" [
    "edge_cases", edge_cases;
    "preserve", preserve_tests;
    "align", align_tests;
    "determinism", determinism_tests;
  ]
