(* Track C — opacity mask compositing unit tests.

   Isolated from the GTK-dependent [canvas_test.ml] so the mask
   logic can be asserted without initialising a GTK display. *)

open Jas

let test_mask ~clip ~invert ~disabled : Element.mask =
  {
    Element.subtree = Element.make_group [||];
    clip;
    invert;
    disabled;
    linked = true;
    unlink_transform = None;
  }

let tests = [
  Alcotest.test_case "mask_plan_clip_not_inverted_is_Clip_in" `Quick (fun () ->
    let m = test_mask ~clip:true ~invert:false ~disabled:false in
    match Canvas_subwindow.mask_plan m with
    | Some Canvas_subwindow.Clip_in -> ()
    | _ -> Alcotest.fail "expected Some Clip_in");

  Alcotest.test_case "mask_plan_clip_inverted_is_Clip_out" `Quick (fun () ->
    let m = test_mask ~clip:true ~invert:true ~disabled:false in
    match Canvas_subwindow.mask_plan m with
    | Some Canvas_subwindow.Clip_out -> ()
    | _ -> Alcotest.fail "expected Some Clip_out");

  Alcotest.test_case "mask_plan_disabled_is_None" `Quick (fun () ->
    (* disabled overrides both clip and invert: falls back to no
       mask rendering per OPACITY.md section States. *)
    List.iter (fun (clip, invert) ->
      let m = test_mask ~clip ~invert ~disabled:true in
      assert (Canvas_subwindow.mask_plan m = None)
    ) [(true, false); (true, true); (false, false); (false, true)]);

  Alcotest.test_case "mask_plan_no_clip_no_invert_is_Reveal_outside_bbox" `Quick (fun () ->
    (* Phase 2: clip=false, invert=false keeps the element visible
       outside the mask subtree's bounding box. *)
    let m = test_mask ~clip:false ~invert:false ~disabled:false in
    match Canvas_subwindow.mask_plan m with
    | Some Canvas_subwindow.Reveal_outside_bbox -> ()
    | _ -> Alcotest.fail "expected Some Reveal_outside_bbox");

  Alcotest.test_case "mask_plan_no_clip_inverted_collapses_to_Clip_out" `Quick (fun () ->
    (* Alpha-based mask: [clip: false, invert: true] gives the same
       output as [clip: true, invert: true] because the mask's
       outside-region alpha is zero either way. *)
    let m = test_mask ~clip:false ~invert:true ~disabled:false in
    match Canvas_subwindow.mask_plan m with
    | Some Canvas_subwindow.Clip_out -> ()
    | _ -> Alcotest.fail "expected Some Clip_out");

  (* ── effective_mask_transform (Track C phase 3) ───────── *)

  Alcotest.test_case "effective_mask_transform_linked_returns_element_transform" `Quick (fun () ->
    (* linked=true: mask follows the element, so the renderer
       should apply [Element.get_transform elem]. *)
    let mask = { (test_mask ~clip:true ~invert:false ~disabled:false)
                 with Element.linked = true } in
    let t_elem : Element.transform =
      { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 5.0; f = 7.0 } in
    let elem = Element.make_rect ~transform:(Some t_elem) 0.0 0.0 10.0 10.0 in
    match Canvas_subwindow.effective_mask_transform mask elem with
    | Some t ->
      assert (t.Element.e = 5.0);
      assert (t.Element.f = 7.0)
    | None -> Alcotest.fail "expected Some element transform");

  Alcotest.test_case "effective_mask_transform_linked_None_when_element_has_no_transform" `Quick (fun () ->
    (* linked=true with no element transform: None — the
       compositing path skips the apply_transform call. *)
    let mask = { (test_mask ~clip:true ~invert:false ~disabled:false)
                 with Element.linked = true } in
    let elem = Element.make_rect 0.0 0.0 10.0 10.0 in
    assert (Canvas_subwindow.effective_mask_transform mask elem = None));

  Alcotest.test_case "effective_mask_transform_unlinked_returns_captured" `Quick (fun () ->
    (* linked=false: mask stays frozen under the unlink-time
       transform, regardless of the element's current transform. *)
    let unlink : Element.transform =
      { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 3.0; f = 4.0 } in
    let mask = { (test_mask ~clip:true ~invert:false ~disabled:false)
                 with Element.linked = false;
                      unlink_transform = Some unlink } in
    let t_elem : Element.transform =
      { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 100.0; f = 100.0 } in
    let elem = Element.make_rect ~transform:(Some t_elem) 0.0 0.0 10.0 10.0 in
    match Canvas_subwindow.effective_mask_transform mask elem with
    | Some t ->
      assert (t.Element.e = 3.0);
      assert (t.Element.f = 4.0)
    | None -> Alcotest.fail "expected Some unlink transform");

  Alcotest.test_case "effective_mask_transform_unlinked_None_when_unlink_missing" `Quick (fun () ->
    (* linked=false with no captured transform: None. *)
    let mask = { (test_mask ~clip:true ~invert:false ~disabled:false)
                 with Element.linked = false;
                      unlink_transform = None } in
    let t_elem : Element.transform =
      { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 7.0; f = 8.0 } in
    let elem = Element.make_rect ~transform:(Some t_elem) 0.0 0.0 10.0 10.0 in
    assert (Canvas_subwindow.effective_mask_transform mask elem = None));
]

let () =
  Alcotest.run "OpacityMask" [
    "mask_plan", tests;
  ]
