let () =
  let open Jas.Element in

  (* Test default document *)
  let ctrl = Jas.Controller.create () in
  assert (ctrl#document.Jas.Document.title = "Untitled");
  assert (List.length ctrl#document.Jas.Document.layers = 1);

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
  assert (List.length ctrl4#document.Jas.Document.layers = 2);

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

  (* === Selection controller tests === *)

  let rect = make_rect 0.0 0.0 10.0 10.0 in
  let line1 = make_line 0.0 0.0 5.0 5.0 in
  let line2 = make_line 1.0 1.0 2.0 2.0 in
  let group = make_group [line1; line2] in
  let layer = make_layer ~name:"L0" [rect; group] in
  let doc_s = Jas.Document.make_document [layer] in
  let model_s = Jas.Model.create ~document:doc_s () in
  let ctrl_s = Jas.Controller.create ~model:model_s () in

  (* Test set_selection *)
  let sel = Jas.Document.PathSet.singleton [0; 0] in
  ctrl_s#set_selection sel;
  assert (Jas.Document.PathSet.equal ctrl_s#document.Jas.Document.selection sel);

  (* Test set_selection clears *)
  ctrl_s#set_selection Jas.Document.PathSet.empty;
  assert (Jas.Document.PathSet.is_empty ctrl_s#document.Jas.Document.selection);

  (* Test select_element: direct child of layer *)
  ctrl_s#select_element [0; 0];
  assert (Jas.Document.PathSet.equal ctrl_s#document.Jas.Document.selection
    (Jas.Document.PathSet.singleton [0; 0]));

  (* Test select_element: child inside a group selects all group children *)
  ctrl_s#select_element [0; 1; 0];
  let expected = Jas.Document.PathSet.of_list [[0; 1; 0]; [0; 1; 1]] in
  assert (Jas.Document.PathSet.equal ctrl_s#document.Jas.Document.selection expected);

  (* Test select_element: other child of same group *)
  ctrl_s#select_element [0; 1; 1];
  assert (Jas.Document.PathSet.equal ctrl_s#document.Jas.Document.selection expected);

  (* Test select_element: layer path *)
  ctrl_s#select_element [0];
  assert (Jas.Document.PathSet.equal ctrl_s#document.Jas.Document.selection
    (Jas.Document.PathSet.singleton [0]));

  (* Test select_element notifies model *)
  let model_n = Jas.Model.create ~document:doc_s () in
  let ctrl_n = Jas.Controller.create ~model:model_n () in
  let notify_count = ref 0 in
  model_n#on_document_changed (fun _ -> notify_count := !notify_count + 1);
  ctrl_n#select_element [0; 0];
  assert (!notify_count = 1);

  (* === select_rect tests === *)

  let rect_far = make_rect 100.0 100.0 10.0 10.0 in
  let sline1 = make_line 0.0 0.0 5.0 5.0 in
  let sline2 = make_line 1.0 1.0 2.0 2.0 in
  let sgroup = make_group [sline1; sline2] in
  let slayer = make_layer ~name:"L0" [rect_far; sgroup] in
  let sdoc = Jas.Document.make_document [slayer] in
  let smodel = Jas.Model.create ~document:sdoc () in
  let sctrl = Jas.Controller.create ~model:smodel () in

  (* select_rect hits element *)
  sctrl#select_rect 99.0 99.0 12.0 12.0;
  assert (Jas.Document.PathSet.mem [0; 0] sctrl#document.Jas.Document.selection);

  (* select_rect misses all *)
  sctrl#select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathSet.is_empty sctrl#document.Jas.Document.selection);

  (* select_rect group expansion *)
  sctrl#select_rect (-1.0) (-1.0) 7.0 7.0;
  let expected_sr = Jas.Document.PathSet.of_list [[0; 1; 0]; [0; 1; 1]] in
  assert (Jas.Document.PathSet.equal sctrl#document.Jas.Document.selection expected_sr);

  (* select_rect replaces previous *)
  sctrl#set_selection (Jas.Document.PathSet.singleton [0; 0]);
  sctrl#select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathSet.is_empty sctrl#document.Jas.Document.selection);

  (* select_rect multiple elements *)
  sctrl#select_rect (-1.0) (-1.0) 120.0 120.0;
  assert (Jas.Document.PathSet.mem [0; 0] sctrl#document.Jas.Document.selection);
  assert (Jas.Document.PathSet.mem [0; 1; 0] sctrl#document.Jas.Document.selection);
  assert (Jas.Document.PathSet.mem [0; 1; 1] sctrl#document.Jas.Document.selection);

  Printf.printf "All controller tests passed.\n"
