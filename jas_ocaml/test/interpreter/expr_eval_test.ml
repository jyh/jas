(** Expression language tests for the extended expression evaluator.

    Covers: arithmetic, unary minus, list literals, mem(), lambdas,
    let bindings, sequences, assignments, and closure application. *)

open Jas.Expr_eval

(* Helper: evaluate an expression with optional state/data context *)
let eval ?(state = []) ?(data = []) expr =
  let ctx =
    `Assoc ([("state", `Assoc state)] @
            (if data = [] then [] else [("data", `Assoc data)]))
  in
  evaluate expr ctx

let assert_number expected v =
  match v with
  | Number n ->
    if abs_float (n -. expected) > 0.001 then
      Alcotest.fail (Printf.sprintf "Expected Number %.3f, got Number %.3f" expected n)
  | _ -> Alcotest.fail (Printf.sprintf "Expected Number %.3f, got non-number" expected)

let assert_bool expected v =
  match v with
  | Bool b ->
    if b <> expected then
      Alcotest.fail (Printf.sprintf "Expected Bool %b, got Bool %b" expected b)
  | _ -> Alcotest.fail (Printf.sprintf "Expected Bool %b, got non-bool" expected)

let assert_string expected v =
  match v with
  | Str s ->
    if s <> expected then
      Alcotest.fail (Printf.sprintf "Expected Str %S, got Str %S" expected s)
  | _ -> Alcotest.fail (Printf.sprintf "Expected Str %S, got non-string" expected)

let assert_null v =
  match v with
  | Null -> ()
  | _ -> Alcotest.fail "Expected Null"

let assert_color expected v =
  match v with
  | Color c ->
    if c <> expected then
      Alcotest.fail (Printf.sprintf "Expected Color %S, got Color %S" expected c)
  | _ -> Alcotest.fail (Printf.sprintf "Expected Color %S, got non-color" expected)

(* ── Arithmetic tests ────────────────────────────────────── *)

let arithmetic_tests = [
  Alcotest.test_case "addition" `Quick (fun () ->
    assert_number 7.0 (eval "3 + 4"));

  Alcotest.test_case "subtraction" `Quick (fun () ->
    assert_number 1.0 (eval "5 - 4"));

  Alcotest.test_case "multiplication" `Quick (fun () ->
    assert_number 12.0 (eval "3 * 4"));

  Alcotest.test_case "division" `Quick (fun () ->
    assert_number 2.5 (eval "5 / 2"));

  Alcotest.test_case "division_by_zero" `Quick (fun () ->
    assert_null (eval "5 / 0"));

  Alcotest.test_case "precedence_mul_over_add" `Quick (fun () ->
    assert_number 14.0 (eval "2 + 3 * 4"));

  Alcotest.test_case "precedence_parens" `Quick (fun () ->
    assert_number 20.0 (eval "(2 + 3) * 4"));

  Alcotest.test_case "string_concat" `Quick (fun () ->
    assert_string "hello world" (eval "\"hello\" + \" world\""));

  Alcotest.test_case "arithmetic_with_state" `Quick (fun () ->
    assert_number 15.0 (eval ~state:[("x", `Int 10)] "state.x + 5"));
]

(* ── Unary minus tests ───────────────────────────────────── *)

let unary_minus_tests = [
  Alcotest.test_case "negate_number" `Quick (fun () ->
    assert_number (-5.0) (eval "-5"));

  Alcotest.test_case "negate_expr" `Quick (fun () ->
    assert_number (-3.0) (eval "-(1 + 2)"));

  Alcotest.test_case "double_negate" `Quick (fun () ->
    assert_number 5.0 (eval "--5"));

  Alcotest.test_case "negate_in_arithmetic" `Quick (fun () ->
    assert_number 7.0 (eval "10 + (-3)"));
]

(* ── List literal tests ──────────────────────────────────── *)

let list_literal_tests = [
  Alcotest.test_case "empty_list" `Quick (fun () ->
    match eval "[]" with
    | List l -> assert (List.length l = 0)
    | _ -> Alcotest.fail "Expected empty list");

  Alcotest.test_case "number_list" `Quick (fun () ->
    match eval "[1, 2, 3]" with
    | List l -> assert (List.length l = 3)
    | _ -> Alcotest.fail "Expected list of 3");

  Alcotest.test_case "list_length" `Quick (fun () ->
    assert_number 3.0 (eval "[1, 2, 3].length"));
]

(* ── mem() function tests ────────────────────────────────── *)

let mem_tests = [
  Alcotest.test_case "mem_found_string" `Quick (fun () ->
    assert_bool true
      (eval ~state:[("tools", `List [`String "pen"; `String "rect"])]
         "mem(\"pen\", state.tools)"));

  Alcotest.test_case "mem_not_found_string" `Quick (fun () ->
    assert_bool false
      (eval ~state:[("tools", `List [`String "pen"; `String "rect"])]
         "mem(\"brush\", state.tools)"));

  Alcotest.test_case "mem_found_number" `Quick (fun () ->
    assert_bool true
      (eval ~state:[("ids", `List [`Int 1; `Int 2; `Int 3])]
         "mem(3, state.ids)"));

  Alcotest.test_case "mem_non_list_rhs" `Quick (fun () ->
    assert_bool false
      (eval ~state:[("name", `String "hello")]
         "mem(\"x\", state.name)"));
]

(* ── Lambda and closure tests ────────────────────────────── *)

let lambda_tests = [
  Alcotest.test_case "lambda_application" `Quick (fun () ->
    assert_number 7.0 (eval "let f = fun x -> x + 2 in f(5)"));

  Alcotest.test_case "lambda_two_params" `Quick (fun () ->
    assert_number 7.0 (eval "let f = fun (x, y) -> x + y in f(3, 4)"));

  Alcotest.test_case "nullary_lambda" `Quick (fun () ->
    assert_number 42.0 (eval "let f = fun () -> 42 in f()"));

  Alcotest.test_case "closure_captures" `Quick (fun () ->
    assert_number 15.0 (eval "let a = 10 in let f = fun x -> x + a in f(5)"));
]

(* ── Let binding tests ───────────────────────────────────── *)

let let_tests = [
  Alcotest.test_case "let_basic" `Quick (fun () ->
    assert_number 5.0 (eval "let x = 5 in x"));

  Alcotest.test_case "let_nested" `Quick (fun () ->
    assert_number 7.0 (eval "let x = 3 in let y = 4 in x + y"));

  Alcotest.test_case "let_shadowing" `Quick (fun () ->
    assert_number 10.0 (eval "let x = 5 in let x = 10 in x"));
]

(* ── Sequence tests ──────────────────────────────────────── *)

let sequence_tests = [
  Alcotest.test_case "sequence_returns_right" `Quick (fun () ->
    assert_number 2.0 (eval "1; 2"));

  Alcotest.test_case "sequence_chain" `Quick (fun () ->
    assert_number 3.0 (eval "1; 2; 3"));
]

(* ── Existing features still work ────────────────────────── *)

let regression_tests = [
  Alcotest.test_case "ternary_still_works" `Quick (fun () ->
    assert_number 10.0
      (eval ~state:[("flag", `Bool true); ("a", `Int 10); ("b", `Int 20)]
         "if state.flag then state.a else state.b"));

  Alcotest.test_case "comparison_still_works" `Quick (fun () ->
    assert_bool true (eval "5 == 5"));

  Alcotest.test_case "color_literal" `Quick (fun () ->
    assert_color "#ff0000" (eval "#ff0000"));

  Alcotest.test_case "not_operator" `Quick (fun () ->
    assert_bool true (eval "not false"));

  Alcotest.test_case "logical_and" `Quick (fun () ->
    assert_bool false
      (eval ~state:[("a", `Bool true); ("b", `Bool false)]
         "state.a and state.b"));

  Alcotest.test_case "logical_or" `Quick (fun () ->
    assert_bool true
      (eval ~state:[("a", `Bool false); ("b", `Bool true)]
         "state.a or state.b"));

  Alcotest.test_case "color_function" `Quick (fun () ->
    assert_number 0.0 (eval "hsb_h(#ff0000)"));

  Alcotest.test_case "color_eq_short_long" `Quick (fun () ->
    assert_bool true (eval "#fff == #ffffff"));

  Alcotest.test_case "dynamic_indexing" `Quick (fun () ->
    assert_string "Web Colors"
      (eval ~state:[("key", `String "web")]
         ~data:[("libs", `Assoc [("web", `Assoc [("name", `String "Web Colors")])])]
         "data.libs[state.key].name"));
]

let () =
  Alcotest.run "Expr_eval" [
    "Arithmetic", arithmetic_tests;
    "Unary minus", unary_minus_tests;
    "List literal", list_literal_tests;
    "mem()", mem_tests;
    "Lambda", lambda_tests;
    "Let", let_tests;
    "Sequence", sequence_tests;
    "Regression", regression_tests;
  ]
