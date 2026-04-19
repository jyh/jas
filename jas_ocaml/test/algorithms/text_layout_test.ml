(** Phase 5: paragraph-aware text layout tests. *)

open Jas

let fixed w = fun s -> Float.of_int (String.length s) *. w

(* ── layout_with_paragraphs basic invariants ─────────────── *)

let empty_paragraph_list_matches_plain () =
  let m = fixed 10.0 in
  let plain = Text_layout.layout "hello world" 100.0 16.0 m in
  let para = Text_layout.layout_with_paragraphs "hello world" 100.0 16.0 [] m in
  Alcotest.(check int) "lines" (Array.length plain.lines) (Array.length para.lines);
  Alcotest.(check int) "glyphs" (Array.length plain.glyphs) (Array.length para.glyphs);
  for i = 0 to Array.length plain.glyphs - 1 do
    Alcotest.(check (float 0.001)) (Printf.sprintf "glyph %d x" i)
      plain.glyphs.(i).x para.glyphs.(i).x;
    Alcotest.(check int) (Printf.sprintf "glyph %d line" i)
      plain.glyphs.(i).line para.glyphs.(i).line
  done

let left_indent_shifts_every_line () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 11; left_indent = 20.0 }] in
  let l = Text_layout.layout_with_paragraphs "hello world" 60.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "first glyph x" 20.0 l.glyphs.(0).x

let right_indent_narrows_wrap_width () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 11; right_indent = 60.0 }] in
  let l = Text_layout.layout_with_paragraphs "hello world" 110.0 16.0 segs m in
  Alcotest.(check bool) "wrapped" true (Array.length l.lines >= 2)

let first_line_indent_only_shifts_first_line () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 11; first_line_indent = 25.0 }] in
  let l = Text_layout.layout_with_paragraphs "hello world" 60.0 16.0 segs m in
  let first_line_first = Array.fold_left (fun acc g ->
    if g.Text_layout.line = 0 && acc = None then Some g else acc) None l.glyphs in
  let second_line_first = Array.fold_left (fun acc g ->
    if g.Text_layout.line = 1 && acc = None then Some g else acc) None l.glyphs in
  (match first_line_first with
   | Some g -> Alcotest.(check (float 0.001)) "line 0 x" 25.0 g.x
   | None -> Alcotest.fail "no line 0 glyph");
  (match second_line_first with
   | Some g -> Alcotest.(check (float 0.001)) "line 1 x" 0.0 g.x
   | None -> Alcotest.fail "no line 1 glyph")

let alignment_center_shifts_to_center () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2; text_align = Text_layout.Center }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "centered x" 40.0 l.glyphs.(0).x

let alignment_right_shifts_to_right_edge () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2; text_align = Text_layout.Right }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "right-aligned x" 80.0 l.glyphs.(0).x

let space_before_skipped_for_first_paragraph () =
  let m = fixed 10.0 in
  let segs = [
    { Text_layout.default_segment with
      char_start = 0; char_end = 2;
      space_before = 50.0; space_after = 0.0 };
    { Text_layout.default_segment with
      char_start = 2; char_end = 4; space_before = 30.0 };
  ] in
  let l = Text_layout.layout_with_paragraphs "abcd" 100.0 16.0 segs m in
  Alcotest.(check int) "two lines" 2 (Array.length l.lines);
  Alcotest.(check (float 0.001)) "line 0 top" 0.0 l.lines.(0).top;
  (* line 1: 16 (line height) + 30 (space_before of para 2) = 46. *)
  Alcotest.(check (float 0.001)) "line 1 top" 46.0 l.lines.(1).top

let space_after_inserts_gap () =
  let m = fixed 10.0 in
  let segs = [
    { Text_layout.default_segment with
      char_start = 0; char_end = 2; space_after = 20.0 };
    { Text_layout.default_segment with char_start = 2; char_end = 4 };
  ] in
  let l = Text_layout.layout_with_paragraphs "abcd" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "line 1 top" 36.0 l.lines.(1).top

let alignment_with_indent_uses_remaining_width () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2;
                left_indent = 20.0; text_align = Text_layout.Center }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  (* effective width = 80; (80-20)/2 = 30; +20 left_indent → 50. *)
  Alcotest.(check (float 0.001)) "centered + indented" 50.0 l.glyphs.(0).x

(* ── build_segments_from_text ────────────────────────────── *)

let _wrapper li ri fli sb sa ta : Element.tspan =
  let opt v = if Float.equal v 0.0 then None else Some v in
  { (Tspan.default_tspan ()) with
    jas_role = Some "paragraph";
    jas_left_indent = opt li;
    jas_right_indent = opt ri;
    text_indent = opt fli;
    jas_space_before = opt sb;
    jas_space_after = opt sa;
    text_align = ta }

let _body content : Element.tspan =
  { (Tspan.default_tspan ()) with content }

let no_wrapper_yields_no_segments () =
  let segs = Text_layout_paragraph.build_segments_from_text
    [| _body "hello" |] "hello" true in
  Alcotest.(check int) "no segs" 0 (List.length segs)

let single_wrapper_covers_content () =
  let segs = Text_layout_paragraph.build_segments_from_text
    [| _wrapper 12.0 0.0 0.0 0.0 0.0 None; _body "hello" |] "hello" true in
  Alcotest.(check int) "1 seg" 1 (List.length segs);
  let s = List.hd segs in
  Alcotest.(check int) "char_end" 5 s.char_end;
  Alcotest.(check (float 0.001)) "left_indent" 12.0 s.left_indent

let two_wrappers_split_content () =
  let segs = Text_layout_paragraph.build_segments_from_text
    [| _wrapper 0.0 0.0 0.0 0.0 0.0 None; _body "ab";
       _wrapper 0.0 0.0 0.0 6.0 0.0 (Some "center"); _body "cde" |]
    "abcde" true in
  Alcotest.(check int) "2 segs" 2 (List.length segs);
  let s2 = List.nth segs 1 in
  Alcotest.(check int) "p2 start" 2 s2.char_start;
  Alcotest.(check int) "p2 end" 5 s2.char_end;
  Alcotest.(check (float 0.001)) "p2 space_before" 6.0 s2.space_before;
  Alcotest.(check bool) "p2 center" true (s2.text_align = Text_layout.Center)

(* ── Phase 6: list markers + counter run rule ──────────── *)

let _list_wrapper style : Element.tspan =
  { (Tspan.default_tspan ()) with
    jas_role = Some "paragraph";
    jas_list_style = Some style }

let marker_text_bullets () =
  Alcotest.(check string) "disc" "\xE2\x80\xA2"
    (Text_layout_paragraph.marker_text "bullet-disc" 1);
  Alcotest.(check string) "open-circle" "\xE2\x97\x8B"
    (Text_layout_paragraph.marker_text "bullet-open-circle" 99);
  Alcotest.(check string) "square" "\xE2\x96\xA0"
    (Text_layout_paragraph.marker_text "bullet-square" 1);
  Alcotest.(check string) "open-square" "\xE2\x96\xA1"
    (Text_layout_paragraph.marker_text "bullet-open-square" 1);
  Alcotest.(check string) "dash" "\xE2\x80\x93"
    (Text_layout_paragraph.marker_text "bullet-dash" 1);
  Alcotest.(check string) "check" "\xE2\x9C\x93"
    (Text_layout_paragraph.marker_text "bullet-check" 1)

let marker_text_decimal () =
  Alcotest.(check string) "1" "1." (Text_layout_paragraph.marker_text "num-decimal" 1);
  Alcotest.(check string) "42" "42." (Text_layout_paragraph.marker_text "num-decimal" 42)

let marker_text_alpha () =
  Alcotest.(check string) "a" "a." (Text_layout_paragraph.marker_text "num-lower-alpha" 1);
  Alcotest.(check string) "z" "z." (Text_layout_paragraph.marker_text "num-lower-alpha" 26);
  Alcotest.(check string) "aa" "aa." (Text_layout_paragraph.marker_text "num-lower-alpha" 27);
  Alcotest.(check string) "AB" "AB." (Text_layout_paragraph.marker_text "num-upper-alpha" 28)

let marker_text_roman () =
  Alcotest.(check string) "i" "i." (Text_layout_paragraph.marker_text "num-lower-roman" 1);
  Alcotest.(check string) "iv" "iv." (Text_layout_paragraph.marker_text "num-lower-roman" 4);
  Alcotest.(check string) "ix" "ix." (Text_layout_paragraph.marker_text "num-lower-roman" 9);
  Alcotest.(check string) "MCMXC" "MCMXC."
    (Text_layout_paragraph.marker_text "num-upper-roman" 1990)

let marker_text_unknown () =
  Alcotest.(check string) "unknown" "" (Text_layout_paragraph.marker_text "invented" 1)

let list_segment_carries_style_and_marker_gap () =
  let segs = Text_layout_paragraph.build_segments_from_text
    [| _list_wrapper "bullet-disc"; _body "hello" |] "hello" true in
  let s = List.hd segs in
  Alcotest.(check (option string)) "list_style" (Some "bullet-disc") s.list_style;
  Alcotest.(check (float 0.001)) "marker_gap" 12.0 s.marker_gap

let counters_consecutive_decimal () =
  let mk () : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "num-decimal" } in
  let cs = Text_layout_paragraph.compute_counters [mk (); mk (); mk ()] in
  Alcotest.(check (list int)) "counters" [1; 2; 3] cs

let counters_bullet_breaks_run () =
  let dec : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "num-decimal" } in
  let bul : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "bullet-disc" } in
  let cs = Text_layout_paragraph.compute_counters [dec; dec; bul; dec] in
  Alcotest.(check (list int)) "counters" [1; 2; 0; 1] cs

let counters_different_num_style_resets () =
  let dec : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "num-decimal" } in
  let alpha : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "num-lower-alpha" } in
  let cs = Text_layout_paragraph.compute_counters [dec; dec; alpha; alpha] in
  Alcotest.(check (list int)) "counters" [1; 2; 1; 2] cs

let counters_no_style_breaks_run () =
  let dec : Text_layout.paragraph_segment =
    { Text_layout.default_segment with list_style = Some "num-decimal" } in
  let none : Text_layout.paragraph_segment = Text_layout.default_segment in
  let cs = Text_layout_paragraph.compute_counters [dec; none; dec] in
  Alcotest.(check (list int)) "counters" [1; 0; 1] cs

let phase6_marker_tests = [
  Alcotest.test_case "marker_text_bullets" `Quick marker_text_bullets;
  Alcotest.test_case "marker_text_decimal" `Quick marker_text_decimal;
  Alcotest.test_case "marker_text_alpha" `Quick marker_text_alpha;
  Alcotest.test_case "marker_text_roman" `Quick marker_text_roman;
  Alcotest.test_case "marker_text_unknown" `Quick marker_text_unknown;
  Alcotest.test_case "list_segment_carries_style_and_marker_gap" `Quick
    list_segment_carries_style_and_marker_gap;
  Alcotest.test_case "counters_consecutive_decimal" `Quick
    counters_consecutive_decimal;
  Alcotest.test_case "counters_bullet_breaks_run" `Quick
    counters_bullet_breaks_run;
  Alcotest.test_case "counters_different_num_style_resets" `Quick
    counters_different_num_style_resets;
  Alcotest.test_case "counters_no_style_breaks_run" `Quick
    counters_no_style_breaks_run;
]

let list_pushes_text_by_marker_gap () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2;
                list_style = Some "bullet-disc"; marker_gap = 12.0 }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "x" 12.0 l.glyphs.(0).x

let list_combines_left_indent_and_marker_gap () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2;
                left_indent = 20.0;
                list_style = Some "num-decimal"; marker_gap = 12.0 }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "x" 32.0 l.glyphs.(0).x

let list_ignores_first_line_indent () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 2;
                first_line_indent = 25.0;
                list_style = Some "bullet-disc"; marker_gap = 12.0 }] in
  let l = Text_layout.layout_with_paragraphs "hi" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "x" 12.0 l.glyphs.(0).x

let phase6_layout_list_tests = [
  Alcotest.test_case "list_pushes_text_by_marker_gap" `Quick
    list_pushes_text_by_marker_gap;
  Alcotest.test_case "list_combines_left_indent_and_marker_gap" `Quick
    list_combines_left_indent_and_marker_gap;
  Alcotest.test_case "list_ignores_first_line_indent" `Quick
    list_ignores_first_line_indent;
]

(* ── Phase 7: hanging punctuation ───────────────────────── *)

let _u (cp : int) = Uchar.of_int cp

let left_hanger_class () =
  List.iter (fun cp ->
    Alcotest.(check bool) (Printf.sprintf "U+%04X is left hanger" cp)
      true (Text_layout.is_left_hanger (_u cp))
  ) [0x0022; 0x0027; 0x201C; 0x2018; 0x00AB; 0x2039;
     0x0028; 0x005B; 0x007B];
  List.iter (fun cp ->
    Alcotest.(check bool) (Printf.sprintf "U+%04X not left hanger" cp)
      false (Text_layout.is_left_hanger (_u cp))
  ) [0x0061; 0x002E; 0x002C; 0x0029; 0x005D; 0x007D; 0x201D]

let right_hanger_class () =
  List.iter (fun cp ->
    Alcotest.(check bool) (Printf.sprintf "U+%04X is right hanger" cp)
      true (Text_layout.is_right_hanger (_u cp))
  ) [0x0022; 0x0027; 0x201D; 0x2019; 0x00BB; 0x203A;
     0x0029; 0x005D; 0x007D; 0x002E; 0x002C;
     0x002D; 0x2013; 0x2014];
  List.iter (fun cp ->
    Alcotest.(check bool) (Printf.sprintf "U+%04X not right hanger" cp)
      false (Text_layout.is_right_hanger (_u cp))
  ) [0x0061; 0x201C; 0x2018; 0x0028; 0x005B; 0x007B]

let hanging_off_no_effect () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 4;
                text_align = Text_layout.Left;
                hanging_punctuation = false }] in
  let l = Text_layout.layout_with_paragraphs "(ab)" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "x" 0.0 l.glyphs.(0).x

let left_aligned_left_hanger () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 4;
                text_align = Text_layout.Left;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "(abc" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "( in margin" (-10.0) l.glyphs.(0).x;
  Alcotest.(check (float 0.001)) "a at edge" 0.0 l.glyphs.(1).x

let left_aligned_right_hanger_no_shift () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 3;
                text_align = Text_layout.Left;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "ab." 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "a x" 0.0 l.glyphs.(0).x;
  Alcotest.(check (float 0.001)) ". inside" 20.0 l.glyphs.(2).x

let right_aligned_right_hanger () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 3;
                text_align = Text_layout.Right;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "ab." 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "b right" 100.0 l.glyphs.(1).right;
  Alcotest.(check (float 0.001)) ". sticks out" 100.0 l.glyphs.(2).x

let right_aligned_left_hanger_no_shift () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 3;
                text_align = Text_layout.Right;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "(ab" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "b right" 100.0 l.glyphs.(2).right;
  Alcotest.(check (float 0.001)) "( inside" 70.0 l.glyphs.(0).x

let centered_both_sides_hang () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 4;
                text_align = Text_layout.Center;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "(ab." 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "( x" 30.0 l.glyphs.(0).x;
  Alcotest.(check (float 0.001)) "a x" 40.0 l.glyphs.(1).x;
  Alcotest.(check (float 0.001)) "b x" 50.0 l.glyphs.(2).x;
  Alcotest.(check (float 0.001)) ". x" 60.0 l.glyphs.(3).x

let dash_hangs_at_eol_right_aligned () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 3;
                text_align = Text_layout.Right;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "ab-" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "- x" 100.0 l.glyphs.(2).x

let hanging_with_left_indent () =
  let m = fixed 10.0 in
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 3;
                left_indent = 20.0;
                text_align = Text_layout.Left;
                hanging_punctuation = true }] in
  let l = Text_layout.layout_with_paragraphs "(ab" 100.0 16.0 segs m in
  Alcotest.(check (float 0.001)) "( x" 10.0 l.glyphs.(0).x;
  Alcotest.(check (float 0.001)) "a x" 20.0 l.glyphs.(1).x

let phase7_tests = [
  Alcotest.test_case "left_hanger_class" `Quick left_hanger_class;
  Alcotest.test_case "right_hanger_class" `Quick right_hanger_class;
  Alcotest.test_case "hanging_off_no_effect" `Quick hanging_off_no_effect;
  Alcotest.test_case "left_aligned_left_hanger" `Quick left_aligned_left_hanger;
  Alcotest.test_case "left_aligned_right_hanger_no_shift" `Quick
    left_aligned_right_hanger_no_shift;
  Alcotest.test_case "right_aligned_right_hanger" `Quick right_aligned_right_hanger;
  Alcotest.test_case "right_aligned_left_hanger_no_shift" `Quick
    right_aligned_left_hanger_no_shift;
  Alcotest.test_case "centered_both_sides_hang" `Quick centered_both_sides_hang;
  Alcotest.test_case "dash_hangs_at_eol_right_aligned" `Quick
    dash_hangs_at_eol_right_aligned;
  Alcotest.test_case "hanging_with_left_indent" `Quick hanging_with_left_indent;
]

(* Phase 10: justify path via Knuth-Plass composer. *)
let m_fixed = (fun s -> Float.of_int (Text_layout.utf8_char_count s) *. 10.0)

let justify_ragged_last_line_keeps_natural () =
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 8;
                text_align = Text_layout.Justify }] in
  let l = Text_layout.layout_with_paragraphs "ab cd ef" 100.0 16.0 segs m_fixed in
  let last = l.glyphs.(Array.length l.glyphs - 1) in
  Alcotest.(check (float 1e-6)) "natural last-line right" 80.0 last.right

let justify_all_stretches_last_line () =
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 8;
                text_align = Text_layout.Justify;
                last_line_align = Text_layout.Justify }] in
  let l = Text_layout.layout_with_paragraphs "ab cd ef" 100.0 16.0 segs m_fixed in
  let last = l.glyphs.(Array.length l.glyphs - 1) in
  Alcotest.(check (float 1.0)) "stretched to box" 100.0 last.right

let justify_two_lines_first_fills_second_ragged () =
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 17;
                text_align = Text_layout.Justify }] in
  let l = Text_layout.layout_with_paragraphs
            "ab cd ef gh ij kl" 100.0 16.0 segs m_fixed in
  Alcotest.(check bool) "two+ lines" true (Array.length l.lines >= 2);
  (* First line stretches near box. *)
  let line0 = l.lines.(0) in
  let line0_right = ref 0.0 in
  for gi = line0.glyph_start to line0.glyph_end - 1 do
    if l.glyphs.(gi).right > !line0_right then line0_right := l.glyphs.(gi).right
  done;
  Alcotest.(check bool) "first line stretches" true (!line0_right > 80.0);
  (* Last line stays within box. *)
  let last_line = l.lines.(Array.length l.lines - 1) in
  let last_right = ref 0.0 in
  for gi = last_line.glyph_start to last_line.glyph_end - 1 do
    if l.glyphs.(gi).right > !last_right then last_right := l.glyphs.(gi).right
  done;
  Alcotest.(check bool) "last line within box" true (!last_right <= 100.0 +. 1e-6)

let justify_preserves_char_count () =
  let segs = [{ Text_layout.default_segment with
                char_start = 0; char_end = 17;
                text_align = Text_layout.Justify }] in
  let l = Text_layout.layout_with_paragraphs
            "ab cd ef gh ij kl" 100.0 16.0 segs m_fixed in
  Alcotest.(check int) "char count" 17 l.char_count;
  Alcotest.(check int) "glyph count" 17 (Array.length l.glyphs)

let phase10_tests = [
  Alcotest.test_case "justify_ragged_last_line_keeps_natural" `Quick
    justify_ragged_last_line_keeps_natural;
  Alcotest.test_case "justify_all_stretches_last_line" `Quick
    justify_all_stretches_last_line;
  Alcotest.test_case "justify_two_lines_first_fills_second_ragged" `Quick
    justify_two_lines_first_fills_second_ragged;
  Alcotest.test_case "justify_preserves_char_count" `Quick
    justify_preserves_char_count;
]

let () =
  Alcotest.run "TextLayout" [
    "Phase 5 layout", [
      Alcotest.test_case "empty_paragraph_list_matches_plain" `Quick
        empty_paragraph_list_matches_plain;
      Alcotest.test_case "left_indent_shifts_every_line" `Quick
        left_indent_shifts_every_line;
      Alcotest.test_case "right_indent_narrows_wrap_width" `Quick
        right_indent_narrows_wrap_width;
      Alcotest.test_case "first_line_indent_only_shifts_first_line" `Quick
        first_line_indent_only_shifts_first_line;
      Alcotest.test_case "alignment_center_shifts_to_center" `Quick
        alignment_center_shifts_to_center;
      Alcotest.test_case "alignment_right_shifts_to_right_edge" `Quick
        alignment_right_shifts_to_right_edge;
      Alcotest.test_case "space_before_skipped_for_first_paragraph" `Quick
        space_before_skipped_for_first_paragraph;
      Alcotest.test_case "space_after_inserts_gap" `Quick
        space_after_inserts_gap;
      Alcotest.test_case "alignment_with_indent_uses_remaining_width" `Quick
        alignment_with_indent_uses_remaining_width;
    ];
    "Phase 5 segments", [
      Alcotest.test_case "no_wrapper_yields_no_segments" `Quick
        no_wrapper_yields_no_segments;
      Alcotest.test_case "single_wrapper_covers_content" `Quick
        single_wrapper_covers_content;
      Alcotest.test_case "two_wrappers_split_content" `Quick
        two_wrappers_split_content;
    ];
    "Phase 6 markers", phase6_marker_tests;
    "Phase 6 layout list", phase6_layout_list_tests;
    "Phase 7 hanging punctuation", phase7_tests;
    "Phase 10 justify", phase10_tests;
  ]
