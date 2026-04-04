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

  (* Helper: extract paths from selection *)
  let sel_paths sel =
    Jas.Document.PathMap.fold (fun p _ acc -> Jas.Document.PathSet.add p acc)
      sel Jas.Document.PathSet.empty
  in

  (* Test set_selection *)
  let sel = Jas.Document.PathMap.singleton [0; 0]
    (Jas.Document.make_element_selection [0; 0]) in
  ctrl_s#set_selection sel;
  assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
    (Jas.Document.PathSet.singleton [0; 0]));

  (* Test set_selection clears *)
  ctrl_s#set_selection Jas.Document.PathMap.empty;
  assert (Jas.Document.PathMap.is_empty ctrl_s#document.Jas.Document.selection);

  (* Test select_element: direct child of layer *)
  ctrl_s#select_element [0; 0];
  assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
    (Jas.Document.PathSet.singleton [0; 0]));

  (* Test select_element: child inside a group selects all group children *)
  ctrl_s#select_element [0; 1; 0];
  let expected = Jas.Document.PathSet.of_list [[0; 1; 0]; [0; 1; 1]] in
  assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection) expected);

  (* Test select_element: other child of same group *)
  ctrl_s#select_element [0; 1; 1];
  assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection) expected);

  (* Test select_element: layer path *)
  ctrl_s#select_element [0];
  assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
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
  assert (Jas.Document.PathMap.mem [0; 0] sctrl#document.Jas.Document.selection);

  (* select_rect misses all *)
  sctrl#select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathMap.is_empty sctrl#document.Jas.Document.selection);

  (* select_rect group expansion *)
  sctrl#select_rect (-1.0) (-1.0) 7.0 7.0;
  let expected_sr = Jas.Document.PathSet.of_list [[0; 1; 0]; [0; 1; 1]] in
  assert (Jas.Document.PathSet.equal (sel_paths sctrl#document.Jas.Document.selection) expected_sr);

  (* select_rect replaces previous *)
  sctrl#set_selection (Jas.Document.PathMap.singleton [0; 0]
    (Jas.Document.make_element_selection [0; 0]));
  sctrl#select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathMap.is_empty sctrl#document.Jas.Document.selection);

  (* select_rect multiple elements *)
  sctrl#select_rect (-1.0) (-1.0) 120.0 120.0;
  assert (Jas.Document.PathMap.mem [0; 0] sctrl#document.Jas.Document.selection);
  assert (Jas.Document.PathMap.mem [0; 1; 0] sctrl#document.Jas.Document.selection);
  assert (Jas.Document.PathMap.mem [0; 1; 1] sctrl#document.Jas.Document.selection);

  (* === Precise geometric hit-testing tests === *)

  (* Diagonal line: marquee in bbox corner misses *)
  let diag_line = make_line 0.0 0.0 100.0 100.0 in
  let diag_layer = make_layer ~name:"L0" [diag_line] in
  let diag_doc = Jas.Document.make_document [diag_layer] in
  let diag_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:diag_doc ()) () in
  diag_ctrl#select_rect 80.0 0.0 20.0 20.0;
  assert (Jas.Document.PathMap.is_empty diag_ctrl#document.Jas.Document.selection);

  (* Diagonal line: marquee crossing the line hits *)
  diag_ctrl#select_rect 40.0 40.0 20.0 20.0;
  assert (Jas.Document.PathMap.mem [0; 0] diag_ctrl#document.Jas.Document.selection);

  (* Stroke-only rect: marquee inside interior misses *)
  let stroke_rect = make_rect 0.0 0.0 100.0 100.0 in
  let sr_layer = make_layer ~name:"L0" [stroke_rect] in
  let sr_doc = Jas.Document.make_document [sr_layer] in
  let sr_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:sr_doc ()) () in
  sr_ctrl#select_rect 30.0 30.0 10.0 10.0;
  assert (Jas.Document.PathMap.is_empty sr_ctrl#document.Jas.Document.selection);

  (* Filled rect: marquee inside interior hits *)
  let fill = Some { fill_color = { r = 1.0; g = 0.0; b = 0.0; a = 1.0 } } in
  let filled_rect = Rect { x = 0.0; y = 0.0; width = 100.0; height = 100.0;
                            rx = 0.0; ry = 0.0; fill;
                            stroke = None; opacity = 1.0; transform = None } in
  let fr_layer = make_layer ~name:"L0" [filled_rect] in
  let fr_doc = Jas.Document.make_document [fr_layer] in
  let fr_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:fr_doc ()) () in
  fr_ctrl#select_rect 30.0 30.0 10.0 10.0;
  assert (Jas.Document.PathMap.mem [0; 0] fr_ctrl#document.Jas.Document.selection);

  (* === Control point selection tests === *)

  let cp_line = make_line 10.0 20.0 50.0 60.0 in
  let cp_layer = make_layer ~name:"L0" [cp_line] in
  let cp_doc = Jas.Document.make_document [cp_layer] in
  let cp_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:cp_doc ()) () in

  cp_ctrl#select_control_point [0; 0] 1;
  let cp_es = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
  assert (cp_es.Jas.Document.es_selected = true);
  assert (cp_es.Jas.Document.es_control_points = [1]);

  (* Default element selection has selected=true and all control points *)
  cp_ctrl#select_element [0; 0];
  let def_es = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
  assert (def_es.Jas.Document.es_selected = true);
  (* Line has 2 control points *)
  assert (def_es.Jas.Document.es_control_points = [0; 1]);

  (* === Direct selection tests === *)

  (* direct_select_rect: no group expansion *)
  let ds_line1 = make_line 0.0 0.0 5.0 5.0 in
  let ds_line2 = make_line 50.0 50.0 55.0 55.0 in
  let ds_group = make_group [ds_line1; ds_line2] in
  let ds_layer = make_layer ~name:"L0" [ds_group] in
  let ds_doc = Jas.Document.make_document [ds_layer] in
  let ds_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_doc ()) () in
  ds_ctrl#direct_select_rect (-1.0) (-1.0) 7.0 7.0;
  assert (Jas.Document.PathMap.mem [0; 0; 0] ds_ctrl#document.Jas.Document.selection);
  assert (not (Jas.Document.PathMap.mem [0; 0; 1] ds_ctrl#document.Jas.Document.selection));

  (* direct_select_rect: selects only hit control points *)
  let ds_rect = make_rect 0.0 0.0 100.0 100.0 in
  let ds_rlayer = make_layer ~name:"L0" [ds_rect] in
  let ds_rdoc = Jas.Document.make_document [ds_rlayer] in
  let ds_rctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_rdoc ()) () in
  ds_rctrl#direct_select_rect (-5.0) (-5.0) 10.0 10.0;
  let ds_res = Jas.Document.PathMap.find [0; 0] ds_rctrl#document.Jas.Document.selection in
  assert (ds_res.Jas.Document.es_control_points = [0]);

  (* direct_select_rect: no CPs when none in rect *)
  let ds_dline = make_line 0.0 0.0 100.0 100.0 in
  let ds_dlayer = make_layer ~name:"L0" [ds_dline] in
  let ds_ddoc = Jas.Document.make_document [ds_dlayer] in
  let ds_dctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_ddoc ()) () in
  ds_dctrl#direct_select_rect 40.0 40.0 20.0 20.0;
  let ds_dres = Jas.Document.PathMap.find [0; 0] ds_dctrl#document.Jas.Document.selection in
  assert (ds_dres.Jas.Document.es_control_points = []);

  (* direct_select_rect: misses element *)
  ds_dctrl#direct_select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathMap.is_empty ds_dctrl#document.Jas.Document.selection);

  (* === Group selection tests === *)

  (* group_select_rect: no group expansion *)
  let gs_line1 = make_line 0.0 0.0 5.0 5.0 in
  let gs_line2 = make_line 50.0 50.0 55.0 55.0 in
  let gs_group = make_group [gs_line1; gs_line2] in
  let gs_layer = make_layer ~name:"L0" [gs_group] in
  let gs_doc = Jas.Document.make_document [gs_layer] in
  let gs_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:gs_doc ()) () in
  gs_ctrl#group_select_rect (-1.0) (-1.0) 7.0 7.0;
  assert (Jas.Document.PathMap.mem [0; 0; 0] gs_ctrl#document.Jas.Document.selection);
  assert (not (Jas.Document.PathMap.mem [0; 0; 1] gs_ctrl#document.Jas.Document.selection));

  (* group_select_rect: selects all control points *)
  let gs_rect = make_rect 0.0 0.0 100.0 100.0 in
  let gs_rlayer = make_layer ~name:"L0" [gs_rect] in
  let gs_rdoc = Jas.Document.make_document [gs_rlayer] in
  let gs_rctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:gs_rdoc ()) () in
  gs_rctrl#group_select_rect (-5.0) (-5.0) 10.0 10.0;
  let gs_res = Jas.Document.PathMap.find [0; 0] gs_rctrl#document.Jas.Document.selection in
  assert (gs_res.Jas.Document.es_control_points = [0; 1; 2; 3]);

  (* group_select_rect: misses element *)
  gs_rctrl#group_select_rect 200.0 200.0 10.0 10.0;
  assert (Jas.Document.PathMap.is_empty gs_rctrl#document.Jas.Document.selection);

  (* === Extend (shift-toggle) selection tests === *)

  let ext_rect1 = make_rect 0.0 0.0 10.0 10.0 in
  let ext_rect2 = make_rect 50.0 50.0 10.0 10.0 in
  let ext_layer = make_layer ~name:"L0" [ext_rect1; ext_rect2] in
  let ext_doc = Jas.Document.make_document [ext_layer] in
  let ext_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ext_doc ()) () in

  (* extend adds new element *)
  ext_ctrl#select_rect (-1.0) (-1.0) 12.0 12.0;
  assert (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection);
  assert (not (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection));
  ext_ctrl#select_rect ~extend:true 49.0 49.0 12.0 12.0;
  assert (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection);
  assert (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection);

  (* extend removes existing element *)
  ext_ctrl#select_rect ~extend:true (-1.0) (-1.0) 12.0 12.0;
  assert (not (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection));
  assert (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection);

  (* extend direct select toggles CPs, not entire elements *)
  let cp_rect = make_rect 0.0 0.0 10.0 10.0 in
  let cp_layer = make_layer ~name:"L0" [cp_rect] in
  let cp_doc = Jas.Document.make_document [cp_layer] in
  let cp_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:cp_doc ()) () in
  (* Direct select top-left corner CP 0 at (0,0) *)
  cp_ctrl#direct_select_rect (-1.0) (-1.0) 2.0 2.0;
  let es0 = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
  assert (List.sort compare es0.Jas.Document.es_control_points = [0]);
  (* Shift-direct-select top-right corner CP 1 at (10,0) — should add CP *)
  cp_ctrl#direct_select_rect ~extend:true 9.0 (-1.0) 2.0 2.0;
  let es1 = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
  assert (List.sort compare es1.Jas.Document.es_control_points = [0; 1]);
  (* Shift-direct-select top-left again — should remove CP 0, keep CP 1 *)
  cp_ctrl#direct_select_rect ~extend:true (-1.0) (-1.0) 2.0 2.0;
  let es2 = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
  assert (List.sort compare es2.Jas.Document.es_control_points = [1]);

  (* === Control point positions tests === *)

  let cp_line2 = make_line 10.0 20.0 30.0 40.0 in
  assert (Jas.Element.control_points cp_line2 = [(10.0, 20.0); (30.0, 40.0)]);

  let cp_rect2 = make_rect 5.0 10.0 20.0 30.0 in
  assert (Jas.Element.control_points cp_rect2 = [(5.0, 10.0); (25.0, 10.0); (25.0, 40.0); (5.0, 40.0)]);

  let cp_circle = make_circle 50.0 50.0 10.0 in
  assert (Jas.Element.control_points cp_circle = [(50.0, 40.0); (60.0, 50.0); (50.0, 60.0); (40.0, 50.0)]);

  let cp_ellipse = make_ellipse 50.0 50.0 20.0 10.0 in
  assert (Jas.Element.control_points cp_ellipse = [(50.0, 40.0); (70.0, 50.0); (50.0, 60.0); (30.0, 50.0)]);

  Printf.printf "All controller tests passed.\n"
