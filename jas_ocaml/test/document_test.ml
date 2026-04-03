let () =
  let open Jas.Element in
  let open Jas.Document in

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

  Printf.printf "All document tests passed.\n"
