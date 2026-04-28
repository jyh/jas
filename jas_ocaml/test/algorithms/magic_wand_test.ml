(** Tests for the OCaml Magic_wand predicate. Parallels
    [jas_dioxus/src/algorithms/magic_wand.rs] +
    [JasSwift/Tests/Algorithms/MagicWandTests.swift]. *)

open Jas

let make_rect ?fill ?stroke ?(opacity = 1.0)
    ?(blend_mode = Element.Normal) () : Element.element =
  Element.Rect {
    x = 0.0; y = 0.0; width = 10.0; height = 10.0;
    rx = 0.0; ry = 0.0;
    fill; stroke; opacity;
    transform = None; locked = false;
    visibility = Element.Preview;
    blend_mode; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let red_fill = Element.{
  fill_color = color_rgb 1.0 0.0 0.0;
  fill_opacity = 1.0;
}

let near_red_fill = Element.{
  fill_color = color_rgb (240.0 /. 255.0) (10.0 /. 255.0) (10.0 /. 255.0);
  fill_opacity = 1.0;
}

let dark_red_fill = Element.{
  fill_color = color_rgb (200.0 /. 255.0) 0.0 0.0;
  fill_opacity = 1.0;
}

let black_stroke width : Element.stroke = {
  stroke_color = Element.color_rgb 0.0 0.0 0.0;
  stroke_width = width;
  stroke_linecap = Element.Butt;
  stroke_linejoin = Element.Miter;
  stroke_miter_limit = 4.0;
  stroke_align = Element.Center;
  stroke_dash_pattern = [];
  stroke_dash_align_anchors = false;
  stroke_start_arrow = Element.Arrow_none;
  stroke_end_arrow = Element.Arrow_none;
  stroke_start_arrow_scale = 1.0;
  stroke_end_arrow_scale = 1.0;
  stroke_arrow_align = Element.Tip_at_end;
  stroke_opacity = 1.0;
}

let tests = [
  Alcotest.test_case "all_disabled_never_matches" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with
      fill_color = false; stroke_color = false;
      stroke_weight = false; opacity = false; blending_mode = false;
    } in
    let seed = make_rect ~fill:red_fill () in
    let cand = make_rect ~fill:red_fill () in
    assert (not (Magic_wand.magic_wand_match seed cand cfg)));

  Alcotest.test_case "identical_elements_match_under_default_config" `Quick (fun () ->
    let cfg = Magic_wand.default_config in
    let seed = make_rect ~fill:red_fill ~stroke:(black_stroke 2.0) () in
    let cand = make_rect ~fill:red_fill ~stroke:(black_stroke 2.0) () in
    assert (Magic_wand.magic_wand_match seed cand cfg));

  Alcotest.test_case "fill_color_within_tolerance_matches" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with stroke_color = false;
      stroke_weight = false; opacity = false; blending_mode = false;
    } in
    let seed = make_rect ~fill:red_fill () in
    let cand = make_rect ~fill:near_red_fill () in
    assert (Magic_wand.magic_wand_match seed cand cfg));

  Alcotest.test_case "fill_color_outside_tolerance_misses" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with stroke_color = false;
      stroke_weight = false; opacity = false; blending_mode = false;
      fill_tolerance = 10.0;
    } in
    let seed = make_rect ~fill:red_fill () in
    let cand = make_rect ~fill:dark_red_fill () in
    assert (not (Magic_wand.magic_wand_match seed cand cfg)));

  Alcotest.test_case "none_fill_matches_only_none_fill" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with stroke_color = false;
      stroke_weight = false; opacity = false; blending_mode = false;
    } in
    let no_fill = make_rect () in
    let red = make_rect ~fill:red_fill () in
    assert (Magic_wand.magic_wand_match no_fill no_fill cfg);
    assert (not (Magic_wand.magic_wand_match no_fill red cfg));
    assert (not (Magic_wand.magic_wand_match red no_fill cfg)));

  Alcotest.test_case "stroke_weight_uses_pt_delta" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with fill_color = false; stroke_color = false;
      opacity = false; blending_mode = false;
      stroke_weight_tolerance = 1.0;
    } in
    let s2 = make_rect ~stroke:(black_stroke 2.0) () in
    let s2_5 = make_rect ~stroke:(black_stroke 2.5) () in
    let s4 = make_rect ~stroke:(black_stroke 4.0) () in
    assert (Magic_wand.magic_wand_match s2 s2_5 cfg);    (* dt 0.5 <= 1 *)
    assert (not (Magic_wand.magic_wand_match s2 s4 cfg)));  (* dt 2.0 > 1 *)

  Alcotest.test_case "opacity_uses_percentage_point_delta" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with fill_color = false; stroke_color = false;
      stroke_weight = false; blending_mode = false;
      opacity_tolerance = 5.0;
    } in
    let a = make_rect ~opacity:1.0 () in
    let b = make_rect ~opacity:0.97 () in
    let c = make_rect ~opacity:0.80 () in
    assert (Magic_wand.magic_wand_match a b cfg);     (* abs delta 100 = 3 *)
    assert (not (Magic_wand.magic_wand_match a c cfg)));  (* abs delta 100 = 20 *)

  Alcotest.test_case "blending_mode_is_exact_match" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with fill_color = false; stroke_color = false;
      stroke_weight = false; opacity = false; blending_mode = true;
    } in
    let normal = make_rect ~blend_mode:Element.Normal () in
    let normal2 = make_rect ~blend_mode:Element.Normal () in
    let multiply = make_rect ~blend_mode:Element.Multiply () in
    assert (Magic_wand.magic_wand_match normal normal2 cfg);
    assert (not (Magic_wand.magic_wand_match normal multiply cfg)));

  Alcotest.test_case "and_across_criteria_one_failure_misses" `Quick (fun () ->
    let cfg = Magic_wand.{
      default_config with opacity = false; blending_mode = false;
      stroke_weight_tolerance = 1.0;
    } in
    let seed = make_rect ~fill:red_fill ~stroke:(black_stroke 2.0) () in
    let cand = make_rect ~fill:red_fill ~stroke:(black_stroke 5.0) () in
    assert (not (Magic_wand.magic_wand_match seed cand cfg)));
]

let () =
  Alcotest.run "magic_wand" [
    "predicate", tests;
  ]
