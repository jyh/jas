(** Tspan primitives tests, fixture-driven against
    test_fixtures/algorithms/tspan_*.json — the same vectors Rust /
    Swift run. Plus a handful of hand-written sanity cases that don't
    depend on fixtures. Mirrors the test sets in
    [jas_dioxus/src/geometry/tspan.rs] and
    [JasSwift/Tests/Geometry/TspanPrimitivesTests.swift]. *)

open Jas.Tspan

(* ── Fixture plumbing ───────────────────────────────────────── *)

(* Walk up from the current working directory until a [test_fixtures]
   sibling exists. [dune exec] runs from the project root while
   [dune test] runs from the test's build artefact dir — the exact
   depth differs, so searching up is the robust option. *)
let fixtures_dir =
  let rec search dir depth =
    if depth > 8 then None
    else
      let candidate = Filename.concat dir "test_fixtures" in
      if Sys.file_exists candidate then Some candidate
      else
        let parent = Filename.dirname dir in
        if parent = dir then None
        else search parent (depth + 1)
  in
  match search (Sys.getcwd ()) 0 with
  | Some d -> d
  | None -> failwith "test_fixtures not found on path upward from cwd"

let load rel =
  Yojson.Safe.from_file (Filename.concat fixtures_dir rel)

let assoc key v =
  match v with
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None

let assoc_exn key v =
  match assoc key v with
  | Some x -> x
  | None -> failwith (Printf.sprintf "missing field %s" key)

let as_string = function `String s -> s | _ -> failwith "expected string"
let as_int = function `Int n -> n | `Float f -> int_of_float f | _ -> failwith "expected int"
let as_list = function `List xs -> xs | _ -> failwith "expected list"

let opt_int = function
  | `Null -> None
  | `Int n -> Some n
  | `Float f -> Some (int_of_float f)
  | _ -> failwith "expected int or null"

let opt_float = function
  | `Null -> None
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | _ -> failwith "expected number or null"

let opt_string = function
  | `Null -> None
  | `String s -> Some s
  | _ -> failwith "expected string or null"

let opt_bool = function
  | `Null -> None
  | `Bool b -> Some b
  | _ -> failwith "expected bool or null"

let opt_string_list = function
  | `Null -> None
  | `List xs -> Some (List.map as_string xs)
  | _ -> failwith "expected string list or null"

(** Decode a single tspan JSON object. Absent fields default to
    None / "" / 0 per the fixture convention. Transforms aren't
    exercised by the algorithm vectors so we ignore the field. *)
let tspan_of_json v : tspan =
  let field k f default =
    match assoc k v with Some x -> f x | None -> default in
  let opt k f = field k f None in
  {
    id = field "id" as_int 0;
    content = field "content" as_string "";
    baseline_shift = opt "baseline_shift" opt_float;
    dx = opt "dx" opt_float;
    font_family = opt "font_family" opt_string;
    font_size = opt "font_size" opt_float;
    font_style = opt "font_style" opt_string;
    font_variant = opt "font_variant" opt_string;
    font_weight = opt "font_weight" opt_string;
    jas_aa_mode = opt "jas_aa_mode" opt_string;
    jas_fractional_widths = opt "jas_fractional_widths" opt_bool;
    jas_kerning_mode = opt "jas_kerning_mode" opt_string;
    jas_no_break = opt "jas_no_break" opt_bool;
    letter_spacing = opt "letter_spacing" opt_float;
    line_height = opt "line_height" opt_float;
    rotate = opt "rotate" opt_float;
    style_name = opt "style_name" opt_string;
    text_decoration = opt "text_decoration" opt_string_list;
    text_rendering = opt "text_rendering" opt_string;
    text_transform = opt "text_transform" opt_string;
    transform = None;
    xml_lang = opt "xml_lang" opt_string;
  }

let parse_tspans v =
  match assoc "tspans" v with
  | Some (`List xs) -> Array.of_list (List.map tspan_of_json xs)
  | _ -> [||]

let vectors_of file =
  match assoc "vectors" file with
  | Some (`List xs) -> xs
  | _ -> failwith "fixture missing vectors"

(* ── Shared-fixture tests ───────────────────────────────────── *)

let default_fixture_test () =
  let file = load "algorithms/tspan_default.json" in
  List.iter (fun v ->
    let expected = tspan_of_json (assoc_exn "expected" v) in
    let got = default_tspan () in
    assert (got = expected);
    assert (got.id = 0);
    assert (got.content = "");
    assert (has_no_overrides got)
  ) (vectors_of file)

let concat_content_fixture_test () =
  let file = load "algorithms/tspan_concat_content.json" in
  List.iter (fun v ->
    let tspans = parse_tspans v in
    let expected = as_string (assoc_exn "expected" v) in
    assert (concat_content tspans = expected)
  ) (vectors_of file)

let resolve_id_fixture_test () =
  let file = load "algorithms/tspan_resolve_id.json" in
  List.iter (fun v ->
    let input = assoc_exn "input" v in
    let tspans = parse_tspans input in
    let id = as_int (assoc_exn "id" input) in
    let expected = opt_int (assoc_exn "expected" v) in
    assert (resolve_id tspans id = expected)
  ) (vectors_of file)

let split_fixture_test () =
  let file = load "algorithms/tspan_split.json" in
  List.iter (fun v ->
    let input = assoc_exn "input" v in
    let tspans = parse_tspans input in
    let idx = as_int (assoc_exn "tspan_idx" input) in
    let offset = as_int (assoc_exn "offset" input) in
    let (got, got_left, got_right) = split tspans idx offset in
    let expected = assoc_exn "expected" v in
    let expected_tspans = parse_tspans expected in
    let expected_left = opt_int (assoc_exn "left_idx" expected) in
    let expected_right = opt_int (assoc_exn "right_idx" expected) in
    assert (got = expected_tspans);
    assert (got_left = expected_left);
    assert (got_right = expected_right)
  ) (vectors_of file)

let split_range_fixture_test () =
  let file = load "algorithms/tspan_split_range.json" in
  List.iter (fun v ->
    let input = assoc_exn "input" v in
    let tspans = parse_tspans input in
    let start_ = as_int (assoc_exn "char_start" input) in
    let end_ = as_int (assoc_exn "char_end" input) in
    let (got, got_first, got_last) = split_range tspans start_ end_ in
    let expected = assoc_exn "expected" v in
    let expected_tspans = parse_tspans expected in
    let expected_first = opt_int (assoc_exn "first_idx" expected) in
    let expected_last = opt_int (assoc_exn "last_idx" expected) in
    assert (got = expected_tspans);
    assert (got_first = expected_first);
    assert (got_last = expected_last)
  ) (vectors_of file)

let merge_fixture_test () =
  let file = load "algorithms/tspan_merge.json" in
  List.iter (fun v ->
    let input_tspans = parse_tspans (assoc_exn "input" v) in
    let expected_tspans = parse_tspans (assoc_exn "expected" v) in
    assert (merge input_tspans = expected_tspans);
    ignore (as_list (`List []))  (* keep as_list referenced *)
  ) (vectors_of file)

(* ── Hand-written sanity tests ──────────────────────────────── *)

let split_preserves_overrides_test () =
  let original = { (default_tspan ()) with
                   id = 0; content = "Hello";
                   font_weight = Some "bold" } in
  let (got, _, _) = split [| original |] 0 2 in
  assert (Array.length got = 2);
  assert (got.(0).font_weight = Some "bold");
  assert (got.(1).font_weight = Some "bold");
  assert (got.(0).content = "He");
  assert (got.(1).content = "llo");
  assert (got.(0).id = 0);
  assert (got.(1).id = 1)

let merge_preserves_overrides_test () =
  let a = { (default_tspan ()) with id = 0; content = "A"; font_weight = Some "bold" } in
  let b = { (default_tspan ()) with id = 1; content = "B"; font_weight = Some "bold" } in
  let got = merge [| a; b |] in
  assert (Array.length got = 1);
  assert (got.(0).content = "AB");
  assert (got.(0).font_weight = Some "bold");
  assert (got.(0).id = 0)

let merge_keeps_distinct_overrides_test () =
  let a = { (default_tspan ()) with id = 0; content = "A"; font_weight = Some "bold" } in
  let b = { (default_tspan ()) with id = 1; content = "B"; font_weight = Some "normal" } in
  assert (Array.length (merge [| a; b |]) = 2)

let resolve_id_after_merge_test () =
  let a = { (default_tspan ()) with id = 0; content = "A" } in
  let b = { (default_tspan ()) with id = 3; content = "B" } in
  let m = merge [| a; b |] in
  assert (resolve_id m 0 = Some 0);
  assert (resolve_id m 3 = None)

let merge_of_all_empty_returns_default_test () =
  let got = merge [| { (default_tspan ()) with id = 5; content = "" };
                     { (default_tspan ()) with id = 7; content = "" } |] in
  assert (Array.length got = 1);
  assert (got.(0).content = "");
  assert (got.(0).id = 0);
  assert (has_no_overrides got.(0))

(* ── Text / Text_path tspans field integration ──────────────── *)

let make_text_populates_tspans_test () =
  let elem = Jas.Element.make_text 0.0 0.0 "Hello" in
  match elem with
  | Jas.Element.Text { tspans; content; _ } ->
    assert (Array.length tspans = 1);
    assert (tspans.(0).content = "Hello");
    assert (tspans.(0).id = 0);
    assert (has_no_overrides tspans.(0));
    assert (content = "Hello");
    assert (concat_content tspans = content)
  | _ -> assert false

let make_text_path_populates_tspans_test () =
  let elem = Jas.Element.make_text_path [] "path text" in
  match elem with
  | Jas.Element.Text_path { tspans; content; _ } ->
    assert (Array.length tspans = 1);
    assert (tspans.(0).content = "path text");
    assert (has_no_overrides tspans.(0));
    assert (concat_content tspans = content)
  | _ -> assert false

let sync_tspans_from_content_test () =
  (* A record-update that changes [content] leaves [tspans] stale; the
     helper rebuilds a single-tspan list reflecting the new content. *)
  let elem = Jas.Element.make_text 0.0 0.0 "old" in
  let updated =
    match elem with
    | Jas.Element.Text r -> Jas.Element.Text { r with content = "new" }
    | _ -> assert false
  in
  let synced = Jas.Element.sync_tspans_from_content updated in
  match synced with
  | Jas.Element.Text { tspans; content; _ } ->
    assert (content = "new");
    assert (tspans.(0).content = "new");
    assert (concat_content tspans = content)
  | _ -> assert false

let sync_tspans_on_non_text_is_noop_test () =
  let rect = Jas.Element.make_rect 0.0 0.0 10.0 10.0 in
  assert (Jas.Element.sync_tspans_from_content rect = rect)

let () =
  Alcotest.run "Tspan" [
    "fixtures", [
      Alcotest.test_case "default" `Quick default_fixture_test;
      Alcotest.test_case "concat_content" `Quick concat_content_fixture_test;
      Alcotest.test_case "resolve_id" `Quick resolve_id_fixture_test;
      Alcotest.test_case "split" `Quick split_fixture_test;
      Alcotest.test_case "split_range" `Quick split_range_fixture_test;
      Alcotest.test_case "merge" `Quick merge_fixture_test;
    ];
    "sanity", [
      Alcotest.test_case "split_preserves_overrides" `Quick split_preserves_overrides_test;
      Alcotest.test_case "merge_preserves_overrides" `Quick merge_preserves_overrides_test;
      Alcotest.test_case "merge_keeps_distinct_overrides" `Quick merge_keeps_distinct_overrides_test;
      Alcotest.test_case "resolve_id_after_merge" `Quick resolve_id_after_merge_test;
      Alcotest.test_case "merge_of_all_empty_returns_default" `Quick merge_of_all_empty_returns_default_test;
    ];
    "integration", [
      Alcotest.test_case "make_text_populates_tspans" `Quick make_text_populates_tspans_test;
      Alcotest.test_case "make_text_path_populates_tspans" `Quick make_text_path_populates_tspans_test;
      Alcotest.test_case "sync_tspans_from_content" `Quick sync_tspans_from_content_test;
      Alcotest.test_case "sync_tspans_on_non_text_is_noop" `Quick sync_tspans_on_non_text_is_noop_test;
    ];
  ]
