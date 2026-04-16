open Jas.Schema
open Jas.State_store

(* --- coerce_value: bool --- *)

let coerce_bool_tests = [
  Alcotest.test_case "coerce_bool_from_bool" `Quick (fun () ->
    let e = get_entry "fill_on_top" |> Option.get in
    assert (coerce_value (`Bool true) e = Ok (`Bool true));
    assert (coerce_value (`Bool false) e = Ok (`Bool false)));

  Alcotest.test_case "coerce_bool_from_string" `Quick (fun () ->
    let e = get_entry "fill_on_top" |> Option.get in
    assert (coerce_value (`String "true") e = Ok (`Bool true));
    assert (coerce_value (`String "false") e = Ok (`Bool false)));

  Alcotest.test_case "coerce_bool_rejects_invalid" `Quick (fun () ->
    let e = get_entry "fill_on_top" |> Option.get in
    assert (Result.is_error (coerce_value (`String "yes") e));
    assert (Result.is_error (coerce_value (`Int 1) e)));
]

(* --- coerce_value: number --- *)

let coerce_number_tests = [
  Alcotest.test_case "coerce_number_from_float" `Quick (fun () ->
    let e = get_entry "stroke_width" |> Option.get in
    assert (coerce_value (`Float 3.5) e = Ok (`Float 3.5)));

  Alcotest.test_case "coerce_number_from_int" `Quick (fun () ->
    let e = get_entry "stroke_width" |> Option.get in
    assert (coerce_value (`Int 2) e = Ok (`Float 2.0)));

  Alcotest.test_case "coerce_number_from_numeric_string" `Quick (fun () ->
    let e = get_entry "stroke_width" |> Option.get in
    assert (coerce_value (`String "2.5") e = Ok (`Float 2.5)));

  Alcotest.test_case "coerce_number_rejects_bool" `Quick (fun () ->
    let e = get_entry "stroke_width" |> Option.get in
    assert (Result.is_error (coerce_value (`Bool true) e)));
]

(* --- coerce_value: color --- *)

let coerce_color_tests = [
  Alcotest.test_case "coerce_color_valid_hex" `Quick (fun () ->
    let e = get_entry "fill_color" |> Option.get in
    assert (coerce_value (`String "#ff0000") e = Ok (`String "#ff0000")));

  Alcotest.test_case "coerce_color_null_nullable" `Quick (fun () ->
    let e = get_entry "fill_color" |> Option.get in
    assert (coerce_value `Null e = Ok `Null));

  Alcotest.test_case "coerce_color_rejects_invalid" `Quick (fun () ->
    let e = get_entry "fill_color" |> Option.get in
    assert (Result.is_error (coerce_value (`String "red") e));
    assert (Result.is_error (coerce_value (`String "#gg0000") e)));
]

(* --- coerce_value: enum --- *)

let coerce_enum_tests = [
  Alcotest.test_case "coerce_enum_valid" `Quick (fun () ->
    let e = get_entry "stroke_cap" |> Option.get in
    assert (coerce_value (`String "round") e = Ok (`String "round")));

  Alcotest.test_case "coerce_enum_invalid" `Quick (fun () ->
    let e = get_entry "stroke_cap" |> Option.get in
    assert (coerce_value (`String "triangle") e = Error "enum_value_not_in_values"));
]

(* --- null on non-nullable --- *)

let null_tests = [
  Alcotest.test_case "null_on_non_nullable_is_error" `Quick (fun () ->
    let e = get_entry "stroke_width" |> Option.get in
    assert (coerce_value `Null e = Error "null_on_non_nullable"));
]

(* --- writable flag --- *)

let writable_tests = [
  Alcotest.test_case "drag_pane_not_writable" `Quick (fun () ->
    let e = get_entry "_drag_pane" |> Option.get in
    assert (not e.writable));

  Alcotest.test_case "fill_color_writable" `Quick (fun () ->
    let e = get_entry "fill_color" |> Option.get in
    assert e.writable);
]

(* --- unknown key --- *)

let unknown_key_tests = [
  Alcotest.test_case "unknown_key_returns_none" `Quick (fun () ->
    assert (get_entry "nonexistent_field" = None));
]

(* --- apply_set_schemadriven --- *)

let apply_set_tests = [
  Alcotest.test_case "valid_key_applies" `Quick (fun () ->
    let store = create () in
    let diags = ref [] in
    apply_set_schemadriven [("fill_on_top", `Bool true)] store diags;
    assert (get store "fill_on_top" = `Bool true);
    assert (!diags = []));

  Alcotest.test_case "unknown_key_warning" `Quick (fun () ->
    let store = create () in
    let diags = ref [] in
    apply_set_schemadriven [("unknown_xyz", `String "val")] store diags;
    assert (List.length !diags = 1);
    assert ((List.hd !diags).level = "warning");
    assert ((List.hd !diags).reason = "unknown_key"));

  Alcotest.test_case "non_writable_warning" `Quick (fun () ->
    let store = create () in
    let diags = ref [] in
    apply_set_schemadriven [("_drag_pane", `String "left")] store diags;
    assert (List.length !diags = 1);
    assert ((List.hd !diags).level = "warning");
    assert ((List.hd !diags).reason = "field_not_writable"));

  Alcotest.test_case "type_mismatch_error" `Quick (fun () ->
    let store = create () in
    let diags = ref [] in
    apply_set_schemadriven [("stroke_width", `String "not-a-number")] store diags;
    assert (List.length !diags = 1);
    assert ((List.hd !diags).level = "error");
    assert ((List.hd !diags).reason = "type_mismatch"));

  Alcotest.test_case "batch_partial_success" `Quick (fun () ->
    let store = create ~defaults:[("fill_on_top", `Bool false)] () in
    let diags = ref [] in
    apply_set_schemadriven
      [("fill_on_top", `Bool true); ("stroke_width", `String "bad")]
      store diags;
    assert (get store "fill_on_top" = `Bool true);
    assert (List.length !diags = 1);
    assert ((List.hd !diags).key = "stroke_width"));
]

let () =
  Alcotest.run "Schema" [
    "CoerceBool", coerce_bool_tests;
    "CoerceNumber", coerce_number_tests;
    "CoerceColor", coerce_color_tests;
    "CoerceEnum", coerce_enum_tests;
    "NullHandling", null_tests;
    "Writable", writable_tests;
    "UnknownKey", unknown_key_tests;
    "ApplySetSchemadriven", apply_set_tests;
  ]
