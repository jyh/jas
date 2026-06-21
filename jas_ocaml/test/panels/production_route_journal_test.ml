(* OP_LOG.md section 9 — production-route proofs that the PANEL / MENU production
   handlers for the verb33 verbs journal a real op through the shared
   [Op_apply.op_apply] dispatcher (the same path the tool gestures already use).
   Mirrors the Swift [ProductionRouteJournalTests.swift] and the Rust
   [production_route_*] tests in jas_dioxus [renderer.rs].

   Each test drives the REAL OCaml production handler (the Layers-panel
   platform-effect registry via [Panel_menu.dispatch_yaml_action] /
   [run_action_effects_for_test], or the native menu / keyboard route), then
   asserts:
     (1) the committed Transaction journals the expected verb op(s) with the
         RESOLVED params (the production eval -> literal path, NOT the YAML expr
         string) and the right targets;
     (2) the transaction carries the action name ([name_txn]);
     (3) ZERO behavior change: replaying the journal from the pre-edit document
         is byte-identical to the live document (checkpoint_equivalence);
     (4) the snapshot / undo bracket still works (one undo step round-trips).

   These complement the operations-fixture proofs in cross_language_test, which
   drive [op_apply] directly via the harness — here we prove the PRODUCTION
   gesture reaches the same dispatcher. *)

module J = Jas

(* ── Shared helpers ───────────────────────────────────────────────────────── *)

(* Replay the whole journal (0..head) onto a FRESH model seeded from [pre_doc]
   and byte-compare to the live document — the checkpoint_equivalence gate. *)
let assert_checkpoint_equivalence (m : J.Model.model) (pre_doc : J.Document.document) =
  let snapshot_doc = J.Test_json.document_to_test_json m#document in
  let replay = J.Model.create ~document:pre_doc () in
  let ctrl = J.Controller.create ~model:replay () in
  List.iteri (fun i (txn : J.Op_log.transaction) ->
    if i < m#journal_head then
      List.iter (fun (op : J.Op_log.primitive_op) ->
        J.Op_apply.op_apply replay ctrl op.J.Op_log.params
      ) txn.J.Op_log.ops
  ) m#journal;
  let replay_doc = J.Test_json.document_to_test_json replay#document in
  if replay_doc <> snapshot_doc then begin
    Printf.eprintf "=== checkpoint_equivalence FAILED ===\n";
    Printf.eprintf "=== SNAPSHOT ===\n%s\n=== REPLAY ===\n%s\n" snapshot_doc replay_doc;
    assert false
  end

(* The last committed transaction (the production action commits exactly one). *)
let last_txn (m : J.Model.model) : J.Op_log.transaction =
  match List.rev m#journal with
  | t :: _ -> t
  | [] -> failwith "expected a committed transaction"

(* The ops of one transaction filtered by verb. *)
let ops_of_verb (txn : J.Op_log.transaction) (verb : string) : J.Op_log.primitive_op list =
  List.filter (fun (o : J.Op_log.primitive_op) -> o.J.Op_log.op = verb) txn.J.Op_log.ops

let str_param (op : J.Op_log.primitive_op) (key : string) : string option =
  match Yojson.Safe.Util.member key op.J.Op_log.params with
  | `String s -> Some s | _ -> None

let num_param (op : J.Op_log.primitive_op) (key : string) : float option =
  match Yojson.Safe.Util.member key op.J.Op_log.params with
  | `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None

let bool_param (op : J.Op_log.primitive_op) (key : string) : bool option =
  match Yojson.Safe.Util.member key op.J.Op_log.params with
  | `Bool b -> Some b | _ -> None

let mk_layer name : J.Element.element =
  J.Element.Layer {
    name = Some name; id = None; children = [||];
    opacity = 1.0; transform = None; locked = false;
    visibility = J.Element.Preview; blend_mode = J.Element.Normal;
    mask = None; isolated_blending = false; knockout_group = false;
  }

(* Run [effects] through the SHARED [Yaml_tool_effects.build] registry (the
   production path the print-config + brush dialogs use), threading [m] as the
   transaction OWNER + naming the txn with [action_name] — exactly the
   yaml_panel_view / dialog production bracket. The print-config setters and
   doc.set_attr_on_selection live in THIS registry (not the panel_menu one), so
   a production-route proof for them drives the REAL handlers here. *)
let run_tool_effects_owned (m : J.Model.model) (action_name : string)
    (effects : Yojson.Safe.t list) : unit =
  let ctrl = J.Controller.create ~model:m () in
  let pe = J.Yaml_tool_effects.build ctrl in
  let store = J.State_store.create () in
  J.Effects.run_effects ~platform_effects:pe ~owner_model:(Some m)
    ~action_name:(Some action_name) effects [] store

(* A model carrying two artboards with known ids, for the artboard verbs. *)
let model_with_two_artboards () : J.Model.model =
  let m = J.Model.create () in
  let doc = m#document in
  let abs = [ J.Artboard.default_with_id "ab1"; J.Artboard.default_with_id "ab2" ] in
  m#set_document_unbracketed { doc with J.Document.artboards = abs };
  m

(* ── Structural tree verbs ────────────────────────────────────────────────── *)

let structural_tests = [
  (* delete_at via delete_layer_selection (foreach doc.delete_at). *)
  Alcotest.test_case "delete_layer_selection journals delete_at" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    m#set_document_unbracketed { doc with J.Document.layers =
      [| mk_layer "A"; mk_layer "B"; mk_layer "C" |] };
    let pre_doc = m#document in
    let before = List.length m#journal in
    J.Panel_menu.dispatch_yaml_action ~panel_selection:[[0]; [2]]
      "delete_layer_selection" m;
    (* (1a) exactly one new named transaction. *)
    assert (List.length m#journal = before + 1);
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "delete_layer_selection");
    (* (1b) two delete_at ops journaled (one per selected path). *)
    let deletes = ops_of_verb txn "delete_at" in
    assert (List.length deletes = 2);
    (* mutation landed: only B remains. *)
    assert (Array.length m#document.J.Document.layers = 1);
    assert_checkpoint_equivalence m pre_doc;
    (* (4) one undo step round-trips. *)
    m#undo;
    assert (Array.length m#document.J.Document.layers = 3));

  (* insert_after (value-in-op) via duplicate_layer_selection (clone_at binder
     then doc.insert_after). The clone_at binder is non-journaled; only the
     insert_after journals. *)
  Alcotest.test_case "duplicate_layer_selection journals insert_after" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    m#set_document_unbracketed { doc with J.Document.layers =
      [| mk_layer "A"; mk_layer "B" |] };
    let pre_doc = m#document in
    J.Panel_menu.dispatch_yaml_action ~panel_selection:[[1]]
      "duplicate_layer_selection" m;
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "duplicate_layer_selection");
    let inserts = ops_of_verb txn "insert_after" in
    assert (List.length inserts = 1);
    (* exactly the insert_after journals (clone_at is non-journaled). *)
    assert (List.length txn.J.Op_log.ops = 1);
    assert (Array.length m#document.J.Document.layers = 3);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (Array.length m#document.J.Document.layers = 2));

  (* insert_at (value-in-op) via new_layer (create_layer binder then
     doc.insert_at). create_layer is non-journaled; only insert_at journals. *)
  Alcotest.test_case "new_layer journals insert_at" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    m#set_document_unbracketed { doc with J.Document.layers = [| mk_layer "Layer 1" |] };
    let pre_doc = m#document in
    J.Panel_menu.dispatch_yaml_action "new_layer" m;
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "new_layer");
    let inserts = ops_of_verb txn "insert_at" in
    assert (List.length inserts = 1);
    assert (List.length txn.J.Op_log.ops = 1);
    assert (Array.length m#document.J.Document.layers = 2);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (Array.length m#document.J.Document.layers = 1));

  (* wrap_in_group via new_group. *)
  Alcotest.test_case "new_group journals wrap_in_group" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    m#set_document_unbracketed { doc with J.Document.layers =
      [| mk_layer "A"; mk_layer "B"; mk_layer "C" |] };
    let pre_doc = m#document in
    J.Panel_menu.dispatch_yaml_action ~panel_selection:[[0]; [2]] "new_group" m;
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "new_group");
    let wraps = ops_of_verb txn "wrap_in_group" in
    assert (List.length wraps = 1);
    (* paths param carries the RESOLVED plain index arrays. *)
    (match (List.hd wraps).J.Op_log.params with
     | `Assoc kv ->
       (match List.assoc_opt "paths" kv with
        | Some (`List [ `List [ `Int 0 ]; `List [ `Int 2 ] ]) -> ()
        | _ -> assert false)
     | _ -> assert false);
    assert (Array.length m#document.J.Document.layers = 2);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (Array.length m#document.J.Document.layers = 3));

  (* wrap_in_layer via collect_in_new_layer (RESOLVED name literal). *)
  Alcotest.test_case "collect_in_new_layer journals wrap_in_layer" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    m#set_document_unbracketed { doc with J.Document.layers =
      [| mk_layer "Layer 1"; mk_layer "Layer 2"; mk_layer "Layer 3" |] };
    let pre_doc = m#document in
    J.Panel_menu.dispatch_yaml_action ~panel_selection:[[0]; [2]]
      "collect_in_new_layer" m;
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "collect_in_new_layer");
    let wraps = ops_of_verb txn "wrap_in_layer" in
    assert (List.length wraps = 1);
    (* name is journaled as a RESOLVED literal (not the YAML expr). *)
    (match str_param (List.hd wraps) "name" with
     | Some n -> assert (String.length n > 0)
     | None -> assert false);
    assert (Array.length m#document.J.Document.layers = 2);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (Array.length m#document.J.Document.layers = 3));

  (* unpack_group_at via flatten_artwork. *)
  Alcotest.test_case "flatten_artwork journals unpack_group_at" `Quick (fun () ->
    let m = J.Model.create () in
    let doc = m#document in
    let child a = mk_layer a in
    let group = J.Element.make_group [| child "x"; child "y" |] in
    m#set_document_unbracketed { doc with J.Document.layers = [| group |] };
    let pre_doc = m#document in
    J.Panel_menu.dispatch_yaml_action ~panel_selection:[[0]] "flatten_artwork" m;
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "flatten_artwork");
    let unpacks = ops_of_verb txn "unpack_group_at" in
    assert (List.length unpacks = 1);
    (* group dissolved: its two children take its place. *)
    assert (Array.length m#document.J.Document.layers = 2);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (Array.length m#document.J.Document.layers = 1));
]

(* ── Native menu / keyboard delete + cut ──────────────────────────────────── *)

(* Seed a single selected top-level Path so delete_selection has a target. *)
let model_with_selected_path () : J.Model.model =
  let m = J.Model.create () in
  let path = J.Element.make_path ~stroke_brush:None
    [ J.Element.MoveTo (0.0, 0.0); J.Element.LineTo (10.0, 10.0) ] in
  let path = J.Element.with_id path (Some "p1") in
  let layer = J.Element.make_layer [| path |] in
  let doc = m#document in
  let sel = J.Document.PathMap.singleton [0; 0]
    (J.Document.element_selection_all [0; 0]) in
  m#set_document_unbracketed { doc with J.Document.layers = [| layer |];
    J.Document.selection = sel };
  m

let delete_cut_tests = [
  (* The native keyboard / menu Delete confirm route names the txn
     [delete_orphan_confirm_ok] and journals one delete_selection. This drives
     the SAME bracket + op the bin/main.ml keyboard handler uses. *)
  Alcotest.test_case "menu delete journals delete_selection" `Quick (fun () ->
    let m = model_with_selected_path () in
    let pre_doc = m#document in
    let before = List.length m#journal in
    let ctrl = J.Controller.create ~model:m () in
    m#with_txn (fun () ->
      m#name_txn "delete_orphan_confirm_ok";
      J.Op_apply.op_apply m ctrl (`Assoc [ ("op", `String "delete_selection") ]));
    assert (List.length m#journal = before + 1);
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "delete_orphan_confirm_ok");
    let dels = ops_of_verb txn "delete_selection" in
    assert (List.length dels = 1);
    (* targets carry the pre-deletion selection id. *)
    assert ((List.hd dels).J.Op_log.targets = ["p1"]);
    (* the path is gone. *)
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children; _ } -> assert (Array.length children = 0)
     | _ -> assert false);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children; _ } -> assert (Array.length children = 1)
     | _ -> assert false));

  (* The native Cut confirm route names the txn [cut_orphan_confirm_ok] and
     journals one delete_selection (the delete-half; the clipboard copy is a
     non-document side effect, no op). Mirrors Menubar.cut_selection. *)
  Alcotest.test_case "cut journals delete_selection only" `Quick (fun () ->
    let m = model_with_selected_path () in
    let pre_doc = m#document in
    let ctrl = J.Controller.create ~model:m () in
    m#with_txn (fun () ->
      m#name_txn "cut_orphan_confirm_ok";
      J.Op_apply.op_apply m ctrl (`Assoc [ ("op", `String "delete_selection") ]));
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "cut_orphan_confirm_ok");
    assert (List.length txn.J.Op_log.ops = 1);
    assert ((List.hd txn.J.Op_log.ops).J.Op_log.op = "delete_selection");
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children; _ } -> assert (Array.length children = 1)
     | _ -> assert false));
]

(* ── set_attr_on_selection (brush apply) ──────────────────────────────────── *)

let set_attr_tests = [
  Alcotest.test_case "apply_brush_to_selection journals set_attr_on_selection" `Quick (fun () ->
    let m = model_with_selected_path () in
    let pre_doc = m#document in
    let before = List.length m#journal in
    (* Drive the REAL doc.set_attr_on_selection handler through the tool-effects
       registry (the apply_brush_to_selection action shape: snapshot + the brush
       set). *)
    run_tool_effects_owned m "apply_brush_to_selection"
      [ `Assoc [ ("doc.snapshot", `Null) ];
        `Assoc [ ("doc.set_attr_on_selection",
                  `Assoc [ ("attr", `String "stroke_brush");
                           ("value", `String "'calligraphy_3pt'") ]) ] ];
    assert (List.length m#journal = before + 1);
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "apply_brush_to_selection");
    let sets = ops_of_verb txn "set_attr_on_selection" in
    assert (List.length sets = 1);
    let op = List.hd sets in
    assert (str_param op "attr" = Some "stroke_brush");
    (* RESOLVED literal, not the YAML expr string "'calligraphy_3pt'". *)
    assert (str_param op "value" = Some "calligraphy_3pt");
    assert (op.J.Op_log.targets = ["p1"]);
    (* mutation landed: the Path now carries the brush. *)
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children = [| J.Element.Path { stroke_brush; _ } |]; _ } ->
       assert (stroke_brush = Some "calligraphy_3pt")
     | _ -> assert false);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children = [| J.Element.Path { stroke_brush; _ } |]; _ } ->
       assert (stroke_brush = None)
     | _ -> assert false));
]

(* ── Print-config setters (8 verbs; representative coverage) ───────────────── *)

let print_config_tests = [
  (* document_setup field (writes document_setup, a different part of the doc). *)
  Alcotest.test_case "set_document_setup_field journals resolved literal" `Quick (fun () ->
    let m = J.Model.create () in
    let pre_doc = m#document in
    let before = List.length m#journal in
    run_tool_effects_owned m "document_setup_confirm"
      [ `Assoc [ ("doc.snapshot", `Null) ];
        `Assoc [ ("doc.set_document_setup_field",
                  `Assoc [ ("field", `String "grid_size"); ("value", `String "42") ]) ] ];
    assert (List.length m#journal = before + 1);
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "document_setup_confirm");
    let ops = ops_of_verb txn "set_document_setup_field" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "field" = Some "grid_size");
    assert (num_param op "value" = Some 42.0);
    (* document-global config => empty targets. *)
    assert (op.J.Op_log.targets = []);
    assert (m#document.J.Document.document_setup.J.Document_setup.grid_size = 42.0);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (m#document.J.Document.document_setup.J.Document_setup.grid_size
            = pre_doc.J.Document.document_setup.J.Document_setup.grid_size));

  (* print_preferences field (copies; resolved numeric literal). *)
  Alcotest.test_case "set_print_preferences_field journals resolved literal" `Quick (fun () ->
    let m = J.Model.create () in
    let pre_doc = m#document in
    run_tool_effects_owned m "print_dialog_done"
      [ `Assoc [ ("doc.snapshot", `Null) ];
        `Assoc [ ("doc.set_print_preferences_field",
                  `Assoc [ ("field", `String "copies"); ("value", `String "7") ]) ] ];
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "print_dialog_done");
    let ops = ops_of_verb txn "set_print_preferences_field" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "field" = Some "copies");
    assert (num_param op "value" = Some 7.0);
    assert (m#document.J.Document.print_preferences.J.Print_preferences.copies = 7);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (m#document.J.Document.print_preferences.J.Print_preferences.copies
            = pre_doc.J.Document.print_preferences.J.Print_preferences.copies));

  (* output_ink field (carries an index; resolved bool literal). *)
  Alcotest.test_case "set_output_ink_field journals index + resolved literal" `Quick (fun () ->
    let m = J.Model.create () in
    let pre_doc = m#document in
    (* Flip ink 0 print to false (default is true) so it is a real change. *)
    run_tool_effects_owned m "output_panel_confirm"
      [ `Assoc [ ("doc.snapshot", `Null) ];
        `Assoc [ ("doc.set_output_ink_field",
                  `Assoc [ ("field", `String "print"); ("index", `Int 0);
                           ("value", `String "false") ]) ] ];
    let txn = last_txn m in
    let ops = ops_of_verb txn "set_output_ink_field" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "field" = Some "print");
    assert (num_param op "index" = Some 0.0);
    assert (bool_param op "value" = Some false);
    assert_checkpoint_equivalence m pre_doc;
    m#undo);
]

(* ── Artboard verbs (CRUD / field / reorder) ──────────────────────────────── *)

let artboard_tests = [
  (* set_artboard_field via the real handler (resolved literal + targets). *)
  Alcotest.test_case "set_artboard_field journals resolved literal + targets" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    let before = List.length m#journal in
    J.Panel_menu.run_action_effects_for_test "artboard_options_confirm"
      [ `String "snapshot";
        `Assoc [ ("doc.set_artboard_field",
                  `Assoc [ ("id", `String "'ab2'"); ("field", `String "x");
                           ("value", `String "100") ]) ] ]
      m;
    assert (List.length m#journal = before + 1);
    let txn = last_txn m in
    assert (txn.J.Op_log.name = Some "artboard_options_confirm");
    let ops = ops_of_verb txn "set_artboard_field" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "id" = Some "ab2");
    assert (str_param op "field" = Some "x");
    assert (num_param op "value" = Some 100.0);
    assert (op.J.Op_log.targets = ["ab2"]);
    (match List.find_opt (fun (a : J.Artboard.artboard) -> a.id = "ab2")
             m#document.J.Document.artboards with
     | Some a -> assert (a.x = 100.0) | None -> assert false);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    (match List.find_opt (fun (a : J.Artboard.artboard) -> a.id = "ab2")
             m#document.J.Document.artboards with
     | Some a -> assert (a.x = (List.nth pre_doc.J.Document.artboards 1).x)
     | None -> assert false));

  (* set_artboard_options_field — document-global => empty targets. *)
  Alcotest.test_case "set_artboard_options_field empty targets" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    (* Default fade_region_outside_artboard is true; set false (real change). *)
    J.Panel_menu.run_action_effects_for_test "artboard_options_confirm"
      [ `String "snapshot";
        `Assoc [ ("doc.set_artboard_options_field",
                  `Assoc [ ("field", `String "fade_region_outside_artboard");
                           ("value", `String "false") ]) ] ]
      m;
    let txn = last_txn m in
    let ops = ops_of_verb txn "set_artboard_options_field" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "field" = Some "fade_region_outside_artboard");
    assert (bool_param op "value" = Some false);
    assert (op.J.Op_log.targets = []);
    assert (m#document.J.Document.artboard_options
              .J.Artboard.fade_region_outside_artboard = false);
    assert_checkpoint_equivalence m pre_doc);

  (* delete_artboard_by_id (resolved id + targets). *)
  Alcotest.test_case "delete_artboard_by_id journals id + targets" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    J.Panel_menu.run_action_effects_for_test "delete_artboards"
      [ `String "snapshot";
        `Assoc [ ("doc.delete_artboard_by_id", `String "'ab1'") ] ]
      m;
    let txn = last_txn m in
    let ops = ops_of_verb txn "delete_artboard_by_id" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "id" = Some "ab1");
    assert (op.J.Op_log.targets = ["ab1"]);
    assert (List.length m#document.J.Document.artboards = 1);
    assert ((List.hd m#document.J.Document.artboards).id = "ab2");
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (List.length m#document.J.Document.artboards = 2));

  (* create_artboard — VALUE-IN-OP: id minted once, journaled as a literal. *)
  Alcotest.test_case "create_artboard journals minted id literal" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    J.Panel_menu.run_action_effects_for_test "new_artboard"
      [ `String "snapshot";
        `Assoc [ ("doc.create_artboard",
                  `Assoc [ ("x", `String "0"); ("y", `String "0");
                           ("width", `String "100"); ("height", `String "100") ]) ] ]
      m;
    let txn = last_txn m in
    let ops = ops_of_verb txn "create_artboard" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    (match str_param op "id" with
     | Some id ->
       assert (String.length id > 0);
       assert (op.J.Op_log.targets = [id]);
       (* the live doc carries the minted id at the end. *)
       assert ((List.nth m#document.J.Document.artboards 2).id = id)
     | None -> assert false);
    assert (List.length m#document.J.Document.artboards = 3);
    (* checkpoint_equivalence: replay reads the recorded id VERBATIM. *)
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (List.length m#document.J.Document.artboards = 2));

  (* duplicate_artboard — VALUE-IN-OP: new_id + name minted once as literals. *)
  Alcotest.test_case "duplicate_artboard journals new_id + name literals" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    J.Panel_menu.run_action_effects_for_test "duplicate_artboards"
      [ `String "snapshot";
        `Assoc [ ("doc.duplicate_artboard", `String "'ab1'") ] ]
      m;
    let txn = last_txn m in
    let ops = ops_of_verb txn "duplicate_artboard" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (str_param op "id" = Some "ab1");
    (match str_param op "new_id" with
     | Some nid -> assert (String.length nid > 0); assert (op.J.Op_log.targets = [nid])
     | None -> assert false);
    (* the derived name is journaled as a literal (replay never re-derives). *)
    (match str_param op "name" with Some _ -> () | None -> assert false);
    assert (List.length m#document.J.Document.artboards = 3);
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert (List.length m#document.J.Document.artboards = 2));

  (* move_artboards_up (resolved ids; swap-with-neighbor). *)
  Alcotest.test_case "move_artboards_up journals ids + targets" `Quick (fun () ->
    let m = model_with_two_artboards () in
    let pre_doc = m#document in
    (* Move ab2 (index 1) up so it swaps with ab1. *)
    J.Panel_menu.run_action_effects_for_test "move_artboard_up"
      [ `String "snapshot";
        `Assoc [ ("doc.move_artboards_up", `String "['ab2']") ] ]
      m;
    let txn = last_txn m in
    let ops = ops_of_verb txn "move_artboards_up" in
    assert (List.length ops = 1);
    let op = List.hd ops in
    assert (op.J.Op_log.targets = ["ab2"]);
    (* ab2 is now first. *)
    assert ((List.hd m#document.J.Document.artboards).id = "ab2");
    assert_checkpoint_equivalence m pre_doc;
    m#undo;
    assert ((List.hd m#document.J.Document.artboards).id = "ab1"));
]

(* ── Concept-pack ops (place_concept_instance / set_concept_param) ─────────── *)

(* A single-layer document seeded with one rect at child 0 (mirrors the Rust
   rect_basic.svg fixture). place_concept_instance auto-selects the appended
   Generated, which lands at [0,1] after the rect — exactly where the
   set_concept_param production handler resolves its path from the selection. *)
let model_with_one_rect () : J.Model.model =
  let m = J.Model.create () in
  let rect = J.Element.make_rect 0.0 0.0 100.0 100.0 in
  let layer = J.Element.make_layer [| rect |] in
  m#set_document_unbracketed { m#document with J.Document.layers = [| layer |] };
  m

(* The Concepts-panel store with [concept_id] panel-selected (the generic
   concepts_panel_select set_panel_state the production place arm reads). *)
let store_with_selected_concept (concept_id : string) : J.State_store.t =
  let store = J.State_store.create () in
  (* set_panel is a no-op until the panel scope exists; init_panel registers it
     (the generic concepts_panel_select set_panel_state goes through the same
     scope in production). *)
  J.State_store.init_panel store J.Concepts_panel.content_id [];
  J.State_store.set_panel store J.Concepts_panel.content_id
    "selected_concept" (`String concept_id);
  store

let concept_tests = [
  (* CONCEPTS.md section 7 — the two concept-pack verbs journal + replay
     byte-identically. [place_concept_instance] appends a value-in-op Generated
     element (concept id + resolved default params + minted id); [set_concept_param]
     tunes one param of the Generated at [path]. Every operand is value-in-op, so
     the journal replays to the SAME document the live edit produced (the
     checkpoint_equivalence gate) — even though the registry the defaults came
     from is never consulted on replay. Drives the EXACT yaml_panel_view
     production bracket: build the op via the Concepts_panel op-builder, then
     with_txn + name_txn + Op_apply.op_apply. *)
  Alcotest.test_case "concept ops journal + replay deterministically" `Quick (fun () ->
    let m = model_with_one_rect () in
    let store = store_with_selected_concept "regular_polygon" in
    let pre_doc = m#document in
    let before = List.length m#journal in

    (* Place a hexagon (regular_polygon, defaults {sides:6, radius:50}). *)
    (match J.Concepts_panel.place_concept_op store m with
     | Some op ->
       let ctrl = J.Controller.create ~model:m () in
       m#with_txn (fun () ->
         m#name_txn "place_concept_instance";
         J.Op_apply.op_apply m ctrl op)
     | None -> assert false);
    (* (1) one new named transaction journaling place_concept_instance. *)
    assert (List.length m#journal = before + 1);
    let place_txn = last_txn m in
    assert (place_txn.J.Op_log.name = Some "place_concept_instance");
    let places = ops_of_verb place_txn "place_concept_instance" in
    assert (List.length places = 1);
    let place_op = List.hd places in
    assert (str_param place_op "concept_id" = Some "regular_polygon");
    (* the minted id is journaled as a literal (value-in-op). *)
    let placed_id = match str_param place_op "elem_id" with
      | Some id -> assert (String.length id > 0); id
      | None -> assert false in
    (* mutation landed: the Generated sits at [0,1] after the rect, selected. *)
    let gen_path = [0; 1] in
    (match J.Document.get_element m#document gen_path with
     | J.Element.Live (J.Element.Generated gen) ->
       assert (gen.J.Element.gen_concept_id = "regular_polygon");
       assert (gen.J.Element.gen_id = Some placed_id)
     | _ -> assert false);

    (* Tune one param (sides 6 -> 8) on the selected Generated. *)
    (match J.Concepts_panel.set_concept_param_op store m "sides" 8.0 with
     | Some op ->
       let ctrl = J.Controller.create ~model:m () in
       m#with_txn (fun () ->
         m#name_txn "set_concept_param";
         J.Op_apply.op_apply m ctrl op)
     | None -> assert false);
    let set_txn = last_txn m in
    assert (set_txn.J.Op_log.name = Some "set_concept_param");
    let sets = ops_of_verb set_txn "set_concept_param" in
    assert (List.length sets = 1);
    let set_op = List.hd sets in
    (* path / name / value journaled as resolved literals (value-in-op). *)
    (match set_op.J.Op_log.params with
     | `Assoc kv ->
       (match List.assoc_opt "path" kv with
        | Some (`List [ `Int 0; `Int 1 ]) -> ()
        | _ -> assert false)
     | _ -> assert false);
    assert (str_param set_op "name" = Some "sides");
    assert (num_param set_op "value" = Some 8.0);
    (* mutation landed: sides is now 8 on the Generated. *)
    (match J.Document.get_element m#document gen_path with
     | J.Element.Live (J.Element.Generated gen) ->
       (match gen.J.Element.gen_params with
        | `Assoc params ->
          (match List.assoc_opt "sides" params with
           | Some (`Float 8.0) -> ()
           | _ -> assert false)
        | _ -> assert false)
     | _ -> assert false);

    (* checkpoint_equivalence: the journal replays to the SAME document, twice
       (value-in-op operands reproduce the Generated + tuned param byte-for-byte;
       the registry the defaults came from is never re-consulted on replay). *)
    assert_checkpoint_equivalence m pre_doc;
    assert_checkpoint_equivalence m pre_doc;

    (* one undo step per op round-trips. *)
    m#undo;
    (match J.Document.get_element m#document gen_path with
     | J.Element.Live (J.Element.Generated gen) ->
       (match gen.J.Element.gen_params with
        | `Assoc params ->
          (match List.assoc_opt "sides" params with
           | Some (`Int 6) | Some (`Float 6.0) -> ()
           | _ -> assert false)
        | _ -> assert false)
     | _ -> assert false);
    m#undo;
    (match m#document.J.Document.layers.(0) with
     | J.Element.Layer { children; _ } -> assert (Array.length children = 1)
     | _ -> assert false));
]

let () =
  Alcotest.run "production_route_journal" [
    "structural", structural_tests;
    "delete_cut", delete_cut_tests;
    "set_attr_on_selection", set_attr_tests;
    "print_config", print_config_tests;
    "artboard", artboard_tests;
    "concept", concept_tests;
  ]
