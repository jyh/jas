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

let () =
  Alcotest.run "Cross_language" [
    (* SVG round-trip idempotence *)
    "SVG round-trip", [
      Alcotest.test_case "svg_roundtrip all fixtures" `Quick (fun () ->
        List.iter assert_svg_roundtrip roundtrip_names);
    ];

    (* JSON round-trip idempotence *)
    "JSON round-trip", [
      Alcotest.test_case "json_roundtrip all expected" `Quick (fun () ->
        List.iter assert_json_roundtrip roundtrip_names);
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
