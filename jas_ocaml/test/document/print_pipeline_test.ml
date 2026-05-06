open Jas
open Jas.Document
open Jas.Test_json

(* DocumentSetup *)

let test_document_setup_defaults () =
  let s = Document_setup.default in
  assert (s.bleed_top = 0.0);
  assert (s.bleed_right = 0.0);
  assert (s.bleed_bottom = 0.0);
  assert (s.bleed_left = 0.0);
  assert (s.bleed_uniform = true);
  assert (s.show_images_outline = false);
  assert (s.highlight_substituted_glyphs = false)

let make_test_artboard () =
  Artboard.{
    id = "ab"; name = "A1";
    x = 10.0; y = 20.0; width = 100.0; height = 200.0;
    fill = Transparent;
    show_center_mark = false;
    show_cross_hairs = false;
    show_video_safe_areas = false;
    video_ruler_pixel_aspect_ratio = 1.0;
  }

let test_bleed_rect_none_when_all_zero () =
  let ab = make_test_artboard () in
  let s = Document_setup.default in
  assert (Document_setup.bleed_rect_for_artboard s ab = None)

let test_bleed_rect_uniform_extends_all_sides () =
  let ab = make_test_artboard () in
  let s = { Document_setup.default with
            bleed_top = 5.0; bleed_right = 5.0;
            bleed_bottom = 5.0; bleed_left = 5.0 } in
  match Document_setup.bleed_rect_for_artboard s ab with
  | Some (x, y, w, h) ->
    assert (x = 5.0 && y = 15.0 && w = 110.0 && h = 210.0)
  | None -> assert false

let test_bleed_rect_partial_only_offsets_sides_with_bleed () =
  let ab = make_test_artboard () in
  let s = { Document_setup.default with bleed_left = 7.0 } in
  match Document_setup.bleed_rect_for_artboard s ab with
  | Some (x, y, w, h) ->
    assert (x = 3.0 && y = 20.0 && w = 107.0 && h = 200.0)
  | None -> assert false

(* PrintPreferences *)

let test_print_preferences_defaults_match_spec () =
  let p = Print_preferences.default in
  assert (p.preset_name = "[Default]");
  assert (p.printer_name = None);
  assert (p.copies = 1);
  assert (p.collate = false);
  assert (p.reverse_order = false);
  assert (p.artboard_range_mode = Print_preferences.All);
  assert (p.artboard_range = "");
  assert (p.ignore_artboards = false);
  assert (p.skip_blank_artboards = false);
  assert (p.media_size = Print_preferences.Defined_by_driver);
  assert (p.media_width = 612.0);
  assert (p.media_height = 792.0);
  assert (p.orientation = Print_preferences.Portrait);
  assert (p.auto_rotate = true);
  assert (p.transverse = false);
  assert (p.print_layers = Print_preferences.Visible_printable);
  assert (p.placement_x = 0.0);
  assert (p.placement_y = 0.0);
  assert (p.scaling_mode = Print_preferences.Do_not_scale);
  assert (p.custom_scale = 100.0);
  assert (p.tile_overlap_h = 0.0);
  assert (p.tile_overlap_v = 0.0);
  assert (p.tile_range = "")

let test_default_preset_holds_defaults () =
  let p = Print_preferences.default_preset in
  assert (p.name = "[Default]");
  assert (p.preferences = Print_preferences.default)

let test_enum_string_forms_are_snake_case () =
  let open Print_preferences in
  assert (artboard_range_mode_to_string All = "all");
  assert (artboard_range_mode_to_string Range = "range");
  assert (media_size_to_string Defined_by_driver = "defined_by_driver");
  assert (media_size_to_string Tabloid = "tabloid");
  assert (orientation_to_string Portrait = "portrait");
  assert (print_layers_to_string Visible_printable = "visible_printable");
  assert (scaling_mode_to_string Do_not_scale = "do_not_scale");
  assert (scaling_mode_to_string Fit_to_page = "fit_to_page")

(* Test JSON omission + roundtrip *)

let test_document_setup_only_emitted_when_non_default () =
  let doc = make_document [||] in
  let json = document_to_test_json doc in
  let contains s sub =
    let len_s = String.length s and len_sub = String.length sub in
    let rec aux i =
      if i + len_sub > len_s then false
      else if String.sub s i len_sub = sub then true
      else aux (i + 1)
    in aux 0 in
  assert (not (contains json "\"document_setup\""));
  let doc2 = make_document
    ~document_setup:{ Document_setup.default with bleed_top = 9.0 }
    [||] in
  let json2 = document_to_test_json doc2 in
  assert (contains json2 "\"document_setup\"");
  assert (contains json2 "\"bleed_top\":9.0")

let test_document_setup_roundtrip () =
  let s = { Document_setup.bleed_top = 9.0; bleed_right = 9.0;
            bleed_bottom = 9.0; bleed_left = 9.0;
            bleed_uniform = false;
            show_images_outline = true;
            highlight_substituted_glyphs = true } in
  let doc = make_document ~document_setup:s [||] in
  let json = document_to_test_json doc in
  let doc2 = test_json_to_document json in
  assert (doc2.document_setup = s)

let test_print_preferences_only_emitted_when_non_default () =
  let doc = make_document [||] in
  let json = document_to_test_json doc in
  let contains s sub =
    let len_s = String.length s and len_sub = String.length sub in
    let rec aux i =
      if i + len_sub > len_s then false
      else if String.sub s i len_sub = sub then true
      else aux (i + 1)
    in aux 0 in
  assert (not (contains json "\"print_preferences\""));
  let doc2 = make_document
    ~print_preferences:{ Print_preferences.default with copies = 5 }
    [||] in
  let json2 = document_to_test_json doc2 in
  assert (contains json2 "\"print_preferences\"");
  assert (contains json2 "\"copies\":5")

let test_print_preferences_roundtrip () =
  let p = { Print_preferences.preset_name = "[Default]";
            printer_name = Some "My Laser";
            copies = 7;
            collate = true;
            reverse_order = true;
            artboard_range_mode = Print_preferences.Range;
            artboard_range = "1-3, 5";
            ignore_artboards = true;
            skip_blank_artboards = true;
            media_size = Print_preferences.A4;
            media_width = 595.28;
            media_height = 841.89;
            orientation = Print_preferences.Landscape;
            auto_rotate = false;
            transverse = true;
            print_layers = Print_preferences.All_layers;
            placement_x = 12.0;
            placement_y = 24.0;
            scaling_mode = Print_preferences.Custom_scale;
            custom_scale = 75.5;
            tile_overlap_h = 6.0;
            tile_overlap_v = 6.0;
            tile_range = "1-2";
            marks_and_bleed = Print_preferences.default_marks_and_bleed;
            output = Print_preferences.default_output } in
  let doc = make_document ~print_preferences:p [||] in
  let json = document_to_test_json doc in
  let doc2 = test_json_to_document json in
  assert (doc2.print_preferences = p)

(* MarksAndBleed (PRINT.md §Phase 2) *)

let test_marks_and_bleed_defaults () =
  let m = Print_preferences.default_marks_and_bleed in
  assert (m.all_printer_marks = false);
  assert (m.trim_marks = false);
  assert (m.registration_marks = false);
  assert (m.color_bars = false);
  assert (m.page_information = false);
  assert (m.printer_mark_type = Print_preferences.Roman);
  assert (m.trim_mark_weight = 0.25);
  assert (m.mark_offset = 6.0);
  assert (m.use_document_bleed = true);
  assert (m.bleed_top = 0.0);
  assert (m.bleed_right = 0.0);
  assert (m.bleed_bottom = 0.0);
  assert (m.bleed_left = 0.0)

let test_printer_mark_type_strings () =
  let open Print_preferences in
  assert (printer_mark_type_to_string Roman = "roman");
  assert (printer_mark_type_to_string Japanese = "japanese");
  assert (printer_mark_type_of_string "roman" = Roman);
  assert (printer_mark_type_of_string "japanese" = Japanese);
  assert (printer_mark_type_of_string "garbage" = Roman)

(* Output sub-record (PRINT.md §Phase 3) *)

let test_output_defaults () =
  let o = Print_preferences.default_output in
  assert (o.mode = Print_preferences.Composite);
  assert (o.emulsion = Print_preferences.Up_right);
  assert (o.image_polarity = Print_preferences.Positive);
  assert (o.printer_resolution = "75 lpi / 600 dpi");
  assert (o.convert_spot_to_process = false);
  assert (o.overprint_black = false);
  assert (List.length o.inks = 4);
  let inks = o.inks in
  assert ((List.nth inks 0).name = "Process Cyan");
  assert ((List.nth inks 0).angle = 105.0);
  assert ((List.nth inks 1).name = "Process Magenta");
  assert ((List.nth inks 2).name = "Process Yellow");
  assert ((List.nth inks 3).name = "Process Black");
  assert ((List.nth inks 3).angle = 45.0);
  List.iter (fun (i : Print_preferences.ink_override) ->
    assert i.print;
    assert (i.frequency = 75.0);
    assert (i.dot_shape = Print_preferences.Dot_round)
  ) inks

let test_output_enum_strings () =
  let open Print_preferences in
  assert (output_mode_to_string Composite = "composite");
  assert (output_mode_to_string Separations = "separations");
  assert (emulsion_to_string Up_right = "up_right");
  assert (emulsion_to_string Down_right = "down_right");
  assert (image_polarity_to_string Positive = "positive");
  assert (image_polarity_to_string Negative = "negative");
  assert (dot_shape_to_string Dot_round = "round");
  assert (dot_shape_to_string Dot_euclidean = "euclidean")

let test_output_roundtrip () =
  let m = { Print_preferences.mode = Print_preferences.Separations;
            emulsion = Print_preferences.Down_right;
            image_polarity = Print_preferences.Negative;
            printer_resolution = "150 lpi / 1200 dpi";
            convert_spot_to_process = true;
            overprint_black = true;
            inks = [
              { name = "Process Cyan"; print = false;
                frequency = 100.0; angle = 105.0;
                dot_shape = Print_preferences.Dot_ellipse };
              { name = "PANTONE 185 C"; print = true;
                frequency = 85.0; angle = 45.0;
                dot_shape = Print_preferences.Dot_square };
            ] } in
  let p = { Print_preferences.default with output = m } in
  let doc = make_document ~print_preferences:p [||] in
  let json = document_to_test_json doc in
  let contains s sub =
    let len_s = String.length s and len_sub = String.length sub in
    let rec aux i =
      if i + len_sub > len_s then false
      else if String.sub s i len_sub = sub then true
      else aux (i + 1)
    in aux 0 in
  assert (contains json "\"output\"");
  assert (contains json "\"PANTONE 185 C\"");
  let doc2 = test_json_to_document json in
  assert (doc2.print_preferences.output = m)

let test_marks_and_bleed_roundtrip () =
  let m = { Print_preferences.all_printer_marks = true;
            trim_marks = true;
            registration_marks = true;
            color_bars = true;
            page_information = true;
            printer_mark_type = Print_preferences.Japanese;
            trim_mark_weight = 0.5;
            mark_offset = 12.0;
            use_document_bleed = false;
            bleed_top = 4.0; bleed_right = 5.0;
            bleed_bottom = 6.0; bleed_left = 7.0 } in
  let p = { Print_preferences.default with marks_and_bleed = m } in
  let doc = make_document ~print_preferences:p [||] in
  let json = document_to_test_json doc in
  let contains s sub =
    let len_s = String.length s and len_sub = String.length sub in
    let rec aux i =
      if i + len_sub > len_s then false
      else if String.sub s i len_sub = sub then true
      else aux (i + 1)
    in aux 0 in
  assert (contains json "\"marks_and_bleed\"");
  let doc2 = test_json_to_document json in
  assert (doc2.print_preferences.marks_and_bleed = m)

let () =
  Alcotest.run "PrintPipeline" [
    "document_setup", [
      Alcotest.test_case "defaults" `Quick test_document_setup_defaults;
      Alcotest.test_case "bleed rect none when all zero" `Quick test_bleed_rect_none_when_all_zero;
      Alcotest.test_case "bleed rect uniform" `Quick test_bleed_rect_uniform_extends_all_sides;
      Alcotest.test_case "bleed rect partial" `Quick test_bleed_rect_partial_only_offsets_sides_with_bleed;
    ];
    "print_preferences", [
      Alcotest.test_case "defaults match spec" `Quick test_print_preferences_defaults_match_spec;
      Alcotest.test_case "default preset holds defaults" `Quick test_default_preset_holds_defaults;
      Alcotest.test_case "enum strings snake_case" `Quick test_enum_string_forms_are_snake_case;
    ];
    "marks_and_bleed", [
      Alcotest.test_case "defaults" `Quick test_marks_and_bleed_defaults;
      Alcotest.test_case "printer_mark_type strings" `Quick test_printer_mark_type_strings;
      Alcotest.test_case "roundtrip" `Quick test_marks_and_bleed_roundtrip;
    ];
    "output", [
      Alcotest.test_case "defaults" `Quick test_output_defaults;
      Alcotest.test_case "enum strings" `Quick test_output_enum_strings;
      Alcotest.test_case "roundtrip" `Quick test_output_roundtrip;
    ];
    "test_json", [
      Alcotest.test_case "document_setup omitted when default" `Quick test_document_setup_only_emitted_when_non_default;
      Alcotest.test_case "document_setup roundtrip" `Quick test_document_setup_roundtrip;
      Alcotest.test_case "print_preferences omitted when default" `Quick test_print_preferences_only_emitted_when_non_default;
      Alcotest.test_case "print_preferences roundtrip" `Quick test_print_preferences_roundtrip;
    ];
  ]
