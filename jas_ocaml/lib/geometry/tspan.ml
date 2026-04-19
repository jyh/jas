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
  jas_role = None;
  jas_left_indent = None;
  jas_right_indent = None;
  jas_hyphenate = None;
  jas_hanging_punctuation = None;
  jas_list_style = None;
  text_align = None;
  text_align_last = None;
  text_indent = None;
  jas_space_before = None;
  jas_space_after = None;
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
  && t.jas_role = None
  && t.jas_left_indent = None
  && t.jas_right_indent = None
  && t.jas_hyphenate = None
  && t.jas_hanging_punctuation = None
  && t.jas_list_style = None
  && t.text_align = None
  && t.text_align_last = None
  && t.text_indent = None
  && t.jas_space_before = None
  && t.jas_space_after = None
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

let _fmt_float v =
  if Float.equal v (Float.of_int (Float.to_int v))
  then Printf.sprintf "%d" (Float.to_int v)
  else Printf.sprintf "%g" v

let _opt_assoc k v = match v with Some x -> [(k, x)] | None -> []

let _tspan_to_json (t : tspan) : Yojson.Safe.t =
  let fields = ref [] in
  let add k v = fields := (k, v) :: !fields in
  add "content" (`String t.content);
  (match t.baseline_shift with Some v -> add "baseline_shift" (`Float v) | None -> ());
  (match t.dx with Some v -> add "dx" (`Float v) | None -> ());
  (match t.font_family with Some v -> add "font_family" (`String v) | None -> ());
  (match t.font_size with Some v -> add "font_size" (`Float v) | None -> ());
  (match t.font_style with Some v -> add "font_style" (`String v) | None -> ());
  (match t.font_variant with Some v -> add "font_variant" (`String v) | None -> ());
  (match t.font_weight with Some v -> add "font_weight" (`String v) | None -> ());
  (match t.jas_aa_mode with Some v -> add "jas_aa_mode" (`String v) | None -> ());
  (match t.jas_fractional_widths with Some v -> add "jas_fractional_widths" (`Bool v) | None -> ());
  (match t.jas_kerning_mode with Some v -> add "jas_kerning_mode" (`String v) | None -> ());
  (match t.jas_no_break with Some v -> add "jas_no_break" (`Bool v) | None -> ());
  (match t.jas_left_indent with Some v -> add "jas_left_indent" (`Float v) | None -> ());
  (match t.jas_right_indent with Some v -> add "jas_right_indent" (`Float v) | None -> ());
  (match t.jas_hyphenate with Some v -> add "jas_hyphenate" (`Bool v) | None -> ());
  (match t.jas_hanging_punctuation with Some v -> add "jas_hanging_punctuation" (`Bool v) | None -> ());
  (match t.jas_list_style with Some v -> add "jas_list_style" (`String v) | None -> ());
  (match t.text_align with Some v -> add "text_align" (`String v) | None -> ());
  (match t.text_align_last with Some v -> add "text_align_last" (`String v) | None -> ());
  (match t.text_indent with Some v -> add "text_indent" (`Float v) | None -> ());
  (match t.jas_space_before with Some v -> add "jas_space_before" (`Float v) | None -> ());
  (match t.jas_space_after with Some v -> add "jas_space_after" (`Float v) | None -> ());
  (match t.letter_spacing with Some v -> add "letter_spacing" (`Float v) | None -> ());
  (match t.line_height with Some v -> add "line_height" (`Float v) | None -> ());
  (match t.rotate with Some v -> add "rotate" (`Float v) | None -> ());
  (match t.style_name with Some v -> add "style_name" (`String v) | None -> ());
  (match t.text_decoration with
   | Some v -> add "text_decoration" (`List (List.map (fun s -> `String s) v))
   | None -> ());
  (match t.text_rendering with Some v -> add "text_rendering" (`String v) | None -> ());
  (match t.text_transform with Some v -> add "text_transform" (`String v) | None -> ());
  (match t.xml_lang with Some v -> add "xml_lang" (`String v) | None -> ());
  ignore _opt_assoc;
  `Assoc (List.rev !fields)

let tspans_to_json_clipboard (tspans : tspan array) : string =
  let arr = Array.to_list tspans |> List.map _tspan_to_json in
  Yojson.Safe.to_string (`Assoc [("tspans", `List arr)])

let _tspan_from_json (i : int) (j : Yojson.Safe.t) : tspan =
  let open Yojson.Safe.Util in
  let get_str key = try Some (to_string (member key j)) with _ -> None in
  let get_float key = try Some (to_number (member key j)) with _ -> None in
  let get_bool key = try Some (to_bool (member key j)) with _ -> None in
  let get_str_list key =
    try
      match member key j with
      | `List xs -> Some (List.map to_string xs)
      | _ -> None
    with _ -> None
  in
  let content = match get_str "content" with Some s -> s | None -> "" in
  {
    id = i;
    content;
    baseline_shift = get_float "baseline_shift";
    dx = get_float "dx";
    font_family = get_str "font_family";
    font_size = get_float "font_size";
    font_style = get_str "font_style";
    font_variant = get_str "font_variant";
    font_weight = get_str "font_weight";
    jas_aa_mode = get_str "jas_aa_mode";
    jas_fractional_widths = get_bool "jas_fractional_widths";
    jas_kerning_mode = get_str "jas_kerning_mode";
    jas_no_break = get_bool "jas_no_break";
    jas_role = get_str "jas_role";
    jas_left_indent = get_float "jas_left_indent";
    jas_right_indent = get_float "jas_right_indent";
    jas_hyphenate = get_bool "jas_hyphenate";
    jas_hanging_punctuation = get_bool "jas_hanging_punctuation";
    jas_list_style = get_str "jas_list_style";
    text_align = get_str "text_align";
    text_align_last = get_str "text_align_last";
    text_indent = get_float "text_indent";
    jas_space_before = get_float "jas_space_before";
    jas_space_after = get_float "jas_space_after";
    letter_spacing = get_float "letter_spacing";
    line_height = get_float "line_height";
    rotate = get_float "rotate";
    style_name = get_str "style_name";
    text_decoration = get_str_list "text_decoration";
    text_rendering = get_str "text_rendering";
    text_transform = get_str "text_transform";
    transform = None;
    xml_lang = get_str "xml_lang";
  }

let tspans_from_json_clipboard (json_str : string) : tspan array option =
  try
    let root = Yojson.Safe.from_string json_str in
    match root with
    | `Assoc fields ->
      (match List.assoc_opt "tspans" fields with
       | Some (`List items) ->
         let tspans = List.mapi _tspan_from_json items in
         Some (Array.of_list tspans)
       | _ -> None)
    | _ -> None
  with _ -> None

let _xml_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let _xml_unescape s =
  (* Minimal: just the five entities our writer emits. *)
  let replace a b s = String.concat b (String.split_on_char '\000'
    (Str.global_replace (Str.regexp_string a) "\000" s)) in
  s |> replace "&quot;" "\""
    |> replace "&gt;" ">"
    |> replace "&lt;" "<"
    |> replace "&amp;" "&"

let tspans_to_svg_fragment (tspans : tspan array) : string =
  let buf = Buffer.create 128 in
  Buffer.add_string buf "<text xmlns=\"http://www.w3.org/2000/svg\">";
  Array.iter (fun (t : tspan) ->
    Buffer.add_string buf "<tspan";
    let attrs = ref [] in
    let add k v = attrs := (k, v) :: !attrs in
    (match t.baseline_shift with Some v -> add "baseline-shift" (_fmt_float v) | None -> ());
    (match t.dx with Some v -> add "dx" (_fmt_float v) | None -> ());
    (match t.font_family with Some v -> add "font-family" v | None -> ());
    (match t.font_size with Some v -> add "font-size" (_fmt_float v) | None -> ());
    (match t.font_style with Some v -> add "font-style" v | None -> ());
    (match t.font_variant with Some v -> add "font-variant" v | None -> ());
    (match t.font_weight with Some v -> add "font-weight" v | None -> ());
    (match t.jas_aa_mode with Some v -> add "jas:aa-mode" v | None -> ());
    (match t.jas_fractional_widths with Some v -> add "jas:fractional-widths" (string_of_bool v) | None -> ());
    (match t.jas_kerning_mode with Some v -> add "jas:kerning-mode" v | None -> ());
    (match t.jas_no_break with Some v -> add "jas:no-break" (string_of_bool v) | None -> ());
    (match t.jas_role with Some v -> add "jas:role" v | None -> ());
    (match t.jas_left_indent with Some v -> add "jas:left-indent" (_fmt_float v) | None -> ());
    (match t.jas_right_indent with Some v -> add "jas:right-indent" (_fmt_float v) | None -> ());
    (match t.jas_hyphenate with Some v -> add "jas:hyphenate" (string_of_bool v) | None -> ());
    (match t.jas_hanging_punctuation with Some v -> add "jas:hanging-punctuation" (string_of_bool v) | None -> ());
    (match t.jas_list_style with Some v -> add "jas:list-style" v | None -> ());
    (match t.text_align with Some v -> add "text-align" v | None -> ());
    (match t.text_align_last with Some v -> add "text-align-last" v | None -> ());
    (match t.text_indent with Some v -> add "text-indent" (_fmt_float v) | None -> ());
    (match t.jas_space_before with Some v -> add "jas:space-before" (_fmt_float v) | None -> ());
    (match t.jas_space_after with Some v -> add "jas:space-after" (_fmt_float v) | None -> ());
    (match t.letter_spacing with Some v -> add "letter-spacing" (_fmt_float v) | None -> ());
    (match t.line_height with Some v -> add "line-height" (_fmt_float v) | None -> ());
    (match t.rotate with Some v -> add "rotate" (_fmt_float v) | None -> ());
    (match t.style_name with Some v -> add "jas:style-name" v | None -> ());
    (match t.text_decoration with
     | Some v when v <> [] -> add "text-decoration" (String.concat " " v)
     | _ -> ());
    (match t.text_rendering with Some v -> add "text-rendering" v | None -> ());
    (match t.text_transform with Some v -> add "text-transform" v | None -> ());
    (match t.xml_lang with Some v -> add "xml:lang" v | None -> ());
    let sorted = List.sort (fun (a, _) (b, _) -> compare a b) !attrs in
    List.iter (fun (k, v) ->
      Buffer.add_char buf ' ';
      Buffer.add_string buf k;
      Buffer.add_string buf "=\"";
      Buffer.add_string buf (_xml_escape v);
      Buffer.add_char buf '"'
    ) sorted;
    Buffer.add_char buf '>';
    Buffer.add_string buf (_xml_escape t.content);
    Buffer.add_string buf "</tspan>"
  ) tspans;
  Buffer.add_string buf "</text>";
  Buffer.contents buf

let _strip_tags s =
  let buf = Buffer.create (String.length s) in
  let in_tag = ref false in
  String.iter (fun c ->
    if c = '<' then in_tag := true
    else if c = '>' && !in_tag then in_tag := false
    else if not !in_tag then Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let _parse_xml_attrs s =
  (* Minimal XML attr parser; handles the shape our writer emits. *)
  let out = ref [] in
  let len = String.length s in
  let i = ref 0 in
  while !i < len do
    while !i < len && (s.[!i] = ' ' || s.[!i] = '\t' || s.[!i] = '\n') do incr i done;
    if !i >= len then ()
    else begin
      let name_start = !i in
      while !i < len && s.[!i] <> '=' && s.[!i] <> ' ' && s.[!i] <> '\t' do incr i done;
      let name = String.sub s name_start (!i - name_start) in
      if name = "" then i := len
      else begin
        while !i < len && s.[!i] <> '=' do incr i done;
        if !i < len then incr i;
        while !i < len && s.[!i] <> '"' && s.[!i] <> '\'' do incr i done;
        if !i < len then begin
          let quote = s.[!i] in
          incr i;
          let val_start = !i in
          while !i < len && s.[!i] <> quote do incr i done;
          let v = String.sub s val_start (!i - val_start) in
          if !i < len then incr i;
          out := (name, _xml_unescape v) :: !out
        end
      end
    end
  done;
  List.rev !out

let tspans_from_svg_fragment (svg_str : string) : tspan array option =
  let trimmed = String.trim svg_str in
  try
    let text_pos = Str.search_forward (Str.regexp_string "<text") trimmed 0 in
    let rest = String.sub trimmed text_pos (String.length trimmed - text_pos) in
    let out = ref [] in
    let next_id = ref 0 in
    let pos = ref 0 in
    let len = String.length rest in
    (try
      while !pos < len do
        let open_pos = Str.search_forward (Str.regexp_string "<tspan") rest !pos in
        let gt_pos =
          try String.index_from rest open_pos '>'
          with Not_found -> raise Exit
        in
        let attrs_str = String.sub rest (open_pos + 6) (gt_pos - (open_pos + 6)) in
        let close_pos =
          try Str.search_forward (Str.regexp_string "</tspan>") rest (gt_pos + 1)
          with Not_found -> raise Exit
        in
        let content_raw = String.sub rest (gt_pos + 1) (close_pos - (gt_pos + 1)) in
        let content = _xml_unescape (_strip_tags content_raw) in
        let t = ref { (default_tspan ()) with id = !next_id; content } in
        incr next_id;
        List.iter (fun (k, v) ->
          let cur : tspan = !t in
          t := (match k with
            | "baseline-shift" -> { cur with baseline_shift = float_of_string_opt v }
            | "dx" -> { cur with dx = float_of_string_opt v }
            | "font-family" -> { cur with font_family = Some v }
            | "font-size" -> { cur with font_size = float_of_string_opt v }
            | "font-style" -> { cur with font_style = Some v }
            | "font-variant" -> { cur with font_variant = Some v }
            | "font-weight" -> { cur with font_weight = Some v }
            | "jas:aa-mode" -> { cur with jas_aa_mode = Some v }
            | "jas:fractional-widths" -> { cur with jas_fractional_widths = Some (v = "true") }
            | "jas:kerning-mode" -> { cur with jas_kerning_mode = Some v }
            | "jas:no-break" -> { cur with jas_no_break = Some (v = "true") }
            | "jas:role" -> { cur with jas_role = Some v }
            | "jas:left-indent" -> { cur with jas_left_indent = float_of_string_opt v }
            | "jas:right-indent" -> { cur with jas_right_indent = float_of_string_opt v }
            | "jas:hyphenate" -> { cur with jas_hyphenate = Some (v = "true") }
            | "jas:hanging-punctuation" -> { cur with jas_hanging_punctuation = Some (v = "true") }
            | "jas:list-style" -> { cur with jas_list_style = Some v }
            | "text-align" -> { cur with text_align = Some v }
            | "text-align-last" -> { cur with text_align_last = Some v }
            | "text-indent" -> { cur with text_indent = float_of_string_opt v }
            | "jas:space-before" -> { cur with jas_space_before = float_of_string_opt v }
            | "jas:space-after" -> { cur with jas_space_after = float_of_string_opt v }
            | "letter-spacing" -> { cur with letter_spacing = float_of_string_opt v }
            | "line-height" -> { cur with line_height = float_of_string_opt v }
            | "rotate" -> { cur with rotate = float_of_string_opt v }
            | "jas:style-name" -> { cur with style_name = Some v }
            | "text-decoration" ->
              let parts = String.split_on_char ' ' v
                |> List.filter (fun p -> p <> "" && p <> "none") in
              { cur with text_decoration = Some parts }
            | "text-rendering" -> { cur with text_rendering = Some v }
            | "text-transform" -> { cur with text_transform = Some v }
            | "xml:lang" -> { cur with xml_lang = Some v }
            | _ -> cur)
        ) (_parse_xml_attrs attrs_str);
        out := !t :: !out;
        pos := close_pos + 8
      done
    with Not_found | Exit -> ());
    if !out = [] then None
    else Some (Array.of_list (List.rev !out))
  with Not_found -> None

let merge_tspan_overrides (target : tspan) (source : tspan) : tspan =
  let or_some a b = match a with Some _ -> a | None -> b in
  {
    id = target.id;
    content = target.content;
    baseline_shift = or_some source.baseline_shift target.baseline_shift;
    dx = or_some source.dx target.dx;
    font_family = or_some source.font_family target.font_family;
    font_size = or_some source.font_size target.font_size;
    font_style = or_some source.font_style target.font_style;
    font_variant = or_some source.font_variant target.font_variant;
    font_weight = or_some source.font_weight target.font_weight;
    jas_aa_mode = or_some source.jas_aa_mode target.jas_aa_mode;
    jas_fractional_widths = or_some source.jas_fractional_widths target.jas_fractional_widths;
    jas_kerning_mode = or_some source.jas_kerning_mode target.jas_kerning_mode;
    jas_no_break = or_some source.jas_no_break target.jas_no_break;
    jas_role = or_some source.jas_role target.jas_role;
    jas_left_indent = or_some source.jas_left_indent target.jas_left_indent;
    jas_right_indent = or_some source.jas_right_indent target.jas_right_indent;
    jas_hyphenate = or_some source.jas_hyphenate target.jas_hyphenate;
    jas_hanging_punctuation = or_some source.jas_hanging_punctuation target.jas_hanging_punctuation;
    jas_list_style = or_some source.jas_list_style target.jas_list_style;
    text_align = or_some source.text_align target.text_align;
    text_align_last = or_some source.text_align_last target.text_align_last;
    text_indent = or_some source.text_indent target.text_indent;
    jas_space_before = or_some source.jas_space_before target.jas_space_before;
    jas_space_after = or_some source.jas_space_after target.jas_space_after;
    letter_spacing = or_some source.letter_spacing target.letter_spacing;
    line_height = or_some source.line_height target.line_height;
    rotate = or_some source.rotate target.rotate;
    style_name = or_some source.style_name target.style_name;
    text_decoration = or_some source.text_decoration target.text_decoration;
    text_rendering = or_some source.text_rendering target.text_rendering;
    text_transform = or_some source.text_transform target.text_transform;
    transform = or_some source.transform target.transform;
    xml_lang = or_some source.xml_lang target.xml_lang;
  }

let identity_omit_tspan (t : tspan) (elem : Element.element) : tspan =
  match elem with
  | Element.Text _ | Element.Text_path _ ->
    let (ff, fs, fw, fst, td, tt, fv, xl, rot, lh, ls, bs, aa) = match elem with
      | Element.Text r ->
        (r.font_family, r.font_size, r.font_weight, r.font_style,
         r.text_decoration, r.text_transform, r.font_variant,
         r.xml_lang, r.rotate, r.line_height, r.letter_spacing,
         r.baseline_shift, r.aa_mode)
      | Element.Text_path r ->
        (r.font_family, r.font_size, r.font_weight, r.font_style,
         r.text_decoration, r.text_transform, r.font_variant,
         r.xml_lang, r.rotate, r.line_height, r.letter_spacing,
         r.baseline_shift, r.aa_mode)
      | _ -> assert false
    in
    let has_suffix ~suffix s =
      let ls = String.length s in
      let lsuf = String.length suffix in
      ls >= lsuf && String.sub s (ls - lsuf) lsuf = suffix
    in
    let parse_pt s =
      let s = String.trim s in
      if s = "" then None
      else
        let rest = if has_suffix ~suffix:"pt" s
          then String.sub s 0 (String.length s - 2) else s in
        try Some (float_of_string rest) with _ -> None
    in
    let parse_em s =
      let s = String.trim s in
      if s = "" then None
      else
        let rest = if has_suffix ~suffix:"em" s
          then String.sub s 0 (String.length s - 2) else s in
        try Some (float_of_string rest) with _ -> None
    in
    let eq_str_opt a b = match a with Some s -> s = b | None -> false in
    let t = if eq_str_opt t.font_family ff then { t with font_family = None } else t in
    let t = match t.font_size with
      | Some v when abs_float (v -. fs) < 1e-6 -> { t with font_size = None }
      | _ -> t in
    let t = if eq_str_opt t.font_weight fw then { t with font_weight = None } else t in
    let t = if eq_str_opt t.font_style fst then { t with font_style = None } else t in
    let t = match t.text_decoration with
      | Some parts ->
        let a = List.sort compare parts in
        let b = List.sort compare
          (String.split_on_char ' ' td
           |> List.filter (fun p -> p <> "" && p <> "none")) in
        if a = b then { t with text_decoration = None } else t
      | None -> t in
    let t = if eq_str_opt t.text_transform tt then { t with text_transform = None } else t in
    let t = if eq_str_opt t.font_variant fv then { t with font_variant = None } else t in
    let t = if eq_str_opt t.xml_lang xl then { t with xml_lang = None } else t in
    let t = match t.rotate with
      | Some v ->
        let elem_rot = try float_of_string rot with _ -> 0.0 in
        if abs_float (v -. elem_rot) < 1e-6 then { t with rotate = None } else t
      | None -> t in
    let t = match t.line_height with
      | Some v ->
        let elem_lh = match parse_pt lh with Some x -> x | None -> fs *. 1.2 in
        if abs_float (v -. elem_lh) < 1e-6 then { t with line_height = None } else t
      | None -> t in
    let t = match t.letter_spacing with
      | Some v ->
        let elem_ls = match parse_em ls with Some x -> x | None -> 0.0 in
        if abs_float (v -. elem_ls) < 1e-6 then { t with letter_spacing = None } else t
      | None -> t in
    let t = match t.baseline_shift with
      | Some v ->
        (match parse_pt bs with
         | Some elem_bs ->
           if abs_float (v -. elem_bs) < 1e-6 then { t with baseline_shift = None } else t
         | None ->
           if bs = "" && v = 0.0 then { t with baseline_shift = None } else t)
      | None -> t in
    let t = match t.jas_aa_mode with
      | Some v ->
        let elem_aa = if aa = "Sharp" then "" else aa in
        if v = elem_aa then { t with jas_aa_mode = None } else t
      | None -> t in
    t
  | _ -> t

type affinity = Left | Right

let char_to_tspan_pos (tspans : tspan array) (char_idx : int) (aff : affinity) : int * int =
  let n_tspans = Array.length tspans in
  if n_tspans = 0 then (0, 0)
  else begin
    let result = ref None in
    let acc = ref 0 in
    let i = ref 0 in
    while !result = None && !i < n_tspans do
      let t : tspan = tspans.(!i) in
      let n = String.length t.content in
      if char_idx < !acc + n then
        result := Some (!i, char_idx - !acc)
      else if char_idx = !acc + n then begin
        if !i + 1 = n_tspans then
          result := Some (!i, n)
        else match aff with
          | Left -> result := Some (!i, n)
          | Right -> result := Some (!i + 1, 0)
      end;
      acc := !acc + n;
      incr i
    done;
    match !result with
    | Some r -> r
    | None ->
      let last = n_tspans - 1 in
      (last, String.length tspans.(last).content)
  end

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
  && a.jas_role = b.jas_role
  && a.jas_left_indent = b.jas_left_indent
  && a.jas_right_indent = b.jas_right_indent
  && a.jas_hyphenate = b.jas_hyphenate
  && a.jas_hanging_punctuation = b.jas_hanging_punctuation
  && a.jas_list_style = b.jas_list_style
  && a.text_align = b.text_align
  && a.text_align_last = b.text_align_last
  && a.text_indent = b.text_indent
  && a.jas_space_before = b.jas_space_before
  && a.jas_space_after = b.jas_space_after
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

let copy_range (original : tspan array) (char_start : int) (char_end : int) : tspan array =
  if char_start >= char_end then [||]
  else begin
    let total = Array.fold_left (fun acc (t : tspan) ->
      acc + String.length t.content) 0 original in
    let s = min char_start total in
    let e = min char_end total in
    if s >= e then [||]
    else begin
      let out = ref [] in
      let cursor = ref 0 in
      Array.iter (fun (t : tspan) ->
        let len = String.length t.content in
        let t_start = !cursor in
        let t_end = t_start + len in
        let overlap_start = max s t_start in
        let overlap_end = min e t_end in
        if overlap_start < overlap_end then begin
          let local_start = overlap_start - t_start in
          let local_end = overlap_end - t_start in
          let sliced = String.sub t.content local_start (local_end - local_start) in
          out := { t with content = sliced } :: !out
        end;
        cursor := t_end
      ) original;
      Array.of_list (List.rev !out)
    end
  end

let insert_tspans_at (original : tspan array) (char_pos : int)
    (to_insert : tspan array) : tspan array =
  let any_nonempty = Array.exists (fun (t : tspan) -> t.content <> "") to_insert in
  if not any_nonempty then Array.copy original
  else begin
    let base_max = Array.fold_left (fun acc (t : tspan) ->
      if t.id > acc then t.id else acc) (-1) original in
    let next_id = ref (base_max + 1) in
    let fresh () = let id = !next_id in incr next_id; id in
    let reindexed = Array.map (fun (t : tspan) -> { t with id = fresh () }) to_insert in
    let total = Array.fold_left (fun acc (t : tspan) ->
      acc + String.length t.content) 0 original in
    let pos = min char_pos total in
    let before = ref [] in
    let after = ref [] in
    let cursor = ref 0 in
    Array.iter (fun (t : tspan) ->
      let len = String.length t.content in
      let t_end = !cursor + len in
      if t_end <= pos then
        before := t :: !before
      else if !cursor >= pos then
        after := t :: !after
      else begin
        let local = pos - !cursor in
        let left = { t with content = String.sub t.content 0 local } in
        let right = { t with id = fresh ();
                             content = String.sub t.content local (len - local) } in
        before := left :: !before;
        after := right :: !after
      end;
      cursor := t_end
    ) original;
    let parts = List.rev !before
              @ Array.to_list reindexed
              @ List.rev !after in
    merge (Array.of_list parts)
  end

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
