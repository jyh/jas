open Jas.Element

(* Focused unit tests for the unique-id invariant enforced on import
   (Normalize.dedupe_element_ids). First-pre-order-wins: the first element to
   use a given id keeps it, later duplicates have their id cleared. A no-op
   when ids are already unique. Mirrors the Rust reference in
   geometry/normalize.rs. *)

let rect_with id x = with_id (make_rect x 0.0 10.0 10.0) id

(* Collect ids of all elements in pre-order across the document. *)
let rec collect_ids acc elem =
  let acc = acc @ [ id_of elem ] in
  match elem with
  | Group r -> Array.fold_left collect_ids acc r.children
  | Layer r -> Array.fold_left collect_ids acc r.children
  | _ -> acc

let doc_ids (doc : Jas.Document.document) =
  Array.fold_left collect_ids [] doc.Jas.Document.layers

let () =
  Alcotest.run "Normalize" [
    "dedupe_element_ids", [
      Alcotest.test_case "first duplicate keeps id, later one cleared" `Quick (fun () ->
        let layer = make_layer [|
          rect_with (Some "dup") 0.0;
          rect_with (Some "dup") 20.0;
        |] in
        let doc = Jas.Document.make_document [| layer |] in
        let out = Jas.Normalize.dedupe_element_ids doc in
        (* Layer (no id), first rect keeps "dup", second cleared. *)
        assert (doc_ids out = [ None; Some "dup"; None ]));

      Alcotest.test_case "no-op when all ids unique" `Quick (fun () ->
        let layer = make_layer [|
          rect_with (Some "a") 0.0;
          rect_with (Some "b") 20.0;
          rect_with None 40.0;
        |] in
        let doc = Jas.Document.make_document [| layer |] in
        let out = Jas.Normalize.dedupe_element_ids doc in
        assert (doc_ids out = [ None; Some "a"; Some "b"; None ]));

      Alcotest.test_case "duplicates across nested groups" `Quick (fun () ->
        let inner = make_group [|
          rect_with (Some "x") 0.0;   (* later dup -> cleared *)
          rect_with (Some "y") 20.0;
        |] in
        let layer = make_layer [|
          rect_with (Some "x") 40.0;  (* first occurrence of x -> kept *)
          inner;
        |] in
        let doc = Jas.Document.make_document [| layer |] in
        let out = Jas.Normalize.dedupe_element_ids doc in
        (* pre-order: Layer(None), rect x (kept), Group(None),
           rect x (cleared), rect y (kept) *)
        assert (doc_ids out = [ None; Some "x"; None; None; Some "y" ]));

      Alcotest.test_case "id-less document untouched" `Quick (fun () ->
        let layer = make_layer [|
          make_rect 0.0 0.0 10.0 10.0;
          make_rect 20.0 0.0 10.0 10.0;
        |] in
        let doc = Jas.Document.make_document [| layer |] in
        let out = Jas.Normalize.dedupe_element_ids doc in
        assert (doc_ids out = [ None; None; None ]));
    ];
  ]
