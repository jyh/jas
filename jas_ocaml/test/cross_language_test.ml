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

  (* --------------------------------------------------------------- *)
  (* SVG round-trip idempotence                                       *)
  (* --------------------------------------------------------------- *)

  Printf.printf "SVG round-trip tests:\n";

  let assert_svg_roundtrip name =
    let svg = read_fixture (Printf.sprintf "svg/%s.svg" name) in
    let doc1 = Jas.Svg.svg_to_document svg in
    let json1 = Jas.Test_json.document_to_test_json doc1 in
    let svg2 = Jas.Svg.document_to_svg doc1 in
    let doc2 = Jas.Svg.svg_to_document svg2 in
    let json2 = Jas.Test_json.document_to_test_json doc2 in
    if json1 <> json2 then begin
      Printf.eprintf "=== FIRST PARSE (%s) ===\n%s\n" name json1;
      Printf.eprintf "=== AFTER ROUND-TRIP (%s) ===\n%s\n" name json2;
      assert false
    end
  in
  let roundtrip_names = [
    "line_basic"; "rect_basic"; "rect_with_stroke";
    "circle_basic"; "ellipse_basic";
    "polyline_basic"; "polygon_basic"; "path_all_commands";
    "text_basic"; "text_path_basic";
    "group_nested"; "transform_translate"; "transform_rotate";
    "multi_layer"; "complex_document"
  ] in
  run_test "svg_roundtrip all fixtures" (fun () ->
    List.iter assert_svg_roundtrip roundtrip_names);

  Printf.printf "SVG parse tests:\n";

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
      let filled = try tc |> member "filled" |> to_bool with _ -> false in
      let polygon =
        try
          tc |> member "polygon" |> to_list
          |> List.map (fun p ->
            let pts = to_list p |> List.map to_float in
            (List.nth pts 0, List.nth pts 1))
          |> Array.of_list
        with _ -> [||]
      in
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
        | "circle_intersects_rect" ->
          Jas.Hit_test.circle_intersects_rect a.(0) a.(1) a.(2)
            a.(3) a.(4) a.(5) a.(6) filled
        | "ellipse_intersects_rect" ->
          Jas.Hit_test.ellipse_intersects_rect a.(0) a.(1) a.(2) a.(3)
            a.(4) a.(5) a.(6) a.(7) filled
        | "point_in_polygon" ->
          Jas.Hit_test.point_in_polygon a.(0) a.(1) polygon
        | _ -> failwith (Printf.sprintf "Unknown function: %s" func)
      in
      if actual <> expected then begin
        Printf.eprintf "Hit test '%s' failed: expected %b, got %b\n"
          name expected actual;
        assert false
      end
    ) tests);

  (* --------------------------------------------------------------- *)
  (* Operation equivalence tests                                      *)
  (* --------------------------------------------------------------- *)

  Printf.printf "Operation tests:\n";

  run_test "select_and_move operations" (fun () ->
    let json_str = read_fixture "operations/select_and_move.json" in
    let json = Yojson.Safe.from_string json_str in
    let tests = Yojson.Safe.Util.to_list json in
    List.iter (fun tc ->
      let open Yojson.Safe.Util in
      let name = tc |> member "name" |> to_string in
      let setup_svg_file = tc |> member "setup_svg" |> to_string in
      let expected_file = tc |> member "expected_json" |> to_string in
      let ops = tc |> member "ops" |> to_list in
      let svg = read_fixture (Printf.sprintf "svg/%s" setup_svg_file) in
      let expected = read_fixture (Printf.sprintf "operations/%s" expected_file) in
      let doc = Jas.Svg.svg_to_document svg in
      let model = Jas.Model.create ~document:doc () in
      let ctrl = Jas.Controller.create ~model () in
      List.iter (fun op ->
        let op_name = op |> member "op" |> to_string in
        match op_name with
        | "select_rect" ->
          let to_num j = try to_float j with _ -> float_of_int (to_int j) in
          let x = op |> member "x" |> to_num in
          let y = op |> member "y" |> to_num in
          let w = op |> member "width" |> to_num in
          let h = op |> member "height" |> to_num in
          let extend = try op |> member "extend" |> to_bool with _ -> false in
          ctrl#select_rect ~extend x y w h
        | "move_selection" ->
          let to_num j = try to_float j with _ -> float_of_int (to_int j) in
          let dx = op |> member "dx" |> to_num in
          let dy = op |> member "dy" |> to_num in
          ctrl#move_selection dx dy
        | "delete_selection" ->
          let new_doc = Jas.Document.delete_selection model#document in
          model#set_document new_doc
        | "snapshot" ->
          model#snapshot
        | "undo" ->
          model#undo
        | "redo" ->
          model#redo
        | _ -> failwith (Printf.sprintf "Unknown op: %s" op_name)
      ) ops;
      let actual = Jas.Test_json.document_to_test_json model#document in
      if actual <> expected then begin
        Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
        Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
        assert false
      end
    ) tests);

  run_test "undo_redo_laws operations" (fun () ->
    let json_str = read_fixture "operations/undo_redo_laws.json" in
    let json = Yojson.Safe.from_string json_str in
    let tests = Yojson.Safe.Util.to_list json in
    List.iter (fun tc ->
      let open Yojson.Safe.Util in
      let name = tc |> member "name" |> to_string in
      let setup_svg_file = tc |> member "setup_svg" |> to_string in
      let expected_file = tc |> member "expected_json" |> to_string in
      let ops = tc |> member "ops" |> to_list in
      let svg = read_fixture (Printf.sprintf "svg/%s" setup_svg_file) in
      let expected = read_fixture (Printf.sprintf "operations/%s" expected_file) in
      let doc = Jas.Svg.svg_to_document svg in
      let model = Jas.Model.create ~document:doc () in
      let ctrl = Jas.Controller.create ~model () in
      List.iter (fun op ->
        let to_num j = try to_float j with _ -> float_of_int (to_int j) in
        let op_name = op |> member "op" |> to_string in
        match op_name with
        | "select_rect" ->
          let x = op |> member "x" |> to_num in
          let y = op |> member "y" |> to_num in
          let w = op |> member "width" |> to_num in
          let h = op |> member "height" |> to_num in
          let extend = try op |> member "extend" |> to_bool with _ -> false in
          ctrl#select_rect ~extend x y w h
        | "move_selection" ->
          let dx = op |> member "dx" |> to_num in
          let dy = op |> member "dy" |> to_num in
          ctrl#move_selection dx dy
        | "delete_selection" ->
          let new_doc = Jas.Document.delete_selection model#document in
          model#set_document new_doc
        | "snapshot" -> model#snapshot
        | "undo" -> model#undo
        | "redo" -> model#redo
        | _ -> failwith (Printf.sprintf "Unknown op: %s" op_name)
      ) ops;
      let actual = Jas.Test_json.document_to_test_json model#document in
      if actual <> expected then begin
        Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
        Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
        assert false
      end
    ) tests);

  Printf.printf "All cross-language tests passed.\n"
