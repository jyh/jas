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
  roundtrip_names @ ["live_reference"; "live_compound"; "live_compound_id";
                     (* Symbols P1: <defs> master + <use> instance
                        round-trips through SVG (SYMBOLS.md section 5 /
                        Fork S3) — defs masters import to symbols, not
                        layers, and re-export identically. *)
                     "symbols_basic";
                     (* Symbols P4: the instance transform rides
                        data-jas-instance-transform on the <use> and
                        round-trips through SVG distinct from
                        [ref_transform] (SYMBOLS.md section 4 / Fork F2). *)
                     "reference_instance_transform"]

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
                     "live_reference_roundtrip"; "live_compound_roundtrip";
                     (* Symbols P1: the [symbols] array (a master) + the
                        instance in layers round-trips through test_json
                        (SYMBOLS.md section 10). *)
                     "symbols_basic";
                     (* Symbols P4: a reference whose instance transform
                        field is set (the "instance_transform" key)
                        round-trips through test_json distinct from
                        [ref_transform] (SYMBOLS.md section 4 / Fork F2). *)
                     "reference_instance_transform"]
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
                     "live_compound_id";
                     (* Symbols P1: the master store rides the trailing element
                        array in the binary document (SYMBOLS.md section 5); its
                        Python-generated symbols_basic.bin is the cross-app pin. *)
                     "symbols_basic";
                     (* Symbols P4: a reference carrying a non-identity instance
                        transform (the instance transform rides binary slot 9). *)
                     "reference_instance_transform"]

(* Binary JSON->binary->JSON round-trip fixtures = [binary_names] (which now
   includes symbols_basic and also feeds the binary-read-Python test), PLUS
   the Symbols P4 instance-transform fixture. The instance transform packs at
   TAG_LIVE slot 9 and round-trips through binary distinct from
   [ref_transform] (SYMBOLS.md section 4 / Fork F2). It is kept OUT of
   [binary_names] (the Python-read list) deliberately: the lead owns wiring
   the Python byte oracle for this fixture. *)
let binary_roundtrip_names =
  binary_names @ ["reference_instance_transform"]

let assert_json_roundtrip name =
  let expected = read_fixture (Printf.sprintf "expected/%s.json" name) in
  let doc = Jas.Test_json.test_json_to_document expected in
  let actual = Jas.Test_json.document_to_test_json doc in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
    Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
    assert false
  end

(* Apply one fixture op to [model] / [ctrl]. Top-level (taking the model and
   controller explicitly) so the checkpoint_equivalence gate can replay a
   transaction's recorded ops into a FRESH model with the identical dispatch.
   OP_LOG.md section 6. *)
let apply_op (model : Jas.Model.model) (ctrl : Jas.Controller.controller) op =
  let open Yojson.Safe.Util in
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
      (* Symbols P2 operations (SYMBOLS.md section 7). Value-in-op: the ids and
         paths are read literally from the fixture payload, exactly like the
         create_reference arm. *)
      | "make_symbol" ->
        let path = op |> member "path" |> to_list |> List.map to_int in
        let master_id = op |> member "master_id" |> to_string in
        let ref_id = op |> member "ref_id" |> to_string in
        ctrl#make_symbol path master_id ref_id
      | "place_instance" ->
        let master_id = op |> member "master_id" |> to_string in
        let ref_id = op |> member "ref_id" |> to_string in
        ctrl#place_instance master_id ref_id
      | "detach" ->
        let path = op |> member "path" |> to_list |> List.map to_int in
        ctrl#detach path
      (* Symbols P4 (SYMBOLS.md section 4 / Fork F2). Value-in-op: the
         instance transform is carried in the payload as {a,b,c,d,e,f} (the
         same matrix shape parsed elsewhere) and applied verbatim. *)
      | "set_instance_transform" ->
        let path = op |> member "path" |> to_list |> List.map to_int in
        let t = op |> member "transform" in
        let transform = {
          Jas.Element.a = t |> member "a" |> to_num;
          b = t |> member "b" |> to_num;
          c = t |> member "c" |> to_num;
          d = t |> member "d" |> to_num;
          e = t |> member "e" |> to_num;
          f = t |> member "f" |> to_num;
        } in
        ctrl#set_instance_transform path transform
      | "redefine" ->
        let master_id = op |> member "master_id" |> to_string in
        let path = op |> member "path" |> to_list |> List.map to_int in
        let ref_id = op |> member "ref_id" |> to_string in
        ctrl#redefine master_id path ref_id
      | "delete_symbol" ->
        let master_id = op |> member "master_id" |> to_string in
        ctrl#delete_symbol master_id
      | "delete_selection" ->
        let new_doc = Jas.Document.delete_selection model#document in
        model#set_document new_doc
      | "lock_selection" -> ctrl#lock_selection
      | "unlock_all" -> ctrl#unlock_all
      | "hide_selection" -> ctrl#hide_selection
      | "show_all" -> ctrl#show_all
      | "boolean_union" ->
        Jas.Boolean_apply.apply_destructive_boolean model "union"
      | "simplify" ->
        let precision = try op |> member "precision" |> to_num with _ -> 0.5 in
        ctrl#simplify_selection precision
  | "snapshot" -> model#snapshot
  | "undo" -> model#undo
  | "redo" -> model#redo
  | _ -> failwith (Printf.sprintf "Unknown op: %s" op_name)

(* checkpoint_equivalence gate (OP_LOG.md section 6): replay the ops recorded
   in [journal.(0..head)] from the setup SVG into a FRESH model and serialize.
   The harness then asserts this equals the snapshot-path document, so a
   committed journal always replays to the same document the production
   undo/redo path produced. *)
let replay_journal svg (journal : Jas.Op_log.transaction list) head =
  let doc = Jas.Svg.svg_to_document svg in
  let model = Jas.Model.create ~document:doc () in
  let ctrl = Jas.Controller.create ~model () in
  List.iteri (fun i (txn : Jas.Op_log.transaction) ->
    if i < head then
      List.iter (fun (op : Jas.Op_log.primitive_op) ->
        apply_op model ctrl op.Jas.Op_log.params
      ) txn.Jas.Op_log.ops
  ) journal;
  Jas.Test_json.document_to_test_json model#document

let run_operation_fixture fixture_name =
  let json_str = read_fixture (Printf.sprintf "operations/%s" fixture_name) in
  let json = Yojson.Safe.from_string json_str in
  let tests = Yojson.Safe.Util.to_list json in
  List.iter (fun tc ->
    let open Yojson.Safe.Util in
    let name = tc |> member "name" |> to_string in
    let setup_svg_file = tc |> member "setup_svg" |> to_string in
    let expected_file = tc |> member "expected_json" |> to_string in
    let svg = read_fixture (Printf.sprintf "svg/%s" setup_svg_file) in
    let expected = read_fixture (Printf.sprintf "operations/%s" expected_file) in
    let doc = Jas.Svg.svg_to_document svg in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    (* Two fixture shapes (OP_LOG.md section 5): the journal-native [txns] form
       (each transaction commits explicitly via begin_txn/commit_txn, then a
       [history] directive of undo/redo positions the cursor; snapshot/undo/redo
       are NOT ops here) and the legacy flat [ops] form (one implicit outer
       transaction, so non-undoable ops like select_rect are captured into the
       journal). In both forms each op is recorded as a PrimitiveOp carrying the
       op verb + its verbatim payload, so the checkpoint_equivalence gate can
       replay them. *)
    (match tc |> member "txns" with
     | `Null ->
       model#begin_txn;
       List.iter (fun op ->
         apply_op model ctrl op;
         model#record_op
           (Jas.Op_log.make_primitive_op
              ~op:(op |> member "op" |> to_string) ~params:op ())
       ) (tc |> member "ops" |> to_list);
       model#commit_txn
     | txns ->
       List.iter (fun txn ->
         model#begin_txn;
         (match txn |> member "name" with
          | `Null -> ()
          | n -> model#name_txn (to_string n));
         List.iter (fun op ->
           apply_op model ctrl op;
           model#record_op
             (Jas.Op_log.make_primitive_op
                ~op:(op |> member "op" |> to_string) ~params:op ())
         ) (txn |> member "ops" |> to_list);
         model#commit_txn
       ) (to_list txns);
       (match tc |> member "history" with
        | `Null -> ()
        | history ->
          List.iter (fun h ->
            match to_string h with
            | "undo" -> model#undo
            | "redo" -> model#redo
            | other -> failwith (Printf.sprintf "Unknown history directive: %s" other)
          ) (to_list history)));
    let actual = Jas.Test_json.document_to_test_json model#document in
    if actual <> expected then begin
      Printf.eprintf "=== EXPECTED (%s) ===\n%s\n" name expected;
      Printf.eprintf "=== ACTUAL (%s) ===\n%s\n" name actual;
      assert false
    end;
    (* checkpoint_equivalence gate (OP_LOG.md section 6): the journal must
       replay to the same document as the snapshot path. *)
    let replayed = replay_journal svg model#journal model#journal_head in
    if replayed <> actual then begin
      Printf.eprintf
        "=== checkpoint_equivalence gate failed for '%s' ===\n" name;
      Printf.eprintf "=== SNAPSHOT PATH ===\n%s\n" actual;
      Printf.eprintf "=== JOURNAL REPLAY ===\n%s\n" replayed;
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

(* Cross-language pin for the chain/diamond graph (REFERENCE_GRAPH.md
   section 8 Phase 4a): read the shared input document, build the index,
   serialize it, and assert byte-equality with the shared chain fixture.
   Exercises multi-level topological ordering that the primary fixture
   cannot (it is mostly cycle + dangling). All apps run this same fixture. *)
let dependency_index_chain_cross_language () =
  let input = read_fixture "expected/dependency_index_chain_input.json" in
  let doc = Jas.Test_json.test_json_to_document input in
  (* Sanity: the parsed input must re-serialize to itself (it is canonical). *)
  let reser = Jas.Test_json.document_to_test_json doc in
  if reser <> input then begin
    Printf.eprintf "=== dependency_index_chain_input.json not canonical ===\n";
    Printf.eprintf "EXPECTED: %s\nACTUAL:   %s\n" input reser;
    assert false
  end;
  let actual = Jas.Dependency_index.to_test_json (Jas.Dependency_index.build doc) in
  let expected = read_fixture "expected/dependency_index_chain.json" in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED (dependency_index_chain) ===\n%s\n" expected;
    Printf.eprintf "=== ACTUAL (dependency_index_chain) ===\n%s\n" actual;
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
        List.iter assert_binary_roundtrip binary_roundtrip_names);
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
      (* Symbols P1 (SYMBOLS.md section 10): the <defs> master (id="m1")
         imports into doc.symbols (NOT layers); the
         <use href="#m1" id="i1"> imports as a live reference in the
         layer. The canonical JSON shows the [symbols] array + the
         instance. All apps parse it to the identical canonical JSON. *)
      Alcotest.test_case "svg_parse symbols_basic" `Quick (fun () -> assert_svg_parse "symbols_basic");
      (* Symbols P4 (SYMBOLS.md section 4 / Fork F2): a <use> carrying
         data-jas-instance-transform parses to a reference whose instance
         transform field (emitted as "instance_transform") is set, distinct
         from [ref_transform] (common.transform stays null). *)
      Alcotest.test_case "svg_parse reference_instance_transform" `Quick
        (fun () -> assert_svg_parse "reference_instance_transform");
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

      (* Phase 4a topo_order: the multi-level chain/diamond fixture pins
         level-by-level Kahn ordering that the primary fixture (mostly
         cycle + dangling) cannot exercise. *)
      Alcotest.test_case "chain cross_language fixture" `Quick
        dependency_index_chain_cross_language;

      (* orphaned_references predicate (reference-aware delete core).
         The cross-language case pins the shared fixture; the unit cases
         mirror the Rust unit tests (target-two-refs, delete target+ref,
         delete instance, group-with-referenced-descendant). *)
      Alcotest.test_case "orphaned_references cross_language" `Quick
        orphaned_references_cross_language;

      (* Reference-aware delete/cut, CONFIRM half: the warn body wording
         is verbatim and pinned cross-language (singular for n=1, plural
         otherwise). The modal itself needs a live window so cannot be
         driven headless; the pure text builder is what differs per
         locale/count/verb, so that is what gets asserted. The body
         helper is now verb-parameterized so delete and cut share it. *)
      Alcotest.test_case "delete orphan warning body singular" `Quick
        (fun () ->
          Alcotest.(check string) "n=1 singular"
            "Deleting will leave 1 live instance empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Deleting" 1));

      Alcotest.test_case "delete orphan warning body plural" `Quick
        (fun () ->
          Alcotest.(check string) "n=2 plural"
            "Deleting will leave 2 live instances empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Deleting" 2);
          Alcotest.(check string) "n=0 plural"
            "Deleting will leave 0 live instances empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Deleting" 0));

      (* Reference-aware cut reuses the SAME verb-parameterized body
         helper with verb "Cutting"; the rest of the wording (the count,
         the singular/plural noun, the trailing clause) is byte-identical
         to delete and pinned cross-language. *)
      Alcotest.test_case "cut orphan warning body singular" `Quick
        (fun () ->
          Alcotest.(check string) "n=1 singular"
            "Cutting will leave 1 live instance empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Cutting" 1));

      Alcotest.test_case "cut orphan warning body plural" `Quick
        (fun () ->
          Alcotest.(check string) "n=2 plural"
            "Cutting will leave 2 live instances empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Cutting" 2);
          Alcotest.(check string) "n=0 plural"
            "Cutting will leave 0 live instances empty."
            (Jas.Menubar.delete_orphan_warning_body ~verb:"Cutting" 0));

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
          Alcotest.(check bool) "deps r1" true (contains "\"r1\":[\"a\"]");
          (* topo_order is the LAST key (alphabetical) and its VALUE is the
             topo sequence: level 0 {a, r3} (r3 dangling -> count 0)
             emitted sorted, freeing r1, r2 for level 1; c1/c2 cycle
             remnants trail in sorted order. *)
          Alcotest.(check bool) "topo_order value" true
            (contains "\"topo_order\":[\"a\",\"r3\",\"r1\",\"r2\",\"c1\",\"c2\"]"));

      (* ---------------------------------------------------------------
         topo_order (Phase 4a — LOCKED algorithm). Kahn with sorted-id
         tie-break; dependencies-first; cycle remnants appended in sorted
         order. These tests pin the deterministic sequence the algorithm
         must produce; the SAME cases are mirrored across all four apps.
         --------------------------------------------------------------- *)

      Alcotest.test_case "topo_order worked example matches locked spec"
        `Quick (fun () ->
          (* The cross-language fixture graph (REFERENCE_GRAPH.md section 8
             worked example): deps c1<->c2, r1->a, r2->a, r3->ghost,
             r4->op1; nodes are {a,c1,c2,r1,r2,r3,r4} (ghost/op1 are
             non-nodes). Expected sequence: ready {a,r3,r4} sorted ->
             a,r3,r4 frees r1,r2 -> r1,r2; cycle c1,c2 trail. *)
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
            dep_rect ~id:"a" ();
            dep_reference ~id:"r1" ~target:"a";
            dep_reference ~id:"r2" ~target:"a";
            dep_reference ~id:"r3" ~target:"ghost";
            dep_reference ~id:"c1" ~target:"c2";
            dep_reference ~id:"c2" ~target:"c1";
            compound;
            dep_reference ~id:"r4" ~target:"op1";
          ]) in
          Alcotest.(check (list string)) "topo_order"
            ["a"; "r3"; "r4"; "r1"; "r2"; "c1"; "c2"] idx.topo_order);

      Alcotest.test_case "topo_order chain is dependencies-first" `Quick
        (fun () ->
          (* The chain/diamond fixture graph: b; s1->b; s2->s1; t1->b;
             t2->b; d1->s1. Level-by-level Kahn:
               level 0: {b}                  emit b      -> frees s1,t1,t2
               level 1: {s1,t1,t2} sorted    emit s1,t1,t2 -> emitting s1
                                                            frees d1, s2
               level 2: {d1,s2} sorted       emit d1, s2
             Expected: b, s1, t1, t2, d1, s2. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"b" ();
            dep_reference ~id:"s1" ~target:"b";
            dep_reference ~id:"s2" ~target:"s1";
            dep_reference ~id:"t1" ~target:"b";
            dep_reference ~id:"t2" ~target:"b";
            dep_reference ~id:"d1" ~target:"s1";
          ]) in
          Alcotest.(check (list string)) "topo_order"
            ["b"; "s1"; "t1"; "t2"; "d1"; "s2"] idx.topo_order;
          (* Dependencies-first invariant: every target precedes its
             referrer. *)
          let pos id =
            let rec go i = function
              | [] -> failwith (Printf.sprintf "id %s not in topo_order" id)
              | x :: _ when x = id -> i
              | _ :: rest -> go (i + 1) rest
            in go 0 idx.topo_order
          in
          Alcotest.(check bool) "b<s1" true (pos "b" < pos "s1");
          Alcotest.(check bool) "b<t1" true (pos "b" < pos "t1");
          Alcotest.(check bool) "b<t2" true (pos "b" < pos "t2");
          Alcotest.(check bool) "s1<s2" true (pos "s1" < pos "s2");
          Alcotest.(check bool) "s1<d1" true (pos "s1" < pos "d1");
          Alcotest.(check bool) "no cycles" true (idx.cycles = []));

      Alcotest.test_case "topo_order pure dag no cycle full ordering" `Quick
        (fun () ->
          (* A pure DAG with no cycle: a -> b -> c (a depends on b depends
             on c). Dependencies-first means c, b, a — the reverse of the
             reference chain. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"c" ();
            dep_reference ~id:"b" ~target:"c";
            dep_reference ~id:"a" ~target:"b";
          ]) in
          Alcotest.(check bool) "no cycles" true (idx.cycles = []);
          Alcotest.(check (list string)) "topo_order"
            ["c"; "b"; "a"] idx.topo_order);

      Alcotest.test_case "topo_order all dangling is empty" `Quick (fun () ->
          (* Every reference points at an absent target -> the targets are
             NOT nodes, so the only nodes are the referencing ids, all with
             dependency count 0. They emit in sorted order. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_reference ~id:"z" ~target:"ghost1";
            dep_reference ~id:"a" ~target:"ghost2";
            dep_reference ~id:"m" ~target:"ghost3";
          ]) in
          Alcotest.(check (list string)) "dangling"
            ["a"; "m"; "z"] idx.dangling;
          Alcotest.(check bool) "no rdeps" true (idx.rdeps = []);
          Alcotest.(check bool) "no cycles" true (idx.cycles = []);
          Alcotest.(check (list string)) "topo_order"
            ["a"; "m"; "z"] idx.topo_order);

      Alcotest.test_case "topo_order truly empty graph is empty" `Quick
        (fun () ->
          (* No id-bearing elements -> no nodes -> empty topo order. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ();
          ]) in
          Alcotest.(check (list string)) "topo_order empty"
            [] idx.topo_order);

      Alcotest.test_case "topo_order cycle remnants trail in sorted order"
        `Quick (fun () ->
          (* A DAG prefix feeding a plain rect, plus two unrelated cyclic
             pairs, to pin that ALL cycle members trail at the end in
             sorted-id order while the acyclic part is emitted
             dependencies-first.
             Graph: head -> root (root is a plain rect, count 0);
                    a cycle z<->y; a cycle q<->p.
             Acyclic nodes: root (0), head (1, dep root). Emit root, head.
             Cyclic nodes never reach 0: p,q,y,z -> trail sorted. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"root" ();
            dep_reference ~id:"head" ~target:"root";
            dep_reference ~id:"z" ~target:"y";
            dep_reference ~id:"y" ~target:"z";
            dep_reference ~id:"q" ~target:"p";
            dep_reference ~id:"p" ~target:"q";
          ]) in
          Alcotest.(check (list string)) "cycles"
            ["p"; "q"; "y"; "z"] idx.cycles;
          Alcotest.(check (list string)) "topo_order"
            ["root"; "head"; "p"; "q"; "y"; "z"] idx.topo_order);

      Alcotest.test_case "topo_order node blocked by cycle trails with remnants"
        `Quick (fun () ->
          (* A node that DEPENDS on a cycle but is not ON it (tail -> c1,
             c1<->c2) never reaches dependency-count 0, so it is a remnant
             too. The remnants are ALL un-emitted nodes appended in sorted
             order — here the superset {c1, c2, tail}, NOT just the cycle
             set {c1, c2}. There is no acyclic prefix (every node is
             blocked), so topo_order is exactly the sorted remnants. This
             pins that [cycles] is a SUBSET of the remnants. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_reference ~id:"tail" ~target:"c1";
            dep_reference ~id:"c1" ~target:"c2";
            dep_reference ~id:"c2" ~target:"c1";
          ]) in
          Alcotest.(check (list string)) "cycles" ["c1"; "c2"] idx.cycles;
          Alcotest.(check (list string))
            "tail trails sorted after the cycle"
            ["c1"; "c2"; "tail"] idx.topo_order);

      Alcotest.test_case "topo_order self cycle node trails" `Quick
        (fun () ->
          (* A self-targeting reference is a cycle of one; it must trail
             after the acyclic nodes in sorted order. tail -> leaf (leaf
             count 0); self -> self. *)
          let idx = Jas.Dependency_index.build (dep_doc_with_layer [
            dep_rect ~id:"leaf" ();
            dep_reference ~id:"tail" ~target:"leaf";
            dep_reference ~id:"self" ~target:"self";
          ]) in
          Alcotest.(check (list string)) "cycles" ["self"] idx.cycles;
          Alcotest.(check (list string)) "topo_order"
            ["leaf"; "tail"; "self"] idx.topo_order);
    ];

    (* Symbols P1 (SYMBOLS.md section 10): the off-canvas master store.
       The RESOLVE test shows an instance in a layer evaluates to a
       master that lives ONLY in doc.symbols; the dep-index test shows
       the instance -> master edge is not dangling and rdeps[m1]==[i1]. *)
    "Symbols", [
      Alcotest.test_case "instance resolves to master geometry from symbols"
        `Quick (fun () ->
          (* SYMBOLS.md section 10 RESOLVE gate: ONE master rect (id "m1")
             in doc.symbols and ONE instance (a reference id "i1"
             targeting "m1") in a layer. A resolver that indexes
             doc.symbols (as the canvas render does) makes the instance
             evaluate to the master's geometry — non-empty and equal to
             evaluating the master rect directly. This is the whole point
             of the off-canvas store: masters are resolvable but never in
             [layers]. *)
          let master =
            Jas.Element.with_id
              (Jas.Element.make_rect 9.0 18.0 27.0 36.0) (Some "m1") in
          let instance =
            Jas.Element.make_reference ~id:(Some "i1") "m1" in
          let doc =
            Jas.Document.make_document
              ~symbols:[| master |]
              [| Jas.Element.make_layer ~name:"Layer" [| instance |] |] in
          (* The master lives ONLY in doc.symbols, never in layers. *)
          Alcotest.(check int) "one master in symbols" 1
            (Array.length doc.Jas.Document.symbols);
          (* The layer's sole child is the instance (a reference). *)
          let layer0_children =
            Jas.Document.children_of doc.Jas.Document.layers.(0) in
          Alcotest.(check int) "layer holds only the instance" 1
            (Array.length layer0_children);

          (* Build the resolver spanning layers + symbols (the symbols
             half is what makes the master resolvable). *)
          let resolver =
            Jas.Live.resolver_of_layers_and_symbols
              doc.Jas.Document.layers doc.Jas.Document.symbols in
          let precision = Jas.Live.default_precision in
          let visiting = ref Jas.Live.VisitSet.empty in
          let resolved =
            Jas.Live.element_to_polygon_set_with
              layer0_children.(0) precision resolver visiting in
          (* Non-empty, and equal to evaluating the master rect directly. *)
          Alcotest.(check bool) "instance resolves to master geometry"
            true (resolved <> []);
          let master_ps =
            Jas.Live.element_to_polygon_set master precision in
          Alcotest.(check bool) "resolved equals master rect geometry"
            true (resolved = master_ps);
          (* The cycle-guard set is restored after the resolve. *)
          Alcotest.(check bool) "cycle-guard set restored"
            true (Jas.Live.VisitSet.is_empty !visiting));

      Alcotest.test_case "symbols master is targetable and instance resolves"
        `Quick (fun () ->
          (* SYMBOLS.md section 6: an instance (a reference) in [layers]
             targeting a master in doc.symbols. The targetable-set walk
             includes symbols, so the instance is NOT dangling and
             rdeps[master] lists the instance. *)
          let master =
            Jas.Element.with_id
              (Jas.Element.make_rect 0.0 0.0 30.0 40.0) (Some "m1") in
          let doc =
            Jas.Document.make_document
              ~symbols:[| master |]
              [| Jas.Element.make_layer ~name:"Layer"
                   [| dep_reference ~id:"i1" ~target:"m1" |] |] in
          let idx = Jas.Dependency_index.build doc in
          (* The instance's edge resolves to a targetable master -> not
             dangling. *)
          Alcotest.(check (list string)) "no dangling" [] idx.dangling;
          (* rdeps[m1] is exactly the instance i1. *)
          Alcotest.(check (option (list string))) "rdeps m1"
            (Some ["i1"]) (List.assoc_opt "m1" idx.rdeps);
          (* The instance's out-edge is recorded; no cycles. *)
          Alcotest.(check (option (list string))) "deps i1"
            (Some ["m1"]) (List.assoc_opt "i1" idx.deps);
          Alcotest.(check (list string)) "no cycles" [] idx.cycles);
    ];

    (* Operation equivalence tests *)
    "Operation", [
      Alcotest.test_case "select_and_move operations" `Quick (fun () ->
        run_operation_fixture "select_and_move.json");
      Alcotest.test_case "undo_redo_laws operations" `Quick (fun () ->
        run_operation_fixture "undo_redo_laws.json");
      Alcotest.test_case "controller_ops operations" `Quick (fun () ->
        run_operation_fixture "controller_ops.json");
      (* Symbols P2 operation fixtures (SYMBOLS.md section 7): make_symbol,
         place_instance, detach, redefine. Each setup parses through the P1 SVG
         <defs> codec, runs the op, and pins the canonical JSON all apps must
         reproduce. *)
      Alcotest.test_case "symbols_ops operations" `Quick (fun () ->
        run_operation_fixture "symbols_ops.json");
      (* Boolean grouping (OP_LOG.md section 10 item 3): boolean_union +
         post-op simplify are one transaction; the gate pins the journal
         replays to the snapshot-path document. *)
      Alcotest.test_case "boolean_ops operations" `Quick (fun () ->
        run_operation_fixture "boolean_ops.json");
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
