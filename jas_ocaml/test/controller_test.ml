let () =
  let open Jas.Element in

  (* Test default document *)
  let ctrl = Jas.Controller.create () in
  assert (ctrl#document.Jas.Document.title = "Untitled");
  assert (ctrl#document.Jas.Document.layers = []);

  (* Test initial document *)
  let doc = Jas.Document.make_document ~title:"Test" [] in
  let model = Jas.Model.create ~document:doc () in
  let ctrl2 = Jas.Controller.create ~model () in
  assert (ctrl2#document.Jas.Document.title = "Test");

  (* Test set_title *)
  let ctrl3 = Jas.Controller.create () in
  ctrl3#set_title "New Title";
  assert (ctrl3#document.Jas.Document.title = "New Title");

  (* Test add_layer *)
  let ctrl4 = Jas.Controller.create () in
  let layer = make_layer ~name:"L1" [make_rect 0.0 0.0 10.0 10.0] in
  ctrl4#add_layer layer;
  assert (List.length ctrl4#document.Jas.Document.layers = 1);

  (* Test remove_layer *)
  let l1 = make_layer ~name:"A" [] in
  let l2 = make_layer ~name:"B" [] in
  let doc5 = Jas.Document.make_document [l1; l2] in
  let model5 = Jas.Model.create ~document:doc5 () in
  let ctrl5 = Jas.Controller.create ~model:model5 () in
  ctrl5#remove_layer 0;
  assert (List.length ctrl5#document.Jas.Document.layers = 1);
  (match List.hd ctrl5#document.Jas.Document.layers with
   | Layer { name; _ } -> assert (name = "B")
   | _ -> assert false);

  (* Test set_document *)
  let ctrl6 = Jas.Controller.create () in
  let new_doc = Jas.Document.make_document ~title:"Replaced" [] in
  ctrl6#set_document new_doc;
  assert (ctrl6#document.Jas.Document.title = "Replaced");

  (* Test mutations notify model *)
  let model7 = Jas.Model.create () in
  let ctrl7 = Jas.Controller.create ~model:model7 () in
  let received = ref [] in
  model7#on_document_changed (fun doc -> received := doc.Jas.Document.title :: !received);
  ctrl7#set_title "Changed";
  assert (!received = ["Changed"]);

  (* Test model immutability: old snapshots unchanged *)
  let ctrl8 = Jas.Controller.create () in
  let before = ctrl8#document in
  ctrl8#set_title "New";
  let after = ctrl8#document in
  assert (before.Jas.Document.title = "Untitled");
  assert (after.Jas.Document.title = "New");

  Printf.printf "All controller tests passed.\n"
