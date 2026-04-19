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
  ]
