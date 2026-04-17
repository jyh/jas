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

(* Phase 3 §6.1: HOFs *)

let assert_path expected v =
  match v with
  | Path p ->
    if p <> expected then
      Alcotest.fail (Printf.sprintf "Expected Path %s, got different path"
                       (String.concat "," (List.map string_of_int expected)))
  | _ -> Alcotest.fail "Expected Path"

let hof_tests = [
  Alcotest.test_case "any_true" `Quick (fun () ->
    assert_bool true (eval "any([1, 2, 3], fun n -> n > 2)"));
  Alcotest.test_case "any_false" `Quick (fun () ->
    assert_bool false (eval "any([1, 2, 3], fun n -> n > 10)"));
  Alcotest.test_case "any_empty" `Quick (fun () ->
    assert_bool false (eval "any([], fun n -> true)"));
  Alcotest.test_case "all_true" `Quick (fun () ->
    assert_bool true (eval "all([2, 4, 6], fun n -> n > 0)"));
  Alcotest.test_case "all_false" `Quick (fun () ->
    assert_bool false (eval "all([2, 4, 5], fun n -> n > 3)"));
  Alcotest.test_case "all_empty" `Quick (fun () ->
    assert_bool true (eval "all([], fun n -> false)"));
  Alcotest.test_case "map" `Quick (fun () ->
    match eval "map([1, 2, 3], fun n -> n * 10)" with
    | List items -> assert (List.length items = 3)
    | _ -> Alcotest.fail "expected list");
  Alcotest.test_case "filter" `Quick (fun () ->
    match eval "filter([1, 2, 3, 4, 5], fun n -> n > 2)" with
    | List items -> assert (List.length items = 3)
    | _ -> Alcotest.fail "expected list");
]

(* Phase 3 §6.2: path type *)

let path_tests = [
  Alcotest.test_case "path_constructor" `Quick (fun () ->
    assert_path [0; 2; 1] (eval "path(0, 2, 1)"));
  Alcotest.test_case "path_empty" `Quick (fun () ->
    assert_path [] (eval "path()"));
  Alcotest.test_case "path_depth" `Quick (fun () ->
    assert_number 3.0 (eval "path(0, 2, 1).depth"));
  Alcotest.test_case "path_depth_empty" `Quick (fun () ->
    assert_number 0.0 (eval "path().depth"));
  Alcotest.test_case "path_parent" `Quick (fun () ->
    assert_path [0; 2] (eval "path(0, 2, 1).parent"));
  Alcotest.test_case "path_parent_empty_is_null" `Quick (fun () ->
    assert_null (eval "path().parent"));
  Alcotest.test_case "path_id" `Quick (fun () ->
    assert_string "0.2.1" (eval "path(0, 2, 1).id"));
  Alcotest.test_case "path_id_empty" `Quick (fun () ->
    assert_string "" (eval "path().id"));
  Alcotest.test_case "path_equality" `Quick (fun () ->
    assert_bool true (eval "path(0, 2) == path(0, 2)");
    assert_bool false (eval "path(0, 2) == path(0, 3)"));
  Alcotest.test_case "path_not_equal_to_list" `Quick (fun () ->
    assert_bool false (eval "path(0, 2) == [0, 2]"));
  Alcotest.test_case "path_child" `Quick (fun () ->
    assert_path [0; 2; 5] (eval "path_child(path(0, 2), 5)"));
  Alcotest.test_case "path_from_id" `Quick (fun () ->
    assert_path [0; 2; 1] (eval "path_from_id('0.2.1')"));
  Alcotest.test_case "path_from_id_empty" `Quick (fun () ->
    assert_path [] (eval "path_from_id('')"));
  Alcotest.test_case "path_from_id_malformed" `Quick (fun () ->
    assert_null (eval "path_from_id('not-a-path')"));

  (* Phase 4: element_at — walks active_document.top_level_layers *)
  Alcotest.test_case "element_at_top_level" `Quick (fun () ->
    let ctx = `Assoc [
      ("active_document", `Assoc [
        ("top_level_layers", `List [
          `Assoc [("kind", `String "Layer"); ("name", `String "A");
                   ("common", `Assoc [("visibility", `String "preview");
                                       ("locked", `Bool false)])];
        ]);
      ]);
    ] in
    assert_string "A" (evaluate "element_at(path(0)).name" ctx));

  Alcotest.test_case "element_at_out_of_range" `Quick (fun () ->
    let ctx = `Assoc [
      ("active_document", `Assoc [
        ("top_level_layers", `List [
          `Assoc [("kind", `String "Layer"); ("name", `String "A")];
        ]);
      ]);
    ] in
    assert_null (evaluate "element_at(path(5))" ctx));

  Alcotest.test_case "element_at_non_path_arg" `Quick (fun () ->
    let ctx = `Assoc [
      ("active_document", `Assoc [("top_level_layers", `List [])]);
    ] in
    assert_null (evaluate "element_at('oops')" ctx));

  Alcotest.test_case "element_at_common_fields" `Quick (fun () ->
    let ctx = `Assoc [
      ("active_document", `Assoc [
        ("top_level_layers", `List [
          `Assoc [("kind", `String "Layer"); ("name", `String "A");
                   ("common", `Assoc [("visibility", `String "outline");
                                       ("locked", `Bool true)])];
        ]);
      ]);
    ] in
    assert_string "outline"
      (evaluate "element_at(path(0)).common.visibility" ctx);
    assert_bool true
      (evaluate "element_at(path(0)).common.locked" ctx));
]

(* Phase 3 §4.4: closure captures shadowed binding (lexical scoping) *)

let closure_lexical_tests = [
  Alcotest.test_case "closure_captures_shadowed_binding" `Quick (fun () ->
    assert_number 1.0
      (eval "let x = 1 in let f = fun _ -> x in let x = 2 in f(null)"));
  Alcotest.test_case "closure_namespace_refreshed" `Quick (fun () ->
    assert_number 42.0
      (eval ~state:[("x", `Int 42)] "let f = fun _ -> state.x in f(null)"));
]

(* AST cache: same source string evaluated against varying contexts
   must yield per-call results, not a stale cached value. *)
let ast_cache_tests = [
  Alcotest.test_case "repeat_with_different_contexts" `Quick (fun () ->
    assert_number 1.0 (eval ~state:[("x", `Int 1)] "state.x");
    assert_number 99.0 (eval ~state:[("x", `Int 99)] "state.x");
    (* Re-eval is a cache hit; must still see the per-call ctx. *)
    assert_number 1.0 (eval ~state:[("x", `Int 1)] "state.x");
    assert_number 100.0 (eval ~state:[("x", `Int 99)] "state.x + 1"));
  Alcotest.test_case "unparseable_input_caches_failure" `Quick (fun () ->
    (match evaluate ")(" (`Assoc []) with
     | Null -> ()
     | _ -> Alcotest.fail "expected Null");
    (* Second call hits the cached None and still returns Null. *)
    (match evaluate ")(" (`Assoc []) with
     | Null -> ()
     | _ -> Alcotest.fail "expected Null"));
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
    "Phase3 HOF", hof_tests;
    "Phase3 Path", path_tests;
    "Phase3 LexicalClosure", closure_lexical_tests;
    "AstCache", ast_cache_tests;
  ]
