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
    ];
  ]
