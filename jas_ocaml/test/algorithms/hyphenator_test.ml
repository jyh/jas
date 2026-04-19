open Jas.Hyphenator

let split_pattern_tests = [
  Alcotest.test_case "split_pattern_simple" `Quick (fun () ->
    let (letters, digits) = split_pattern "2'2" in
    Alcotest.(check string) "letters" "'" letters;
    Alcotest.(check (array int)) "digits" [| 2; 2 |] digits);

  Alcotest.test_case "split_pattern_no_digits" `Quick (fun () ->
    let (letters, digits) = split_pattern "abc" in
    Alcotest.(check string) "letters" "abc" letters;
    Alcotest.(check (array int)) "digits" [| 0; 0; 0; 0 |] digits);

  Alcotest.test_case "split_pattern_with_word_anchors" `Quick (fun () ->
    let (letters, digits) = split_pattern ".un1" in
    Alcotest.(check string) "letters" ".un" letters;
    Alcotest.(check (array int)) "digits" [| 0; 0; 0; 1 |] digits);
]

let hyphenate_tests = [
  Alcotest.test_case "empty_word_returns_empty_breaks" `Quick (fun () ->
    let breaks = hyphenate "" [".un1"] ~min_before:1 ~min_after:1 in
    Alcotest.(check int) "len" 0 (Array.length breaks));

  Alcotest.test_case "no_patterns_no_breaks" `Quick (fun () ->
    let breaks = hyphenate "hello" [] ~min_before:1 ~min_after:1 in
    Alcotest.(check int) "len" 6 (Array.length breaks);
    Array.iter (fun b -> Alcotest.(check bool) "no break" false b) breaks);

  Alcotest.test_case "min_before_suppresses_early_breaks" `Quick (fun () ->
    let breaks = hyphenate "hello" ["1ello"] ~min_before:2 ~min_after:1 in
    Alcotest.(check bool) "pos1 suppressed" false breaks.(1));

  Alcotest.test_case "min_after_suppresses_late_breaks" `Quick (fun () ->
    let breaks = hyphenate "hello" ["hell1o"] ~min_before:1 ~min_after:2 in
    Alcotest.(check bool) "pos4 suppressed" false breaks.(4));

  Alcotest.test_case "en_us_sample_breaks_repeat" `Quick (fun () ->
    let breaks = hyphenate "repeat" en_us_patterns_sample
                   ~min_before:1 ~min_after:1 in
    Alcotest.(check bool) "break after re" true breaks.(2));
]

let () =
  Alcotest.run "Hyphenator" [
    "split_pattern", split_pattern_tests;
    "hyphenate", hyphenate_tests;
  ]
