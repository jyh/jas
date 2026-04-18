(** Pure-function primitives over tspan lists.

    The [tspan] / [tspan_id] types live in [Element] to break the
    circular module dep (see the header of [element.mli]). Mirrors
    [jas_dioxus/src/geometry/tspan.rs] and
    [JasSwift/Sources/Geometry/TspanPrimitives.swift]. *)

type tspan_id = Element.tspan_id
type tspan = Element.tspan

let default_tspan () : tspan = {
  id = 0;
  content = "";
  baseline_shift = None;
  dx = None;
  font_family = None;
  font_size = None;
  font_style = None;
  font_variant = None;
  font_weight = None;
  jas_aa_mode = None;
  jas_fractional_widths = None;
  jas_kerning_mode = None;
  jas_no_break = None;
  letter_spacing = None;
  line_height = None;
  rotate = None;
  style_name = None;
  text_decoration = None;
  text_rendering = None;
  text_transform = None;
  transform = None;
  xml_lang = None;
}

let has_no_overrides (t : tspan) : bool =
  t.baseline_shift = None
  && t.dx = None
  && t.font_family = None
  && t.font_size = None
  && t.font_style = None
  && t.font_variant = None
  && t.font_weight = None
  && t.jas_aa_mode = None
  && t.jas_fractional_widths = None
  && t.jas_kerning_mode = None
  && t.jas_no_break = None
  && t.letter_spacing = None
  && t.line_height = None
  && t.rotate = None
  && t.style_name = None
  && t.text_decoration = None
  && t.text_rendering = None
  && t.text_transform = None
  && t.transform = None
  && t.xml_lang = None

let concat_content (tspans : tspan array) : string =
  let buf = Buffer.create 64 in
  Array.iter (fun (t : tspan) -> Buffer.add_string buf t.content) tspans;
  Buffer.contents buf

let resolve_id (tspans : tspan array) (id : tspan_id) : int option =
  let result = ref None in
  Array.iteri (fun i (t : tspan) ->
    if !result = None && t.id = id then result := Some i
  ) tspans;
  !result

(** Max id in the list; [-1] when empty (caller adds [+ 1] to get
    the next fresh id, yielding [0] for an empty list). *)
let _max_id (tspans : tspan array) : tspan_id =
  Array.fold_left (fun acc (t : tspan) -> if t.id > acc then t.id else acc) (-1) tspans

let split (tspans : tspan array) (tspan_idx : int) (offset : int)
  : tspan array * int option * int option =
  if tspan_idx < 0 || tspan_idx >= Array.length tspans then
    invalid_arg (Printf.sprintf
      "Tspan.split: tspan_idx %d out of range (%d tspans)"
      tspan_idx (Array.length tspans));
  let t = tspans.(tspan_idx) in
  let len = String.length t.content in
  if offset < 0 || offset > len then
    invalid_arg (Printf.sprintf
      "Tspan.split: offset %d exceeds tspan content length %d"
      offset len);

  if offset = 0 then begin
    let left = if tspan_idx > 0 then Some (tspan_idx - 1) else None in
    (Array.copy tspans, left, Some tspan_idx)
  end
  else if offset = len then begin
    let right =
      if tspan_idx + 1 < Array.length tspans
      then Some (tspan_idx + 1) else None in
    (Array.copy tspans, Some tspan_idx, right)
  end
  else begin
    let right_id = _max_id tspans + 1 in
    let left = { t with content = String.sub t.content 0 offset } in
    let right = { t with id = right_id;
                         content = String.sub t.content offset (len - offset) } in
    let n = Array.length tspans in
    let result = Array.make (n + 1) (default_tspan ()) in
    for i = 0 to tspan_idx - 1 do result.(i) <- tspans.(i) done;
    result.(tspan_idx) <- left;
    result.(tspan_idx + 1) <- right;
    for i = tspan_idx + 1 to n - 1 do result.(i + 1) <- tspans.(i) done;
    (result, Some tspan_idx, Some (tspan_idx + 1))
  end

let split_range (tspans : tspan array) (char_start : int) (char_end : int)
  : tspan array * int option * int option =
  if char_start > char_end then
    invalid_arg (Printf.sprintf
      "Tspan.split_range: char_start %d > char_end %d" char_start char_end);
  let total = Array.fold_left (fun acc (t : tspan) -> acc + String.length t.content) 0 tspans in
  if char_end > total then
    invalid_arg (Printf.sprintf
      "Tspan.split_range: char_end %d exceeds content length %d" char_end total);

  if char_start = char_end then (Array.copy tspans, None, None)
  else begin
    let next_id = ref (_max_id tspans + 1) in
    let fresh () = let id = !next_id in incr next_id; id in
    let out = ref [] in
    let first_idx = ref None in
    let last_idx = ref None in
    let cursor = ref 0 in
    let record_middle_index idx =
      if !first_idx = None then first_idx := Some idx;
      last_idx := Some idx
    in
    Array.iter (fun (t : tspan) ->
      let len = String.length t.content in
      let span_start = !cursor in
      let span_end = span_start + len in
      let overlap_start = max char_start span_start in
      let overlap_end = min char_end span_end in
      if overlap_start >= overlap_end then
        out := t :: !out
      else begin
        let local_start = overlap_start - span_start in
        let local_end = overlap_end - span_start in
        if local_start > 0 then begin
          (* prefix keeps the original id *)
          let prefix = { t with content = String.sub t.content 0 local_start } in
          out := prefix :: !out
        end;
        let middle =
          let middle_content =
            String.sub t.content local_start (local_end - local_start) in
          if local_start > 0 then
            (* middle is the right side of the char_start split -> fresh id *)
            { t with id = fresh (); content = middle_content }
          else
            { t with content = middle_content }
        in
        (* the new length of [!out] before adding middle gives the middle's
           position in the final array — !out is in reverse so [List.length]
           is the pre-push index. *)
        record_middle_index (List.length !out);
        out := middle :: !out;
        if local_end < len then begin
          let suffix = { t with id = fresh ();
                                content = String.sub t.content local_end (len - local_end) } in
          out := suffix :: !out
        end
      end;
      cursor := span_end
    ) tspans;
    (Array.of_list (List.rev !out), !first_idx, !last_idx)
  end

(** True when every override slot agrees. Content and id ignored. *)
let _attrs_equal (a : tspan) (b : tspan) : bool =
  a.baseline_shift = b.baseline_shift
  && a.dx = b.dx
  && a.font_family = b.font_family
  && a.font_size = b.font_size
  && a.font_style = b.font_style
  && a.font_variant = b.font_variant
  && a.font_weight = b.font_weight
  && a.jas_aa_mode = b.jas_aa_mode
  && a.jas_fractional_widths = b.jas_fractional_widths
  && a.jas_kerning_mode = b.jas_kerning_mode
  && a.jas_no_break = b.jas_no_break
  && a.letter_spacing = b.letter_spacing
  && a.line_height = b.line_height
  && a.rotate = b.rotate
  && a.style_name = b.style_name
  && a.text_decoration = b.text_decoration
  && a.text_rendering = b.text_rendering
  && a.text_transform = b.text_transform
  && a.transform = b.transform
  && a.xml_lang = b.xml_lang

let merge (tspans : tspan array) : tspan array =
  let filtered = Array.to_list tspans |> List.filter (fun (t : tspan) -> t.content <> "") in
  match filtered with
  | [] -> [| default_tspan () |]
  | head :: rest ->
    (* Build result in reverse: prepend new tspans, rewrite-in-place the
       head when the next matches it. *)
    let out = ref [head] in
    List.iter (fun t ->
      match !out with
      | prev :: rest' when _attrs_equal prev t ->
        out := { prev with content = prev.content ^ t.content } :: rest'
      | _ ->
        out := t :: !out
    ) rest;
    Array.of_list (List.rev !out)

(** True when [byte_offset] is at a UTF-8 scalar boundary in [s].
    Continuation bytes start with the bit pattern [10xxxxxx]. *)
let _is_utf8_boundary (s : string) (byte_offset : int) : bool =
  if byte_offset <= 0 || byte_offset >= String.length s then true
  else (Char.code s.[byte_offset] land 0xC0) <> 0x80

let reconcile_content (original : tspan array) (new_content : string) : tspan array =
  let old_content = concat_content original in
  if old_content = new_content then original
  else if Array.length original = 0 then
    [| { (default_tspan ()) with content = new_content } |]
  else begin
    let old_len = String.length old_content in
    let new_len = String.length new_content in
    (* Longest common prefix (byte-level), snapped to a UTF-8 boundary. *)
    let max_prefix = min old_len new_len in
    let prefix_len = ref 0 in
    while !prefix_len < max_prefix
          && old_content.[!prefix_len] = new_content.[!prefix_len] do
      incr prefix_len
    done;
    while !prefix_len > 0 && not (_is_utf8_boundary old_content !prefix_len) do
      decr prefix_len
    done;
    (* Longest common suffix, bounded so it doesn't overlap the prefix. *)
    let max_suffix = min (old_len - !prefix_len) (new_len - !prefix_len) in
    let suffix_len = ref 0 in
    while !suffix_len < max_suffix
          && old_content.[old_len - 1 - !suffix_len]
             = new_content.[new_len - 1 - !suffix_len] do
      incr suffix_len
    done;
    while !suffix_len > 0
          && not (_is_utf8_boundary old_content (old_len - !suffix_len)) do
      decr suffix_len
    done;

    let old_mid_start = !prefix_len in
    let old_mid_end = old_len - !suffix_len in
    let new_middle = String.sub new_content !prefix_len
      (new_len - !suffix_len - !prefix_len) in

    (* Pure insertion at a boundary: splice new_middle into the
       tspan containing old_mid_start. Everything else passes
       through unchanged. *)
    if old_mid_start = old_mid_end then begin
      let result = Array.copy original in
      let pos = ref old_mid_start in
      let absorbed = ref false in
      let i = ref 0 in
      while not !absorbed && !i < Array.length result do
        let t = result.(!i) in
        let t_len = String.length t.content in
        if !pos <= t_len then begin
          let before = String.sub t.content 0 !pos in
          let after = String.sub t.content !pos (t_len - !pos) in
          result.(!i) <- { t with content = before ^ new_middle ^ after };
          absorbed := true
        end else begin
          pos := !pos - t_len;
          incr i
        end
      done;
      if not !absorbed then begin
        let last_idx = Array.length result - 1 in
        if last_idx >= 0 then begin
          let last = result.(last_idx) in
          result.(last_idx) <- { last with content = last.content ^ new_middle }
        end
      end;
      merge result
    end else begin
      (* Replacement (including pure deletion): walk tspans and absorb
         new_middle into the first overlapping tspan. *)
      let out = ref [] in
      let cursor = ref 0 in
      let middle_consumed = ref false in
      Array.iter (fun (t : tspan) ->
        let t_start = !cursor in
        let t_end = !cursor + String.length t.content in
        if t_end <= old_mid_start then
          out := t :: !out
        else if t_start >= old_mid_end then
          out := t :: !out
        else begin
          let before_len = max 0 (old_mid_start - t_start) in
          let after_off =
            if t_end > old_mid_end then old_mid_end - t_start
            else String.length t.content in
          let before = String.sub t.content 0 before_len in
          let after =
            if t_end > old_mid_end then
              String.sub t.content after_off (String.length t.content - after_off)
            else "" in
          let mid = if !middle_consumed then "" else begin
            middle_consumed := true;
            new_middle
          end in
          let new_content_str = before ^ mid ^ after in
          if new_content_str <> "" then
            out := { t with content = new_content_str } :: !out
        end;
        cursor := t_end
      ) original;
      let result = match List.rev !out with
        | [] -> [| default_tspan () |]
        | lst -> Array.of_list lst
      in
      merge result
    end
  end
