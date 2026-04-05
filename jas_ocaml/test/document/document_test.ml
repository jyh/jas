let () =
  let open Jas.Element in
  let open Jas.Document in

  (* Test default document *)
  let doc0 = make_document [] in
  assert (List.length doc0.layers = 0);

  (* Test empty document *)
  let doc = make_document [] in
  let (x, y, w, h) = bounds doc in
  assert (x = 0.0 && y = 0.0 && w = 0.0 && h = 0.0);

  (* Test single layer *)
  let l1 = make_layer ~name:"Layer 1" [make_rect 0.0 0.0 10.0 10.0] in
  let doc2 = make_document [l1] in
  let (x, y, w, h) = bounds doc2 in
  assert (x = 0.0 && y = 0.0 && w = 10.0 && h = 10.0);

  (* Test multiple layers *)
  let l2 = make_layer ~name:"Background" [make_rect 0.0 0.0 10.0 10.0] in
  let l3 = make_layer ~name:"Foreground" [make_circle 50.0 50.0 5.0] in
  let doc3 = make_document [l2; l3] in
  let (x, y, w, h) = bounds doc3 in
  assert (x = 0.0 && y = 0.0 && w = 55.0 && h = 55.0);

  (* Test layers accessible *)
  let l4 = make_layer ~name:"A" [] in
  let l5 = make_layer ~name:"B" [] in
  let doc4 = make_document [l4; l5] in
  assert (List.length doc4.layers = 2);
  (match List.nth doc4.layers 0 with Layer { name; _ } -> assert (name = "A") | _ -> assert false);
  (match List.nth doc4.layers 1 with Layer { name; _ } -> assert (name = "B") | _ -> assert false);

  (* === Selection tests === *)

  let rect = make_rect 0.0 0.0 10.0 10.0 in
  let circle = make_circle 50.0 50.0 5.0 in
  let line = make_line 0.0 0.0 1.0 1.0 in
  let group = make_group [line] in
  let layer0 = make_layer ~name:"L0" [rect; circle; group] in
  let layer1 = make_layer ~name:"L1" [rect] in
  let doc = make_document [layer0; layer1] in

  (* Test default selection is empty *)
  assert (PathMap.is_empty doc.selection);

  (* Test selection with paths *)
  let sel = List.fold_left (fun acc p ->
    PathMap.add p (make_element_selection p) acc
  ) PathMap.empty [[0; 0]; [0; 1]] in
  let doc_sel = make_document ~selection:sel [layer0; layer1] in
  assert (PathMap.cardinal doc_sel.selection = 2);
  assert (PathMap.mem [0; 0] doc_sel.selection);
  assert (PathMap.mem [0; 1] doc_sel.selection);

  (* Test get_element: layer *)
  let elem = get_element doc [0] in
  assert (elem = layer0);

  (* Test get_element: child *)
  let elem = get_element doc [0; 1] in
  assert (elem = circle);

  (* Test get_element: nested *)
  let elem = get_element doc [0; 2; 0] in
  assert (elem = line);

  (* Test get_element: empty path raises *)
  (try
     let _ = get_element doc [] in
     assert false
   with Failure _ -> ());

  (* Test replace_element: child *)
  let new_rect = make_rect 5.0 5.0 20.0 20.0 in
  let doc2 = replace_element doc [0; 0] new_rect in
  assert (get_element doc2 [0; 0] = new_rect);
  (* original unchanged *)
  assert (get_element doc [0; 0] = rect);

  (* Test replace_element: nested *)
  let new_line = make_line 1.0 2.0 3.0 4.0 in
  let doc3 = replace_element doc [0; 2; 0] new_line in
  assert (get_element doc3 [0; 2; 0] = new_line);

  (* Test replace_element: preserves other children *)
  let doc4 = replace_element doc [0; 0] new_rect in
  assert (get_element doc4 [0; 1] = circle);
  assert (get_element doc4 [0; 2] = group);

  (* Test replace_element: preserves other layers *)
  let doc5 = replace_element doc [0; 0] new_rect in
  assert (List.nth doc5.layers 1 = layer1);

  (* Test replace_element: preserves selection *)
  let sel_map = PathMap.singleton [0; 1] (make_element_selection [0; 1]) in
  let doc_with_sel = make_document ~selection:sel_map [layer0; layer1] in
  let doc6 = replace_element doc_with_sel [0; 0] new_rect in
  assert (PathMap.mem [0; 1] doc6.selection);

  (* Test replace_element: empty path raises *)
  (try
     let _ = replace_element doc [] new_rect in
     assert false
   with Failure _ -> ());

  (* Test replace_element: result layer is still a Layer *)
  let doc7 = replace_element doc [0; 0] new_rect in
  (match List.nth doc7.layers 0 with Layer _ -> () | _ -> assert false);

  Printf.printf "All document tests passed.\n"
