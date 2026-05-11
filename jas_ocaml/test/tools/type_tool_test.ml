(** Type tool unit tests. Currently just covers the UTF-8 sanitizer
    that defends against bad clipboard payloads — see
    [Type_tool.sanitize_utf8]. The full editing path needs a live
    canvas/tool_context and lives under manual testing. *)

open Jas

let sanitize_passes_valid_utf8_unchanged () =
  let s = "smart \xE2\x80\x9Cquoted\xE2\x80\x9D and en\xE2\x80\x93dash" in
  Alcotest.(check bool) "input is valid" true (String.is_valid_utf_8 s);
  Alcotest.(check string) "round-trips" s (Type_tool.sanitize_utf8 s)

let sanitize_strips_lone_continuation_byte () =
  (* 0x80 alone is a UTF-8 continuation byte without a leading byte.
     Drop it; ASCII context survives. *)
  let s = "hello\x80world" in
  Alcotest.(check bool) "input invalid" false (String.is_valid_utf_8 s);
  let cleaned = Type_tool.sanitize_utf8 s in
  Alcotest.(check bool) "output valid" true (String.is_valid_utf_8 cleaned);
  Alcotest.(check string) "ASCII kept" "helloworld" cleaned

let sanitize_strips_truncated_multibyte () =
  (* 0xE2 0x80 starts a 3-byte sequence but is truncated to 2 bytes. *)
  let s = "\xE2\x80hi" in
  Alcotest.(check bool) "input invalid" false (String.is_valid_utf_8 s);
  let cleaned = Type_tool.sanitize_utf8 s in
  Alcotest.(check bool) "output valid" true (String.is_valid_utf_8 cleaned);
  Alcotest.(check string) "ASCII kept" "hi" cleaned

let sanitize_empty_input_yields_empty () =
  Alcotest.(check string) "" "" (Type_tool.sanitize_utf8 "")

let sanitize_passes_pure_ascii_unchanged () =
  let s = "Russian trade of the week" in
  Alcotest.(check string) "ASCII" s (Type_tool.sanitize_utf8 s)

let () =
  Alcotest.run "TypeTool" [
    "sanitize_utf8", [
      Alcotest.test_case "passes_valid_utf8_unchanged" `Quick
        sanitize_passes_valid_utf8_unchanged;
      Alcotest.test_case "strips_lone_continuation_byte" `Quick
        sanitize_strips_lone_continuation_byte;
      Alcotest.test_case "strips_truncated_multibyte" `Quick
        sanitize_strips_truncated_multibyte;
      Alcotest.test_case "empty_input_yields_empty" `Quick
        sanitize_empty_input_yields_empty;
      Alcotest.test_case "passes_pure_ascii_unchanged" `Quick
        sanitize_passes_pure_ascii_unchanged;
    ];
  ]
