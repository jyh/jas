let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

(* Helper: extract paths from selection *)
let sel_paths sel =
  Jas.Document.PathMap.fold (fun p _ acc -> Jas.Document.PathSet.add p acc)
    sel Jas.Document.PathSet.empty

let () =
  let open Jas.Element in
  Printf.printf "Controller tests:\n";

  run_test "default document" (fun () ->
    let ctrl = Jas.Controller.create () in
    assert (String.sub ctrl#model#filename 0 9 = "Untitled-");
    assert (Array.length ctrl#document.Jas.Document.layers = 1));

  run_test "initial filename" (fun () ->
    let model2 = Jas.Model.create ~filename:"Test" () in
    let ctrl2 = Jas.Controller.create ~model:model2 () in
    assert (ctrl2#model#filename = "Test"));

  run_test "set_filename" (fun () ->
    let ctrl3 = Jas.Controller.create () in
    ctrl3#set_filename "New Name";
    assert (ctrl3#model#filename = "New Name"));

  run_test "add_layer" (fun () ->
    let ctrl4 = Jas.Controller.create () in
    let layer = make_layer ~name:"L1" [|make_rect 0.0 0.0 10.0 10.0|] in
    ctrl4#add_layer layer;
    assert (Array.length ctrl4#document.Jas.Document.layers = 2));

  run_test "remove_layer" (fun () ->
    let l1 = make_layer ~name:"A" [||] in
    let l2 = make_layer ~name:"B" [||] in
    let doc5 = Jas.Document.make_document [|l1; l2|] in
    let model5 = Jas.Model.create ~document:doc5 () in
    let ctrl5 = Jas.Controller.create ~model:model5 () in
    ctrl5#remove_layer 0;
    assert (Array.length ctrl5#document.Jas.Document.layers = 1);
    (match ctrl5#document.Jas.Document.layers.(0) with
     | Layer { name; _ } -> assert (name = "B")
     | _ -> assert false));

  run_test "set_document" (fun () ->
    let ctrl6 = Jas.Controller.create () in
    let new_doc = Jas.Document.make_document [||] in
    ctrl6#set_document new_doc;
    assert (Array.length ctrl6#document.Jas.Document.layers = 0));

  run_test "set_document notifies model" (fun () ->
    let model7 = Jas.Model.create () in
    let ctrl7 = Jas.Controller.create ~model:model7 () in
    let received = ref [] in
    model7#on_document_changed (fun doc -> received := Array.length doc.Jas.Document.layers :: !received);
    ctrl7#set_document (Jas.Document.make_document [||]);
    assert (!received = [0]));

  (* === Selection controller tests === *)
  (* These tests share a controller; later ones depend on state from earlier ones *)
  let rect = make_rect 0.0 0.0 10.0 10.0 in
  let line1 = make_line 0.0 0.0 5.0 5.0 in
  let line2 = make_line 1.0 1.0 2.0 2.0 in
  let group = make_group [|line1; line2|] in
  let layer = make_layer ~name:"L0" [|rect; group|] in
  let doc_s = Jas.Document.make_document [|layer|] in
  let model_s = Jas.Model.create ~document:doc_s () in
  let ctrl_s = Jas.Controller.create ~model:model_s () in

  run_test "set_selection" (fun () ->
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    ctrl_s#set_selection sel;
    assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
      (Jas.Document.PathSet.singleton [0; 0])));

  run_test "set_selection clears" (fun () ->
    ctrl_s#set_selection Jas.Document.PathMap.empty;
    assert (Jas.Document.PathMap.is_empty ctrl_s#document.Jas.Document.selection));

  run_test "select_element: direct child of layer" (fun () ->
    ctrl_s#select_element [0; 0];
    assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
      (Jas.Document.PathSet.singleton [0; 0])));

  run_test "select_element: child inside a group selects group and all children" (fun () ->
    ctrl_s#select_element [0; 1; 0];
    let expected = Jas.Document.PathSet.of_list [[0; 1]; [0; 1; 0]; [0; 1; 1]] in
    assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection) expected));

  run_test "select_element: other child of same group" (fun () ->
    ctrl_s#select_element [0; 1; 1];
    let expected = Jas.Document.PathSet.of_list [[0; 1]; [0; 1; 0]; [0; 1; 1]] in
    assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection) expected));

  run_test "select_element: layer path" (fun () ->
    ctrl_s#select_element [0];
    assert (Jas.Document.PathSet.equal (sel_paths ctrl_s#document.Jas.Document.selection)
      (Jas.Document.PathSet.singleton [0])));

  run_test "select_element notifies model" (fun () ->
    let model_n = Jas.Model.create ~document:doc_s () in
    let ctrl_n = Jas.Controller.create ~model:model_n () in
    let notify_count = ref 0 in
    model_n#on_document_changed (fun _ -> notify_count := !notify_count + 1);
    ctrl_n#select_element [0; 0];
    assert (!notify_count = 1));

  (* === select_rect tests === *)
  let rect_far = make_rect 100.0 100.0 10.0 10.0 in
  let sline1 = make_line 0.0 0.0 5.0 5.0 in
  let sline2 = make_line 1.0 1.0 2.0 2.0 in
  let sgroup = make_group [|sline1; sline2|] in
  let slayer = make_layer ~name:"L0" [|rect_far; sgroup|] in
  let sdoc = Jas.Document.make_document [|slayer|] in
  let smodel = Jas.Model.create ~document:sdoc () in
  let sctrl = Jas.Controller.create ~model:smodel () in

  run_test "select_rect hits element" (fun () ->
    sctrl#select_rect 99.0 99.0 12.0 12.0;
    assert (Jas.Document.PathMap.mem [0; 0] sctrl#document.Jas.Document.selection));

  run_test "select_rect misses all" (fun () ->
    sctrl#select_rect 200.0 200.0 10.0 10.0;
    assert (Jas.Document.PathMap.is_empty sctrl#document.Jas.Document.selection));

  run_test "select_rect group expansion" (fun () ->
    sctrl#select_rect (-1.0) (-1.0) 7.0 7.0;
    let expected_sr = Jas.Document.PathSet.of_list [[0; 1]; [0; 1; 0]; [0; 1; 1]] in
    assert (Jas.Document.PathSet.equal (sel_paths sctrl#document.Jas.Document.selection) expected_sr));

  run_test "select_rect replaces previous" (fun () ->
    sctrl#set_selection (Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]));
    sctrl#select_rect 200.0 200.0 10.0 10.0;
    assert (Jas.Document.PathMap.is_empty sctrl#document.Jas.Document.selection));

  run_test "select_rect multiple elements" (fun () ->
    sctrl#select_rect (-1.0) (-1.0) 120.0 120.0;
    assert (Jas.Document.PathMap.mem [0; 0] sctrl#document.Jas.Document.selection);
    assert (Jas.Document.PathMap.mem [0; 1; 0] sctrl#document.Jas.Document.selection);
    assert (Jas.Document.PathMap.mem [0; 1; 1] sctrl#document.Jas.Document.selection));

  (* === Precise geometric hit-testing tests === *)

  run_test "diagonal line: marquee in bbox corner misses" (fun () ->
    let diag_line = make_line 0.0 0.0 100.0 100.0 in
    let diag_layer = make_layer ~name:"L0" [|diag_line|] in
    let diag_doc = Jas.Document.make_document [|diag_layer|] in
    let diag_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:diag_doc ()) () in
    diag_ctrl#select_rect 80.0 0.0 20.0 20.0;
    assert (Jas.Document.PathMap.is_empty diag_ctrl#document.Jas.Document.selection));

  run_test "diagonal line: marquee crossing the line hits" (fun () ->
    let diag_line = make_line 0.0 0.0 100.0 100.0 in
    let diag_layer = make_layer ~name:"L0" [|diag_line|] in
    let diag_doc = Jas.Document.make_document [|diag_layer|] in
    let diag_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:diag_doc ()) () in
    diag_ctrl#select_rect 40.0 40.0 20.0 20.0;
    assert (Jas.Document.PathMap.mem [0; 0] diag_ctrl#document.Jas.Document.selection));

  run_test "stroke-only rect: marquee inside interior misses" (fun () ->
    let stroke_rect = make_rect 0.0 0.0 100.0 100.0 in
    let sr_layer = make_layer ~name:"L0" [|stroke_rect|] in
    let sr_doc = Jas.Document.make_document [|sr_layer|] in
    let sr_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:sr_doc ()) () in
    sr_ctrl#select_rect 30.0 30.0 10.0 10.0;
    assert (Jas.Document.PathMap.is_empty sr_ctrl#document.Jas.Document.selection));

  run_test "filled rect: marquee inside interior hits" (fun () ->
    let fill = Some { fill_color = { r = 1.0; g = 0.0; b = 0.0; a = 1.0 } } in
    let filled_rect = Rect { x = 0.0; y = 0.0; width = 100.0; height = 100.0;
                              rx = 0.0; ry = 0.0; fill;
                              stroke = None; opacity = 1.0; transform = None; locked = false;
                              visibility = Jas.Element.Preview } in
    let fr_layer = make_layer ~name:"L0" [|filled_rect|] in
    let fr_doc = Jas.Document.make_document [|fr_layer|] in
    let fr_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:fr_doc ()) () in
    fr_ctrl#select_rect 30.0 30.0 10.0 10.0;
    assert (Jas.Document.PathMap.mem [0; 0] fr_ctrl#document.Jas.Document.selection));

  (* === Control point selection tests === *)
  let cp_line = make_line 10.0 20.0 50.0 60.0 in
  let cp_layer = make_layer ~name:"L0" [|cp_line|] in
  let cp_doc = Jas.Document.make_document [|cp_layer|] in
  let cp_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:cp_doc ()) () in

  run_test "select_control_point selects one CP" (fun () ->
    cp_ctrl#select_control_point [0; 0] 1;
    let cp_es = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
    match cp_es.Jas.Document.es_kind with
    | Jas.Document.SelKindPartial s ->
      assert (Jas.Document.SortedCps.to_list s = [1])
    | _ -> assert false);

  run_test "default element selection is `all`" (fun () ->
    cp_ctrl#select_element [0; 0];
    let def_es = Jas.Document.PathMap.find [0; 0] cp_ctrl#document.Jas.Document.selection in
    assert (def_es.Jas.Document.es_kind = Jas.Document.SelKindAll));

  (* === Direct selection tests === *)

  run_test "direct_select_rect: no group expansion" (fun () ->
    let ds_line1 = make_line 0.0 0.0 5.0 5.0 in
    let ds_line2 = make_line 50.0 50.0 55.0 55.0 in
    let ds_group = make_group [|ds_line1; ds_line2|] in
    let ds_layer = make_layer ~name:"L0" [|ds_group|] in
    let ds_doc = Jas.Document.make_document [|ds_layer|] in
    let ds_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_doc ()) () in
    ds_ctrl#direct_select_rect (-1.0) (-1.0) 7.0 7.0;
    assert (Jas.Document.PathMap.mem [0; 0; 0] ds_ctrl#document.Jas.Document.selection);
    assert (not (Jas.Document.PathMap.mem [0; 0; 1] ds_ctrl#document.Jas.Document.selection)));

  run_test "direct_select_rect: selects only hit control points" (fun () ->
    let ds_rect = make_rect 0.0 0.0 100.0 100.0 in
    let ds_rlayer = make_layer ~name:"L0" [|ds_rect|] in
    let ds_rdoc = Jas.Document.make_document [|ds_rlayer|] in
    let ds_rctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_rdoc ()) () in
    ds_rctrl#direct_select_rect (-5.0) (-5.0) 10.0 10.0;
    let ds_res = Jas.Document.PathMap.find [0; 0] ds_rctrl#document.Jas.Document.selection in
    match ds_res.Jas.Document.es_kind with
    | Jas.Document.SelKindPartial s ->
      assert (Jas.Document.SortedCps.to_list s = [0])
    | _ -> assert false);

  (* ds_dctrl is shared across two tests *)
  let ds_dline = make_line 0.0 0.0 100.0 100.0 in
  let ds_dlayer = make_layer ~name:"L0" [|ds_dline|] in
  let ds_ddoc = Jas.Document.make_document [|ds_dlayer|] in
  let ds_dctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ds_ddoc ()) () in

  run_test "direct_select_rect: body hit without CPs yields SelKindPartial []" (fun () ->
    (* The Direct Selection tool must not promote "body intersects"
       to "every CP selected" (which is what [SelKindAll] would
       mean). Instead the element is selected with an empty CP set. *)
    ds_dctrl#direct_select_rect 40.0 40.0 20.0 20.0;
    let ds_dres = Jas.Document.PathMap.find [0; 0] ds_dctrl#document.Jas.Document.selection in
    match ds_dres.Jas.Document.es_kind with
    | Jas.Document.SelKindPartial s ->
      assert (Jas.Document.SortedCps.to_list s = [])
    | _ -> assert false);

  run_test "direct_select_rect: misses element" (fun () ->
    ds_dctrl#direct_select_rect 200.0 200.0 10.0 10.0;
    assert (Jas.Document.PathMap.is_empty ds_dctrl#document.Jas.Document.selection));

  run_test "move_control_points: Partial [] is a noop" (fun () ->
    (* Without the guard, a Rect with [Partial []] would silently
       convert to a Polygon at its original coordinates (because
       is_all=false drops into the polygon-conversion branch with no
       indices to move). *)
    let r = make_rect 1.0 2.0 10.0 20.0 in
    let moved = Jas.Element.move_control_points ~is_all:false r [] 5.0 7.0 in
    assert (moved = r));

  (* === Visibility / Hide / Show All tests === *)

  run_test "visibility ordering: Invisible < Outline < Preview" (fun () ->
    assert (compare Jas.Element.Invisible Jas.Element.Outline < 0);
    assert (compare Jas.Element.Outline Jas.Element.Preview < 0));

  run_test "hide_selection: sets Invisible and clears selection" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#select_element [0; 0];
    ctrl#hide_selection;
    assert (Jas.Document.PathMap.is_empty ctrl#document.Jas.Document.selection);
    let elem = Jas.Document.get_element ctrl#document [0; 0] in
    assert (Jas.Element.get_visibility elem = Jas.Element.Invisible));

  run_test "hidden element: not selectable via select_rect" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#select_element [0; 0];
    ctrl#hide_selection;
    ctrl#select_rect (-1.0) (-1.0) 12.0 12.0;
    let paths = sel_paths ctrl#document.Jas.Document.selection in
    assert (not (Jas.Document.PathSet.mem [0; 0] paths)));

  run_test "hidden element: not selectable via select_element" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#select_element [0; 0];
    ctrl#hide_selection;
    ctrl#select_element [0; 0];
    assert (Jas.Document.PathMap.is_empty ctrl#document.Jas.Document.selection));

  run_test "invisible group caps children effective visibility" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let g = make_group [|r|] in
    let layer = make_layer ~name:"L0" [|g|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#select_element [0; 0];
    ctrl#hide_selection;
    let doc2 = ctrl#document in
    (* Group itself is Invisible *)
    assert (Jas.Element.get_visibility (Jas.Document.get_element doc2 [0; 0])
            = Jas.Element.Invisible);
    (* Child's own flag is unchanged *)
    assert (Jas.Element.get_visibility (Jas.Document.get_element doc2 [0; 0; 0])
            = Jas.Element.Preview);
    (* But effective visibility of child is Invisible *)
    assert (Jas.Document.effective_visibility doc2 [0; 0; 0]
            = Jas.Element.Invisible));

  run_test "show_all: resets invisible elements and selects them" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 50.0 50.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#set_selection
      (Jas.Document.PathMap.add [0; 0] (Jas.Document.element_selection_all [0; 0])
        (Jas.Document.PathMap.add [0; 1] (Jas.Document.element_selection_all [0; 1])
          Jas.Document.PathMap.empty));
    ctrl#hide_selection;
    ctrl#show_all;
    let doc2 = ctrl#document in
    assert (Jas.Element.get_visibility (Jas.Document.get_element doc2 [0; 0])
            = Jas.Element.Preview);
    assert (Jas.Element.get_visibility (Jas.Document.get_element doc2 [0; 1])
            = Jas.Element.Preview);
    let paths = sel_paths doc2.Jas.Document.selection in
    assert (Jas.Document.PathSet.mem [0; 0] paths);
    assert (Jas.Document.PathSet.mem [0; 1] paths);
    assert (Jas.Document.PathSet.cardinal paths = 2));

  run_test "show_all: nothing hidden leaves empty selection" (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:doc ()) () in
    ctrl#show_all;
    assert (Jas.Document.PathMap.is_empty ctrl#document.Jas.Document.selection));

  (* === Group selection tests === *)

  run_test "group_select_rect: no group expansion" (fun () ->
    let gs_line1 = make_line 0.0 0.0 5.0 5.0 in
    let gs_line2 = make_line 50.0 50.0 55.0 55.0 in
    let gs_group = make_group [|gs_line1; gs_line2|] in
    let gs_layer = make_layer ~name:"L0" [|gs_group|] in
    let gs_doc = Jas.Document.make_document [|gs_layer|] in
    let gs_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:gs_doc ()) () in
    gs_ctrl#group_select_rect (-1.0) (-1.0) 7.0 7.0;
    assert (Jas.Document.PathMap.mem [0; 0; 0] gs_ctrl#document.Jas.Document.selection);
    assert (not (Jas.Document.PathMap.mem [0; 0; 1] gs_ctrl#document.Jas.Document.selection)));

  (* gs_rctrl is shared across two tests *)
  let gs_rect = make_rect 0.0 0.0 100.0 100.0 in
  let gs_rlayer = make_layer ~name:"L0" [|gs_rect|] in
  let gs_rdoc = Jas.Document.make_document [|gs_rlayer|] in
  let gs_rctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:gs_rdoc ()) () in

  run_test "group_select_rect: selects element as a whole" (fun () ->
    gs_rctrl#group_select_rect (-5.0) (-5.0) 10.0 10.0;
    let gs_res = Jas.Document.PathMap.find [0; 0] gs_rctrl#document.Jas.Document.selection in
    assert (gs_res.Jas.Document.es_kind = Jas.Document.SelKindAll));

  run_test "group_select_rect: misses element" (fun () ->
    gs_rctrl#group_select_rect 200.0 200.0 10.0 10.0;
    assert (Jas.Document.PathMap.is_empty gs_rctrl#document.Jas.Document.selection));

  (* === Extend (shift-toggle) selection tests === *)
  let ext_rect1 = make_rect 0.0 0.0 10.0 10.0 in
  let ext_rect2 = make_rect 50.0 50.0 10.0 10.0 in
  let ext_layer = make_layer ~name:"L0" [|ext_rect1; ext_rect2|] in
  let ext_doc = Jas.Document.make_document [|ext_layer|] in
  let ext_ctrl = Jas.Controller.create ~model:(Jas.Model.create ~document:ext_doc ()) () in

  run_test "extend adds new element" (fun () ->
    ext_ctrl#select_rect (-1.0) (-1.0) 12.0 12.0;
    assert (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection);
    assert (not (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection));
    ext_ctrl#select_rect ~extend:true 49.0 49.0 12.0 12.0;
    assert (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection);
    assert (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection));

  run_test "extend removes existing element" (fun () ->
    ext_ctrl#select_rect ~extend:true (-1.0) (-1.0) 12.0 12.0;
    assert (not (Jas.Document.PathMap.mem [0; 0] ext_ctrl#document.Jas.Document.selection));
    assert (Jas.Document.PathMap.mem [0; 1] ext_ctrl#document.Jas.Document.selection));

  run_test "extend direct select toggles CPs, not entire elements" (fun () ->
    let kind_to_cps k =
      match k with
      | Jas.Document.SelKindPartial s -> Jas.Document.SortedCps.to_list s
      | Jas.Document.SelKindAll -> assert false
    in
    let cp_rect2 = make_rect 0.0 0.0 10.0 10.0 in
    let cp_layer2 = make_layer ~name:"L0" [|cp_rect2|] in
    let cp_doc2 = Jas.Document.make_document [|cp_layer2|] in
    let cp_ctrl2 = Jas.Controller.create ~model:(Jas.Model.create ~document:cp_doc2 ()) () in
    (* Direct select top-left corner CP 0 at (0,0) *)
    cp_ctrl2#direct_select_rect (-1.0) (-1.0) 2.0 2.0;
    let es0 = Jas.Document.PathMap.find [0; 0] cp_ctrl2#document.Jas.Document.selection in
    assert (kind_to_cps es0.Jas.Document.es_kind = [0]);
    (* Shift-direct-select top-right corner CP 1 at (10,0) — should add CP *)
    cp_ctrl2#direct_select_rect ~extend:true 9.0 (-1.0) 2.0 2.0;
    let es1 = Jas.Document.PathMap.find [0; 0] cp_ctrl2#document.Jas.Document.selection in
    assert (kind_to_cps es1.Jas.Document.es_kind = [0; 1]);
    (* Shift-direct-select top-left again — should remove CP 0, keep CP 1 *)
    cp_ctrl2#direct_select_rect ~extend:true (-1.0) (-1.0) 2.0 2.0;
    let es2 = Jas.Document.PathMap.find [0; 0] cp_ctrl2#document.Jas.Document.selection in
    assert (kind_to_cps es2.Jas.Document.es_kind = [1]));

  (* === Control point positions tests === *)

  run_test "control_points: line" (fun () ->
    let cp_line2 = make_line 10.0 20.0 30.0 40.0 in
    assert (Jas.Element.control_points cp_line2 = [(10.0, 20.0); (30.0, 40.0)]));

  run_test "control_points: rect" (fun () ->
    let cp_rect2 = make_rect 5.0 10.0 20.0 30.0 in
    assert (Jas.Element.control_points cp_rect2 = [(5.0, 10.0); (25.0, 10.0); (25.0, 40.0); (5.0, 40.0)]));

  run_test "control_points: circle" (fun () ->
    let cp_circle = make_circle 50.0 50.0 10.0 in
    assert (Jas.Element.control_points cp_circle = [(50.0, 40.0); (60.0, 50.0); (50.0, 60.0); (40.0, 50.0)]));

  run_test "control_points: ellipse" (fun () ->
    let cp_ellipse = make_ellipse 50.0 50.0 20.0 10.0 in
    assert (Jas.Element.control_points cp_ellipse = [(50.0, 40.0); (70.0, 50.0); (50.0, 60.0); (30.0, 50.0)]));

  (* === Move control points tests === *)

  run_test "move line both CPs" (fun () ->
    let mv_line = make_line 10.0 20.0 30.0 40.0 in
    let mv_line2 = Jas.Element.move_control_points ~is_all:true mv_line [0; 1] 5.0 (-3.0) in
    (match mv_line2 with
     | Line { x1; y1; x2; y2; _ } ->
       assert (x1 = 15.0); assert (y1 = 17.0);
       assert (x2 = 35.0); assert (y2 = 37.0)
     | _ -> assert false));

  run_test "move line one CP" (fun () ->
    let mv_line3 = make_line 0.0 0.0 10.0 10.0 in
    let mv_line4 = Jas.Element.move_control_points mv_line3 [1] 5.0 5.0 in
    (match mv_line4 with
     | Line { x1; y1; x2; y2; _ } ->
       assert (x1 = 0.0); assert (y1 = 0.0);
       assert (x2 = 15.0); assert (y2 = 15.0)
     | _ -> assert false));

  run_test "move rect all CPs — translate" (fun () ->
    let mv_rect = make_rect 10.0 20.0 30.0 40.0 in
    let mv_rect2 = Jas.Element.move_control_points ~is_all:true mv_rect [0; 1; 2; 3] 5.0 (-5.0) in
    (match mv_rect2 with
     | Rect { x; y; width; height; _ } ->
       assert (x = 15.0); assert (y = 15.0);
       assert (width = 30.0); assert (height = 40.0)
     | _ -> assert false));

  run_test "move circle all CPs — translate" (fun () ->
    let mv_circle = make_circle 50.0 50.0 10.0 in
    let mv_circle2 = Jas.Element.move_control_points ~is_all:true mv_circle [0; 1; 2; 3] 10.0 (-10.0) in
    (match mv_circle2 with
     | Circle { cx; cy; r; _ } ->
       assert (cx = 60.0); assert (cy = 40.0); assert (r = 10.0)
     | _ -> assert false));

  (* === Move selection tests === *)

  run_test "move selected line" (fun () ->
    let ms_line = make_line 10.0 20.0 30.0 40.0 in
    let ms_layer = make_layer [|ms_line|] in
    let ms_sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.element_selection_all [0; 0]) in
    let ms_doc = Jas.Document.make_document ~selection:ms_sel [|ms_layer|] in
    let ms_model = Jas.Model.create ~document:ms_doc () in
    let ms_ctrl = Jas.Controller.create ~model:ms_model () in
    ms_ctrl#move_selection 5.0 (-3.0);
    let ms_moved = Jas.Document.get_element ms_ctrl#document [0; 0] in
    (match ms_moved with
     | Line { x1; y1; x2; y2; _ } ->
       assert (x1 = 15.0); assert (y1 = 17.0);
       assert (x2 = 35.0); assert (y2 = 37.0)
     | _ -> assert false));

  run_test "move partial CPs" (fun () ->
    let ms_line2 = make_line 0.0 0.0 10.0 10.0 in
    let ms_layer2 = make_layer [|ms_line2|] in
    let ms_sel2 = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.element_selection_partial [0; 0] [0]) in
    let ms_doc2 = Jas.Document.make_document ~selection:ms_sel2 [|ms_layer2|] in
    let ms_model2 = Jas.Model.create ~document:ms_doc2 () in
    let ms_ctrl2 = Jas.Controller.create ~model:ms_model2 () in
    ms_ctrl2#move_selection 5.0 5.0;
    let ms_moved2 = Jas.Document.get_element ms_ctrl2#document [0; 0] in
    (match ms_moved2 with
     | Line { x1; y1; x2; y2; _ } ->
       assert (x1 = 5.0); assert (y1 = 5.0);
       assert (x2 = 10.0); assert (y2 = 10.0)
     | _ -> assert false));

  (* === Copy selection tests === *)
  (* cp_ctrl3 is shared across two tests *)
  let cp_rect3 = make_rect 10.0 20.0 30.0 40.0 in
  let cp_layer3 = make_layer ~name:"L0" [|cp_rect3|] in
  let cp_sel3 = Jas.Document.PathMap.singleton [0; 0]
    (Jas.Document.element_selection_all [0; 0]) in
  let cp_doc3 = Jas.Document.make_document ~selection:cp_sel3 [|cp_layer3|] in
  let cp_model3 = Jas.Model.create ~document:cp_doc3 () in
  let cp_ctrl3 = Jas.Controller.create ~model:cp_model3 () in

  run_test "copy_selection copies element with offset" (fun () ->
    cp_ctrl3#copy_selection 5.0 5.0;
    assert (Array.length (Jas.Document.children_of cp_ctrl3#document.Jas.Document.layers.(0)) = 2);
    let cp_orig = (Jas.Document.children_of cp_ctrl3#document.Jas.Document.layers.(0)).(0) in
    let cp_copy = (Jas.Document.children_of cp_ctrl3#document.Jas.Document.layers.(0)).(1) in
    (match cp_orig with Rect { x; y; _ } -> assert (x = 10.0 && y = 20.0) | _ -> assert false);
    (match cp_copy with Rect { x; y; _ } -> assert (x = 15.0 && y = 25.0) | _ -> assert false));

  run_test "copy selection updates selection to point to the copy" (fun () ->
    let cp_paths = sel_paths cp_ctrl3#document.Jas.Document.selection in
    assert (Jas.Document.PathSet.mem [0; 1] cp_paths);
    assert (not (Jas.Document.PathSet.mem [0; 0] cp_paths)));

  (* === Delete selection with nested groups === *)

  run_test "delete element from inside a group" (fun () ->
    let ds_l1 = make_line 0.0 0.0 1.0 1.0 in
    let ds_l2 = make_line 2.0 2.0 3.0 3.0 in
    let ds_grp = make_group [|ds_l1; ds_l2|] in
    let ds_layer2 = make_layer ~name:"L0" [|ds_grp|] in
    let ds_sel = Jas.Document.PathMap.singleton [0; 0; 0]
      (Jas.Document.make_element_selection [0; 0; 0]) in
    let ds_doc2 = Jas.Document.make_document ~selection:ds_sel [|ds_layer2|] in
    let ds_doc3 = Jas.Document.delete_selection ds_doc2 in
    let ds_inner = ds_doc3.Jas.Document.layers.(0) in
    assert (Array.length (Jas.Document.children_of ds_inner) = 1);
    let ds_grp2 = (Jas.Document.children_of ds_inner).(0) in
    assert (Array.length (Jas.Document.children_of ds_grp2) = 1);
    assert ((Jas.Document.children_of ds_grp2).(0) = ds_l2);
    assert (Jas.Document.PathMap.is_empty ds_doc3.Jas.Document.selection));

  run_test "delete from nested group (two levels deep)" (fun () ->
    let dn_line = make_line 0.0 0.0 1.0 1.0 in
    let dn_rect = make_rect 0.0 0.0 5.0 5.0 in
    let dn_inner = make_group [|dn_line; dn_rect|] in
    let dn_outer = make_group [|dn_inner|] in
    let dn_layer = make_layer ~name:"L0" [|dn_outer|] in
    let dn_sel = Jas.Document.PathMap.singleton [0; 0; 0; 1]
      (Jas.Document.make_element_selection [0; 0; 0; 1]) in
    let dn_doc = Jas.Document.make_document ~selection:dn_sel [|dn_layer|] in
    let dn_doc2 = Jas.Document.delete_selection dn_doc in
    let dn_inner2 = (Jas.Document.children_of (Jas.Document.children_of dn_doc2.Jas.Document.layers.(0)).(0)).(0) in
    assert (Array.length (Jas.Document.children_of dn_inner2) = 1);
    assert ((Jas.Document.children_of dn_inner2).(0) = dn_line));

  run_test "delete multiple elements from same group" (fun () ->
    let dm_l1 = make_line 0.0 0.0 1.0 1.0 in
    let dm_l2 = make_line 2.0 2.0 3.0 3.0 in
    let dm_l3 = make_line 4.0 4.0 5.0 5.0 in
    let dm_grp = make_group [|dm_l1; dm_l2; dm_l3|] in
    let dm_layer = make_layer ~name:"L0" [|dm_grp|] in
    let dm_sel = List.fold_left (fun acc p ->
      Jas.Document.PathMap.add p (Jas.Document.make_element_selection p) acc
    ) Jas.Document.PathMap.empty [[0; 0; 0]; [0; 0; 2]] in
    let dm_doc = Jas.Document.make_document ~selection:dm_sel [|dm_layer|] in
    let dm_doc2 = Jas.Document.delete_selection dm_doc in
    let dm_grp2 = (Jas.Document.children_of dm_doc2.Jas.Document.layers.(0)).(0) in
    assert (Array.length (Jas.Document.children_of dm_grp2) = 1);
    assert ((Jas.Document.children_of dm_grp2).(0) = dm_l2));

  Printf.printf "All controller tests passed.\n"
