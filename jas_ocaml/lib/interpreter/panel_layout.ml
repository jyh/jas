(* Shared canonical panel widget-layout pass (Path B).

   OCaml port of jas_dioxus/src/interpreter/panel_layout.rs and
   jas/panels/panel_layout.py. A pure, integer-arithmetic layout of a compiled
   panel node into widget rects, byte-identical across all five apps. The full
   contract is PATH_B_DESIGN.md Appendix A.

   All arithmetic is integer (no float anywhere), so the native implementations
   are byte-identical and the corpus (test_fixtures/algorithms/panel_layout.json)
   needs no tolerance. Text widths use the deterministic stub measure
   (number of Unicode code points) times CHAR_WIDTH (= 10) and columns use the
   Bootstrap-12 rule cell_w = (2*inner_w*N + 12) / 24 (round-half-up, exact). *)

let char_width = 10

let container_types = [ "container"; "row"; "col"; "panel" ]

(* A measured item with coordinates relative to its node origin. *)
type mitem = {
  path : int list;
  mutable x : int;
  mutable y : int;
  mutable w : int;
  mutable h : int;
}

(* Field access over a Yojson object, returning Null for a missing key or a
   non-object node. *)
let mem (key : string) (n : Yojson.Safe.t) : Yojson.Safe.t =
  match n with
  | `Assoc fields -> (match List.assoc_opt key fields with Some v -> v | None -> `Null)
  | _ -> `Null

(* Numeric coercion mirroring the Rust as_i64().or(as_f64 as i64): only numeric
   nodes coerce; floats truncate toward zero. *)
let to_int_opt (v : Yojson.Safe.t) : int option =
  match v with
  | `Int i -> Some i
  | `Intlit s -> (try Some (int_of_string s) with _ -> None)
  | `Float f -> Some (int_of_float f)
  | _ -> None

let to_str_opt (v : Yojson.Safe.t) : string option =
  match v with `String s -> Some s | _ -> None

let node_type (n : Yojson.Safe.t) : string =
  match mem "type" n with `String s -> s | _ -> ""

let style (n : Yojson.Safe.t) : Yojson.Safe.t = mem "style" n

let style_i (n : Yojson.Safe.t) (key : string) : int option =
  to_int_opt (mem key (style n))

let is_container (n : Yojson.Safe.t) : bool =
  List.mem (node_type n) container_types

let has_col (n : Yojson.Safe.t) : bool =
  match mem "col" n with `Null -> false | _ -> true

let resolved_layout (n : Yojson.Safe.t) : string =
  match to_str_opt (mem "layout" n) with
  | Some "row" -> "row"
  | Some "column" -> "column"
  | _ -> if node_type n = "row" then "row" else "column"

(* Count Unicode code points in a UTF-8 string (continuation bytes have their
   top two bits set to 10, so every non-continuation byte starts a code point). *)
let utf8_length (s : string) : int =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let text_w (s : string) : int = utf8_length s * char_width

let is_fill (kind : string) : bool =
  match kind with
  | "select" | "number_input" | "text_input" | "length_input" | "slider"
  | "placeholder" | "separator" | "combo_box" | "icon_select" | "spacer"
  (* composite / data-driven widgets: placed as a fixed box (fill width) *)
  | "color_bar" | "fill_stroke_widget" | "gradient_slider" | "gradient_tile"
  | "dropdown" | "tree_view" -> true
  | _ -> false

let kind_height (kind : string) : int =
  match kind with
  | "text" -> 20
  | "button" -> 24
  | "checkbox" -> 20
  | "icon_button" -> 24
  | "icon" -> 20
  | "select" -> 20
  | "number_input" -> 20
  | "text_input" -> 20
  | "length_input" -> 20
  | "slider" -> 12
  | "placeholder" -> 40
  | "separator" -> 1
  | "combo_box" -> 20
  | "icon_select" -> 20
  | "spacer" -> 0
  | "color_swatch" -> 16
  | "toggle" -> 20
  (* composite box heights (provisional) *)
  | "color_bar" -> 24
  | "fill_stroke_widget" -> 44
  | "gradient_slider" -> 24
  | "gradient_tile" -> 24
  | "dropdown" -> 20
  | "tree_view" -> 200
  | _ -> 20

let kind_fallback_w (kind : string) : int =
  match kind with
  | "select" -> 80
  | "number_input" -> 45
  | "text_input" -> 80
  | "length_input" -> 80
  | "slider" -> 100
  | "placeholder" -> 60
  | "combo_box" -> 80
  | "icon_select" -> 80
  | "spacer" -> 0
  | "fill_stroke_widget" -> 50
  | "gradient_tile" -> 32
  | "dropdown" -> 80
  | _ -> 0

(* Resolve a style dimension to integer px, or None to ignore. Numbers truncate
   toward zero; "N%" is (avail*N)/100 (ignored when avail <= 0, e.g. heights,
   which have no reference); a bare numeric string is that int; anything else
   (auto, junk) is ignored. *)
let resolve_dim (v : Yojson.Safe.t) (avail : int) : int option =
  match v with
  | `Null -> None
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | `Intlit s -> (try Some (int_of_string s) with _ -> None)
  | `String raw ->
    let s = String.trim raw in
    let len = String.length s in
    if len > 0 && s.[len - 1] = '%' then begin
      let num = String.trim (String.sub s 0 (len - 1)) in
      let p_opt =
        try Some (int_of_string num)
        with _ -> (try Some (int_of_float (float_of_string num)) with _ -> None)
      in
      match p_opt with
      | Some p -> if avail > 0 then Some (avail * p / 100) else None
      | None -> None
    end else begin
      try Some (int_of_string s)
      with _ -> (try Some (int_of_float (float_of_string s)) with _ -> None)
    end
  | _ -> None

(* CSS 1/2/4-value shorthand to (top, right, bottom, left), ints. *)
let parse_padding (v : Yojson.Safe.t) : int * int * int * int =
  match v with
  | `Null -> (0, 0, 0, 0)
  | `Int n -> (n, n, n, n)
  | `Intlit s -> (let n = int_of_string s in (n, n, n, n))
  | `Float f -> (let n = int_of_float f in (n, n, n, n))
  | _ ->
    let parts =
      match v with
      | `String s ->
        Str.split (Str.regexp "[ \t\n\r]+") s |> List.filter_map (fun p ->
          try Some (int_of_string p) with _ -> None)
      | `List a -> List.filter_map to_int_opt a
      | _ -> []
    in
    (match parts with
     | [ n ] -> (n, n, n, n)
     | [ vv; hh ] -> (vv, hh, vv, hh)
     | a :: b :: c :: d :: _ -> (a, b, c, d)
     | _ -> (0, 0, 0, 0))

(* Visible children as (index, node) pairs: only object nodes, excluding any
   whose visible field is exactly false. *)
let visible_children (n : Yojson.Safe.t) : (int * Yojson.Safe.t) list =
  match mem "children" n with
  | `List ch ->
    List.mapi (fun i c -> (i, c)) ch
    |> List.filter (fun (_, c) ->
      match c with
      | `Assoc _ -> (match mem "visible" c with `Bool false -> false | _ -> true)
      | _ -> false)
  | _ -> []

(* Mirror Python int(c.get("col") or 1): 0 and null both become 1. *)
let col_span (n : Yojson.Safe.t) : int =
  let raw = match to_int_opt (mem "col" n) with Some i -> i | None -> 0 in
  if raw <> 0 then raw else 1

(* Return (w, h, fill) for a leaf widget. *)
let leaf_size (n : Yojson.Safe.t) (avail_w : int) : int * int * bool =
  let t = node_type n in
  let st = style n in
  let h =
    match resolve_dim (mem "height" st) 0 with Some v -> v | None -> kind_height t
  in
  let fill = is_fill t in
  let w =
    if fill then (if avail_w > 0 then avail_w else kind_fallback_w t)
    else
      match t with
      | "text" -> text_w (match to_str_opt (mem "content" n) with Some s -> s | None -> "")
      | "button" -> text_w (match to_str_opt (mem "label" n) with Some s -> s | None -> "") + 16
      | "checkbox" | "toggle" -> 16 + 4 + text_w (match to_str_opt (mem "label" n) with Some s -> s | None -> "")
      | "color_swatch" -> 16
      | "icon_button" -> 24
      | "icon" -> 20
      | _ -> 0
  in
  let w = match resolve_dim (mem "width" st) avail_w with Some x -> x | None -> w in
  let w = match resolve_dim (mem "min_width" st) avail_w with Some m -> max w m | None -> w in
  (w, h, fill)

(* Returns (w, h, items) with item coords RELATIVE to this node origin. *)
let rec measure (n : Yojson.Safe.t) (path : int list) (avail_w : int)
  : int * int * mitem list =
  let pt, pr, pb, pl = parse_padding (mem "padding" (style n)) in
  let gap = match style_i n "gap" with Some g -> g | None -> 0 in
  let inner_w = avail_w - pl - pr in
  if is_container n then begin
    let children = visible_children n in
    let lay = resolved_layout n in
    let ch_items, content_h =
      if lay = "row" && List.exists (fun (_, c) -> has_col c) children then
        grid children path inner_w gap
      else if lay = "row" then
        flow children path inner_w gap
      else
        column children path inner_w gap
    in
    let w = avail_w in
    let h = content_h + pt + pb in
    let root = { path; x = 0; y = 0; w; h } in
    List.iter (fun it -> it.x <- it.x + pl; it.y <- it.y + pt) ch_items;
    (w, h, root :: ch_items)
  end else begin
    let w, h, _fill = leaf_size n avail_w in
    (w, h, [ { path; x = 0; y = 0; w; h } ])
  end

and column children path inner_w gap : mitem list * int =
  let items = ref [] in
  let cy = ref 0 in
  let n = ref 0 in
  List.iter (fun (i, c) ->
    let _cw, ch, cit = measure c (path @ [ i ]) inner_w in
    List.iter (fun it -> it.y <- it.y + !cy) cit;
    items := !items @ cit;
    cy := !cy + ch + gap;
    incr n)
    children;
  (!items, if !n > 0 then !cy - gap else 0)

and flow children path inner_w gap : mitem list * int =
  (* Measure each child at intrinsic width (fill leaves use fallbacks). *)
  let measured =
    List.map (fun (i, c) ->
      let cw, ch, cit = measure c (path @ [ i ]) (-1) in
      (c, cw, ch, cit))
      children
  in
  let n = List.length measured in
  let fixed =
    List.fold_left (fun acc (_, cw, _, _) -> acc + cw) 0 measured
    + (if n > 0 then gap * (n - 1) else 0)
  in
  let leftover = max 0 (inner_w - fixed) in
  let weights =
    List.map (fun (c, _, _, _) ->
      let wt = match style_i c "flex" with Some f -> f | None -> 0 in
      if wt = 0 && node_type c = "spacer" then 1 else wt)
      measured
  in
  let sumw = List.fold_left ( + ) 0 weights in
  let extra = Array.make n 0 in
  if sumw > 0 && leftover > 0 then begin
    let wts = Array.of_list weights in
    for k = 0 to n - 1 do
      extra.(k) <- leftover * wts.(k) / sumw
    done;
    let used = Array.fold_left ( + ) 0 extra in
    let rem = ref (leftover - used) in
    (try
       for k = 0 to n - 1 do
         if !rem <= 0 then raise Exit;
         if wts.(k) > 0 then begin
           extra.(k) <- extra.(k) + 1;
           decr rem
         end
       done
     with Exit -> ())
  end;
  let row_h =
    List.fold_left (fun acc (_, _, ch, _) -> max acc ch) 0 measured
  in
  let items = ref [] in
  let cx = ref 0 in
  List.iteri (fun k (_c, cw, ch, cit) ->
    let fw = cw + extra.(k) in
    let dy = (row_h - ch) / 2 in
    List.iter (fun it -> it.x <- it.x + !cx; it.y <- it.y + dy) cit;
    (if extra.(k) <> 0 then
       match cit with first :: _ -> first.w <- fw | [] -> ());
    items := !items @ cit;
    cx := !cx + fw + gap)
    measured;
  (!items, row_h)

and grid children path inner_w gap : mitem list * int =
  (* Wrap into lines so each line column span sums to at most 12. *)
  let lines = ref [] in
  let cur = ref [] in
  let cur_span = ref 0 in
  List.iter (fun (i, c) ->
    let span = col_span c in
    if !cur <> [] && !cur_span + span > 12 then begin
      lines := !lines @ [ List.rev !cur ];
      cur := [];
      cur_span := 0
    end;
    cur := (i, c, span) :: !cur;
    cur_span := !cur_span + span)
    children;
  if !cur <> [] then lines := !lines @ [ List.rev !cur ];
  let items = ref [] in
  let line_y = ref 0 in
  List.iter (fun line ->
    let cx = ref 0 in
    let line_h = ref 0 in
    let cells = ref [] in
    List.iter (fun (i, c, span) ->
      let cell_w = (2 * inner_w * span + 12) / 24 in
      let _cw, ch, cit = measure c (path @ [ i ]) cell_w in
      cells := !cells @ [ (cit, ch, !cx) ];
      if ch > !line_h then line_h := ch;
      cx := !cx + cell_w + gap)
      line;
    List.iter (fun (cit, ch, cell_x) ->
      let dy = (!line_h - ch) / 2 in
      List.iter (fun it -> it.x <- it.x + cell_x; it.y <- it.y + !line_y + dy) cit;
      items := !items @ cit)
      !cells;
    line_y := !line_y + !line_h + gap)
    !lines;
  (!items, if !lines <> [] then !line_y - gap else 0)

(* Lay out a compiled panel node ({"type":"panel","content":<root>}) into a
   JSON array of {"path":[..],"rect":{x,y,w,h}}, pre-order, panel-relative. *)
let layout_panel (panel_node : Yojson.Safe.t) (avail_w : int) : Yojson.Safe.t =
  match mem "content" panel_node with
  | `Assoc _ as root ->
    let _w, _h, items = measure root [] avail_w in
    `List
      (List.map (fun it ->
         `Assoc
           [ ("path", `List (List.map (fun i -> `Int i) it.path));
             ("rect",
              `Assoc
                [ ("x", `Int it.x); ("y", `Int it.y);
                  ("w", `Int it.w); ("h", `Int it.h) ]) ])
        items)
  | _ -> `List []
