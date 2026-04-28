(* Companion to [lib/interpreter/length.ml]. Mirrors the Python
   ([workspace_interpreter/tests/test_length.py]) and Rust
   ([jas_dioxus/src/interpreter/length.rs] test module) parity tests.
   Keep in lockstep when adding cases. *)

open Jas.Length

let near a b = abs_float (a -. b) < 1e-9
let near_eps eps a b = abs_float (a -. b) < eps

(* ── pt_per_unit ──────────────────────────────────────────────────── *)

let pt_per_unit_tests = [
  Alcotest.test_case "known_units" `Quick (fun () ->
    assert (pt_per_unit "pt" = Some 1.0);
    assert (pt_per_unit "px" = Some 0.75);
    assert (pt_per_unit "in" = Some 72.0);
    (match pt_per_unit "mm" with
     | Some v -> assert (near v (72.0 /. 25.4))
     | None -> assert false);
    (match pt_per_unit "cm" with
     | Some v -> assert (near v (720.0 /. 25.4))
     | None -> assert false);
    assert (pt_per_unit "pc" = Some 12.0));

  Alcotest.test_case "unknown_returns_none" `Quick (fun () ->
    assert (pt_per_unit "dpi" = None);
    assert (pt_per_unit "" = None));

  Alcotest.test_case "case_insensitive" `Quick (fun () ->
    assert (pt_per_unit "PT" = Some 1.0);
    assert (pt_per_unit "In" = Some 72.0));
]

(* ── parse: bare number, default unit ─────────────────────────────── *)

let parse_bare_tests = [
  Alcotest.test_case "default_pt" `Quick (fun () ->
    assert (parse "12" ~default_unit:"pt" = Some 12.0);
    assert (parse "12" ~default_unit:"px" = Some 9.0);
    assert (parse "12" ~default_unit:"in" = Some 864.0));

  Alcotest.test_case "decimal" `Quick (fun () ->
    assert (parse "12.5" ~default_unit:"pt" = Some 12.5);
    assert (parse "0.5" ~default_unit:"pt" = Some 0.5));

  Alcotest.test_case "leading_dot" `Quick (fun () ->
    assert (parse ".5" ~default_unit:"pt" = Some 0.5));

  Alcotest.test_case "trailing_dot" `Quick (fun () ->
    assert (parse "5." ~default_unit:"pt" = Some 5.0));

  Alcotest.test_case "negative" `Quick (fun () ->
    assert (parse "-3" ~default_unit:"pt" = Some (-3.0));
    assert (parse "-3.5" ~default_unit:"pt" = Some (-3.5));
    assert (parse "-.5" ~default_unit:"pt" = Some (-0.5)));

  Alcotest.test_case "zero" `Quick (fun () ->
    assert (parse "0" ~default_unit:"pt" = Some 0.0);
    assert (parse "0.0" ~default_unit:"pt" = Some 0.0);
    assert (parse "-0" ~default_unit:"pt" = Some 0.0));
]

(* ── parse: with unit suffix ──────────────────────────────────────── *)

let parse_unit_tests = [
  Alcotest.test_case "pt_suffix" `Quick (fun () ->
    assert (parse "12 pt" ~default_unit:"pt" = Some 12.0);
    assert (parse "12pt" ~default_unit:"pt" = Some 12.0);
    assert (parse "12  pt" ~default_unit:"pt" = Some 12.0));

  Alcotest.test_case "px_suffix" `Quick (fun () ->
    assert (parse "12 px" ~default_unit:"pt" = Some 9.0);
    assert (parse "12px" ~default_unit:"pt" = Some 9.0));

  Alcotest.test_case "in_suffix" `Quick (fun () ->
    assert (parse "1 in" ~default_unit:"pt" = Some 72.0);
    assert (parse "0.5 in" ~default_unit:"pt" = Some 36.0));

  Alcotest.test_case "mm_suffix" `Quick (fun () ->
    (match parse "25.4 mm" ~default_unit:"pt" with
     | Some v -> assert (near v 72.0)
     | None -> assert false);
    (match parse "5 mm" ~default_unit:"pt" with
     | Some v -> assert (near v (5.0 *. 72.0 /. 25.4))
     | None -> assert false));

  Alcotest.test_case "cm_suffix" `Quick (fun () ->
    (match parse "2.54 cm" ~default_unit:"pt" with
     | Some v -> assert (near v 72.0)
     | None -> assert false));

  Alcotest.test_case "pc_suffix" `Quick (fun () ->
    assert (parse "1 pc" ~default_unit:"pt" = Some 12.0);
    assert (parse "3 pc" ~default_unit:"pt" = Some 36.0));

  Alcotest.test_case "case_insensitive" `Quick (fun () ->
    assert (parse "12 PT" ~default_unit:"pt" = Some 12.0);
    assert (parse "12 Pt" ~default_unit:"pt" = Some 12.0);
    assert (parse "12pT" ~default_unit:"pt" = Some 12.0));

  Alcotest.test_case "unit_overrides_default" `Quick (fun () ->
    assert (parse "12 px" ~default_unit:"pt" = Some 9.0);
    assert (parse "12 pt" ~default_unit:"px" = Some 12.0));
]

(* ── parse: whitespace ────────────────────────────────────────────── *)

let parse_ws_tests = [
  Alcotest.test_case "leading_ws" `Quick (fun () ->
    assert (parse "  12" ~default_unit:"pt" = Some 12.0);
    assert (parse "\t12 pt" ~default_unit:"pt" = Some 12.0));

  Alcotest.test_case "trailing_ws" `Quick (fun () ->
    assert (parse "12  " ~default_unit:"pt" = Some 12.0);
    assert (parse "12 pt  " ~default_unit:"pt" = Some 12.0));
]

(* ── parse: rejection paths ───────────────────────────────────────── *)

let parse_reject_tests = [
  Alcotest.test_case "empty" `Quick (fun () ->
    assert (parse "" ~default_unit:"pt" = None);
    assert (parse "   " ~default_unit:"pt" = None));

  Alcotest.test_case "unit_only" `Quick (fun () ->
    assert (parse "pt" ~default_unit:"pt" = None);
    assert (parse " mm " ~default_unit:"pt" = None));

  Alcotest.test_case "unknown_unit" `Quick (fun () ->
    assert (parse "12 dpi" ~default_unit:"pt" = None);
    assert (parse "12 ft" ~default_unit:"pt" = None);
    assert (parse "12 foo" ~default_unit:"pt" = None));

  Alcotest.test_case "extra_tokens" `Quick (fun () ->
    assert (parse "12 mm pt" ~default_unit:"pt" = None);
    assert (parse "5 mm 3" ~default_unit:"pt" = None);
    assert (parse "12pt5" ~default_unit:"pt" = None));

  Alcotest.test_case "garbage" `Quick (fun () ->
    assert (parse "abc" ~default_unit:"pt" = None);
    assert (parse "12.5.5" ~default_unit:"pt" = None);
    assert (parse "." ~default_unit:"pt" = None);
    assert (parse "-" ~default_unit:"pt" = None);
    assert (parse "-." ~default_unit:"pt" = None));
]

(* ── format ───────────────────────────────────────────────────────── *)

let format_tests = [
  Alcotest.test_case "integer_strips_decimal" `Quick (fun () ->
    assert (format (Some 12.0) ~unit:"pt" ~precision:2 = "12 pt");
    assert (format (Some 0.0) ~unit:"pt" ~precision:2 = "0 pt");
    assert (format (Some 72.0) ~unit:"in" ~precision:2 = "1 in"));

  Alcotest.test_case "decimal" `Quick (fun () ->
    assert (format (Some 12.5) ~unit:"pt" ~precision:2 = "12.5 pt");
    assert (format (Some 12.34) ~unit:"pt" ~precision:2 = "12.34 pt"));

  Alcotest.test_case "trims_trailing_zeros" `Quick (fun () ->
    assert (format (Some 12.50) ~unit:"pt" ~precision:2 = "12.5 pt");
    assert (format (Some 12.500) ~unit:"pt" ~precision:3 = "12.5 pt");
    assert (format (Some 12.0) ~unit:"pt" ~precision:4 = "12 pt"));

  Alcotest.test_case "rounds_to_precision" `Quick (fun () ->
    let r = format (Some 12.345) ~unit:"pt" ~precision:2 in
    (* Banker's rounding may produce 12.34 or 12.35 depending on
       platform. Accept either. *)
    assert (r = "12.35 pt" || r = "12.34 pt");
    assert (format (Some 12.344) ~unit:"pt" ~precision:2 = "12.34 pt"));

  Alcotest.test_case "converts_to_target_unit" `Quick (fun () ->
    assert (format (Some 72.0) ~unit:"in" ~precision:2 = "1 in");
    assert (format (Some 1.0) ~unit:"px" ~precision:2 = "1.33 px"));

  Alcotest.test_case "mm" `Quick (fun () ->
    assert (format (Some 72.0) ~unit:"mm" ~precision:2 = "25.4 mm"));

  Alcotest.test_case "negative" `Quick (fun () ->
    assert (format (Some (-3.0)) ~unit:"pt" ~precision:2 = "-3 pt");
    assert (format (Some (-3.5)) ~unit:"pt" ~precision:2 = "-3.5 pt"));

  Alcotest.test_case "null_returns_empty" `Quick (fun () ->
    assert (format None ~unit:"pt" ~precision:2 = ""));

  Alcotest.test_case "unknown_unit_falls_back_to_pt" `Quick (fun () ->
    assert (format (Some 12.0) ~unit:"dpi" ~precision:2 = "12 pt"));
]

(* ── round-trip ───────────────────────────────────────────────────── *)

let round_trip_tests = [
  Alcotest.test_case "format_then_parse" `Quick (fun () ->
    let pts = [0.0; 1.0; 12.0; 12.5; 72.0; 100.0; 0.75] in
    List.iter (fun pt ->
      List.iter (fun unit ->
        let formatted = format (Some pt) ~unit ~precision:6 in
        match parse formatted ~default_unit:unit with
        | None ->
          Alcotest.failf "round-trip parse failed for pt=%g unit=%s formatted=%s"
            pt unit formatted
        | Some back ->
          if not (near_eps 1e-3 back pt) then
            Alcotest.failf "round-trip diverged for pt=%g unit=%s formatted=%s back=%g"
              pt unit formatted back
      ) supported_units
    ) pts);
]

let () =
  Alcotest.run "Length" [
    "pt_per_unit", pt_per_unit_tests;
    "parse_bare", parse_bare_tests;
    "parse_unit", parse_unit_tests;
    "parse_ws", parse_ws_tests;
    "parse_reject", parse_reject_tests;
    "format", format_tests;
    "round_trip", round_trip_tests;
  ]
