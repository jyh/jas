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
                     "reference_instance_transform";
                     (* CONCEPTS.md 3b: a Generated concept-instance (concept id
                        + params) round-trips byte-identically to the
                        Rust-authored golden — the cross-language pin. *)
                     "generated_polygon"]
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

(* Thin harness shim over the production dispatcher (OP_LOG.md section 9,
   Increment 3b-B): both the cross-language harness and the production effect
   path go through the SAME [Op_apply.op_apply] module and the SAME [record_op]
   site, so this lift is behavior-preserving (the operations fixtures stay
   byte-green) and [targets] is recorded identically on both paths. Top-level
   (taking the model and controller explicitly) so the checkpoint_equivalence
   gate can replay a transaction's recorded ops into a FRESH model with the
   identical dispatch (OP_LOG.md section 6). [op_apply] records the op into the
   open transaction itself, so the harness no longer calls [model#record_op]
   separately. *)
let apply_op (model : Jas.Model.model) (ctrl : Jas.Controller.controller) op =
  Jas.Op_apply.op_apply model ctrl op

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
         (* [op_apply] records the op into the open transaction itself
            (OP_LOG.md section 9, 3b-B), so the harness no longer calls
            [record_op] separately. *)
         apply_op model ctrl op
       ) (tc |> member "ops" |> to_list);
       model#commit_txn
     | txns ->
       List.iter (fun txn ->
         model#begin_txn;
         (match txn |> member "name" with
          | `Null -> ()
          | n -> model#name_txn (to_string n));
         List.iter (fun op ->
           apply_op model ctrl op
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

(* Canonical JSON of the Transaction journal (OP_LOG.md section 10 item 4):
   pins the reserved causal/merge metadata + each op's verb and targets across
   apps. Fixed key order + deterministic txn-N ids make it byte-shareable.
   Mirrors journal_to_test_json in the other apps' harnesses. *)
let journal_to_test_json (journal : Jas.Op_log.transaction list) : string =
  let opt = function Some v -> Printf.sprintf "\"%s\"" v | None -> "null" in
  let op_json (o : Jas.Op_log.primitive_op) =
    let targets =
      String.concat ","
        (List.map (fun x -> Printf.sprintf "\"%s\"" x) o.Jas.Op_log.targets) in
    Printf.sprintf "{\"op\":\"%s\",\"targets\":[%s]}" o.Jas.Op_log.op targets
  in
  let txn_json (t : Jas.Op_log.transaction) =
    let ops = String.concat "," (List.map op_json t.Jas.Op_log.ops) in
    Printf.sprintf
      "{\"actor\":\"%s\",\"label\":%s,\"lamport\":%d,\"name\":%s,\"ops\":[%s],\"parent\":%s,\"txn_id\":\"%s\"}"
      t.Jas.Op_log.actor (opt t.Jas.Op_log.label) t.Jas.Op_log.lamport
      (opt t.Jas.Op_log.name) ops (opt t.Jas.Op_log.parent) t.Jas.Op_log.txn_id
  in
  "[" ^ String.concat "," (List.map txn_json journal) ^ "]"

(* OP_LOG.md section 10 item 4: the journal's causal/merge metadata serializes
   byte-identically across apps (deterministic txn-N counter + parent edge). *)
let run_journal_metadata fixture_name =
  let json_str = read_fixture (Printf.sprintf "operations/%s" fixture_name) in
  let tests = Yojson.Safe.Util.to_list (Yojson.Safe.from_string json_str) in
  List.iter (fun tc ->
    let open Yojson.Safe.Util in
    let setup_svg_file = tc |> member "setup_svg" |> to_string in
    let expected_file = tc |> member "expected_journal_json" |> to_string in
    let svg = read_fixture (Printf.sprintf "svg/%s" setup_svg_file) in
    let doc = Jas.Svg.svg_to_document svg in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    List.iter (fun txn ->
      model#begin_txn;
      (match txn |> member "name" with `Null -> () | n -> model#name_txn (to_string n));
      List.iter (fun op ->
        (* [op_apply] records the op itself (OP_LOG.md section 9, 3b-B). *)
        apply_op model ctrl op
      ) (txn |> member "ops" |> to_list);
      model#commit_txn;
      (* OP_LOG.md Increment 3a: a [label] on a transaction marks a version
         point — label_version stamps it onto the committed transaction so it
         serializes into the journal artifact. *)
      (match txn |> member "label" with
       | `Null -> ()
       | l -> model#label_version (to_string l))
    ) (tc |> member "txns" |> to_list);
    let actual = journal_to_test_json model#journal in
    let expected =
      String.trim (read_fixture (Printf.sprintf "operations/%s" expected_file)) in
    if actual <> expected then begin
      Printf.eprintf "=== EXPECTED journal ===\n%s\n=== ACTUAL journal ===\n%s\n"
        expected actual;
      assert false
    end
  ) tests

(* Thin shim over the RUNTIME layout-op dispatcher (OP_LOG.md section 12,
   Increment 3d-2). The 15-verb dispatcher body was promoted out of this
   harness into [Jas.Layout_apply.layout_apply] so production and the harness
   share ONE dispatcher and ONE per-verb mutation body. The harness keeps this
   one-line entry point so the corpus runner below is unchanged. *)
let apply_workspace_op layout op = Jas.Layout_apply.layout_apply layout op

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

(* The canonical recorded-live-element document (RECORDED_ELEMENTS.md): a
   recorded element whose recipe copies its input "eye" and translates the
   copy +50x. Built identically in every app's harness, so its
   document_to_test_json serialization (the recipe + inputs) is the
   cross-language pin. Mirrors the Rust [recorded_canonical_document]. *)
let recorded_canonical_document () : Jas.Document.document =
  let open Jas.Element in
  let ops = [
    { rop_op = "copy";
      rop_params = `Assoc [ ("from", `List [ `String "eye" ]);
                            ("dx", `Float 0.0); ("dy", `Float 0.0) ];
      rop_targets = [] };
    { rop_op = "translate";
      rop_params = `Assoc [ ("ids", `List [ `String "$0" ]);
                            ("dx", `Float 50.0); ("dy", `Float 0.0) ];
      rop_targets = [] };
  ] in
  let rec_ = make_recorded ~id:(Some "rec") ops [ "eye" ] in
  let layer = make_layer [| rec_ |] in
  Jas.Document.make_document ~artboards:[] [| layer |]

(* Cross-language pin (RECORDED_ELEMENTS.md section 8): a recorded element's
   recipe + inputs serialize byte-identically across the four native apps.
   Mirrors the Rust [recorded_cross_language]. *)
let recorded_cross_language () =
  let actual =
    Jas.Test_json.document_to_test_json (recorded_canonical_document ()) in
  let expected = read_fixture "operations/recorded_eye.json" in
  if actual <> expected then begin
    Printf.eprintf "=== EXPECTED ===\n%s\n=== ACTUAL ===\n%s\n" expected actual;
    assert false
  end

(* ------------------------------------------------------------------ *)
(* Production op-capture cross-language fixture (OP_LOG.md section 9,
   Increment 3b-B). Drives the REAL [Effects.run_effects] (NOT the
   hand-bracketed harness [apply_op] path) over the shared fixtures, exercising
   the YAML->journal param translation (marquee corners x1/y1/x2/y2/additive ->
   x/y/width/height/extend), batch ownership / single-transaction commit, action
   naming, and the lazy-begin drag-frame-hole fix. Mirrors the Rust + Swift
   harness. *)
(* ------------------------------------------------------------------ *)

(* Production-capture JOURNAL serializer (OP_LOG.md section 10 item 4). Distinct
   from [journal_to_test_json] (the txn_metadata serializer, which OMITS op
   params and pins txn_id/lamport/parent/actor). The production golden pins the
   PARAM-TRANSLATION result, so this variant emits, per transaction: [name], and
   per op [{op, params, targets}] with [params] canonicalized (sorted-key +
   fixed-float) exactly like [document_to_test_json] (via
   [Test_json.canonical_value]). [txn_id] is EXCLUDED (a live-entropy seam,
   non-deterministic per-app). The redundant top-level "op" key inside the
   recorded [params] (op_apply records the full op value, verb included) is
   STRIPPED — the verb already lives in the op-level [op] field.
   [actor]/[parent]/[lamport] are OMITTED (their own byte-stable golden exists).
   Mirrors the Rust [production_journal_to_test_json]. *)
let production_journal_to_test_json
    (journal : Jas.Op_log.transaction list) : string =
  let opt = function Some v -> Printf.sprintf "%S" v | None -> "null" in
  let op_json (o : Jas.Op_log.primitive_op) =
    (* Strip the redundant top-level "op" key from params. *)
    let params = match o.Jas.Op_log.params with
      | `Assoc fields -> `Assoc (List.filter (fun (k, _) -> k <> "op") fields)
      | other -> other in
    let targets =
      String.concat ","
        (List.map (fun x -> Printf.sprintf "%S" x) o.Jas.Op_log.targets) in
    Printf.sprintf "{\"op\":%S,\"params\":%s,\"targets\":[%s]}"
      o.Jas.Op_log.op (Jas.Test_json.canonical_value params) targets
  in
  let txn_json (t : Jas.Op_log.transaction) =
    let ops = String.concat "," (List.map op_json t.Jas.Op_log.ops) in
    Printf.sprintf "{\"name\":%s,\"ops\":[%s]}" (opt t.Jas.Op_log.name) ops
  in
  "[" ^ String.concat "," (List.map txn_json journal) ^ "]"

(* Canonical JSON of an evaluated [polygon_set] (a list of rings, each an array
   of (x,y) points), using the SAME fixed-float canonicalization as
   [document_to_test_json] so the re-derived geometry golden is byte-shareable.
   Mirrors the Rust [polygon_set_to_test_json]. *)
let polygon_set_to_test_json (ps : Jas.Boolean.polygon_set) : string =
  let pt_json (x, y) =
    Printf.sprintf "[%s,%s]"
      (Jas.Test_json.canonical_value (`Float x))
      (Jas.Test_json.canonical_value (`Float y)) in
  let ring_json ring =
    "[" ^ String.concat "," (Array.to_list (Array.map pt_json ring)) ^ "]" in
  "[" ^ String.concat "," (List.map ring_json ps) ^ "]"

(* Build the fresh Model a production-capture fixture's [setup_svg] defines. *)
let production_model (fixture : Yojson.Safe.t) : Jas.Model.model =
  let open Yojson.Safe.Util in
  let setup_svg = read_fixture (fixture |> member "setup_svg" |> to_string) in
  Jas.Model.create ~document:(Jas.Svg.svg_to_document setup_svg) ()

(* Run every [run_effects] batch a production-capture fixture defines through the
   REAL production interpreter, stamping the fixture's [action_name]. Supports
   both fixture shapes: [effect_batch] (ONE run_effects call) and [frames]
   (MULTIPLE separate run_effects calls — the drag-frame-hole closure). Each
   batch threads the Model as owner so it commits its own named transaction.
   Mirrors the Rust [run_production_batches]. *)
let run_production_batches (fixture : Yojson.Safe.t) (model : Jas.Model.model) =
  let open Yojson.Safe.Util in
  let action_name = match fixture |> member "action_name" with
    | `String s -> Some s | _ -> None in
  let ctrl = Jas.Controller.create ~model () in
  let store = Jas.State_store.create () in
  let platform_effects = Jas.Yaml_tool_effects.build ctrl in
  let run_batch effects =
    Jas.Effects.run_effects ~platform_effects
      ~owner_model:(Some model) ~action_name effects [] store in
  match fixture |> member "effect_batch" with
  | `List effects -> run_batch effects
  | _ ->
    (match fixture |> member "frames" with
     | `List frames ->
       List.iter (fun frame -> run_batch (to_list frame)) frames
     | _ ->
       failwith "production-capture fixture has neither effect_batch nor frames")

(* Re-derive the recorded element's output against the EDITED source and return
   its canonical polygon-set JSON. Lifts the LAST committed transaction's op
   segment, runs [capture_recipe] to normalize it into an input-addressed
   recipe, wraps it in a recorded element, then evaluates it over a resolver
   that returns the EDITED source (the fixture's [recorded.edit_source] applies
   a textual SVG edit). The SVG px->pt conversion (96/72 = x0.75) bakes into the
   re-derived bbox: editing the source [eye] to x=100 (px) maps to x=75 (pt)
   with w=10px->7.5pt; copy(dx=0)+translate(+50) -> the derived bbox spans x in
   [125, 132.5] (pt). Mirrors the Rust [rederive_recorded_output]. *)
let rederive_recorded_output
    (fixture : Yojson.Safe.t) (journal : Jas.Op_log.transaction list) : string =
  let open Yojson.Safe.Util in
  let segment = (List.nth journal (List.length journal - 1)).Jas.Op_log.ops in
  (* Convert the journal segment (primitive_op list) into the recorded_op list
     [capture_recipe] consumes. *)
  let recorded_ops =
    List.map (fun (o : Jas.Op_log.primitive_op) ->
      { Jas.Element.rop_op = o.Jas.Op_log.op;
        rop_params = o.Jas.Op_log.params;
        rop_targets = o.Jas.Op_log.targets }) segment in
  let (recipe, inputs) = Jas.Live.capture_recipe recorded_ops in
  let recorded_el =
    Jas.Element.make_recorded ~id:(Some "rec") recipe inputs in
  let rec_ = match recorded_el with
    | Jas.Element.Live (Jas.Element.Recorded r) -> r
    | _ -> failwith "make_recorded did not yield a recorded element" in
  (* Apply the fixture's edit to the source SVG, parse, and resolve the edited
     element by id. Mirror the effects proof's textual edit (replace
     x="0" y="0" -> x="100" y="0") so the parse is identical to Rust. *)
  let rec_spec = fixture |> member "recorded" in
  let edit = rec_spec |> member "edit_source" in
  let edit_id = edit |> member "id" |> to_string in
  let new_x = edit |> member "set" |> member "x" |> to_int in
  let setup_svg = read_fixture (fixture |> member "setup_svg" |> to_string) in
  let edited_svg =
    Str.global_replace (Str.regexp_string "x=\"0\" y=\"0\"")
      (Printf.sprintf "x=\"%d\" y=\"0\"" new_x) setup_svg in
  let edited_doc = Jas.Svg.svg_to_document edited_svg in
  (* The edited source is layers.(0) children.(0). *)
  let edited_el = Jas.Document.get_element edited_doc [0; 0] in
  let resolver : Jas.Live.element_resolver =
    fun (r : Jas.Element.element_ref) ->
      if r = edit_id then Some edited_el else None in
  let visiting = ref Jas.Live.VisitSet.empty in
  let ps =
    Jas.Live.recorded_evaluate rec_ Jas.Live.default_precision resolver visiting in
  polygon_set_to_test_json ps

(* Reusable production-capture harness (OP_LOG.md section 9, Increment 3b-B).
   Loads the fixture, drives the REAL [run_effects] over [setup_svg], then
   asserts: (a) journal == golden; (b) checkpoint_equivalence replay (replaying
   the journal ops via [op_apply] from [setup_svg] is byte-identical BOTH to the
   document golden AND to the live snapshot-path document); (c) the recorded
   re-derivation (when declared) == golden; (d) a SCOPED completeness assert:
   EVERY committed production transaction's [ops] is non-empty. Mirrors the Rust
   [run_production_batch_fixture]. *)
let run_production_batch_fixture (fixture_path : string) =
  let open Yojson.Safe.Util in
  let fx = Yojson.Safe.from_string (read_fixture fixture_path) in
  let name = match fx |> member "name" with
    | `String s -> s | _ -> fixture_path in

  (* Drive the REAL production interpreter. *)
  let model = production_model fx in
  run_production_batches fx model;

  (* (a) journal serialization == golden. *)
  let actual_journal = production_journal_to_test_json model#journal in
  let expected_journal =
    read_fixture (fx |> member "expected_journal_json" |> to_string) in
  if actual_journal <> expected_journal then begin
    Printf.eprintf "=== EXPECTED journal (%s) ===\n%s\n" name expected_journal;
    Printf.eprintf "=== ACTUAL journal (%s) ===\n%s\n" name actual_journal;
    assert false
  end;

  (* Snapshot-path document (the live result of run_effects). *)
  let snapshot_doc = Jas.Test_json.document_to_test_json model#document in

  (* (b) checkpoint_equivalence: replay the WHOLE journal via op_apply from a
     fresh setup, byte-compare to BOTH the expected_document golden AND the live
     snapshot-path document. *)
  let replay = production_model fx in
  let replay_ctrl = Jas.Controller.create ~model:replay () in
  List.iter (fun (txn : Jas.Op_log.transaction) ->
    List.iter (fun (op : Jas.Op_log.primitive_op) ->
      Jas.Op_apply.op_apply replay replay_ctrl op.Jas.Op_log.params
    ) txn.Jas.Op_log.ops
  ) model#journal;
  let replay_doc = Jas.Test_json.document_to_test_json replay#document in
  let expected_doc =
    read_fixture (fx |> member "expected_document_json" |> to_string) in
  if replay_doc <> snapshot_doc then begin
    Printf.eprintf "=== checkpoint_equivalence GATE FAILED (%s) ===\n" name;
    Printf.eprintf "--- snapshot path ---\n%s\n" snapshot_doc;
    Printf.eprintf "--- journal replay ---\n%s\n" replay_doc;
    assert false
  end;
  if replay_doc <> expected_doc then begin
    Printf.eprintf "=== EXPECTED doc (%s) ===\n%s\n" name expected_doc;
    Printf.eprintf "=== ACTUAL doc (%s) ===\n%s\n" name replay_doc;
    assert false
  end;

  (* (c) recorded re-derivation against the edited source == golden. *)
  (match fx |> member "recorded" with
   | `Null -> ()
   | rec_spec ->
     let actual_out = rederive_recorded_output fx model#journal in
     let expected_out =
       read_fixture (rec_spec |> member "expected_output_json" |> to_string) in
     if actual_out <> expected_out then begin
       Printf.eprintf "=== EXPECTED rederived (%s) ===\n%s\n" name expected_out;
       Printf.eprintf "=== ACTUAL rederived (%s) ===\n%s\n" name actual_out;
       assert false
     end);

  (* (d) scoped completeness assert: every committed production transaction
     emits ops (the production path here is NOT named-but-op-less). *)
  assert (model#journal <> []);
  List.iteri (fun i (txn : Jas.Op_log.transaction) ->
    if txn.Jas.Op_log.ops = [] then begin
      Printf.eprintf
        "production txn %d emits no ops (3b-B completeness, %s)\n" i name;
      assert false
    end
  ) model#journal

let production_capture_eye_demo () =
  run_production_batch_fixture "production_capture/eye_demo.json"

let production_capture_eye_demo_bare_frame () =
  run_production_batch_fixture "production_capture/eye_demo_bare_frame.json"

(* ------------------------------------------------------------------ *)
(* Per-frame drag coalescing (OP_LOG.md section 9 follow-up). A live drag commits
   ONE transaction PER FRAME (selection.yaml fires doc.snapshot only on the first
   mousemove; each on_mousemove is its own run_effects batch that begin_txns +
   commits), so a drag of N frames lands as N consecutive single-op move
   transactions in the journal — and N undo steps. [Model.commit_txn] coalesces
   ADJACENT same-gesture move transactions (move_selection / move_by_ids) into ONE
   summed-delta translate, collapsing the N undo steps into one. The txns-form
   below commits each frame SEPARATELY, so the SECOND commit triggers coalescing
   into the first. Mirrors the Rust [drag_coalesce*] tests. *)
(* ------------------------------------------------------------------ *)

(* The dx/dy of a journal transaction's LAST op (the move being summed). *)
let last_op_delta (txn : Jas.Op_log.transaction) : float * float =
  let op = match List.rev txn.Jas.Op_log.ops with
    | op :: _ -> op
    | [] -> failwith "txn has at least one op" in
  let num key = match op.Jas.Op_log.params with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> 0.0)
    | _ -> 0.0 in
  (num "dx", num "dy")

(* The journal tip (last transaction). *)
let journal_tip (model : Jas.Model.model) : Jas.Op_log.transaction =
  match List.rev model#journal with
  | t :: _ -> t
  | [] -> failwith "expected a tip txn"

(* Build + drive a coalescing fixture case (txns-form, each frame committed
   separately) and assert the post-coalesce journal shape + undo-step lock-step:
    - the journal collapsed to [expect_journal_txns] transactions;
    - the tip txn op list is [expect_journal_ops] long (when declared);
    - the tip txn last move op carries the SUMMED delta (when declared);
    - the undo stack and journal cursor are in lock-step ([journal_head] ==
      [expect_undo_steps]), and undoing exactly that many times drains both back
      to the origin ([can_undo] false, [journal_head] = 0) — i.e. ONE undo
      reverts a whole coalesced drag. Mirrors the Rust [assert_drag_coalesce]. *)
let assert_drag_coalesce (tc : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let name = tc |> member "name" |> to_string in
  let setup_svg_file = tc |> member "setup_svg" |> to_string in
  let svg = read_fixture (Printf.sprintf "svg/%s" setup_svg_file) in
  let doc = Jas.Svg.svg_to_document svg in
  let model = Jas.Model.create ~document:doc () in
  let ctrl = Jas.Controller.create ~model () in
  (* Commit each frame as its own transaction (the live drag shape). *)
  List.iter (fun txn ->
    model#begin_txn;
    (match txn |> member "name" with
     | `Null -> () | n -> model#name_txn (to_string n));
    List.iter (fun op -> apply_op model ctrl op) (txn |> member "ops" |> to_list);
    model#commit_txn
  ) (tc |> member "txns" |> to_list);

  let expect_txns = tc |> member "expect_journal_txns" |> to_int in
  let got_txns = List.length model#journal in
  if got_txns <> expect_txns then
    failwith (Printf.sprintf
      "[%s] journal txn count: expected %d, got %d" name expect_txns got_txns);

  (match tc |> member "expect_journal_ops" with
   | `Null -> ()
   | v ->
     let ops = to_int v in
     let tip_ops = List.length (journal_tip model).Jas.Op_log.ops in
     if tip_ops <> ops then
       failwith (Printf.sprintf
         "[%s] tip txn op count: expected %d, got %d" name ops tip_ops));

  (match tc |> member "expect_last_move_dx" with
   | `Null -> ()
   | v ->
     let dx = to_number v in
     let dy = match tc |> member "expect_last_move_dy" with
       | `Null -> 0.0 | w -> to_number w in
     let gdx, gdy = last_op_delta (journal_tip model) in
     if (gdx, gdy) <> (dx, dy) then
       failwith (Printf.sprintf
         "[%s] summed delta: expected (%g,%g), got (%g,%g)"
         name dx dy gdx gdy));

  (* Undo-step lock-step: journal cursor == undo depth == declared steps. *)
  let steps = tc |> member "expect_undo_steps" |> to_int in
  if model#journal_head <> steps then
    failwith (Printf.sprintf
      "[%s] journal_head (== undo steps): expected %d, got %d"
      name steps model#journal_head);
  for i = 0 to steps - 1 do
    if not model#can_undo then
      failwith (Printf.sprintf "[%s] expected to undo step %d" name i);
    model#undo
  done;
  if model#can_undo then
    failwith (Printf.sprintf
      "[%s] after %d undos the undo stack must be empty (lock-step)" name steps);
  if model#journal_head <> 0 then
    failwith (Printf.sprintf
      "[%s] after %d undos the journal cursor must be at the origin" name steps)

(* (a)/(c)-twin coalescing pins + (c)-via-name/copy break pins, driven from the
   shared [drag_coalesce.json] fixture (txns-form, cross-language). Mirrors the
   Rust [drag_coalesce] test. *)
let drag_coalesce () =
  let json_str = read_fixture "operations/drag_coalesce.json" in
  let tests = Yojson.Safe.Util.to_list (Yojson.Safe.from_string json_str) in
  List.iter assert_drag_coalesce tests

(* A single move op as a Yojson value (the apply_op payload). *)
let move_op dx dy : Yojson.Safe.t =
  `Assoc [("op", `String "move_selection"); ("dx", `Int dx); ("dy", `Int dy)]

(* NET-ZERO whole-drag: a same-name same-target run that sums to (0,0) AND
   round-trips the document leaves NO journal entry and NO undo step. The
   selection is pre-established OUT OF BAND (non-undoable [select_rect], journaling
   nothing) so the two move frames are the ONLY journaled transactions — and after
   the net-zero drop the journal is genuinely EMPTY and the document is
   byte-identical to pre-drag. Mirrors the Rust [drag_coalesce_net_zero]. *)
let drag_coalesce_net_zero () =
  let svg = read_fixture "svg/eye.svg" in
  let model = Jas.Model.create ~document:(Jas.Svg.svg_to_document svg) () in
  let ctrl = Jas.Controller.create ~model () in
  (* Pre-select the eye out of band (no journal entry, no undo step). *)
  ctrl#select_rect ~extend:false (-5.0) (-5.0) 55.0 55.0;
  let pre_drag = Jas.Test_json.document_to_test_json model#document in
  assert (model#journal = []);
  assert (not model#can_undo);
  (* Frame 1: move dx:5 (commits one txn into the empty journal). *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op 5 0);
  model#commit_txn;
  assert (List.length model#journal = 1);
  assert model#can_undo;
  (* Frame 2: move dx:-5 (same name, same target) -> net (0,0) round-trip. *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op (-5) 0);
  model#commit_txn;
  if model#journal <> [] then
    failwith (Printf.sprintf
      "net-zero whole-drag must leave NO journal entry, got %d txns"
      (List.length model#journal));
  assert (model#journal_head = 0);
  assert (not model#can_undo);
  if Jas.Test_json.document_to_test_json model#document <> pre_drag then
    failwith "net-zero whole-drag must restore the pre-drag document byte-for-byte"

(* Build a single-element selection at [path] (out of band). *)
let select_path (ctrl : Jas.Controller.controller) (path : int list) =
  let es = Jas.Document.element_selection_all path in
  ctrl#set_selection (Jas.Document.PathMap.singleton path es)

(* TARGET break (predicate c proper): two ADJACENT single-op move frames whose
   target sets differ do NOT coalesce. The selection is changed OUT OF BAND
   between the frames (so each frame is a single-op move txn, isolating the
   target-mismatch predicate from the op-count predicate), proving the run breaks
   and stays TWO distinct undo steps. Mirrors the Rust
   [drag_coalesce_target_break]. *)
let drag_coalesce_target_break () =
  let svg = read_fixture "svg/two_ided_rects.svg" in
  let model = Jas.Model.create ~document:(Jas.Svg.svg_to_document svg) () in
  let ctrl = Jas.Controller.create ~model () in
  (* Select element "a" (path [0;0]) out of band. *)
  select_path ctrl [0; 0];
  (* Frame 1: move "a". *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op 5 0);
  model#commit_txn;
  assert (List.length model#journal = 1);
  assert ((List.nth model#journal 0).Jas.Op_log.ops |> List.hd
          |> fun o -> o.Jas.Op_log.targets = ["a"]);
  (* Change selection to "b" (path [0;1]) out of band — a DIFFERENT target. *)
  select_path ctrl [0; 1];
  (* Frame 2: a single-op move on "b". Same name, same verb, but the target set
     differs ([a] vs [b]) -> predicate (c) fails -> NO coalesce. *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op 7 0);
  model#commit_txn;
  if List.length model#journal <> 2 then
    failwith "different target must NOT coalesce -> two distinct txns";
  assert ((List.nth model#journal 1).Jas.Op_log.ops |> List.hd
          |> fun o -> o.Jas.Op_log.targets = ["b"]);
  assert (model#journal_head = 2);
  let dx0, _ = last_op_delta (List.nth model#journal 0) in
  let dx1, _ = last_op_delta (List.nth model#journal 1) in
  if (dx0, dx1) <> (5.0, 7.0) then
    failwith "deltas stay separate (5 and 7), not summed"

(* TIP guard (predicate [journal_head = List.length op_journal]): a coalescable
   move frame committed AFTER an undo — when the journal cursor sits BEHIND the
   tip ([journal_head < len]) — must NOT merge into the about-to-be-truncated redo
   tail. It must take the normal truncate/append path: the redo tail is discarded
   and the new frame lands as its OWN txn with its OWN delta (never summed into
   the stale tail). This is the ONLY test that drives [commit_txn] with
   [journal_head < len] for a coalescable move, so it is the sole signal for the
   TIP guard. Mirrors the Rust [drag_coalesce_post_undo_no_merge]. *)
let drag_coalesce_post_undo_no_merge () =
  let svg = read_fixture "svg/two_ided_rects.svg" in
  let model = Jas.Model.create ~document:(Jas.Svg.svg_to_document svg) () in
  let ctrl = Jas.Controller.create ~model () in
  (* Select element "a" (path [0;0]) out of band (no journal entry). *)
  select_path ctrl [0; 0];
  (* Frame 1: a coalescable move (dx:5). Commits one txn at the tip. *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op 5 0);
  model#commit_txn;
  assert (List.length model#journal = 1);
  assert (model#journal_head = 1);
  (* Undo frame 1: cursor moves BEHIND the tip (journal_head 0 < len 1) and a
     redo entry is staged. This is the guard's scenario. *)
  model#undo;
  assert (model#journal_head = 0);
  assert (List.length model#journal = 1);
  assert model#can_redo;
  (* Frame 2: a SAME name / SAME target / SAME verb coalescable move (dx:11) —
     every predicate holds EXCEPT the TIP guard, which fails (journal_head 0 !=
     len 1). So it must NOT coalesce: the normal path truncates the redo tail and
     appends frame 2 as its own txn. *)
  model#begin_txn;
  model#name_txn "selection on_mousemove";
  apply_op model ctrl (move_op 11 0);
  model#commit_txn;
  if List.length model#journal <> 1 then
    failwith
      "post-undo frame must truncate+append (one txn), NOT merge into the redo tail";
  assert (model#journal_head = 1);
  assert (not model#can_redo);
  (* The decisive guard signal: the surviving txn carries frame 2's delta ALONE
     (11), never frame 1's (5) summed in (16). *)
  let dx, _ = last_op_delta (List.nth model#journal 0) in
  if dx <> 11.0 then
    failwith
      "surviving txn carries frame 2 delta alone (11), not summed with the \
       discarded tail (would be 16) — proves the TIP guard blocked the merge";
  model#undo;
  assert (model#journal_head = 0);
  assert (not model#can_undo)

(* 3c-1 determinism check (OP_LOG.md section 7): an id-primary op reads its
   operand ids from its OWN params, NEVER from doc.selection, so it applies the
   SAME operands regardless of the ambient selection. Drive [move_by_ids{["eye"]}]
   with a DELIBERATELY WRONG ambient selection (the whole top-level layer
   pre-selected) and confirm the result still equals the shared golden — i.e. the
   op ignored the ambient selection and moved exactly the operand named in its
   params. Then confirm snapshot==replay even though the snapshot ran with a
   poisoned ambient selection: the journaled ops carry their own operands, so a
   fresh replay (no ambient selection) reproduces the document byte-identically.
   Mirrors the Rust [id_primary_move_reads_operand_from_params_not_selection]. *)
let id_primary_move_reads_operand_from_params () =
  let setup_svg = read_fixture "svg/eye.svg" in
  let doc = Jas.Svg.svg_to_document setup_svg in
  let model = Jas.Model.create ~document:doc () in
  let ctrl = Jas.Controller.create ~model () in
  (* Poison the ambient selection with an unrelated path — an op that inferred
     its operand from doc.selection would act on the wrong thing. *)
  ctrl#set_selection
    (Jas.Document.PathMap.singleton [0]
       (Jas.Document.element_selection_all [0]));
  model#begin_txn;
  apply_op model ctrl
    (`Assoc [ ("op", `String "select_by_ids");
              ("ids", `List [ `String "eye" ]) ]);
  apply_op model ctrl
    (`Assoc [ ("op", `String "move_by_ids");
              ("ids", `List [ `String "eye" ]);
              ("dx", `Int 50); ("dy", `Int 0) ]);
  model#commit_txn;
  let actual = Jas.Test_json.document_to_test_json model#document in
  let expected =
    String.trim (read_fixture "operations/id_primary_move_eye.json") in
  if actual <> expected then begin
    Printf.eprintf
      "=== id-primary move read operand from selection, not params ===\n";
    Printf.eprintf "=== EXPECTED ===\n%s\n=== ACTUAL ===\n%s\n" expected actual;
    assert false
  end;
  (* Snapshot==replay even with a poisoned ambient selection at snapshot time. *)
  let replayed = replay_journal setup_svg model#journal model#journal_head in
  if replayed <> actual then begin
    Printf.eprintf
      "=== id-primary determinism: snapshot != replay ===\n";
    Printf.eprintf "=== SNAPSHOT ===\n%s\n=== REPLAY ===\n%s\n" actual replayed;
    assert false
  end

(* 3c-1 EYE-DEMO RE-DERIVATION PIN (the load-bearing payoff): run a FAITHFUL
   id-primary journal segment [select_by_ids, copy_by_ids] through the SHARED
   dispatcher (so it is a real, byte-gated, replayable journal segment),
   normalize the committed segment to a recorded element via the now-pass-through
   [capture_recipe], edit the SOURCE input, re-derive, and confirm the output
   TRACKS the edited source. The recipe survives source edits with NO selection
   dependency — the operand ids came from the op params ([from:["eye"]]), never
   from a select op-resolved selection. Reuses the existing eye-demo golden
   (production_capture/eye_demo_rederived.json): copy_by_ids{dx:50} captures to
   copy{dx:50}, whose re-derivation against the edited source (eye -> x=100 px)
   is byte-identical to the selection-relative demo's copy(0)+translate(50) net
   offset. Mirrors the Rust [id_primary_capture_recipe_rederives_on_source_edit]. *)
let id_primary_capture_recipe_rederives_on_source_edit () =
  (* A faithful id-primary demonstration: select the eye, copy it +50. This is a
     REAL journal segment op_apply replays byte-identically (the id_primary_copy
     fixture's id-primary case). *)
  let setup_svg = read_fixture "svg/eye.svg" in
  let doc = Jas.Svg.svg_to_document setup_svg in
  let model = Jas.Model.create ~document:doc () in
  let ctrl = Jas.Controller.create ~model () in
  model#begin_txn;
  model#name_txn "id-primary demo";
  apply_op model ctrl
    (`Assoc [ ("op", `String "select_by_ids");
              ("ids", `List [ `String "eye" ]) ]);
  apply_op model ctrl
    (`Assoc [ ("op", `String "copy_by_ids");
              ("from", `List [ `String "eye" ]);
              ("dx", `Int 50); ("dy", `Int 0) ]);
  model#commit_txn;
  (* [capture_recipe] is a PASS-THROUGH over the id-primary segment: it reads the
     operand id from the op-OWN [from] PARAM (no selection dependency —
     select_by_ids targets are NOT consulted). *)
  let segment =
    (List.nth model#journal (List.length model#journal - 1)).Jas.Op_log.ops in
  (* Guard: the captured segment is purely id-primary (proves the brittle
     selection-relative bridge is NOT on this path). *)
  List.iter (fun (o : Jas.Op_log.primitive_op) ->
    match o.Jas.Op_log.op with
    | "select_by_ids" | "copy_by_ids" -> ()
    | other -> Printf.eprintf "segment is id-primary, got %s\n" other;
      assert false
  ) segment;
  let recorded_ops =
    List.map (fun (o : Jas.Op_log.primitive_op) ->
      { Jas.Element.rop_op = o.Jas.Op_log.op;
        rop_params = o.Jas.Op_log.params;
        rop_targets = o.Jas.Op_log.targets }) segment in
  let (recipe, inputs) = Jas.Live.capture_recipe recorded_ops in
  assert (inputs = [ "eye" ]);
  assert (List.length recipe = 1);
  assert ((List.hd recipe).Jas.Element.rop_op = "copy");
  (* Wrap + re-derive against the EDITED source (eye moved to x=100 px). *)
  let recorded_el = Jas.Element.make_recorded ~id:(Some "rec") recipe inputs in
  let rec_ = match recorded_el with
    | Jas.Element.Live (Jas.Element.Recorded r) -> r
    | _ -> failwith "make_recorded did not yield a recorded element" in
  let edited_svg =
    Str.global_replace (Str.regexp_string "x=\"0\" y=\"0\"")
      "x=\"100\" y=\"0\"" setup_svg in
  let edited_doc = Jas.Svg.svg_to_document edited_svg in
  let edited_el = Jas.Document.get_element edited_doc [0; 0] in
  let resolver : Jas.Live.element_resolver =
    fun (r : Jas.Element.element_ref) ->
      if r = "eye" then Some edited_el else None in
  let visiting = ref Jas.Live.VisitSet.empty in
  let ps =
    Jas.Live.recorded_evaluate rec_ Jas.Live.default_precision resolver visiting in
  let actual = polygon_set_to_test_json ps in
  let expected =
    String.trim (read_fixture "production_capture/eye_demo_rederived.json") in
  if actual <> expected then begin
    Printf.eprintf
      "=== id-primary recipe re-derivation failed ===\n";
    Printf.eprintf "=== EXPECTED ===\n%s\n=== ACTUAL ===\n%s\n" expected actual;
    assert false
  end

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

(* Expression-language conformance (shared corpus).
   Loads test_fixtures/expressions/conformance.json (generated from
   workspace/tests/expressions.yaml — the same corpus the Python conformance
   test reads) and asserts this app's evaluator produces the expected result
   type and value for every case. Pins cross-language expression equivalence,
   including the closure lexical-scoping contract. *)
let assert_expression_conformance () =
  let open Yojson.Safe.Util in
  let json_str = read_fixture "expressions/conformance.json" in
  let cases = Yojson.Safe.from_string json_str |> to_list in
  let num_of = function
    | `Int i -> float_of_int i
    | `Float f -> f
    | `Intlit s -> float_of_string s
    | _ -> nan
  in
  let failures = List.filter_map (fun tc ->
    let expr = tc |> member "expr" |> to_string in
    (* Build the eval context from the optional state/data namespaces. *)
    let ns key = match tc |> member key with `Null -> [] | v -> [(key, v)] in
    let ctx = `Assoc (ns "state" @ ns "data") in
    let result = Jas.Expr_eval.evaluate expr ctx in
    let ty = tc |> member "type" |> to_string in
    let expected = tc |> member "expected" in
    let ok = match ty, result with
      | "null", Jas.Expr_eval.Null -> true
      | "bool", Jas.Expr_eval.Bool b -> b = to_bool expected
      | "number", Jas.Expr_eval.Number n -> abs_float (n -. num_of expected) < 1e-9
      | "string", Jas.Expr_eval.Str s -> s = to_string expected
      | "color", Jas.Expr_eval.Color c -> c = to_string expected
      | "list", Jas.Expr_eval.List _ -> true
      | _ -> false
    in
    if ok then None
    else Some (Printf.sprintf "  %s -> expected type %s, got a mismatch" expr ty)
  ) cases in
  if failures <> [] then begin
    Printf.eprintf "expression conformance failures (%d of %d):\n%s\n"
      (List.length failures) (List.length cases) (String.concat "\n" failures);
    assert false
  end

(* Concept-generator conformance (shared corpus).
   Loads test_fixtures/concepts/conformance.json (compiled from
   workspace/concepts/*.yaml + workspace/tests/concepts.yaml). Evaluates each
   concept's generator expression with its params bound under `param` and
   asserts the resulting [x,y] points match the expected geometry (1e-9). A
   generator is just an expression, so this reuses the evaluator. See CONCEPTS.md. *)
let assert_concept_conformance () =
  let open Yojson.Safe.Util in
  let json_str = read_fixture "concepts/conformance.json" in
  let cases = Yojson.Safe.from_string json_str |> to_list in
  let num_of = function
    | `Int i -> float_of_int i
    | `Float f -> f
    | `Intlit s -> float_of_string s
    | _ -> nan
  in
  let failures = ref [] in
  let add s = failures := s :: !failures in
  List.iter (fun tc ->
    let concept = tc |> member "concept" |> to_string in
    let generator = tc |> member "generator" |> to_string in
    let ctx = `Assoc [("param", tc |> member "params")] in
    let result = Jas.Expr_eval.evaluate generator ctx in
    let expected = tc |> member "expected" |> to_list in
    match result with
    | Jas.Expr_eval.List items ->
      if List.length items <> List.length expected then
        add (Printf.sprintf "%s: point count expected %d got %d" concept
               (List.length expected) (List.length items))
      else
        List.iteri (fun i (item, exp) ->
          match item, exp with
          | `List [a; b], `List [ea; eb] ->
            let px, py = num_of a, num_of b in
            let ex, ey = num_of ea, num_of eb in
            if Float.abs (px -. ex) >= 1e-9 || Float.abs (py -. ey) >= 1e-9 then
              add (Printf.sprintf "%s point %d: expected (%g,%g) got (%g,%g)"
                     concept i ex ey px py)
          | _ -> add (Printf.sprintf "%s point %d: not a 2-element point" concept i)
        ) (List.combine items expected)
    | _ -> add (Printf.sprintf "%s: generator returned non-list" concept)
  ) cases;
  if !failures <> [] then begin
    Printf.eprintf "concept conformance failures:\n%s\n"
      (String.concat "\n" (List.rev !failures));
    assert false
  end

(* Concept-fitter conformance (shared corpus).
   Loads test_fixtures/concept_fitters/conformance.json (compiled from
   workspace/concepts/*.yaml + workspace/tests/concept_fitters.yaml). For each
   case, evaluates the concept's `fitter` expression with the case's points bound
   under `shape.points` and asserts the result matches `expected` — `null` for no
   match, else the flat [params..., cx, cy, rotation] list (1e-9). A fitter is the
   dual of the generator and just an expression, so this reuses the evaluator —
   pinning concept DETECTION across all apps (CONCEPTS.md §10). The production
   promote handler runs exactly this and bakes the recovered values into the op. *)
let assert_concept_fitters_conformance () =
  let open Yojson.Safe.Util in
  let json_str = read_fixture "concept_fitters/conformance.json" in
  let cases = Yojson.Safe.from_string json_str |> to_list in
  let num_of = function
    | `Int i -> float_of_int i
    | `Float f -> f
    | `Intlit s -> float_of_string s
    | _ -> nan
  in
  let failures = ref [] in
  let add s = failures := s :: !failures in
  List.iter (fun tc ->
    let concept = tc |> member "concept" |> to_string in
    let fitter = tc |> member "fitter" |> to_string in
    (* Bind the input vertices under `shape.points`, exactly as the production
       promote handler does at detect time. *)
    let ctx = `Assoc [("shape", `Assoc [("points", tc |> member "points")])] in
    let result = Jas.Expr_eval.evaluate fitter ctx in
    match tc |> member "expected" with
    | `Null ->
      (* A no-match case: the fitter must evaluate to Null. *)
      (match result with
       | Jas.Expr_eval.Null -> ()
       | _ -> add (Printf.sprintf "%s: expected no match (null)" concept))
    | expected ->
      let exp = expected |> to_list in
      (match result with
       | Jas.Expr_eval.List items ->
         if List.length items <> List.length exp then
           add (Printf.sprintf "%s: result arity %d != expected %d" concept
                  (List.length items) (List.length exp))
         else
           List.iteri (fun i (g, e) ->
             let gv = num_of g and ev = num_of e in
             if Float.abs (gv -. ev) >= 1e-9 then
               add (Printf.sprintf "%s output[%d]: expected %g got %g"
                      concept i ev gv)
           ) (List.combine items exp)
       | _ -> add (Printf.sprintf "%s: expected a list, got a non-list" concept))
  ) cases;
  if !failures <> [] then begin
    Printf.eprintf "concept-fitter conformance failures:\n%s\n"
      (String.concat "\n" (List.rev !failures));
    assert false
  end

(* The generator and fitter are inverses (CONCEPTS.md §10 — the round-trip
   property). Generate a regular_polygon's vertices from the registry generator,
   feed them back through the SAME concept's fitter, and assert it recovers
   [sides, radius, 0, 0, 0] (canonical placement: origin-centred, first vertex on
   +x => rotation 0). Both expressions are read from the compiled registry, so
   this pins that a concept's two halves agree. Mirrors Rust
   generator_fitter_round_trip. *)
let assert_generator_fitter_round_trip () =
  let open Yojson.Safe.Util in
  let num_of = function
    | `Int i -> float_of_int i | `Float f -> f
    | `Intlit s -> float_of_string s | _ -> nan in
  match Jas.Workspace_loader.load () with
  | None -> failwith "workspace failed to load"
  | Some ws ->
    (match Jas.Workspace_loader.concept ws "regular_polygon" with
     | None -> failwith "regular_polygon concept not registered"
     | Some concept ->
       let generator = concept |> member "generator" |> to_string in
       let fitter = concept |> member "fitter" |> to_string in
       List.iter (fun (sides, radius) ->
         (* Generate the canonical points. *)
         let gctx = `Assoc [("param",
           `Assoc [("sides", `Float sides); ("radius", `Float radius)])] in
         let pts = match Jas.Expr_eval.evaluate generator gctx with
           | Jas.Expr_eval.List items -> `List items
           | _ -> Printf.ksprintf failwith "generator non-list for sides=%g" sides in
         (* Fit them back. *)
         let fctx = `Assoc [("shape", `Assoc [("points", pts)])] in
         let recovered = match Jas.Expr_eval.evaluate fitter fctx with
           | Jas.Expr_eval.List items -> List.map num_of items
           | _ -> Printf.ksprintf failwith "fitter non-list for sides=%g" sides in
         let expected = [ sides; radius; 0.0; 0.0; 0.0 ] in
         if List.length recovered <> List.length expected then
           Printf.ksprintf failwith "round-trip sides=%g arity %d != %d" sides
             (List.length recovered) (List.length expected);
         List.iteri (fun i (g, e) ->
           if Float.abs (g -. e) >= 1e-9 then
             Printf.ksprintf failwith
               "round-trip sides=%g radius=%g output[%d]: expected %g got %g"
               sides radius i e g
         ) (List.combine recovered expected)
       ) [ (6.0, 50.0); (4.0, 10.0); (5.0, 25.0) ])

(* CONCEPTS.md §10 — promote_to_concept journals + replays byte-identically.
   Every operand is value-in-op (the detection ran at production time): the
   concept id, the recovered params, and the placement transform are baked into
   the op, so replay rebuilds the SAME Generated element that replaced the raw
   polygon — the checkpoint_equivalence gate for the promote verb. Mirrors Rust
   operation_promote_to_concept_replay_is_deterministic. *)
let assert_promote_to_concept_replay () =
  let svg = read_fixture "svg/polygon_basic.svg" in
  let model = Jas.Model.create ~document:(Jas.Svg.svg_to_document svg) () in
  let ctrl = Jas.Controller.create ~model () in
  model#begin_txn;
  model#name_txn "promote_to_concept";
  apply_op model ctrl (`Assoc [
    ("op", `String "promote_to_concept");
    ("path", `List [ `Int 0; `Int 0 ]);
    ("concept_id", `String "regular_polygon");
    ("params", `Assoc [ ("sides", `Float 3.0); ("radius", `Float 50.0) ]);
    ("transform", `List [ `Float 1.0; `Float 0.0; `Float 0.0; `Float 1.0;
                          `Float 48.0; `Float 32.0 ]);
  ]);
  model#commit_txn;

  let live = Jas.Test_json.document_to_test_json model#document in
  (* The raw polygon was promoted to a Generated instance. *)
  let contains needle = (try ignore (Str.search_forward (Str.regexp_string needle) live 0); true
    with Not_found -> false) in
  assert (contains "regular_polygon");
  assert (contains "generated");

  let head = model#journal_head in
  let replay1 = replay_journal svg model#journal head in
  let replay2 = replay_journal svg model#journal head in
  assert (replay1 = replay2);
  if replay1 <> live then begin
    Printf.eprintf "=== promote_to_concept replay != snapshot ===\n";
    Printf.eprintf "=== SNAPSHOT ===\n%s\n=== REPLAY ===\n%s\n" live replay1;
    assert false
  end

(* Concept-operation conformance (shared corpus).
   Loads test_fixtures/concept_operations/conformance.json (compiled from
   workspace/concepts/*.yaml + workspace/tests/concept_operations.yaml). For each
   case, binds the params under `param` and evaluates each set[name] expression,
   asserting the resolved value matches expected[name] (1e-9). An operation's
   effect is just expression evaluation, so this reuses the evaluator — pinning
   concept-operation RESOLUTION across all apps (CONCEPTS.md §9). The production
   handler bakes exactly these resolved changes into the op (value-in-op), so the
   gate also pins what gets journaled. *)
let assert_concept_operations_conformance () =
  let open Yojson.Safe.Util in
  let json_str = read_fixture "concept_operations/conformance.json" in
  let cases = Yojson.Safe.from_string json_str |> to_list in
  let failures = ref [] in
  let add s = failures := s :: !failures in
  List.iter (fun tc ->
    let concept = tc |> member "concept" |> to_string in
    let op = tc |> member "op" |> to_string in
    (* Bind the current params under the `param` namespace (the generator's
       namespace), exactly as the production handler does at resolve time. *)
    let ctx = `Assoc [("param", tc |> member "params")] in
    let set = tc |> member "set" |> to_assoc in
    let expected = tc |> member "expected" in
    List.iter (fun (name, expr_v) ->
      let src = to_string expr_v in
      match Jas.Expr_eval.evaluate src ctx with
      | Jas.Expr_eval.Number got ->
        let want = match expected |> member name with
          | `Int i -> float_of_int i
          | `Float f -> f
          | `Intlit s -> float_of_string s
          | _ -> Printf.ksprintf failwith "%s/%s: expected has no %s" concept op name in
        if Float.abs (got -. want) >= 1e-9 then
          add (Printf.sprintf "%s/%s param %s: expected %g got %g"
                 concept op name want got)
      | _ ->
        add (Printf.sprintf "%s/%s param %s: non-numeric result" concept op name)
    ) set
  ) cases;
  if !failures <> [] then begin
    Printf.eprintf "concept-operation conformance failures:\n%s\n"
      (String.concat "\n" (List.rev !failures));
    assert false
  end

(* Concept-constraint conformance (shared corpus).
   Loads test_fixtures/concept_constraints/conformance.json (compiled from
   workspace/concepts/*.yaml + workspace/tests/concept_constraints.yaml). For each
   case, evaluates each constraint `check` expression with the case params bound
   under `param` and collects the constraints whose result is NOT truthy
   (Expr_eval.to_bool, the same truthiness `if` uses) — the violations, in
   declared order — then asserts they match `expected`. A constraint is just a
   boolean expression, so this reuses the evaluator — pinning concept CHECKING
   across all apps (CONCEPTS.md §11). Checking is advisory plus read-only (no
   op-log verb). *)
let assert_concept_constraints_conformance () =
  let open Yojson.Safe.Util in
  let json_str = read_fixture "concept_constraints/conformance.json" in
  let cases = Yojson.Safe.from_string json_str |> to_list in
  let failures = ref [] in
  let add s = failures := s :: !failures in
  List.iter (fun tc ->
    let concept = tc |> member "concept" |> to_string in
    (* Bind the params under the `param` namespace, exactly as the production
       checker does at render time. *)
    let ctx = `Assoc [("param", tc |> member "params")] in
    let constraints = tc |> member "constraints" |> to_list in
    let violated = List.filter_map (fun c ->
      let check = c |> member "check" |> to_string in
      if Jas.Expr_eval.to_bool (Jas.Expr_eval.evaluate check ctx) then None
      else Some (c |> member "id" |> to_string)) constraints in
    let expected = tc |> member "expected" |> to_list |> List.map to_string in
    if violated <> expected then
      add (Printf.sprintf "%s: expected violations [%s], got [%s]" concept
             (String.concat "; " expected) (String.concat "; " violated))
  ) cases;
  if !failures <> [] then begin
    Printf.eprintf "concept-constraint conformance failures:\n%s\n"
      (String.concat "\n" (List.rev !failures));
    assert false
  end

(* Concept registry (increment 3a): the concept packs are bundled into
   workspace.json and loadable via Workspace_loader. See CONCEPTS.md §6/§7. *)
let assert_concept_registry () =
  let open Yojson.Safe.Util in
  match Jas.Workspace_loader.load () with
  | None -> failwith "workspace failed to load"
  | Some ws ->
    (match Jas.Workspace_loader.concept ws "gear" with
     | None -> failwith "gear concept not registered"
     | Some gear ->
       assert (gear |> member "closed" |> to_bool = true);
       assert (String.length (gear |> member "generator" |> to_string) > 0));
    assert (Jas.Workspace_loader.concept ws "no_such_concept" = None);
    (* Registry -> evaluator round-trip: the bundled generator yields geometry. *)
    (match Jas.Workspace_loader.concept ws "regular_polygon" with
     | None -> failwith "regular_polygon not registered"
     | Some poly ->
       let g = poly |> member "generator" |> to_string in
       let ctx = `Assoc [("param", `Assoc [("sides", `Int 4); ("radius", `Int 10)])] in
       match Jas.Expr_eval.evaluate g ctx with
       | Jas.Expr_eval.List items -> assert (List.length items = 4)
       | _ -> failwith "generator did not return a list")

(* A Generated element evaluates through a concept_resolver to the concept's
   geometry (CONCEPTS.md 3b). Mirrors the Rust generated_evaluates_via_concept_resolver. *)
let assert_generated_element_evaluates () =
  let generator =
    "map(range(0, param.sides), fun i -> \
     let a = 360 * i / param.sides in \
     [param.radius * cos(a), param.radius * sin(a)])"
  in
  let num = function `Float f -> f | `Int i -> float_of_int i | _ -> nan in
  let concept_resolver : Jas.Live.concept_resolver = fun id ->
    if id = "regular_polygon" then
      Some (fun params ->
        match Jas.Expr_eval.evaluate generator (`Assoc [ ("param", params) ]) with
        | Jas.Expr_eval.List items ->
          List.filter_map (function `List [ a; b ] -> Some (num a, num b) | _ -> None) items
        | _ -> [])
    else None
  in
  let gen : Jas.Element.generated_elem =
    let open Jas.Element in
    { gen_concept_id = "regular_polygon";
      gen_params = `Assoc [ ("sides", `Int 4); ("radius", `Int 10) ];
      gen_fill = None; gen_stroke = None; gen_id = None; gen_transform = None;
      gen_opacity = 1.0; gen_locked = false; gen_visibility = Preview;
      gen_blend_mode = Normal; gen_mask = None }
  in
  let ps = Jas.Live.generated_evaluate gen 0.1 concept_resolver in
  assert (List.length ps = 1);
  let ring = List.hd ps in
  assert (Array.length ring = 4);
  let (x0, y0) = ring.(0) in
  assert (Float.abs (x0 -. 10.0) < 1e-9 && Float.abs y0 < 1e-9);
  (* Unknown concept (null resolver) -> empty, never a failure. *)
  assert (Jas.Live.generated_evaluate gen 0.1 Jas.Live.null_concept_resolver = [])

let () =
  Alcotest.run "Cross_language" [
    (* Expression-language conformance (shared corpus) *)
    "Expression conformance", [
      Alcotest.test_case "expression_conformance all cases" `Quick
        assert_expression_conformance;
    ];

    (* Concept-generator conformance (shared corpus) *)
    "Concept conformance", [
      Alcotest.test_case "concept_conformance all cases" `Quick
        assert_concept_conformance;
    ];

    (* Concept-operation conformance (shared corpus) — CONCEPTS.md §9 *)
    "Concept operations conformance", [
      Alcotest.test_case "concept_operations_conformance all cases" `Quick
        assert_concept_operations_conformance;
    ];

    (* Concept-fitter conformance (shared corpus) + round-trip + replay —
       CONCEPTS.md §10 (the fitter / promote). *)
    "Concept fitters conformance", [
      Alcotest.test_case "concept_fitters_conformance all cases" `Quick
        assert_concept_fitters_conformance;
      Alcotest.test_case "generator_fitter_round_trip" `Quick
        assert_generator_fitter_round_trip;
      Alcotest.test_case "promote_to_concept replay is deterministic" `Quick
        assert_promote_to_concept_replay;
    ];

    (* Concept-constraint conformance (shared corpus) — CONCEPTS.md §11 *)
    "Concept constraints conformance", [
      Alcotest.test_case "concept_constraints_conformance all cases" `Quick
        assert_concept_constraints_conformance;
    ];

    (* Concept registry: concepts load from workspace.json (increment 3a) *)
    "Concept registry", [
      Alcotest.test_case "concept_registry loads + evaluates" `Quick
        assert_concept_registry;
    ];

    (* Generated element evaluation (CONCEPTS.md 3b) *)
    "Generated element", [
      Alcotest.test_case "generated_element evaluates via concept_resolver" `Quick
        assert_generated_element_evaluates;
    ];

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
      (* OP_LOG.md section 10 item 4: the journal metadata serializes
         byte-identically across apps. Both the base metadata fixture and the
         Increment 3a versioning-labels fixture (a [label] on a transaction
         stamps the journal txn via label_version) byte-match their goldens. *)
      Alcotest.test_case "txn_metadata journal" `Quick (fun () ->
        run_journal_metadata "txn_metadata.json");
      Alcotest.test_case "txn_labels journal" `Quick (fun () ->
        run_journal_metadata "txn_labels.json");
      (* OP_LOG Increment 3b (RECORDED_ELEMENTS.md section 8): the recorded
         live element's recipe + inputs serialize byte-identically across the
         four native apps, pinned to operations/recorded_eye.json. *)
      Alcotest.test_case "recorded cross-language" `Quick recorded_cross_language;
      (* Production op-capture (OP_LOG.md section 9, Increment 3b-B): marquee-
         select -> copy -> move driven through the REAL run_effects pins the
         translated journal, the checkpoint-equivalent document, and the live
         re-derivation. The bare-frame variant pins the drag-frame-hole closure
         (two SEPARATE batches, the second a BARE translate with no snapshot,
         both committing NAMED transactions that journal their op). Mirrors the
         Rust + Swift production-capture tests. *)
      Alcotest.test_case "production_capture eye_demo" `Quick
        production_capture_eye_demo;
      Alcotest.test_case "production_capture eye_demo_bare_frame" `Quick
        production_capture_eye_demo_bare_frame;

      (* OP_LOG.md section 9 follow-up: per-frame drag coalescing. The shared
         [drag_coalesce.json] fixture pins the 3-frame collapse + move_by_ids
         twin + break-on-different-name/target/copy; the dedicated tests pin the
         net-zero whole-drag (round-trip drag leaves no journal entry / no undo
         step), the single-op target break (predicate c proper), and the TIP
         guard (a post-undo coalescable frame must not merge into the
         about-to-be-truncated redo tail). Mirror the Rust [drag_coalesce*]. *)
      Alcotest.test_case "drag_coalesce operations" `Quick drag_coalesce;
      Alcotest.test_case "drag_coalesce net-zero whole-drag" `Quick
        drag_coalesce_net_zero;
      Alcotest.test_case "drag_coalesce target break" `Quick
        drag_coalesce_target_break;
      Alcotest.test_case "drag_coalesce post-undo no merge (tip guard)" `Quick
        drag_coalesce_post_undo_no_merge;

      (* OP_LOG.md section 9 verb33 P1-P7 (the actions.yaml<->op_apply
         unification). Each shared source fixture replays through
         [Op_apply.op_apply] and byte-matches the Rust goldens via
         [document_to_test_json] AND the checkpoint_equivalence gate (the
         prime-directive pin). Mirrors the Rust + Swift harness registration. *)
      (* P1 print-config (8 verbs). *)
      Alcotest.test_case "print_config_setters operations" `Quick (fun () ->
        run_operation_fixture "print_config_setters.json");
      (* P2 artboard reorder/field (5 verbs). *)
      Alcotest.test_case "artboard_set_field_batch operations" `Quick (fun () ->
        run_operation_fixture "artboard_set_field_batch.json");
      Alcotest.test_case "artboard_reorder operations" `Quick (fun () ->
        run_operation_fixture "artboard_reorder.json");
      Alcotest.test_case "artboard_delete operations" `Quick (fun () ->
        run_operation_fixture "artboard_delete.json");
      (* P3 artboard create/duplicate (2 verbs, value-in-op id). *)
      Alcotest.test_case "artboard_create operations" `Quick (fun () ->
        run_operation_fixture "artboard_create.json");
      Alcotest.test_case "artboard_duplicate operations" `Quick (fun () ->
        run_operation_fixture "artboard_duplicate.json");
      (* P4 structural tree-mutation (4 verbs, value-in-op element). *)
      Alcotest.test_case "structural_delete_at operations" `Quick (fun () ->
        run_operation_fixture "structural_delete_at.json");
      Alcotest.test_case "structural_delete_selection operations" `Quick (fun () ->
        run_operation_fixture "structural_delete_selection.json");
      Alcotest.test_case "structural_insert_after operations" `Quick (fun () ->
        run_operation_fixture "structural_insert_after.json");
      Alcotest.test_case "structural_insert_at operations" `Quick (fun () ->
        run_operation_fixture "structural_insert_at.json");
      (* P5 group/layer wrapping (3 verbs). *)
      Alcotest.test_case "wrap_in_group operations" `Quick (fun () ->
        run_operation_fixture "wrap_in_group.json");
      Alcotest.test_case "wrap_in_layer operations" `Quick (fun () ->
        run_operation_fixture "wrap_in_layer.json");
      Alcotest.test_case "unpack_group_at operations" `Quick (fun () ->
        run_operation_fixture "unpack_group_at.json");
      (* P6 set_attr_on_selection (brush attrs; no-op hardening). *)
      Alcotest.test_case "set_attr_on_selection operations" `Quick (fun () ->
        run_operation_fixture "set_attr_on_selection.json");
      (* P7 transform trio (scale / rotate / shear) + copy. *)
      Alcotest.test_case "transform_scale operations" `Quick (fun () ->
        run_operation_fixture "transform_scale.json");
      Alcotest.test_case "transform_rotate operations" `Quick (fun () ->
        run_operation_fixture "transform_rotate.json");
      Alcotest.test_case "transform_shear operations" `Quick (fun () ->
        run_operation_fixture "transform_shear.json");
      Alcotest.test_case "transform_copy operations" `Quick (fun () ->
        run_operation_fixture "transform_copy.json");
      (* OP_LOG.md section 5 Fork 4 / 3c-1 — the id-primary op-addressing flip.
         Each fixture carries TWO cases on the SAME eye.svg pointing at ONE shared
         golden: a selection-relative case ([select_rect, move/copy_selection])
         and an id-primary case ([select_by_ids, move/copy_by_ids]). Both must
         produce a BYTE-IDENTICAL document AND selection, which proves the
         id-primary verbs replay to the same document+selection as the
         selection-relative pair (the byte-gate reconciliation). The unchanged
         checkpoint_equivalence gate (run per case by [run_operation_fixture])
         additionally proves each journals a replay-safe segment. The id-primary
         verb reads its operand ids from its OWN params, so snapshot and replay
         apply identical operands (the section 7 determinism rule). Mirrors the
         Rust + Swift id-primary fixture registration. *)
      Alcotest.test_case "id_primary_move operations" `Quick (fun () ->
        run_operation_fixture "id_primary_move.json");
      Alcotest.test_case "id_primary_copy operations" `Quick (fun () ->
        run_operation_fixture "id_primary_copy.json");
      (* 3c-1 determinism: an id-primary op reads its operand from its OWN params,
         never the ambient selection (snapshot==replay even when poisoned). *)
      Alcotest.test_case "id_primary determinism (operand from params)" `Quick
        id_primary_move_reads_operand_from_params;
      (* 3c-1 eye-demo re-derivation pin: an id-primary segment captures as a
         pass-through recipe that re-derives against an edited source with NO
         selection dependency, byte-matching the existing eye-demo golden. *)
      Alcotest.test_case "id_primary capture_recipe re-derives on source edit"
        `Quick id_primary_capture_recipe_rederives_on_source_edit;
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

      (* OP_LOG 3d-2 production-route test: drive a REAL production layout
         handler ([Panel_menu.panel_dispatch] with the hamburger "close_panel"
         command) and assert it both (a) routes through the runtime dispatcher,
         producing the byte-identical corpus serialization, and (b) fires the
         dirty signal ([needs_save] flips). This proves production and the
         harness share ONE dispatcher with no behavior drift. *)
      Alcotest.test_case "production_route_close_panel" `Quick (fun () ->
        let setup_json = read_fixture "expected/workspace_default.json" in
        let layout = Jas.Workspace_test_json.test_json_to_workspace setup_json in
        Jas.Workspace_layout.mark_saved layout;
        assert (not (Jas.Workspace_layout.needs_save layout));
        let model = Jas.Model.create ~document:(Jas.Document.default_document ()) () in
        (* Close dock 0 / group 2 / panel 0 via the real panel-menu handler. *)
        let addr : Jas.Workspace_layout.panel_addr =
          { group = { dock_id = 0; group_idx = 2 }; panel_idx = 0 } in
        Jas.Panel_menu.panel_dispatch Jas.Workspace_layout.Layers "close_panel"
          addr layout ~fill_on_top:true ~get_model:(fun () -> model) ();
        (* (a) byte-identical to the corpus golden for this op. *)
        let actual = Jas.Workspace_test_json.workspace_to_test_json layout in
        let expected =
          read_fixture "workspace_operations/panel_close_layers.json" in
        if actual <> expected then begin
          Printf.eprintf "=== EXPECTED (production_route) ===\n%s\n" expected;
          Printf.eprintf "=== ACTUAL (production_route) ===\n%s\n" actual;
          assert false
        end;
        (* (b) the dirty signal fired. *)
        assert (Jas.Workspace_layout.needs_save layout));

      (* OP_LOG 3d-2 no-panic pin: the runtime dispatcher MUST tolerate
         malformed / garbage ops without raising (production input is never
         trusted). Missing [op], unknown verb, wrong-typed params, and missing
         required [kind] must all SKIP. A well-formed op on a fresh layout must
         still mutate (sanity) — confirming the dispatcher is live, not inert.
         Mirrors the Rust [layout_apply_no_panic_on_malformed]. *)
      Alcotest.test_case "dispatcher_no_panic_on_malformed" `Quick (fun () ->
        let setup_json = read_fixture "expected/workspace_default.json" in
        let layout = Jas.Workspace_test_json.test_json_to_workspace setup_json in
        let malformed : Yojson.Safe.t list = [
          `Assoc [];                                       (* no "op" *)
          `Assoc [ "op", `Int 42 ];                        (* "op" not a string *)
          `Assoc [ "op", `String "totally_unknown_verb" ]; (* unknown verb *)
          `Assoc [ "op", `String "show_panel" ];           (* missing required "kind" *)
          `Assoc [ "op", `String "show_panel"; "kind", `Int 7 ]; (* "kind" wrong type *)
          `Assoc [ "op", `String "hide_pane" ];            (* missing required "kind" *)
          `Assoc [ "op", `String "close_panel" ];          (* missing dock/group/panel *)
          `Assoc [ "op", `String "set_pane_position";
                   "pane_id", `String "x" ];               (* garbage param *)
          `Assoc [ "op", `String "toggle_group_collapsed";
                   "dock_id", `String "nope" ];            (* number wrong type *)
          `Assoc [ "op", `String "redock"; "dock_id", `String "nope" ];
          `String "not even an object";                    (* envelope not an assoc *)
          `Null;                                           (* null op *)
        ] in
        (* Must not raise on any malformed op. *)
        List.iter (fun op -> Jas.Layout_apply.layout_apply layout op) malformed;
        (* The dispatcher is live, not inert: a well-formed op on a fresh layout
           still mutates the serialization. *)
        let fresh = Jas.Workspace_test_json.test_json_to_workspace setup_json in
        let before = Jas.Workspace_test_json.workspace_to_test_json fresh in
        Jas.Layout_apply.layout_apply fresh
          (Jas.Layout_apply.op_toggle_group_collapsed { dock_id = 0; group_idx = 0 });
        let after = Jas.Workspace_test_json.workspace_to_test_json fresh in
        if before = after then begin
          Printf.eprintf "=== a well-formed op did NOT mutate (dispatcher inert) ===\n";
          assert false
        end);
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
