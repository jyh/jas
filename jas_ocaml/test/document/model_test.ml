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
  ]
