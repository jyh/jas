let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

(** Path to the shared test fixtures directory. *)
(* Dune runs tests with CWD at the dune file's directory (test/).
   Fixtures are at jas/test_fixtures/, two levels up. *)
let fixtures_dir =
  let candidates = [
    "../../test_fixtures";    (* from jas_ocaml/test/ *)
    "../test_fixtures";       (* from jas_ocaml/ *)
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some d -> d
  | None -> "../../test_fixtures"

let read_fixture path =
  let full = Filename.concat fixtures_dir path in
  let ic = open_in full in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  String.trim (Bytes.to_string s)

let assert_svg_parse name =
  let svg = read_fixture (Printf.sprintf "svg/%s.svg" name) in
  let expected = read_fixture (Printf.sprintf "expected/%s.json" name) in
  let doc = Jas.Svg.svg_to_document svg in
  let actual = Jas.Test_json.document_to_test_json doc in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
    Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
    assert false
  end

let () =
  Printf.printf "Cross-language tests:\n";

  run_test "svg_parse line_basic" (fun () -> assert_svg_parse "line_basic");
  run_test "svg_parse rect_basic" (fun () -> assert_svg_parse "rect_basic");
  run_test "svg_parse rect_with_stroke" (fun () -> assert_svg_parse "rect_with_stroke");
  run_test "svg_parse circle_basic" (fun () -> assert_svg_parse "circle_basic");
  run_test "svg_parse ellipse_basic" (fun () -> assert_svg_parse "ellipse_basic");
  run_test "svg_parse polyline_basic" (fun () -> assert_svg_parse "polyline_basic");
  run_test "svg_parse polygon_basic" (fun () -> assert_svg_parse "polygon_basic");
  run_test "svg_parse path_all_commands" (fun () -> assert_svg_parse "path_all_commands");
  run_test "svg_parse text_basic" (fun () -> assert_svg_parse "text_basic");
  run_test "svg_parse text_path_basic" (fun () -> assert_svg_parse "text_path_basic");
  run_test "svg_parse group_nested" (fun () -> assert_svg_parse "group_nested");
  run_test "svg_parse transform_translate" (fun () -> assert_svg_parse "transform_translate");
  run_test "svg_parse transform_rotate" (fun () -> assert_svg_parse "transform_rotate");
  run_test "svg_parse multi_layer" (fun () -> assert_svg_parse "multi_layer");
  run_test "svg_parse complex_document" (fun () -> assert_svg_parse "complex_document");

  (* --------------------------------------------------------------- *)
  (* Algorithm test vectors                                           *)
  (* --------------------------------------------------------------- *)

  Printf.printf "Algorithm tests:\n";

  run_test "hit_test vectors" (fun () ->
    let json_str = read_fixture "algorithms/hit_test.json" in
    let json = Yojson.Safe.from_string json_str in
    let tests = Yojson.Safe.Util.to_list json in
    List.iter (fun tc ->
      let open Yojson.Safe.Util in
      let name = tc |> member "name" |> to_string in
      let func = tc |> member "function" |> to_string in
      let args = tc |> member "args" |> to_list |> List.map to_float in
      let expected = tc |> member "expected" |> to_bool in
      let a = Array.of_list args in
      let actual = match func with
        | "point_in_rect" ->
          Jas.Hit_test.point_in_rect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5)
        | "segments_intersect" ->
          Jas.Hit_test.segments_intersect a.(0) a.(1) a.(2) a.(3)
            a.(4) a.(5) a.(6) a.(7)
        | "segment_intersects_rect" ->
          Jas.Hit_test.segment_intersects_rect a.(0) a.(1) a.(2) a.(3)
            a.(4) a.(5) a.(6) a.(7)
        | "rects_intersect" ->
          Jas.Hit_test.rects_intersect a.(0) a.(1) a.(2) a.(3)
            a.(4) a.(5) a.(6) a.(7)
        | _ -> failwith (Printf.sprintf "Unknown function: %s" func)
      in
      if actual <> expected then begin
        Printf.eprintf "Hit test '%s' failed: expected %b, got %b\n"
          name expected actual;
        assert false
      end
    ) tests);

  Printf.printf "All cross-language tests passed.\n"
