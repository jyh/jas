let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let () =
  let open Jas.Element in
  Printf.printf "Menu tests:\n";

  (* === group_selection tests === *)

  run_test "group_selection groups 2 sibling rects" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    (* Select both rects *)
    let sel = Jas.Document.PathMap.empty
      |> Jas.Document.PathMap.add [0; 0] (Jas.Document.make_element_selection [0; 0])
      |> Jas.Document.PathMap.add [0; 1] (Jas.Document.make_element_selection [0; 1]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.group_selection model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    (* Layer should have 1 child (the group) *)
    assert (Array.length layer_children = 1);
    (* The group should have 2 children *)
    match layer_children.(0) with
    | Group { children; _ } ->
      assert (Array.length children = 2)
    | _ -> assert false);

  run_test "group_selection with fewer than 2 elements does nothing" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.group_selection model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (Array.length layer_children = 1));

  (* === ungroup_selection tests === *)

  run_test "ungroup_selection ungroups a selected group" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let group = make_group [|r1; r2|] in
    let layer = make_layer ~name:"L0" [|group|] in
    let doc = Jas.Document.make_document [|layer|] in
    (* Select the group *)
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.ungroup_selection model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    (* Layer should now have 2 children (the ungrouped rects) *)
    assert (Array.length layer_children = 2));

  run_test "ungroup_selection on non-group does nothing" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.ungroup_selection model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (Array.length layer_children = 1));

  (* === ungroup_all tests === *)

  run_test "ungroup_all flattens nested groups" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let r3 = make_rect 40.0 40.0 10.0 10.0 in
    let inner_group = make_group [|r2; r3|] in
    let outer_group = make_group [|r1; inner_group|] in
    let layer = make_layer ~name:"L0" [|outer_group|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.ungroup_all model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    (* All 3 rects should be direct children of the layer *)
    assert (Array.length layer_children = 3));

  run_test "ungroup_all preserves locked groups" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let locked_group = make_group ~locked:true [|r1; r2|] in
    let layer = make_layer ~name:"L0" [|locked_group|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.ungroup_all model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    (* Locked group stays as a group *)
    assert (Array.length layer_children = 1);
    match layer_children.(0) with
    | Group _ -> ()
    | _ -> assert false);

  run_test "ungroup_all with no groups does nothing" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.ungroup_all model ();
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (Array.length layer_children = 2));

  (* === is_svg tests === *)

  run_test "is_svg returns true for <svg> string" (fun () ->
    assert (Jas.Menubar.is_svg "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));

  run_test "is_svg returns true for <?xml> string" (fun () ->
    assert (Jas.Menubar.is_svg "<?xml version=\"1.0\"?><svg></svg>"));

  run_test "is_svg returns true with leading whitespace" (fun () ->
    assert (Jas.Menubar.is_svg "  \n  <svg></svg>"));

  run_test "is_svg returns false for plain text" (fun () ->
    assert (not (Jas.Menubar.is_svg "hello world")));

  run_test "is_svg returns false for empty string" (fun () ->
    assert (not (Jas.Menubar.is_svg "")));

  run_test "is_svg returns false for HTML" (fun () ->
    assert (not (Jas.Menubar.is_svg "<html><body></body></html>")));

  (* === lock_selection / unlock_all tests === *)

  run_test "lock_selection locks selected elements" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.empty
      |> Jas.Document.PathMap.add [0; 0] (Jas.Document.make_element_selection [0; 0])
      |> Jas.Document.PathMap.add [0; 1] (Jas.Document.make_element_selection [0; 1]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    model#snapshot;
    ctrl#lock_selection;
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (is_locked layer_children.(0));
    assert (is_locked layer_children.(1));
    (* Selection should be cleared after locking *)
    assert (Jas.Document.PathMap.is_empty doc.Jas.Document.selection));

  run_test "unlock_all unlocks all locked elements" (fun () ->
    let r1 = make_rect ~locked:true 0.0 0.0 10.0 10.0 in
    let r2 = make_rect ~locked:true 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    model#snapshot;
    ctrl#unlock_all;
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (not (is_locked layer_children.(0)));
    assert (not (is_locked layer_children.(1))));

  run_test "lock then unlock round-trip" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    (* Lock *)
    model#snapshot;
    ctrl#lock_selection;
    let layer_children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (is_locked layer_children.(0));
    (* Unlock *)
    model#snapshot;
    ctrl#unlock_all;
    let layer_children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (not (is_locked layer_children.(0))));

  (* === hide_selection / show_all tests === *)

  run_test "hide_selection hides selected elements" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.empty
      |> Jas.Document.PathMap.add [0; 0] (Jas.Document.make_element_selection [0; 0])
      |> Jas.Document.PathMap.add [0; 1] (Jas.Document.make_element_selection [0; 1]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    model#snapshot;
    ctrl#hide_selection;
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (get_visibility layer_children.(0) = Invisible);
    assert (get_visibility layer_children.(1) = Invisible);
    (* Selection should be cleared after hiding *)
    assert (Jas.Document.PathMap.is_empty doc.Jas.Document.selection));

  run_test "show_all restores hidden elements" (fun () ->
    let r1 = set_visibility Invisible (make_rect 0.0 0.0 10.0 10.0) in
    let r2 = set_visibility Invisible (make_rect 20.0 20.0 10.0 10.0) in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    model#snapshot;
    ctrl#show_all;
    let doc = model#document in
    let layer_children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (get_visibility layer_children.(0) = Preview);
    assert (get_visibility layer_children.(1) = Preview));

  run_test "hide then show round-trip" (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.make_element_selection [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    let ctrl = Jas.Controller.create ~model () in
    (* Hide *)
    model#snapshot;
    ctrl#hide_selection;
    let layer_children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (get_visibility layer_children.(0) = Invisible);
    (* Show *)
    model#snapshot;
    ctrl#show_all;
    let layer_children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (get_visibility layer_children.(0) = Preview));

  Printf.printf "All menu tests passed.\n"
