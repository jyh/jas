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

  Printf.printf "All model tests passed.\n"
