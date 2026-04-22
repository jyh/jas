(* Track C phase 1 — opacity mask compositing unit tests.

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
  Alcotest.test_case "mask_composite_op_clip_not_inverted_is_DEST_IN" `Quick (fun () ->
    let m = test_mask ~clip:true ~invert:false ~disabled:false in
    match Jas.Canvas_subwindow.mask_composite_op m with
    | Some Cairo.DEST_IN -> ()
    | _ -> Alcotest.fail "expected Some DEST_IN");

  Alcotest.test_case "mask_composite_op_clip_inverted_is_DEST_OUT" `Quick (fun () ->
    let m = test_mask ~clip:true ~invert:true ~disabled:false in
    match Jas.Canvas_subwindow.mask_composite_op m with
    | Some Cairo.DEST_OUT -> ()
    | _ -> Alcotest.fail "expected Some DEST_OUT");

  Alcotest.test_case "mask_composite_op_disabled_is_None" `Quick (fun () ->
    (* disabled overrides both clip and invert: falls back to no
       mask rendering per OPACITY.md section States. *)
    List.iter (fun (clip, invert) ->
      let m = test_mask ~clip ~invert ~disabled:true in
      assert (Jas.Canvas_subwindow.mask_composite_op m = None)
    ) [(true, false); (true, true); (false, false); (false, true)]);

  Alcotest.test_case "mask_composite_op_no_clip_is_None_phase1" `Quick (fun () ->
    (* clip=false (element visible outside the mask shape) needs a
       two-pass composite; not yet supported, falls back to no
       mask. Phase 2 of Track C will handle this. *)
    let m1 = test_mask ~clip:false ~invert:false ~disabled:false in
    let m2 = test_mask ~clip:false ~invert:true ~disabled:false in
    assert (Jas.Canvas_subwindow.mask_composite_op m1 = None);
    assert (Jas.Canvas_subwindow.mask_composite_op m2 = None));
]

let () =
  Alcotest.run "OpacityMask" [
    "mask_composite_op", tests;
  ]
