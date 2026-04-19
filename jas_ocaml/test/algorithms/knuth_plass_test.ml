open Jas.Knuth_plass

let b w idx = Box { width = w; char_idx = idx }
let g w idx = Glue { width = w; stretch = w *. 0.5; shrink = w *. 0.33;
                     char_idx = idx }
let g_wide w idx = Glue { width = w; stretch = 20.0; shrink = 5.0;
                          char_idx = idx }
let fil_glue idx = Glue { width = 0.0; stretch = 1e9; shrink = 0.0;
                          char_idx = idx }
let forced idx = Penalty { width = 0.0; value = -. penalty_infinity;
                            flagged = false; char_idx = idx }

let kp_tests = [
  Alcotest.test_case "empty_returns_empty" `Quick (fun () ->
    let breaks = compose [||] [| 100.0 |] in
    Alcotest.(check (option int)) "empty list"
      (Some 0)
      (Option.map List.length breaks));

  Alcotest.test_case "three_words_one_line_when_wide_enough" `Quick (fun () ->
    let items = [|
      b 30.0 0; g 10.0 3; b 30.0 4; g 10.0 7; b 30.0 8;
      fil_glue 11; forced 11;
    |] in
    match compose items [| 200.0 |] with
    | Some breaks ->
      Alcotest.(check int) "one line" 1 (List.length breaks);
      let last = List.hd breaks in
      Alcotest.(check int) "ends at terminator"
        (Array.length items - 1) last.item_idx
    | None -> Alcotest.fail "expected Some");

  Alcotest.test_case "three_words_two_lines_when_narrow" `Quick (fun () ->
    let items = [|
      b 30.0 0; g 10.0 3; b 30.0 4; g 10.0 7; b 30.0 8;
      fil_glue 11; forced 11;
    |] in
    match compose items [| 70.0 |] with
    | Some breaks ->
      Alcotest.(check int) "two lines" 2 (List.length breaks);
      let first = List.hd breaks in
      Alcotest.(check int) "first break at glue 3" 3 first.item_idx
    | None -> Alcotest.fail "expected Some");

  Alcotest.test_case "hyphen_penalty_discourages_high" `Quick (fun () ->
    let items = [|
      b 35.0 0; g_wide 5.0 2; b 50.0 3; g 5.0 8; b 10.0 9;
      Penalty { width = 5.0; value = 1000.0; flagged = true; char_idx = 11 };
      b 10.0 11; fil_glue 13; forced 13;
    |] in
    match compose items [| 110.0 |] with
    | Some breaks ->
      let used_hyphen = List.exists (fun br -> br.item_idx = 5) breaks in
      Alcotest.(check bool) "hyphen suppressed" false used_hyphen
    | None -> Alcotest.fail "expected Some");

  Alcotest.test_case "hyphen_penalty_taken_low" `Quick (fun () ->
    let items = [|
      b 35.0 0; g_wide 5.0 2; b 50.0 3; g 5.0 8; b 10.0 9;
      Penalty { width = 5.0; value = 10.0; flagged = true; char_idx = 11 };
      b 10.0 11; fil_glue 13; forced 13;
    |] in
    match compose items [| 110.0 |] with
    | Some breaks ->
      let used_hyphen = List.exists (fun br -> br.item_idx = 5) breaks in
      Alcotest.(check bool) "hyphen taken" true used_hyphen
    | None -> Alcotest.fail "expected Some");
]

let () = Alcotest.run "Knuth-Plass" [ "compose", kp_tests ]
