let () =
  (* Test default document *)
  let model = Jas.Model.create () in
  assert (model#document.Jas.Document.title = "Untitled");
  assert (List.length model#document.Jas.Document.layers = 1);

  (* Test initial document *)
  let doc = Jas.Document.make_document ~title:"Test" [] in
  let model2 = Jas.Model.create ~document:doc () in
  assert (model2#document.Jas.Document.title = "Test");

  (* Test set_document notifies *)
  let model3 = Jas.Model.create () in
  let received = ref [] in
  model3#on_document_changed (fun doc -> received := doc.Jas.Document.title :: !received);
  model3#set_document (Jas.Document.make_document ~title:"Changed" []);
  assert (!received = ["Changed"]);

  (* Test multiple listeners *)
  let model4 = Jas.Model.create () in
  let a = ref [] in
  let b = ref [] in
  model4#on_document_changed (fun doc -> a := doc.Jas.Document.title :: !a);
  model4#on_document_changed (fun doc -> b := doc.Jas.Document.title :: !b);
  model4#set_document (Jas.Document.make_document ~title:"X" []);
  assert (!a = ["X"]);
  assert (!b = ["X"]);

  (* Test immutability *)
  let model5 = Jas.Model.create () in
  let before = model5#document in
  model5#set_document (Jas.Document.make_document ~title:"New" []);
  let after = model5#document in
  assert (before.Jas.Document.title = "Untitled");
  assert (after.Jas.Document.title = "New");

  (* Test undo/redo *)
  let model6 = Jas.Model.create () in
  assert (not model6#can_undo);
  model6#snapshot;
  model6#set_document (Jas.Document.make_document ~title:"A" []);
  assert model6#can_undo;
  assert (not model6#can_redo);
  model6#undo;
  assert (model6#document.Jas.Document.title = "Untitled");
  assert model6#can_redo;
  model6#redo;
  assert (model6#document.Jas.Document.title = "A");

  (* Test undo clears redo on new edit *)
  let model7 = Jas.Model.create () in
  model7#snapshot;
  model7#set_document (Jas.Document.make_document ~title:"A" []);
  model7#snapshot;
  model7#set_document (Jas.Document.make_document ~title:"B" []);
  model7#undo;
  assert (model7#document.Jas.Document.title = "A");
  assert model7#can_redo;
  model7#snapshot;
  model7#set_document (Jas.Document.make_document ~title:"C" []);
  assert (not model7#can_redo);

  (* Test undo/redo on empty stacks *)
  let model8 = Jas.Model.create () in
  model8#undo;
  assert (model8#document.Jas.Document.title = "Untitled");
  model8#redo;
  assert (model8#document.Jas.Document.title = "Untitled");

  Printf.printf "All model tests passed.\n"
