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
]

let () =
  Alcotest.run "OpacityMask" [
    "mask_plan", tests;
  ]
