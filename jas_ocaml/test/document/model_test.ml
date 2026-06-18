let () =
  Alcotest.run "Model" [
    "model", [
      Alcotest.test_case "default document" `Quick (fun () ->
        let model = Jas.Model.create () in
        assert (String.length model#filename > 0 && String.sub model#filename 0 9 = "Untitled-");
        assert (Array.length model#document.Jas.Document.layers = 1));

      Alcotest.test_case "initial filename" `Quick (fun () ->
        let model2 = Jas.Model.create ~filename:"Test" () in
        assert (model2#filename = "Test"));

      Alcotest.test_case "set_document notifies" `Quick (fun () ->
        let model3 = Jas.Model.create () in
        let received = ref [] in
        model3#on_document_changed (fun doc -> received := Array.length doc.Jas.Document.layers :: !received);
        model3#set_document (Jas.Document.make_document [||]);
        assert (!received = [0]));

      Alcotest.test_case "multiple listeners" `Quick (fun () ->
        let model4 = Jas.Model.create () in
        let a = ref [] in
        let b = ref [] in
        model4#on_document_changed (fun doc -> a := Array.length doc.Jas.Document.layers :: !a);
        model4#on_document_changed (fun doc -> b := Array.length doc.Jas.Document.layers :: !b);
        model4#set_document (Jas.Document.make_document [||]);
        assert (!a = [0]);
        assert (!b = [0]));

      Alcotest.test_case "immutability" `Quick (fun () ->
        let model5 = Jas.Model.create () in
        let before = model5#document in
        model5#set_document (Jas.Document.make_document [||]);
        let after = model5#document in
        assert (Array.length before.Jas.Document.layers = 1);
        assert (Array.length after.Jas.Document.layers = 0));

      Alcotest.test_case "filename" `Quick (fun () ->
        let model_f = Jas.Model.create () in
        assert (String.sub model_f#filename 0 9 = "Untitled-");
        model_f#set_filename "drawing.jas";
        assert (model_f#filename = "drawing.jas"));

      Alcotest.test_case "undo/redo" `Quick (fun () ->
        let model6 = Jas.Model.create () in
        assert (not model6#can_undo);
        model6#snapshot;
        model6#set_document (Jas.Document.make_document [||]);
        assert model6#can_undo;
        assert (not model6#can_redo);
        model6#undo;
        assert (Array.length model6#document.Jas.Document.layers = 1);
        assert model6#can_redo;
        model6#redo;
        assert (Array.length model6#document.Jas.Document.layers = 0));

      Alcotest.test_case "undo clears redo on new edit" `Quick (fun () ->
        let layer = Jas.Element.make_layer [||] in
        let model7 = Jas.Model.create () in
        model7#snapshot;
        model7#set_document (Jas.Document.make_document [|layer|]);
        model7#snapshot;
        model7#set_document (Jas.Document.make_document [|layer; layer|]);
        model7#undo;
        assert (Array.length model7#document.Jas.Document.layers = 1);
        assert model7#can_redo;
        model7#snapshot;
        model7#set_document (Jas.Document.make_document [||]);
        assert (not model7#can_redo));

      Alcotest.test_case "undo/redo on empty stacks" `Quick (fun () ->
        let model8 = Jas.Model.create () in
        model8#undo;
        assert (Array.length model8#document.Jas.Document.layers = 1);
        model8#redo;
        assert (Array.length model8#document.Jas.Document.layers = 1));

      (* OP_LOG.md Increment 2: is_modified is the journal-head cursor, so undo
         back to the saved point reads as not-modified. *)
      Alcotest.test_case "is_modified is the journal-head cursor" `Quick (fun () ->
        let m = Jas.Model.create () in
        assert (not m#is_modified);
        m#mark_saved;  (* saved at journal_head 0 *)
        m#snapshot;
        m#set_document (Jas.Document.make_document [||]);
        assert m#is_modified;
        m#undo;
        assert (not m#is_modified);  (* undo back to the saved point *)
        m#redo;
        assert m#is_modified;  (* redo past the saved point *)
        m#mark_saved;
        assert (not m#is_modified));

      (* ── EditingTarget (Mask editor UI) ─────────────────
         OPACITY.md section Preview interactions. *)

      Alcotest.test_case "defaults to Content editing target" `Quick (fun () ->
        let m = Jas.Model.create () in
        assert (m#editing_target = Jas.Model.Content));

      Alcotest.test_case "editing target round-trips through Mask mode" `Quick (fun () ->
        let m = Jas.Model.create () in
        m#set_editing_target (Jas.Model.Mask [0; 2; 1]);
        (match m#editing_target with
         | Jas.Model.Mask p -> assert (p = [0; 2; 1])
         | Jas.Model.Content -> Alcotest.fail "expected Mask");
        m#set_editing_target Jas.Model.Content;
        assert (m#editing_target = Jas.Model.Content));

      Alcotest.test_case "defaults to no mask isolation" `Quick (fun () ->
        (* Mask-isolation is entered explicitly via Alt-click on
           MASK_PREVIEW. OPACITY.md section Preview interactions. *)
        let m = Jas.Model.create () in
        assert (m#mask_isolation_path = None));

      Alcotest.test_case "mask isolation path round-trips" `Quick (fun () ->
        let m = Jas.Model.create () in
        m#set_mask_isolation_path (Some [0; 3]);
        assert (m#mask_isolation_path = Some [0; 3]);
        m#set_mask_isolation_path None;
        assert (m#mask_isolation_path = None));

      (* ── Phase 4b: id->element index companion ─────────
         REFERENCE_GRAPH.md section 2.4. The [assert] gate inside
         set_document/undo/redo also fires while these run (the suite runs
         with assertions on), proving the stored index never diverges from a
         from-scratch rebuild. Equivalence is pinned on the index VALUE
         (and so on resolve() results), unchanged. *)

      Alcotest.test_case "id index paired at construction" `Quick (fun () ->
        let m = Jas.Model.create () in
        let expect =
          Jas.Live.rebuild_id_index
            m#document.Jas.Document.layers m#document.Jas.Document.symbols in
        assert (Jas.Live.Id_map.equal ( = ) m#id_index expect));

      Alcotest.test_case "id index tracks set_document" `Quick (fun () ->
        let m = Jas.Model.create () in
        let id_rect id =
          Jas.Element.Rect { name = None; id = Some id; x = 0.0; y = 0.0;
            width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
            fill = None; stroke = None; opacity = 1.0; transform = None;
            locked = false; visibility = Jas.Element.Preview;
            blend_mode = Jas.Element.Normal; mask = None;
            fill_gradient = None; stroke_gradient = None } in
        let layer = Jas.Element.make_layer [| id_rect "a" |] in
        m#set_document (Jas.Document.make_document [| layer |]);
        (* The chokepoint rebuilt the index: "a" resolves, and the stored
           index equals a from-scratch rebuild of the new document. *)
        assert (Jas.Live.Id_map.mem "a" m#id_index);
        let expect =
          Jas.Live.rebuild_id_index
            m#document.Jas.Document.layers m#document.Jas.Document.symbols in
        assert (Jas.Live.Id_map.equal ( = ) m#id_index expect));

      Alcotest.test_case "id index carried + restored across undo/redo"
        `Quick (fun () ->
        let m = Jas.Model.create () in
        let id_rect id =
          Jas.Element.Rect { name = None; id = Some id; x = 0.0; y = 0.0;
            width = 10.0; height = 10.0; rx = 0.0; ry = 0.0;
            fill = None; stroke = None; opacity = 1.0; transform = None;
            locked = false; visibility = Jas.Element.Preview;
            blend_mode = Jas.Element.Normal; mask = None;
            fill_gradient = None; stroke_gradient = None } in
        let layer_with ids =
          Jas.Element.make_layer (Array.of_list (List.map id_rect ids)) in
        (* Edit 1: add "r1" (undoable). *)
        m#snapshot;
        m#set_document (Jas.Document.make_document [| layer_with ["r1"] |]);
        (* Edit 2: add "r2" (undoable). *)
        m#snapshot;
        m#set_document (Jas.Document.make_document [| layer_with ["r1"; "r2"] |]);
        assert (Jas.Live.Id_map.mem "r1" m#id_index);
        assert (Jas.Live.Id_map.mem "r2" m#id_index);
        (* Undo edit 2: the carried (paired) index must equal a from-scratch
           rebuild of the restored document — the gate, asserted explicitly
           (it also fires as the [assert] inside undo). *)
        m#undo;
        let expect_after_undo =
          Jas.Live.rebuild_id_index
            m#document.Jas.Document.layers m#document.Jas.Document.symbols in
        assert (Jas.Live.Id_map.equal ( = ) m#id_index expect_after_undo);
        assert (Jas.Live.Id_map.mem "r1" m#id_index);
        assert (not (Jas.Live.Id_map.mem "r2" m#id_index));
        (* The carried index resolves a live reference to the survivor. *)
        let resolver = Jas.Live.resolver_of_index m#id_index in
        assert (resolver "r1" <> None);
        (* Redo edit 2: index again carries r2 and matches rebuild. *)
        m#redo;
        assert (Jas.Live.Id_map.mem "r2" m#id_index);
        let expect_after_redo =
          Jas.Live.rebuild_id_index
            m#document.Jas.Document.layers m#document.Jas.Document.symbols in
        assert (Jas.Live.Id_map.equal ( = ) m#id_index expect_after_redo));
    ];

    (* ── Transaction journal (OP_LOG.md Increment 2, full journal) ─────────
       These mirror the Python jas/document/model.py journal tests and the
       Rust jas_dioxus/src/document/model.rs ones: commit appends one
       transaction per net-change transaction, undo/redo move the cursor, the
       redo tail is dropped on a new commit, no-op transactions are not
       journaled (and leave no undo step), the txn ids are a deterministic
       counter with a parent edge, and abort journals nothing. *)
    "journal", [
      Alcotest.test_case "commit journals one transaction per net-change edit"
        `Quick (fun () ->
          let m = Jas.Model.create () in
          assert (List.length m#journal = 0);
          assert (m#journal_head = 0);
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]));
          assert (List.length m#journal = 1);
          assert (m#journal_head = 1);
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document [| Jas.Element.make_layer [||] |]));
          assert (List.length m#journal = 2);
          assert (m#journal_head = 2));

      Alcotest.test_case "txn ids are a deterministic counter with parent edge"
        `Quick (fun () ->
          (* OP_LOG.md section 7: txn-0, txn-1, … so the journal is
             byte-shareable; the causal parent edge points at the prior
             transaction. *)
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]));
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document [| Jas.Element.make_layer [||] |]));
          let j = Array.of_list m#journal in
          assert (j.(0).Jas.Op_log.txn_id = "txn-0");
          assert (j.(1).Jas.Op_log.txn_id = "txn-1");
          assert (j.(0).Jas.Op_log.parent = None);
          assert (j.(1).Jas.Op_log.parent = Some "txn-0");
          (* The lamport clock mirrors the counter. *)
          assert (j.(0).Jas.Op_log.lamport = 0);
          assert (j.(1).Jas.Op_log.lamport = 1);
          (* The default actor is "artist". *)
          assert (j.(0).Jas.Op_log.actor = "artist"));

      Alcotest.test_case
        "no-op transaction is not journaled and leaves no undo step"
        `Quick (fun () ->
          (* OP_LOG.md section 5/9: an empty / zero-net-change transaction is
             elided from BOTH the journal and the undo stack. *)
          let m = Jas.Model.create () in
          m#with_txn (fun () -> ());  (* no edit *)
          assert (List.length m#journal = 0);
          assert (m#journal_head = 0);
          assert (not m#can_undo);
          (* A write that nets back to the checkpoint document is also a no-op
             (compared via document_to_test_json — the canonical byte form). *)
          let checkpoint = m#document in
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]);
            m#set_document checkpoint);  (* back to the exact checkpoint *)
          assert (List.length m#journal = 0);
          assert (not m#can_undo);
          assert (not m#is_modified));

      Alcotest.test_case "undo and redo move the journal cursor" `Quick
        (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]));
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document [| Jas.Element.make_layer [||] |]));
          assert (m#journal_head = 2);
          m#undo;
          assert (m#journal_head = 1);
          m#undo;
          assert (m#journal_head = 0);
          (* The journal itself is retained across undo (it is a cursor, not a
             high-water mark). *)
          assert (List.length m#journal = 2);
          m#redo;
          assert (m#journal_head = 1);
          m#redo;
          assert (m#journal_head = 2));

      Alcotest.test_case
        "new commit after undo drops the redo tail of the journal" `Quick
        (fun () ->
          (* OP_LOG.md section 5: commit truncates the journal at journal_head
             and appends, so a new edit after undo drops the undone (redo)
             transactions. *)
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]));  (* txn-0 *)
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer [||] |]));  (* txn-1 *)
          assert (List.length m#journal = 2);
          m#undo;  (* cursor at 1, txn-1 is now the redo tail *)
          assert (m#journal_head = 1);
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer [||];
                    Jas.Element.make_layer [||] |]));  (* new txn *)
          assert (List.length m#journal = 2);  (* redo tail dropped, appended *)
          assert (m#journal_head = 2);
          let j = Array.of_list m#journal in
          assert (j.(1).Jas.Op_log.txn_id = "txn-2");  (* counter advances *)
          assert (not m#can_redo));  (* redo cleared on the new edit *)

      Alcotest.test_case "abort does not journal or move the cursor" `Quick
        (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document (Jas.Document.make_document [||]));  (* txn-0 *)
          let head = m#journal_head in
          let len = List.length m#journal in
          m#begin_txn;
          m#set_document
            (Jas.Document.make_document [| Jas.Element.make_layer [||] |]);
          m#abort_txn;
          assert (List.length m#journal = len);  (* not journaled *)
          assert (m#journal_head = head);        (* cursor unmoved *)
          assert (Array.length m#document.Jas.Document.layers = 0));

      Alcotest.test_case "begin_txn is idempotent while open" `Quick
        (fun () ->
          (* A session that calls begin_txn repeatedly pushes exactly ONE
             checkpoint and undoes in one step (the type-tool lazy-session
             shape). *)
          let m = Jas.Model.create () in
          (* The default document is one empty layer; end the session with a
             genuinely different document (two layers) so the net change is
             real and the session journals exactly one transaction. *)
          m#begin_txn;
          m#set_document (Jas.Document.make_document [||]);
          m#begin_txn;  (* nested / repeated — no-op while open *)
          m#set_document
            (Jas.Document.make_document
               [| Jas.Element.make_layer [||]; Jas.Element.make_layer [||] |]);
          m#commit_txn;
          assert (List.length m#journal = 1);  (* one transaction *)
          m#undo;
          (* One undo step reverts the whole session to the pre-begin doc
             (the default one-layer document). *)
          assert (Array.length m#document.Jas.Document.layers = 1));

      Alcotest.test_case "record_op accumulates ops in apply order" `Quick
        (fun () ->
          (* The op_apply path records each op; commit_txn finalizes a
             transaction whose [ops] preserve apply order, and name_txn labels
             it. No-op when no transaction is open. *)
          let m = Jas.Model.create () in
          (* record_op / name_txn outside any bracket are no-ops. *)
          m#record_op (Jas.Op_log.make_primitive_op ~op:"stray"
                         ~params:(`Assoc []) ());
          m#name_txn "stray";
          assert (List.length m#journal = 0);
          m#begin_txn;
          m#name_txn "move things";
          m#record_op (Jas.Op_log.make_primitive_op ~op:"select_rect"
                         ~params:(`Assoc ["op", `String "select_rect"]) ());
          m#record_op (Jas.Op_log.make_primitive_op ~op:"move_selection"
                         ~params:(`Assoc ["op", `String "move_selection"]) ());
          m#set_document (Jas.Document.make_document [||]);
          m#commit_txn;
          let j = Array.of_list m#journal in
          assert (Array.length j = 1);
          assert (j.(0).Jas.Op_log.name = Some "move things");
          let ops = Array.of_list j.(0).Jas.Op_log.ops in
          assert (Array.length ops = 2);
          assert (ops.(0).Jas.Op_log.op = "select_rect");
          assert (ops.(1).Jas.Op_log.op = "move_selection"));
    ];

    (* ── Versioning labels (OP_LOG.md Increment 3a / VISION.md 6.9) ─────────
       These mirror the Rust jas_dioxus/src/document/model.rs versioning tests:
       label stores a version and stamps the committed transaction; restore is
       an undoable edit back to the labeled state; restore-to-current is a no-op
       (no new transaction); re-label re-points (no duplicate) and an
       unknown-name restore returns false. *)
    "versioning", [
      (* Named layers (not the default empty layer) so each edit is a genuine
         net change — an unnamed empty layer is byte-identical to the default
         document, which the commit no-op rule would elide. Mirrors the Rust
         make_layer("A") helper. *)
      Alcotest.test_case
        "label_version stores a version and stamps the transaction" `Quick
        (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||] |]));
          m#label_version "v1";
          let vs = Array.of_list m#versions in
          assert (Array.length vs = 1);
          assert (vs.(0).Jas.Model.label = "v1");
          assert (vs.(0).Jas.Model.journal_head = 1);
          (* The label is stamped onto the committed transaction (serializes
             into the journal artifact). *)
          let j = Array.of_list m#journal in
          assert (j.(0).Jas.Op_log.label = Some "v1"));

      Alcotest.test_case
        "restore_version is an undoable edit back to the labeled state" `Quick
        (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||] |]));
          m#label_version "v1";
          (* Edit past the version. *)
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||];
                    Jas.Element.make_layer ~name:"B" [||] |]));
          assert (Array.length m#document.Jas.Document.layers = 2);
          assert (m#restore_version "v1");
          assert (Array.length m#document.Jas.Document.layers = 1);
          (* Restore is an ordinary transaction on the linear timeline —
             undoable. *)
          assert m#can_undo;
          m#undo;
          assert (Array.length m#document.Jas.Document.layers = 2));

      Alcotest.test_case "restore_version to current state is a no-op" `Quick
        (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||] |]));
          m#label_version "v1";
          let head = m#journal_head in
          (* Already at v1's state — restoring is a no-op (not journaled). *)
          assert (m#restore_version "v1");
          assert (m#journal_head = head));

      Alcotest.test_case
        "label_version re-label re-points and unknown restore returns false"
        `Quick (fun () ->
          let m = Jas.Model.create () in
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||] |]));
          m#label_version "v1";
          m#with_txn (fun () ->
            m#set_document
              (Jas.Document.make_document
                 [| Jas.Element.make_layer ~name:"A" [||];
                    Jas.Element.make_layer ~name:"B" [||] |]));
          m#label_version "v1";  (* re-point to the new state *)
          let vs = Array.of_list m#versions in
          assert (Array.length vs = 1);  (* re-label re-points, no duplicate *)
          assert (vs.(0).Jas.Model.journal_head = 2);
          (* Unknown version restore is a no-op false. *)
          assert (not (m#restore_version "nope")));
    ];
  ]
