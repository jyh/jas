let () =
  (* Test default document *)
  let model = Jas.Model.create () in
  assert (String.length model#filename > 0 && String.sub model#filename 0 9 = "Untitled-");
  assert (List.length model#document.Jas.Document.layers = 1);

  (* Test initial filename *)
  let model2 = Jas.Model.create ~filename:"Test" () in
  assert (model2#filename = "Test");

  (* Test set_document notifies *)
  let model3 = Jas.Model.create () in
  let received = ref [] in
  model3#on_document_changed (fun doc -> received := List.length doc.Jas.Document.layers :: !received);
  model3#set_document (Jas.Document.make_document []);
  assert (!received = [0]);

  (* Test multiple listeners *)
  let model4 = Jas.Model.create () in
  let a = ref [] in
  let b = ref [] in
  model4#on_document_changed (fun doc -> a := List.length doc.Jas.Document.layers :: !a);
  model4#on_document_changed (fun doc -> b := List.length doc.Jas.Document.layers :: !b);
  model4#set_document (Jas.Document.make_document []);
  assert (!a = [0]);
  assert (!b = [0]);

  (* Test immutability *)
  let model5 = Jas.Model.create () in
  let before = model5#document in
  model5#set_document (Jas.Document.make_document []);
  let after = model5#document in
  assert (List.length before.Jas.Document.layers = 1);
  assert (List.length after.Jas.Document.layers = 0);

  (* Test filename *)
  let model_f = Jas.Model.create () in
  assert (String.sub model_f#filename 0 9 = "Untitled-");
  model_f#set_filename "drawing.jas";
  assert (model_f#filename = "drawing.jas");

  (* Test undo/redo *)
  let model6 = Jas.Model.create () in
  assert (not model6#can_undo);
  model6#snapshot;
  model6#set_document (Jas.Document.make_document []);
  assert model6#can_undo;
  assert (not model6#can_redo);
  model6#undo;
  assert (List.length model6#document.Jas.Document.layers = 1);
  assert model6#can_redo;
  model6#redo;
  assert (List.length model6#document.Jas.Document.layers = 0);

  (* Test undo clears redo on new edit *)
  let layer = Jas.Element.make_layer [] in
  let model7 = Jas.Model.create () in
  model7#snapshot;
  model7#set_document (Jas.Document.make_document [layer]);
  model7#snapshot;
  model7#set_document (Jas.Document.make_document [layer; layer]);
  model7#undo;
  assert (List.length model7#document.Jas.Document.layers = 1);
  assert model7#can_redo;
  model7#snapshot;
  model7#set_document (Jas.Document.make_document []);
  assert (not model7#can_redo);

  (* Test undo/redo on empty stacks *)
  let model8 = Jas.Model.create () in
  model8#undo;
  assert (List.length model8#document.Jas.Document.layers = 1);
  model8#redo;
  assert (List.length model8#document.Jas.Document.layers = 1);

  Printf.printf "All model tests passed.\n"
