(** Tests for the OCaml Eyedropper extract / apply helpers. Parallels
    [jas_dioxus/src/algorithms/eyedropper.rs] +
    [JasSwift/Tests/Algorithms/EyedropperTests.swift]. *)

open Jas

(* ──────────────────────────────────────────────────────────────── *)
(* Fixtures                                                            *)
(* ──────────────────────────────────────────────────────────────── *)

let red_fill : Element.fill = {
  fill_color = Element.color_rgb 1.0 0.0 0.0;
  fill_opacity = 1.0;
}

let blue_stroke : Element.stroke = {
  stroke_color = Element.color_rgb 0.0 0.0 1.0;
  stroke_width = 4.0;
  stroke_linecap = Element.Round_cap;
  stroke_linejoin = Element.Bevel;
  stroke_miter_limit = 4.0;
  stroke_align = Element.Inside;
  stroke_dash_pattern = [];
  stroke_start_arrow = Element.Arrow_none;
  stroke_end_arrow = Element.Arrow_none;
  stroke_start_arrow_scale = 1.0;
  stroke_end_arrow_scale = 1.0;
  stroke_arrow_align = Element.Tip_at_end;
  stroke_opacity = 1.0;
}

let make_rect ?fill ?stroke ?(opacity = 1.0)
    ?(blend_mode = Element.Normal)
    ?(locked = false)
    ?(visibility = Element.Preview) () : Element.element =
  Element.Rect {
    x = 0.0; y = 0.0; width = 100.0; height = 100.0;
    rx = 0.0; ry = 0.0;
    fill; stroke; opacity;
    transform = None; locked; visibility; blend_mode; mask = None;
    fill_gradient = None; stroke_gradient = None;
  }

let make_line ?stroke ?(width_points = []) () : Element.element =
  Element.Line {
    x1 = 0.0; y1 = 0.0; x2 = 10.0; y2 = 10.0;
    stroke; width_points;
    opacity = 1.0; transform = None; locked = false;
    visibility = Element.Preview; blend_mode = Element.Normal;
    mask = None; stroke_gradient = None;
  }

let make_group () : Element.element =
  Element.Group {
    children = [||]; opacity = 1.0; transform = None; locked = false;
    visibility = Element.Preview; blend_mode = Element.Normal;
    mask = None; isolated_blending = false; knockout_group = false;
  }

(* ──────────────────────────────────────────────────────────────── *)
(* Tests                                                                *)
(* ──────────────────────────────────────────────────────────────── *)

let tests = [
  Alcotest.test_case "extract_rect_with_fill_and_stroke" `Quick (fun () ->
    let el = make_rect ~fill:red_fill ~stroke:blue_stroke () in
    let app = Eyedropper.extract_appearance el in
    assert (app.app_fill = Some red_fill);
    assert (app.app_stroke = Some blue_stroke);
    assert (app.app_opacity = Some 1.0);
    assert (app.app_blend_mode = Some Element.Normal);
    assert (app.app_stroke_brush = None);
    assert (app.app_width_points = []));

  Alcotest.test_case "extract_line_has_no_fill" `Quick (fun () ->
    let el = make_line ~stroke:blue_stroke () in
    let app = Eyedropper.extract_appearance el in
    assert (app.app_fill = None);
    assert (app.app_stroke = Some blue_stroke));

  Alcotest.test_case "appearance_json_roundtrip" `Quick (fun () ->
    let app : Eyedropper.appearance = {
      app_fill = Some red_fill;
      app_stroke = Some blue_stroke;
      app_opacity = Some 0.75;
      app_blend_mode = Some Element.Multiply;
      app_stroke_brush = Some "calligraphic_default";
      app_width_points = [];
      app_character = None;
      app_paragraph = None;
    } in
    let j = Eyedropper.appearance_to_json app in
    let back = Eyedropper.appearance_of_json j in
    assert (back.app_fill = app.app_fill);
    assert (back.app_stroke = app.app_stroke);
    assert (back.app_opacity = app.app_opacity);
    assert (back.app_blend_mode = app.app_blend_mode);
    assert (back.app_stroke_brush = app.app_stroke_brush);
    assert (back.app_width_points = app.app_width_points));

  Alcotest.test_case "apply_master_off_skips_group" `Quick (fun () ->
    let src = make_rect ~fill:red_fill ~stroke:blue_stroke () in
    let app = Eyedropper.extract_appearance src in
    let target = make_rect () in
    let cfg = { Eyedropper.default_config with
                fill = false; stroke = false; opacity = false } in
    let out = Eyedropper.apply_appearance target app cfg in
    assert (Eyedropper.fill_of out = None);
    assert (Eyedropper.stroke_of out = None));

  Alcotest.test_case "apply_stroke_color_sub_only" `Quick (fun () ->
    let src = make_rect ~stroke:blue_stroke () in
    let app = Eyedropper.extract_appearance src in
    let existing : Element.stroke = {
      stroke_color = Element.color_rgb 0.5 0.5 0.5;
      stroke_width = 2.0;
      stroke_linecap = Element.Square;
      stroke_linejoin = Element.Miter;
      stroke_miter_limit = 4.0;
      stroke_align = Element.Center;
      stroke_dash_pattern = [];
      stroke_start_arrow = Element.Arrow_none;
      stroke_end_arrow = Element.Arrow_none;
      stroke_start_arrow_scale = 1.0;
      stroke_end_arrow_scale = 1.0;
      stroke_arrow_align = Element.Tip_at_end;
      stroke_opacity = 1.0;
    } in
    let target = make_rect ~stroke:existing () in
    let cfg = { Eyedropper.default_config with
                fill = false; opacity = false;
                stroke = true;
                stroke_color = true;
                stroke_weight = false;
                stroke_cap_join = false;
                stroke_align = false;
                stroke_dash = false;
                stroke_arrowheads = false;
                stroke_brush = false;
                stroke_profile = false } in
    let out = Eyedropper.apply_appearance target app cfg in
    let out_stroke =
      match Eyedropper.stroke_of out with
      | Some s -> s
      | None -> failwith "expected stroke"
    in
    (* Color copied from source... *)
    let (r, g, b, _) = Element.color_to_rgba out_stroke.stroke_color in
    assert (r = 0.0 && g = 0.0 && b = 1.0);
    (* ...but weight, cap, etc. preserved from target. *)
    assert (out_stroke.stroke_width = 2.0);
    assert (out_stroke.stroke_linecap = Element.Square));

  Alcotest.test_case "apply_opacity_alpha_only" `Quick (fun () ->
    let src = make_rect ~opacity:0.4 ~blend_mode:Element.Screen () in
    let app = Eyedropper.extract_appearance src in
    let target = make_rect () in
    let cfg = { Eyedropper.default_config with
                fill = false; stroke = false;
                opacity = true;
                opacity_alpha = true;
                opacity_blend = false } in
    let out = Eyedropper.apply_appearance target app cfg in
    assert (Eyedropper.opacity_of out = 0.4);
    assert (Element.get_blend_mode out = Element.Normal));

  Alcotest.test_case "source_eligibility_filters_hidden_and_containers" `Quick
    (fun () ->
       let hidden = make_rect ~visibility:Element.Invisible () in
       assert (not (Eyedropper.is_source_eligible hidden));

       let visible = make_rect () in
       assert (Eyedropper.is_source_eligible visible);

       let locked = make_rect ~locked:true () in
       (* Locked is OK on the source side. *)
       assert (Eyedropper.is_source_eligible locked);

       let group = make_group () in
       assert (not (Eyedropper.is_source_eligible group)));

  Alcotest.test_case "target_eligibility_filters_locked_and_containers" `Quick
    (fun () ->
       let unlocked = make_rect () in
       assert (Eyedropper.is_target_eligible unlocked);

       let locked = make_rect ~locked:true () in
       assert (not (Eyedropper.is_target_eligible locked));

       (* Hidden is OK on the target side (writes persist). *)
       let hidden = make_rect ~visibility:Element.Invisible () in
       assert (Eyedropper.is_target_eligible hidden);

       let group = make_group () in
       assert (not (Eyedropper.is_target_eligible group)));
]

let () =
  Alcotest.run "eyedropper" [
    "extract_apply", tests;
  ]
