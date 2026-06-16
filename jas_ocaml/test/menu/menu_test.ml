open Jas.Element

let tests = [
  (* === group_selection tests === *)

  Alcotest.test_case "group_selection groups 2 sibling rects" `Quick (fun () ->
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

  Alcotest.test_case "group_selection with fewer than 2 elements does nothing" `Quick (fun () ->
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

  (* === make_instance tests === *)

  Alcotest.test_case "make_instance creates an offset selected reference" `Quick (fun () ->
    (* Make Instance = create_reference + move_selection(24, 24) under a
       single snapshot. After it: a reference targeting the source's id
       exists, is offset by (24, 24) via its common transform, and is the
       selection. The source keeps its position. Mirrors the Rust
       make_instance_creates_offset_selected_reference test. *)
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.element_selection_all [0; 0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.make_instance model ();
    let doc = model#document in
    (* Source rect untouched at the origin. *)
    (match Jas.Document.get_element doc [0; 0] with
     | Rect { x; y; _ } -> assert (x = 0.0 && y = 0.0)
     | _ -> assert false);
    (* New reference at [0; 1], targeting the source, offset by (24, 24)
       on its common transform; the dead instance transform stays None. *)
    (match Jas.Document.get_element doc [0; 1] with
     | Live (Reference re) ->
       (* The target id is the (minted) source id, not empty. *)
       assert (String.length re.ref_target > 0);
       assert (re.ref_id <> None);
       (match re.ref_transform with
        | Some t -> assert (t.e = 24.0 && t.f = 24.0)
        | None -> assert false);
       assert (re.ref_instance_transform = None)
     | _ -> assert false);
    (* The source now carries the minted target id, and the reference
       points at exactly that id. *)
    (match Jas.Document.get_element doc [0; 0],
           Jas.Document.get_element doc [0; 1] with
     | src, Live (Reference re) ->
       assert (id_of src = Some re.ref_target)
     | _ -> assert false);
    (* The reference is the whole-element selection. *)
    let bindings = Jas.Document.PathMap.bindings doc.Jas.Document.selection in
    (match bindings with
     | [ (path, es) ] ->
       assert (path = [0; 1]);
       assert (es.Jas.Document.es_kind = Jas.Document.SelKindAll)
     | _ -> assert false);
    (* Single snapshot => one undo restores the pre-Make-Instance state
       (just the source rect, no reference). *)
    model#undo;
    let doc = model#document in
    let children = Jas.Document.children_of doc.Jas.Document.layers.(0) in
    assert (Array.length children = 1);
    (match children.(0) with Rect _ -> () | _ -> assert false));

  Alcotest.test_case "make_instance is a no-op with no selection" `Quick (fun () ->
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.make_instance model ();
    let children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (Array.length children = 1));

  Alcotest.test_case "make_instance is a no-op with two elements selected" `Quick (fun () ->
    let r1 = make_rect 0.0 0.0 10.0 10.0 in
    let r2 = make_rect 20.0 20.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r1; r2|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.empty
      |> Jas.Document.PathMap.add [0; 0] (Jas.Document.element_selection_all [0; 0])
      |> Jas.Document.PathMap.add [0; 1] (Jas.Document.element_selection_all [0; 1]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.make_instance model ();
    let children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (Array.length children = 2));

  Alcotest.test_case "make_instance is a no-op for a control-point sub-selection" `Quick (fun () ->
    (* Only a partial (control-point) selection: not a whole element, so
       no reference is created. *)
    let r = make_rect 0.0 0.0 10.0 10.0 in
    let layer = make_layer ~name:"L0" [|r|] in
    let doc = Jas.Document.make_document [|layer|] in
    let sel = Jas.Document.PathMap.singleton [0; 0]
      (Jas.Document.element_selection_partial [0; 0] [0]) in
    let doc = { doc with Jas.Document.selection = sel } in
    let model = Jas.Model.create ~document:doc () in
    Jas.Menubar.make_instance model ();
    let children = Jas.Document.children_of model#document.Jas.Document.layers.(0) in
    assert (Array.length children = 1));

  (* === ungroup_selection tests === *)

  Alcotest.test_case "ungroup_selection ungroups a selected group" `Quick (fun () ->
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

  Alcotest.test_case "ungroup_selection on non-group does nothing" `Quick (fun () ->
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

  Alcotest.test_case "ungroup_all flattens nested groups" `Quick (fun () ->
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

  Alcotest.test_case "ungroup_all preserves locked groups" `Quick (fun () ->
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

  Alcotest.test_case "ungroup_all with no groups does nothing" `Quick (fun () ->
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

  Alcotest.test_case "is_svg returns true for <svg> string" `Quick (fun () ->
    assert (Jas.Menubar.is_svg "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));

  Alcotest.test_case "is_svg returns true for <?xml> string" `Quick (fun () ->
    assert (Jas.Menubar.is_svg "<?xml version=\"1.0\"?><svg></svg>"));

  Alcotest.test_case "is_svg returns true with leading whitespace" `Quick (fun () ->
    assert (Jas.Menubar.is_svg "  \n  <svg></svg>"));

  Alcotest.test_case "is_svg returns false for plain text" `Quick (fun () ->
    assert (not (Jas.Menubar.is_svg "hello world")));

  Alcotest.test_case "is_svg returns false for empty string" `Quick (fun () ->
    assert (not (Jas.Menubar.is_svg "")));

  Alcotest.test_case "is_svg returns false for HTML" `Quick (fun () ->
    assert (not (Jas.Menubar.is_svg "<html><body></body></html>")));

  (* === lock_selection / unlock_all tests === *)

  Alcotest.test_case "lock_selection locks selected elements" `Quick (fun () ->
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

  Alcotest.test_case "unlock_all unlocks all locked elements" `Quick (fun () ->
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

  Alcotest.test_case "lock then unlock round-trip" `Quick (fun () ->
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

  Alcotest.test_case "hide_selection hides selected elements" `Quick (fun () ->
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

  Alcotest.test_case "show_all restores hidden elements" `Quick (fun () ->
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

  Alcotest.test_case "hide then show round-trip" `Quick (fun () ->
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
]

let () =
  Alcotest.run "Menu" [
    "Menu tests", tests;
  ]
