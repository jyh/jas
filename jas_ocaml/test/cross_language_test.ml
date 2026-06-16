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

let roundtrip_names = [
  "line_basic"; "rect_basic"; "rect_with_stroke";
  "circle_basic"; "ellipse_basic";
  "polyline_basic"; "polygon_basic"; "path_all_commands";
  "text_basic"; "text_path_basic";
  "group_nested"; "transform_translate"; "transform_rotate";
  "multi_layer"; "complex_document"
]

(* SVG round-trip fixtures. Extends [roundtrip_names] with the Live
   element fixtures (REFERENCE_GRAPH.md Phase 2a): a reference writes as
   <use href> and reads back; a compound writes as
   <g data-jas-live=... data-jas-operation=...> and reads back. Kept
   separate from [roundtrip_names] because the latter also seeds
   [binary_names], where Live binary serialization is deferred. *)
let svg_roundtrip_names =
  roundtrip_names @ ["live_reference"; "live_compound"; "live_compound_id"]

(* Names that additionally include the id-bearing "element_ids" fixture, which
   exercises the per-element name and id fields. The binary v2 format and the
   test_json codec both round-trip those fields, so element_ids participates in
   the binary and JSON idempotence tests. It is kept out of [roundtrip_names]
   only because there is no element_ids.svg fixture for the SVG tests. *)
(* Live elements (REFERENCE_GRAPH.md Phase 1a): reference + compound
   round-trip through the test_json codec. Compound now carries
   [operation]. *)
let json_roundtrip_names =
  roundtrip_names @ ["element_ids";
                     "live_reference_roundtrip"; "live_compound_roundtrip"]
(* Binary fixtures. Includes the id-bearing "element_ids" fixture and the Live
   element fixtures (REFERENCE_GRAPH.md Phase 2b): reference + compound now
   serialize through binary (TAG_LIVE, kind-discriminated), so both the
   JSON→binary→JSON round-trip and the Python-generated .bin read cases cover
   them. Mirrors the Rust binary fixture lists. Note these are the
   [_roundtrip] variants (which have matching expected/*.json and *.bin), not
   the bare live_reference / live_compound SVG-parse fixtures. *)
let binary_names =
  roundtrip_names @ ["element_ids";
                     "live_reference_roundtrip"; "live_compound_roundtrip";
                     (* The compound id is the cross-app byte pin: its
                        Python-generated 108-byte .bin must decode here, and
                        the JSON to binary to JSON round-trip must preserve the
                        id (REFERENCE_GRAPH.md compound-id round-trip). *)
                     "live_compound_id"]

let assert_json_roundtrip name =
  let expected = read_fixture (Printf.sprintf "expected/%s.json" name) in
  let doc = Jas.Test_json.test_json_to_document expected in
  let actual = Jas.Test_json.document_to_test_json doc in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
    Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
    assert false
  end

let run_operation_fixture fixture_name =
  let json_str = read_fixture (Printf.sprintf "operations/%s" fixture_name) in
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
      | "copy_selection" ->
        let dx = op |> member "dx" |> to_num in
        let dy = op |> member "dy" |> to_num in
        ctrl#copy_selection dx dy
      | "assign_id" ->
        let path = op |> member "path" |> to_list |> List.map to_int in
        let id = op |> member "id" |> to_string in
        ctrl#assign_id path id
      | "create_reference" ->
        let target_path =
          op |> member "target_path" |> to_list |> List.map to_int in
        let target_id = op |> member "target_id" |> to_string in
        let ref_id = op |> member "ref_id" |> to_string in
        ctrl#create_reference target_path target_id ref_id
      | "delete_selection" ->
        let new_doc = Jas.Document.delete_selection model#document in
        model#set_document new_doc
      | "lock_selection" -> ctrl#lock_selection
      | "unlock_all" -> ctrl#unlock_all
      | "hide_selection" -> ctrl#hide_selection
      | "show_all" -> ctrl#show_all
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
  ) tests

let apply_workspace_op layout op =
  let open Yojson.Safe.Util in
  let to_num j = try to_float j with _ -> float_of_int (to_int j) in
  let name = op |> member "op" |> to_string in
  match name with
  | "toggle_group_collapsed" ->
    Jas.Workspace_layout.toggle_group_collapsed layout
      { dock_id = op |> member "dock_id" |> to_int;
        group_idx = op |> member "group_idx" |> to_int }
  | "set_active_panel" ->
    Jas.Workspace_layout.set_active_panel layout
      { group = { dock_id = op |> member "dock_id" |> to_int;
                  group_idx = op |> member "group_idx" |> to_int };
        panel_idx = op |> member "panel_idx" |> to_int }
  | "close_panel" ->
    Jas.Workspace_layout.close_panel layout
      { group = { dock_id = op |> member "dock_id" |> to_int;
                  group_idx = op |> member "group_idx" |> to_int };
        panel_idx = op |> member "panel_idx" |> to_int }
  | "show_panel" ->
    let kind = Jas.Workspace_test_json.parse_panel_kind_str
      (op |> member "kind" |> to_string) in
    Jas.Workspace_layout.show_panel layout kind
  | "reorder_panel" ->
    Jas.Workspace_layout.reorder_panel layout
      ~group:{ dock_id = op |> member "dock_id" |> to_int;
               group_idx = op |> member "group_idx" |> to_int }
      ~from:(op |> member "from" |> to_int)
      ~to_:(op |> member "to" |> to_int)
  | "move_panel_to_group" ->
    Jas.Workspace_layout.move_panel_to_group layout
      ~from:{ group = { dock_id = op |> member "from_dock_id" |> to_int;
                        group_idx = op |> member "from_group_idx" |> to_int };
              panel_idx = op |> member "from_panel_idx" |> to_int }
      ~to_:{ dock_id = op |> member "to_dock_id" |> to_int;
             group_idx = op |> member "to_group_idx" |> to_int }
  | "detach_group" ->
    ignore (Jas.Workspace_layout.detach_group layout
      ~from:{ dock_id = op |> member "dock_id" |> to_int;
              group_idx = op |> member "group_idx" |> to_int }
      ~x:(op |> member "x" |> to_num)
      ~y:(op |> member "y" |> to_num))
  | "redock" ->
    Jas.Workspace_layout.redock layout
      (op |> member "dock_id" |> to_int)
  | "set_pane_position" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl ->
       Jas.Pane.set_pane_position pl
         (op |> member "pane_id" |> to_int)
         ~x:(op |> member "x" |> to_num)
         ~y:(op |> member "y" |> to_num)
     | None -> ())
  | "tile_panes" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl -> Jas.Pane.tile_panes pl ~collapsed_override:None
     | None -> ())
  | "toggle_canvas_maximized" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl -> Jas.Pane.toggle_canvas_maximized pl
     | None -> ())
  | "resize_pane" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl ->
       Jas.Pane.resize_pane pl
         (op |> member "pane_id" |> to_int)
         ~width:(op |> member "width" |> to_num)
         ~height:(op |> member "height" |> to_num)
     | None -> ())
  | "hide_pane" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl ->
       let kind = Jas.Workspace_test_json.parse_pane_kind_str
         (op |> member "kind" |> to_string) in
       Jas.Pane.hide_pane pl kind
     | None -> ())
  | "show_pane" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl ->
       let kind = Jas.Workspace_test_json.parse_pane_kind_str
         (op |> member "kind" |> to_string) in
       Jas.Pane.show_pane pl kind
     | None -> ())
  | "bring_pane_to_front" ->
    (match layout.Jas.Workspace_layout.pane_layout with
     | Some pl ->
       Jas.Pane.bring_pane_to_front pl
         (op |> member "pane_id" |> to_int)
     | None -> ())
  | _ -> failwith (Printf.sprintf "Unknown workspace op: %s" name)

let run_workspace_operation_fixture fixture_name =
  let json_str = read_fixture (Printf.sprintf "workspace_operations/%s" fixture_name) in
  let json = Yojson.Safe.from_string json_str in
  let tests = Yojson.Safe.Util.to_list json in
  List.iter (fun tc ->
    let open Yojson.Safe.Util in
    let name = tc |> member "name" |> to_string in
    let setup_name = tc |> member "setup" |> to_string in
    let expected_file = tc |> member "expected_json" |> to_string in
    let ops = tc |> member "ops" |> to_list in
    let setup_json = read_fixture (Printf.sprintf "expected/%s" setup_name) in
    let expected = read_fixture (Printf.sprintf "workspace_operations/%s" expected_file) in
    let layout = Jas.Workspace_test_json.test_json_to_workspace setup_json in
    List.iter (fun op -> apply_workspace_op layout op) ops;
    let actual = Jas.Workspace_test_json.workspace_to_test_json layout in
    if actual <> expected then begin
      Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
      Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
      assert false
    end
  ) tests

let read_fixture_bytes path =
  let full = Filename.concat fixtures_dir path in
  let ic = open_in_bin full in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let assert_binary_roundtrip name =
  let expected = read_fixture (Printf.sprintf "expected/%s.json" name) in
  let doc = Jas.Test_json.test_json_to_document expected in
  let binary = Jas.Binary.document_to_binary doc in
  let doc2 = Jas.Binary.binary_to_document binary in
  let actual = Jas.Test_json.document_to_test_json doc2 in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
    Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
    assert false
  end

let assert_binary_read_python name =
  let bin_data = read_fixture_bytes (Printf.sprintf "expected/%s.bin" name) in
  let doc = Jas.Binary.binary_to_document bin_data in
  let actual = Jas.Test_json.document_to_test_json doc in
  let expected = read_fixture (Printf.sprintf "expected/%s.json" name) in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
    Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
    assert false
  end

(* ------------------------------------------------------------------ *)
(* Dependency index (REFERENCE_GRAPH.md section 3)                     *)
(* ------------------------------------------------------------------ *)

(* Build a single-layer document whose children are [kids], so unit
   tests mirror the Rust [doc_with_layer] helper. *)
let dep_doc_with_layer (kids : Jas.Element.element list) : Jas.Document.document =
  Jas.Document.make_document [| Jas.Element.make_layer ~name:"Layer" (Array.of_list kids) |]

(* A rect carrying an optional stable id. *)
let dep_rect ?id () : Jas.Element.element =
  Jas.Element.with_id (Jas.Element.make_rect 0.0 0.0 10.0 10.0) id

(* A by-id reference [id -> target]. *)
let dep_reference ~id ~target : Jas.Element.element =
  Jas.Element.make_reference ~id:(Some id) target

let dependency_index_cross_language () =
  (* Parse the shared input document. *)
  let input = read_fixture "expected/dependency_index_input.json" in
  let doc = Jas.Test_json.test_json_to_document input in
  (* Sanity: the parsed input must re-serialize to itself (the fixture is
     canonical), so the index is computed over the same doc all apps see. *)
  let reser = Jas.Test_json.document_to_test_json doc in
  if reser <> input then begin
    Printf.eprintf "=== dependency_index_input.json not canonical ===\n";
    Printf.eprintf "EXPECTED: %s\nACTUAL:   %s\n" input reser;
    assert false
  end;
  (* Build + serialize the index, compare with the expected fixture. *)
  let actual = Jas.Dependency_index.to_test_json (Jas.Dependency_index.build doc) in
  let expected = read_fixture "expected/dependency_index.json" in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (dependency_index) ===\n%s\n" expected;
    Printf.eprintf "=== ACTUAL (dependency_index) ===\n%s\n" actual;
    assert false
  end

(* Cross-language pin (REFERENCE_GRAPH.md): parse the shared input
   document, read the shared orphaned-references fixture, and for each
   case assert that [orphaned_references doc delete_paths] equals the
   expected ids. All apps run this same pair of fixtures. *)
let orphaned_references_cross_language () =
  let input = read_fixture "expected/dependency_index_input.json" in
  let doc = Jas.Test_json.test_json_to_document input in
  let cases_json = read_fixture "expected/orphaned_references.json" in
  let cases = Yojson.Safe.from_string cases_json |> Yojson.Safe.Util.to_list in
  List.iteri (fun i case ->
    let open Yojson.Safe.Util in
    let delete_paths =
      case |> member "delete_paths" |> to_list
      |> List.map (fun p -> p |> to_list |> List.map to_int)
    in
    let expected =
      case |> member "orphaned" |> to_list |> List.map to_string
    in
    let actual = Jas.Dependency_index.orphaned_references doc delete_paths in
    if actual <> expected then begin
      Printf.eprintf "=== orphaned_references case %d mismatch ===\n" i;
      Printf.eprintf "EXPECTED: [%s]\nACTUAL:   [%s]\n"
        (String.concat ";" expected) (String.concat ";" actual);
      assert false
    end
  ) cases

let () =
  Alcotest.run "Cross_language" [
    (* Binary round-trip *)
    "Binary round-trip", [
      Alcotest.test_case "binary_roundtrip all expected" `Quick (fun () ->
        List.iter assert_binary_roundtrip binary_names);
    ];

    (* Binary read Python fixtures *)
    "Binary read Python", [
      Alcotest.test_case "binary_read_python all fixtures" `Quick (fun () ->
        List.iter assert_binary_read_python binary_names);
    ];

    (* SVG round-trip idempotence *)
    "SVG round-trip", [
      Alcotest.test_case "svg_roundtrip all fixtures" `Quick (fun () ->
        List.iter assert_svg_roundtrip svg_roundtrip_names);
    ];

    (* JSON round-trip idempotence *)
    "JSON round-trip", [
      Alcotest.test_case "json_roundtrip all expected" `Quick (fun () ->
        List.iter assert_json_roundtrip json_roundtrip_names);
    ];

    (* SVG parse tests *)
    "SVG parse", [
      Alcotest.test_case "svg_parse line_basic" `Quick (fun () -> assert_svg_parse "line_basic");
      Alcotest.test_case "svg_parse rect_basic" `Quick (fun () -> assert_svg_parse "rect_basic");
      Alcotest.test_case "svg_parse rect_with_stroke" `Quick (fun () -> assert_svg_parse "rect_with_stroke");
      Alcotest.test_case "svg_parse circle_basic" `Quick (fun () -> assert_svg_parse "circle_basic");
      Alcotest.test_case "svg_parse ellipse_basic" `Quick (fun () -> assert_svg_parse "ellipse_basic");
      Alcotest.test_case "svg_parse polyline_basic" `Quick (fun () -> assert_svg_parse "polyline_basic");
      Alcotest.test_case "svg_parse polygon_basic" `Quick (fun () -> assert_svg_parse "polygon_basic");
      Alcotest.test_case "svg_parse path_all_commands" `Quick (fun () -> assert_svg_parse "path_all_commands");
      Alcotest.test_case "svg_parse text_basic" `Quick (fun () -> assert_svg_parse "text_basic");
      Alcotest.test_case "svg_parse text_path_basic" `Quick (fun () -> assert_svg_parse "text_path_basic");
      Alcotest.test_case "svg_parse group_nested" `Quick (fun () -> assert_svg_parse "group_nested");
      Alcotest.test_case "svg_parse transform_translate" `Quick (fun () -> assert_svg_parse "transform_translate");
      Alcotest.test_case "svg_parse transform_rotate" `Quick (fun () -> assert_svg_parse "transform_rotate");
      Alcotest.test_case "svg_parse multi_layer" `Quick (fun () -> assert_svg_parse "multi_layer");
      Alcotest.test_case "svg_parse complex_document" `Quick (fun () -> assert_svg_parse "complex_document");
      Alcotest.test_case "svg_parse dup_id_import" `Quick (fun () -> assert_svg_parse "dup_id_import");
      (* Live elements (REFERENCE_GRAPH.md Phase 2a): <use href> parses
         to a reference; <g data-jas-live="compound_shape"
         data-jas-operation=...> parses to a compound. *)
      Alcotest.test_case "svg_parse live_reference" `Quick (fun () -> assert_svg_parse "live_reference");
      Alcotest.test_case "svg_parse live_compound" `Quick (fun () -> assert_svg_parse "live_compound");
      (* Compound id round-trips through SVG (id="..." on the <g>), unlike
         name which live elements never emit. *)
      Alcotest.test_case "svg_parse live_compound_id" `Quick (fun () -> assert_svg_parse "live_compound_id");
    ];

    (* Algorithm test vectors *)
    "Algorithm", [
      Alcotest.test_case "hit_test vectors" `Quick (fun () ->
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
    ];

    (* Compound id assignment (regression pin for the cross-language
       compound-id round-trip bug): assign_id must stamp a compound's id,
       and the assigned id must survive a binary round-trip. *)
    "Compound id", [
      Alcotest.test_case "assign_id stamps a compound" `Quick (fun () ->
        let svg = read_fixture "svg/live_compound.svg" in
        let doc = Jas.Svg.svg_to_document svg in
        let model = Jas.Model.create ~document:doc () in
        let ctrl = Jas.Controller.create ~model () in
        (* The compound is the first child of the first layer. *)
        let path = [0; 0] in
        (match (try Some (Jas.Document.get_element model#document path)
                with _ -> None) with
         | Some (Jas.Element.Live (Jas.Element.Compound_shape _)) -> ()
         | _ -> failwith "expected a compound at path [0; 0]");
        ctrl#assign_id path "c-assigned";
        let stamped = Jas.Document.get_element model#document path in
        (match Jas.Element.id_of stamped with
         | Some "c-assigned" -> ()
         | other ->
           failwith (Printf.sprintf "compound id not stamped: %s"
             (match other with Some s -> s | None -> "<none>")));
        (* And it survives the binary codec. *)
        let binary = Jas.Binary.document_to_binary model#document in
        let doc2 = Jas.Binary.binary_to_document binary in
        let round = Jas.Document.get_element doc2 path in
        (match Jas.Element.id_of round with
         | Some "c-assigned" -> ()
         | other ->
           failwith (Printf.sprintf "compound id lost through binary: %s"
             (match other with Some s -> s | None -> "<none>"))));
    ];

    (* Dependency index (REFERENCE_GRAPH.md section 3): the derived by-id
       reference graph. The cross-language case pins byte-equality with
       the shared fixture; the unit cases mirror the Rust unit tests. *)
    "Dependency index", [
      Alcotest.test_case "cross_language fixture" `Quick
        dependency_index_cross_language;

      (* orphaned_references predicate (reference-aware delete core).
         The cross-language case pins the shared fixture; the unit cases
         mirror the Rust unit tests (target-two-refs, delete target+ref,
         delete instance, group-with-referenced-descendant). *)
      Alcotest.test_case "orphaned_references cross_language" `Quick
        orphaned_references_cross_language;

      Alcotest.test_case "orphaned target with two refs returns both" `Quick
        (fun () ->
          (* a <- r1, r2. Deleting [a] (at [0;0]) orphans both r1 and r2. *)
          let doc = dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
            dep_reference ~id:"r2" ~target:"a";
          ] in
          Alcotest.(check (list string)) "orphaned" ["r1"; "r2"]
            (Jas.Dependency_index.orphaned_references doc [[0; 0]]));

      Alcotest.test_case "orphaned target plus one ref returns the other"
        `Quick (fun () ->
          (* Deleting [a] AND r1 ([0;0]+[0;1]) leaves only r2 orphaned;
             r1 is itself deleted, so it is not orphaned. *)
          let doc = dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
            dep_reference ~id:"r2" ~target:"a";
          ] in
          Alcotest.(check (list string)) "orphaned" ["r2"]
            (Jas.Dependency_index.orphaned_references doc [[0; 0]; [0; 1]]));

      Alcotest.test_case "orphaned deleting an instance returns empty" `Quick
        (fun () ->
          (* Deleting a reference (an instance) orphans nothing: an
             instance has no rdeps (nothing points AT it). *)
          let doc = dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
          ] in
          Alcotest.(check (list string)) "orphaned" []
            (Jas.Dependency_index.orphaned_references doc [[0; 1]]));

      Alcotest.test_case "orphaned group containing referenced element"
        `Quick (fun () ->
          (* A group at [0;1] contains the referenced rect [a]; an
             external reference r1 -> a sits outside the group. Deleting
             the group orphans r1 (its target [a] vanishes with it). *)
          let group = Jas.Element.make_group [| dep_rect ~id:"a" () |] in
          let doc = dep_doc_with_layer [
            dep_reference ~id:"r1" ~target:"a";
            group;
          ] in
          Alcotest.(check (list string)) "orphaned" ["r1"]
            (Jas.Dependency_index.orphaned_references doc [[0; 1]]));

      Alcotest.test_case "orphaned compound operand target is opaque" `Quick
        (fun () ->
          (* op1 lives only inside a CompoundShape operand
             (operand-opaque), so it is never a targetable node and
             r4 -> op1 is already dangling, not orphaned-by-this-delete.
             Deleting the compound [cs] (no rdeps of its own) therefore
             orphans nothing. *)
          let compound = Jas.Element.Live (Jas.Element.Compound_shape {
            operation = Jas.Element.Op_subtract_front;
            id = Some "cs";
            operands = [| dep_rect ~id:"op1" (); dep_rect () |];
            fill = None; stroke = None; opacity = 1.0;
            transform = None; locked = false;
            visibility = Jas.Element.Preview; blend_mode = Jas.Element.Normal;
            mask = None;
          }) in
          let doc = dep_doc_with_layer [
            compound;
            dep_reference ~id:"r4" ~target:"op1";
          ] in
          Alcotest.(check (list string)) "orphaned" []
            (Jas.Dependency_index.orphaned_references doc [[0; 0]]));

      Alcotest.test_case "orphaned invalid path is skipped" `Quick (fun () ->
          (* An out-of-range path resolves to no element and is skipped;
             the valid path still produces its orphans. *)
          let doc = dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
          ] in
          Alcotest.(check (list string)) "orphaned" ["r1"]
            (Jas.Dependency_index.orphaned_references doc [[0; 99]; [0; 0]]));

      Alcotest.test_case "empty document has empty index" `Quick (fun () ->
        let idx = Jas.Dependency_index.build (dep_doc_with_layer []) in
        Alcotest.(check bool) "deps empty" true (idx.deps = []);
        Alcotest.(check bool) "rdeps empty" true (idx.rdeps = []);
        Alcotest.(check bool) "dangling empty" true (idx.dangling = []);
        Alcotest.(check bool) "cycles empty" true (idx.cycles = []));

      Alcotest.test_case "deps and rdeps for two refs to one target" `Quick
        (fun () ->
          (* a <- r1, a <- r2. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
            dep_reference ~id:"r2" ~target:"a";
          ]) in
          Alcotest.(check (option (list string))) "deps r1"
            (Some ["a"]) (List.assoc_opt "r1" idx.deps);
          Alcotest.(check (option (list string))) "deps r2"
            (Some ["a"]) (List.assoc_opt "r2" idx.deps);
          Alcotest.(check (option (list string))) "rdeps a"
            (Some ["r1"; "r2"]) (List.assoc_opt "a" idx.rdeps);
          Alcotest.(check bool) "no dangling" true (idx.dangling = []);
          Alcotest.(check bool) "no cycles" true (idx.cycles = []));

      Alcotest.test_case "id-less element is not a node" `Quick (fun () ->
        (* The rect has no id; only the reference is a node, and its target
           is absent -> dangling. *)
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_rect ();
          dep_reference ~id:"r" ~target:"ghost";
        ]) in
        Alcotest.(check int) "one dep" 1 (List.length idx.deps);
        Alcotest.(check (option (list string))) "deps r"
          (Some ["ghost"]) (List.assoc_opt "r" idx.deps);
        Alcotest.(check bool) "no rdeps (ghost not targetable)" true
          (idx.rdeps = []);
        Alcotest.(check (list string)) "dangling" ["r"] idx.dangling);

      Alcotest.test_case "dangling when target absent" `Quick (fun () ->
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_reference ~id:"r3" ~target:"ghost";
        ]) in
        Alcotest.(check (list string)) "dangling" ["r3"] idx.dangling;
        Alcotest.(check bool) "no rdeps" true (idx.rdeps = []);
        Alcotest.(check bool) "no cycles" true (idx.cycles = []));

      Alcotest.test_case "two-cycle is detected" `Quick (fun () ->
        (* c1 -> c2 -> c1. *)
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_reference ~id:"c1" ~target:"c2";
          dep_reference ~id:"c2" ~target:"c1";
        ]) in
        Alcotest.(check (list string)) "cycles" ["c1"; "c2"] idx.cycles;
        Alcotest.(check (option (list string))) "rdeps c1"
          (Some ["c2"]) (List.assoc_opt "c1" idx.rdeps);
        Alcotest.(check (option (list string))) "rdeps c2"
          (Some ["c1"]) (List.assoc_opt "c2" idx.rdeps);
        Alcotest.(check bool) "no dangling" true (idx.dangling = []));

      Alcotest.test_case "self-target is a cycle" `Quick (fun () ->
        (* R -> R counts as a cycle. *)
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_reference ~id:"self" ~target:"self";
        ]) in
        Alcotest.(check (list string)) "cycles" ["self"] idx.cycles;
        Alcotest.(check (option (list string))) "rdeps self"
          (Some ["self"]) (List.assoc_opt "self" idx.rdeps);
        Alcotest.(check bool) "no dangling" true (idx.dangling = []));

      Alcotest.test_case "three-cycle collects all members" `Quick (fun () ->
        (* x -> y -> z -> x. *)
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_reference ~id:"x" ~target:"y";
          dep_reference ~id:"y" ~target:"z";
          dep_reference ~id:"z" ~target:"x";
        ]) in
        Alcotest.(check (list string)) "cycles" ["x"; "y"; "z"] idx.cycles);

      Alcotest.test_case "node off a cycle is not reported" `Quick (fun () ->
        (* tail -> c1, and c1 <-> c2 is a 2-cycle. tail reaches the cycle
           but is not on it. *)
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          dep_reference ~id:"tail" ~target:"c1";
          dep_reference ~id:"c1" ~target:"c2";
          dep_reference ~id:"c2" ~target:"c1";
        ]) in
        Alcotest.(check (list string)) "cycles" ["c1"; "c2"] idx.cycles;
        Alcotest.(check bool) "tail not on cycle" false
          (List.mem "tail" idx.cycles));

      Alcotest.test_case "compound operand id is opaque" `Quick (fun () ->
        (* A CompoundShape whose first operand carries id "op1". The walk
           does NOT recurse into operands, so op1 is NOT targetable. A
           reference r4 -> op1 must come out DANGLING, and op1 gets NO
           rdeps entry. This pins the operands-opaque decision. *)
        let compound = Jas.Element.Live (Jas.Element.Compound_shape {
          operation = Jas.Element.Op_subtract_front;
          id = Some "cs";
          operands = [| dep_rect ~id:"op1" (); dep_rect () |];
          fill = None; stroke = None; opacity = 1.0;
          transform = None; locked = false;
          visibility = Jas.Element.Preview; blend_mode = Jas.Element.Normal;
          mask = None;
        }) in
        let idx = Jas.Dependency_index.build (dep_doc_with_layer [
          compound;
          dep_reference ~id:"r4" ~target:"op1";
        ]) in
        Alcotest.(check bool) "cs not in deps" false
          (List.mem_assoc "cs" idx.deps);
        Alcotest.(check bool) "op1 not in deps" false
          (List.mem_assoc "op1" idx.deps);
        Alcotest.(check (option (list string))) "deps r4"
          (Some ["op1"]) (List.assoc_opt "r4" idx.deps);
        Alcotest.(check (list string)) "dangling" ["r4"] idx.dangling;
        Alcotest.(check bool) "op1 has no rdeps" false
          (List.mem_assoc "op1" idx.rdeps);
        Alcotest.(check bool) "cs has no rdeps" false
          (List.mem_assoc "cs" idx.rdeps));

      Alcotest.test_case "group children are walked but operands are not"
        `Quick (fun () ->
          (* A group nesting a reference proves the walk recurses into
             Group/Layer. *)
          let group = Jas.Element.make_group
            [| dep_reference ~id:"g_ref" ~target:"a" |] in
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"a" ();
            group;
          ]) in
          Alcotest.(check (option (list string))) "deps g_ref"
            (Some ["a"]) (List.assoc_opt "g_ref" idx.deps);
          Alcotest.(check (option (list string))) "rdeps a"
            (Some ["g_ref"]) (List.assoc_opt "a" idx.rdeps));

      Alcotest.test_case "canonical json has sorted keys and arrays" `Quick
        (fun () ->
          (* c1<->c2 cycle plus two refs to a and a dangling ref. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"a" ();
            dep_reference ~id:"r2" ~target:"a";
            dep_reference ~id:"r1" ~target:"a";
            dep_reference ~id:"r3" ~target:"ghost";
            dep_reference ~id:"c1" ~target:"c2";
            dep_reference ~id:"c2" ~target:"c1";
          ]) in
          let json = Jas.Dependency_index.to_test_json idx in
          let prefix = "{\"cycles\":[\"c1\",\"c2\"],\"dangling\":[\"r3\"]," in
          let starts =
            String.length json >= String.length prefix
            && String.sub json 0 (String.length prefix) = prefix in
          Alcotest.(check bool) "sorted top-level keys/arrays" true starts;
          let contains sub =
            let nlen = String.length sub and hlen = String.length json in
            let rec go i =
              if i + nlen > hlen then false
              else if String.sub json i nlen = sub then true
              else go (i + 1)
            in go 0 in
          Alcotest.(check bool) "rdeps a sorted" true (contains "\"a\":[\"r1\",\"r2\"]");
          Alcotest.(check bool) "deps r1" true (contains "\"r1\":[\"a\"]"));
    ];

    (* Operation equivalence tests *)
    "Operation", [
      Alcotest.test_case "select_and_move operations" `Quick (fun () ->
        run_operation_fixture "select_and_move.json");
      Alcotest.test_case "undo_redo_laws operations" `Quick (fun () ->
        run_operation_fixture "undo_redo_laws.json");
      Alcotest.test_case "controller_ops operations" `Quick (fun () ->
        run_operation_fixture "controller_ops.json");
    ];

    (* Workspace layout tests *)
    "Workspace layout", [
      Alcotest.test_case "workspace_default_layout" `Quick (fun () ->
        let expected = read_fixture "expected/workspace_default.json" in
        let layout = Jas.Workspace_layout.default_layout () in
        let actual = Jas.Workspace_test_json.workspace_to_test_json layout in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (workspace_default) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (workspace_default) ===\n%s\n" actual;
          assert false
        end);

      Alcotest.test_case "workspace_default_with_panes" `Quick (fun () ->
        let expected = read_fixture "expected/workspace_default_with_panes.json" in
        let layout = Jas.Workspace_layout.default_layout () in
        Jas.Workspace_layout.ensure_pane_layout layout ~viewport_w:1200.0 ~viewport_h:800.0;
        let actual = Jas.Workspace_test_json.workspace_to_test_json layout in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (workspace_default_with_panes) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (workspace_default_with_panes) ===\n%s\n" actual;
          assert false
        end);

      Alcotest.test_case "workspace_json_roundtrip" `Quick (fun () ->
        let json1 = read_fixture "expected/workspace_default_with_panes.json" in
        let layout = Jas.Workspace_test_json.test_json_to_workspace json1 in
        let json2 = Jas.Workspace_test_json.workspace_to_test_json layout in
        if json1 <> json2 then begin
          Printf.eprintf "=== EXPECTED (workspace_json_roundtrip) ===\n%s\n" json1;
          Printf.eprintf "=== ACTUAL (workspace_json_roundtrip) ===\n%s\n" json2;
          assert false
        end);

      Alcotest.test_case "toolbar_structure" `Quick (fun () ->
        let expected = read_fixture "expected/toolbar_structure.json" in
        let actual = Jas.Workspace_test_json.toolbar_structure_json () in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (toolbar_structure) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (toolbar_structure) ===\n%s\n" actual;
          assert false
        end);

      Alcotest.test_case "menu_structure" `Quick (fun () ->
        let expected = read_fixture "expected/menu_structure.json" in
        let actual = Jas.Workspace_test_json.menu_structure_json () in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (menu_structure) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (menu_structure) ===\n%s\n" actual;
          assert false
        end);

      Alcotest.test_case "state_defaults" `Quick (fun () ->
        let expected = read_fixture "expected/state_defaults.json" in
        let actual = Jas.Workspace_test_json.state_defaults_json () in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (state_defaults) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (state_defaults) ===\n%s\n" actual;
          assert false
        end);

      Alcotest.test_case "shortcut_structure" `Quick (fun () ->
        let expected = read_fixture "expected/shortcut_structure.json" in
        let actual = Jas.Workspace_test_json.shortcut_structure_json () in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (shortcut_structure) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (shortcut_structure) ===\n%s\n" actual;
          assert false
        end);
    ];

    (* Workspace operation tests *)
    "Workspace operation", [
      Alcotest.test_case "workspace_panel_ops" `Quick (fun () ->
        run_workspace_operation_fixture "panel_ops.json");

      Alcotest.test_case "workspace_pane_ops" `Quick (fun () ->
        run_workspace_operation_fixture "pane_ops.json");
    ];

    (* Pane geometry algorithm tests *)
    "Pane geometry algorithm", [
      Alcotest.test_case "algorithm_pane_geometry" `Quick (fun () ->
        let json_str = read_fixture "algorithms/pane_geometry.json" in
        let json = Yojson.Safe.from_string json_str in
        let tests = Yojson.Safe.Util.to_list json in
        List.iter (fun tc ->
          let open Yojson.Safe.Util in
          let name = tc |> member "name" |> to_string in
          let func = tc |> member "function" |> to_string in
          let args = tc |> member "args" in
          let expected = tc |> member "expected" |> to_float in
          let actual = match func with
            | "pane_edge_coord" ->
              let x = args |> member "x" |> to_float in
              let y = args |> member "y" |> to_float in
              let width = args |> member "width" |> to_float in
              let height = args |> member "height" |> to_float in
              let edge_str = args |> member "edge" |> to_string in
              let p : Jas.Pane.pane = {
                id = 0;
                kind = Jas.Pane.Canvas;
                config = Jas.Pane.config_for_kind Jas.Pane.Canvas;
                x; y; width; height;
              } in
              let edge = match edge_str with
                | "right" -> Jas.Pane.Right
                | "top" -> Jas.Pane.Top
                | "bottom" -> Jas.Pane.Bottom
                | _ -> Jas.Pane.Left
              in
              Jas.Pane.pane_edge_coord p edge
            | _ -> failwith (Printf.sprintf "Unknown function: %s" func)
          in
          if actual <> expected then begin
            Printf.eprintf "Pane geometry '%s' failed: expected %f, got %f\n"
              name expected actual;
            assert false
          end
        ) tests);
    ];
  ]
