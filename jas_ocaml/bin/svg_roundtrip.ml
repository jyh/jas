(** CLI tool for cross-language commutativity testing.

    Usage:
      svg_roundtrip parse <file.svg>      -- parse SVG, output canonical JSON
      svg_roundtrip roundtrip <file.svg>  -- parse SVG, re-serialize, output SVG *)

let () =
  if Array.length Sys.argv < 3 then begin
    Printf.eprintf "Usage: %s parse|roundtrip <file.svg>\n" Sys.argv.(0);
    exit 1
  end;
  let mode = Sys.argv.(1) in
  let file = Sys.argv.(2) in
  let ic = open_in file in
  let n = in_channel_length ic in
  let svg = Bytes.create n in
  really_input ic svg 0 n;
  close_in ic;
  let doc = Jas.Svg.svg_to_document (Bytes.to_string svg) in
  match mode with
  | "parse" ->
    print_string (Jas.Test_json.document_to_test_json doc)
  | "roundtrip" ->
    print_string (Jas.Svg.document_to_svg doc)
  | _ ->
    Printf.eprintf "Unknown mode: %s (use 'parse' or 'roundtrip')\n" mode;
    exit 1
