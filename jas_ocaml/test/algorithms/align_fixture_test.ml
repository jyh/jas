(** Consumes [test_fixtures/algorithms/align.json] entirely
    inside `dune runtest` and asserts the OCaml Align output
    matches the Rust and Swift reference for every vector. *)

open Yojson.Safe.Util
open Jas

(* Dune runs tests with CWD at the dune file's directory. Try a
   few relative paths so the test works both in-tree and from a
   build copy. *)
let fixture_path =
  let candidates = [
    "../../test_fixtures/algorithms/align.json";       (* jas_ocaml/test/ *)
    "../../../test_fixtures/algorithms/align.json";    (* jas_ocaml/test/algorithms/ *)
    "../test_fixtures/algorithms/align.json";          (* jas_ocaml/ *)
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None -> "../../../test_fixtures/algorithms/align.json"

let rect_of_json j =
  let to_f = function
    | `Int i -> float_of_int i
    | `Float f -> f
    | _ -> 0.0 in
  match to_list j with
  | [a; b; c; d] ->
    Element.make_rect (to_f a) (to_f b) (to_f c) (to_f d)
  | _ -> failwith "unexpected rect shape"

let bounds_of_json j =
  let to_f = function
    | `Int i -> float_of_int i
    | `Float f -> f
    | _ -> 0.0 in
  match to_list j with
  | [a; b; c; d] -> (to_f a, to_f b, to_f c, to_f d)
  | _ -> (0.0, 0.0, 0.0, 0.0)

let eps = 1e-4

let run_vector v =
  let op = to_string (member "op" v) in
  let rects = to_list (member "rects" v) |> List.map rect_of_json in
  let pairs = List.mapi (fun i e -> ([i], e)) rects in
  let use_preview = try to_bool (member "use_preview_bounds" v) with _ -> false in
  let bounds_fn =
    if use_preview then Align.preview_bounds
    else Align.geometric_bounds in
  let ref_kind = try to_string (member "kind" (member "reference" v))
                 with _ -> "selection" in
  let reference = match ref_kind with
    | "selection" -> Align.Selection (Align.union_bounds rects bounds_fn)
    | "artboard" ->
      Align.Artboard (bounds_of_json (member "bbox" (member "reference" v)))
    | "key_object" ->
      let idx = to_int (member "index" (member "reference" v)) in
      Align.Key_object { bbox = bounds_fn (List.nth rects idx); path = [idx] }
    | _ -> Align.Selection (0.0, 0.0, 0.0, 0.0) in
  let explicit_gap = match member "explicit_gap" v with
    | `Null -> None
    | `Float f -> Some f
    | `Int i -> Some (float_of_int i)
    | _ -> None in
  match op with
  | "align_left" -> Align.align_left pairs reference bounds_fn
  | "align_horizontal_center" -> Align.align_horizontal_center pairs reference bounds_fn
  | "align_right" -> Align.align_right pairs reference bounds_fn
  | "align_top" -> Align.align_top pairs reference bounds_fn
  | "align_vertical_center" -> Align.align_vertical_center pairs reference bounds_fn
  | "align_bottom" -> Align.align_bottom pairs reference bounds_fn
  | "distribute_left" -> Align.distribute_left pairs reference bounds_fn
  | "distribute_horizontal_center" -> Align.distribute_horizontal_center pairs reference bounds_fn
  | "distribute_right" -> Align.distribute_right pairs reference bounds_fn
  | "distribute_top" -> Align.distribute_top pairs reference bounds_fn
  | "distribute_vertical_center" -> Align.distribute_vertical_center pairs reference bounds_fn
  | "distribute_bottom" -> Align.distribute_bottom pairs reference bounds_fn
  | "distribute_vertical_spacing" ->
    Align.distribute_vertical_spacing pairs reference explicit_gap bounds_fn
  | "distribute_horizontal_spacing" ->
    Align.distribute_horizontal_spacing pairs reference explicit_gap bounds_fn
  | _ -> failwith ("unknown op: " ^ op)

let () =
  let json_str =
    let ic = open_in fixture_path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s in
  let fixture = Yojson.Safe.from_string json_str in
  let vectors = to_list (member "vectors" fixture) in
  let fixture_tests = List.map (fun v ->
    let name = to_string (member "name" v) in
    Alcotest.test_case name `Quick (fun () ->
      let actual = run_vector v in
      let expected = to_list (member "translations" v) in
      assert (List.length actual = List.length expected);
      List.iter2 (fun (a : Align.align_translation) e ->
        let e_path = to_list (member "path" e) |> List.map to_int in
        let e_dx = match member "dx" e with
          | `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        let e_dy = match member "dy" e with
          | `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
        assert (a.path = e_path);
        assert (abs_float (a.dx -. e_dx) < eps);
        assert (abs_float (a.dy -. e_dy) < eps)
      ) actual expected)
  ) vectors in
  Alcotest.run "align_fixture" [ "vectors", fixture_tests ]
